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
short_hostname=$1
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

systemctl enable --now containerd
systemctl start containerd

### Install Nerdctl
wget https://github.com/containerd/nerdctl/releases/download/v2.2.1/nerdctl-2.2.1-linux-${ARCH}.tar.gz
sudo tar Cxzvvf /usr/bin nerdctl-2.2.1-linux-${ARCH}.tar.gz
echo "source <(nerdctl completion bash)" >> ~/.bashrc

### Configure Haproxy
mkdir -p haproxy && cd haproxy
cat <<EOF | sudo tee haproxy.cfg
frontend kubernetes-frontend
    bind *:6443
    mode tcp
    option tcplog
    default_backend kubernetes-backend

frontend stats
    mode http
    bind :8404
    stats enable
    stats refresh 10s
    stats uri /stats
    stats show-modules

backend kubernetes-backend
    mode tcp
    option tcp-check
    balance roundrobin
    server kubemaster01 192.168.51.101:6443 check
    server kubemaster02 192.168.51.102:6443 check
    server kubemaster03 192.168.51.103:6443 check
EOF

### Create compose
cat <<EOF | sudo tee docker-compose.yml
version: '3.8'
services:
  haproxy:
    image: haproxy:latest
    ports:
      - "6443:6443"
      - "8404:8404"
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg
EOF

### Start compose
nerdctl compose up -d