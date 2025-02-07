# Auto Install Single Node Kubernetes

This is a script for installing single node Kubernetes cluster on Ubuntu 22.04.

This is created to automatically install single node Kubernetes cluster when provisioning an instance/VM (e.g. in AWS, Azure, or vCenter).
The instance that is used to run this script uses px-admin-<random_text> as sudo user name.

The script writes its logs to /var/log/syslog with "K8S-SETUP" tags.

