#!/bin/bash

# Source: https://kubernetes.io/docs/reference/setup-tools/kubeadm
KUBE_VERSION=1.32.5

set -e

### Verify Rocky Linux version
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" != "rocky" ]; then
        echo "################################# "
        echo "############ WARNING ############ "
        echo "################################# "
        echo "This script is intended for Rocky Linux!"
        echo "You're using: ${PRETTY_NAME}"
        echo "Better ABORT with Ctrl+C. Or press any key to continue."
        read
    fi
fi

### Get platform architecture
PLATFORM=$(uname -p)
if [ "${PLATFORM}" == "aarch64" ]; then
  ARCH="arm64"
elif [ "${PLATFORM}" == "x86_64" ]; then
  ARCH="amd64"
else
  echo "Unsupported architecture: ${PLATFORM}"
  exit 1
fi

### Set hostname
short_hostname=$(hostname | cut -d. -f1)
hostnamectl set-hostname "$short_hostname"

### Setup terminal and base tools
dnf install -y bash-completion binutils vim-enhanced curl wget
echo 'colorscheme ron' >> ~/.vimrc
echo 'set tabstop=2' >> ~/.vimrc
echo 'set shiftwidth=2' >> ~/.vimrc
echo 'set expandtab' >> ~/.vimrc
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'alias c=clear' >> ~/.bashrc
echo 'complete -F __start_kubectl k' >> ~/.bashrc

### Disable Linux swap
swapoff -a
sed -i '/\sswap\s/ s/^\(.*\)$/#\1/g' /etc/fstab

### SELinux to Permissive (Required for K8s)
# This allows containers to access the host filesystem, which is required by CNI plugins.
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

### Remove existing packages
kubeadm reset -f || true
dnf remove -y kubelet kubeadm kubectl kubernetes-cni containerd podman || true
rm -rf /etc/containerd/*
systemctl daemon-reload

### Install Podman
dnf install -y podman
cat > /etc/containers/registries.conf <<EOF
unqualified-search-registries = ["docker.io"]
[[registry]]
prefix = "docker.io"
location = "docker.io"
EOF

### Kubernetes Repository Configuration
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/repodata/repomd.xml.key
EOF

sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

dnf makecache
dnf install -y containerd.io kubelet kubeadm kubectl --disableexcludes=kubernetes

### Configure Containerd modules
cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

### Network sysctl settings
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system

### Containerd Config
mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
# Ensure SystemdCgroup is enabled for Rocky Linux stability
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

### crictl config
cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
EOF

### Disable Firewalld (Commonly blocks node communication)
systemctl stop firewalld || true
systemctl disable firewalld || true

### Start services
systemctl daemon-reload
systemctl enable --now containerd
systemctl enable --now kubelet

### Final Cleanup before joining
kubeadm reset -f
systemctl daemon-reload
systemctl restart kubelet

echo
echo "------------------------------------------------------------"
echo "DONE! Your Rocky Linux node is ready."
echo "EXECUTE ON MASTER: kubeadm token create --print-join-command --ttl 0"
echo "THEN RUN THE OUTPUT AS A COMMAND HERE TO JOIN THE CLUSTER"
echo "------------------------------------------------------------"