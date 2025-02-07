#!/bin/bash

set -e  # Exit immediately on error
set -o pipefail  # Fail if any command in a pipeline fails

LOG_TAG="K8S-SETUP"

log() {
    echo "$1" | tee >(logger -t "$LOG_TAG")
}

exec > >(tee >(logger -t "$LOG_TAG")) 2>&1  # Redirect all output to syslog and terminal

log "====> Checking Operating System..."

# Load OS details
if [[ -f "/etc/os-release" ]]; then
    source /etc/os-release
else
    log "ERROR: Unable to detect OS. Exiting."
    exit 1
fi

# Ensure it's Ubuntu 22.04
if [[ "$ID" != "ubuntu" || "$VERSION_ID" != "22.04" ]]; then
    log "ERROR: This script only supports Ubuntu 22.04. Detected OS: $PRETTY_NAME"
    exit 1
fi

log "====> Starting Kubernetes single-node installation..."

export DEBIAN_FRONTEND=noninteractive  # Prevents all apt-get prompts

log "====> Updating system and installing dependencies..."
apt-get update -qq && apt-get install -yq apt-transport-https ca-certificates curl gnupg

log "====> Configuring kernel modules..."
cat <<EOF | tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

log "====> Configuring sysctl settings for Kubernetes networking..."
cat <<EOF | tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl --system

log "====> Installing containerd..."
apt-get install -yq containerd

log "====> Configuring containerd with systemd cgroup driver..."
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

log "====> Disabling swap (required for Kubernetes)..."
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

log "====> Adding Kubernetes GPG Key and Repository..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg
chmod u+rw,g+r,o+r /etc/apt/keyrings/kubernetes-archive-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

log "====> Updating package list..."
apt-get update -qq

log "====> Installing Kubernetes components..."
apt-get install -yq kubelet kubeadm kubectl cri-tools
apt-mark hold kubelet kubeadm kubectl

# Check if Kubernetes is already initialized
if [ -f "/etc/kubernetes/manifests/kube-apiserver.yaml" ]; then
    log "====> Kubernetes is already initialized. Resetting cluster..."
    kubeadm reset -f
    rm -rf /etc/cni/net.d
    rm -rf /var/lib/etcd
    log "====> Kubernetes cluster reset complete."
fi

log "====> Initializing Kubernetes cluster..."
kubeadm init --pod-network-cidr=192.168.0.0/16 | tee /root/kubeadm-init.log
log "====> Kubernetes cluster initialized."

log "====> Configuring kubectl for user..."

mkdir -p /root/.kube
cp -i /etc/kubernetes/admin.conf /root/.kube/config

grep '^px-admin' /etc/passwd | awk -F: '{print $1}' | while read user; do
   log "====> Configuring kubectl for the $user user..."
   mkdir -p /home/$user/.kube
   cp -f /etc/kubernetes/admin.conf /home/$user/.kube/config
   chown -R $user:$user /home/$user/.kube
    log "Copied .kube config to $user's home directory."
done

sleep 5

log "====> Installing Calico network plugin..."
log "====> $user user will execute the command.."
su - $user -c "kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml"

log "====> Allowing scheduling of pods on the control plane..."
su - $user -c "kubectl taint nodes --all node-role.kubernetes.io/control-plane-"

log "====> Enabling kubectl auto-completion for $user user..."
echo 'source <(kubectl completion bash)' >> /home/$user/.bashrc

log "====> Kubernetes single-node cluster setup complete!"
sleep 5

log "====> Check pods and nodes"
su - $user -c "kubectl get nodes"
su - $user -c "kubectl get pods -A"

log "====> Kubernetes setup completed successfully!"
log "====> Installing helm…"
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

exit 0
