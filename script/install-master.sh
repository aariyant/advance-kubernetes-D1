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

### get platform
PLATFORM=`uname -p`
if [ "${PLATFORM}" == "aarch64" ]; then
  PLATFORM_ARCH="arm64"
elif [ "${PLATFORM}" == "x86_64" ]; then
  PLATFORM_ARCH="amd64"
else
  echo "Unsupported architecture"
  exit 1
fi

### set hostname
short_hostname=$(hostname | cut -d. -f1)
hostnamectl set-hostname "$short_hostname"

### setup terminal and base tools
dnf install -y bash-completion binutils vim-enhanced curl wget
echo 'colorscheme ron' >> ~/.vimrc
echo 'set tabstop=2' >> ~/.vimrc
echo 'set shiftwidth=2' >> ~/.vimrc
echo 'set expandtab' >> ~/.vimrc
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'alias c=clear' >> ~/.bashrc
echo 'complete -F __start_kubectl k' >> ~/.bashrc

### disable swap
swapoff -a
sed -i '/\sswap\s/ s/^\(.*\)$/#\1/g' /etc/fstab

### SELinux to Permissive (Required for K8s on RHEL)
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

### Cleanup existing installs
kubeadm reset -f || true
dnf remove -y kubelet kubeadm kubectl kubernetes-cni containerd podman || true
rm -rf /etc/containerd/*

### install podman
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

dnf makecache
dnf install -y containerd.io kubelet kubeadm kubectl --disableexcludes=kubernetes

### Load Kernel Modules for Containerd
cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

### Networking sysctl
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system

### Containerd Config
mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
# Set SystemdCgroup to true (Critical for RHEL/Rocky)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

### crictl config
cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

### Firewall (Commonly blocks K8s on Rocky)
systemctl stop firewalld || true
systemctl disable firewalld || true

### Start services
systemctl daemon-reload
systemctl enable --now containerd
systemctl enable --now kubelet

### Init K8s
rm -rf /root/.kube/config || true
kubeadm init --kubernetes-version=${KUBE_VERSION} --ignore-preflight-errors=NumCPU --skip-token-print --pod-network-cidr 192.168.0.0/16

mkdir -p ~/.kube
sudo cp -i /etc/kubernetes/admin.conf ~/.kube/config
chown $(id -u):$(id -g) ~/.kube/config

### CNI (Using standard Flannel as Weave is legacy, but kept your link)
kubectl apply -f https://raw.githubusercontent.com/killer-sh/cks-course-environment/master/cluster-setup/weave.yaml

echo "Waiting for network to be ready..."
sleep 15
kubectl -n kube-system wait --for=condition=Ready pod -l name=weave-net --timeout=3600s || true

### Finished
echo
echo "### COMMAND TO ADD A WORKER NODE ###"
kubeadm token create --print-join-command --ttl 0