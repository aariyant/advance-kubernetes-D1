#!/bin/bash

# Global Variables
KUBE_VERSION=1.32.5

set -e

usage() {
  echo "Usage: $0 [mode] [args...]"
  echo "Modes:"
  echo "  initial_cluster <hostname> <haproxy_ip>  Initialize a new cluster"
  echo "  add_master <hostname> <node_ip>          Add a new master node"
  echo "  add_worker <hostname> <node_ip>          Add a new worker node"
  echo "  install_haproxy <hostname>               Enable HAProxy load balancer"
  exit 1
}

minimal_setup(){
  local short_hostname=$1
  if [ -z "$short_hostname" ]; then echo "Hostname required"; exit 1; fi
  
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
  sed -i "/^127.0.0.1/s/$/ $short_hostname/" "/etc/hosts"
  hostnamectl set-hostname "$short_hostname"

  ### Kubernetes Repository Configuration
  cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.32/rpm/repodata/repomd.xml.key
EOF

  ### setup terminal and base tools
  dnf install -y bash-completion binutils vim-enhanced curl wget epel-release tar kubernetes-cni
  echo 'colorscheme ron' >> ~/.vimrc
  echo 'set tabstop=2' >> ~/.vimrc
  echo 'set shiftwidth=2' >> ~/.vimrc
  echo 'set expandtab' >> ~/.vimrc
  
  ### disable swap
  swapoff -a
  sed -i '/\sswap\s/ s/^\(.*\)$/#\1/g' /etc/fstab

  ### SELinux to Permissive
  setenforce 0
  sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

  ### Firewall
  systemctl stop firewalld || true
  systemctl disable firewalld || true

  ### Install Container Runtime (Containerd)
  sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  dnf makecache
  dnf install -y containerd.io
  systemctl enable --now containerd

  ### Install Nerdctl
  wget https://github.com/containerd/nerdctl/releases/download/v2.2.1/nerdctl-2.2.1-linux-${PLATFORM_ARCH}.tar.gz
  sudo tar Cxzvvf /usr/bin nerdctl-2.2.1-linux-${PLATFORM_ARCH}.tar.gz
  echo "source <(nerdctl completion bash)" >> ~/.bashrc
}

initial_setup(){
  local short_hostname=$1
  minimal_setup "$short_hostname"

  ### Setup K8s aliasing
  echo 'source <(kubectl completion bash)' >> ~/.bashrc
  echo 'alias k=kubectl' >> ~/.bashrc
  echo 'alias c=clear' >> ~/.bashrc
  echo 'complete -F __start_kubectl k' >> ~/.bashrc

  ### Cleanup existing installs
  kubeadm reset -f || true
  dnf remove -y kubelet kubeadm kubectl kubernetes-cni || true

  ### install podman
  dnf install -y podman
  cat > /etc/containers/registries.conf <<EOF
unqualified-search-registries = ["docker.io"]
[[registry]]
prefix = "docker.io"
location = "docker.io"
EOF

  dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes

  ### Load Kernel Modules for Containerd
  cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
  sudo modprobe overlay
  sudo modprobe br_netfilter
  sudo modprobe ip_tables

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

  ### Start services
  systemctl daemon-reload
  systemctl enable --now containerd
  systemctl enable --now kubelet
}

init_cluster(){
  local HAPROXY_IP=$1
  if [ -z "$HAPROXY_IP" ]; then echo "HAProxy IP required"; exit 1; fi

  ### Init K8s
  rm -rf /root/.kube/config || true
  if [ -f kubeadm-config.yaml ]; then
    kubeadm init --config kubeadm-config.yaml --skip-token-print
  else
    kubeadm init --kubernetes-version=${KUBE_VERSION} --control-plane-endpoint=${HAPROXY_IP}:6443 --ignore-preflight-errors=NumCPU --skip-token-print --pod-network-cidr 10.0.0.0/16 --apiserver-cert-extra-sans kubemaster01,kubemaster02,kubemaster03,kubelb
  fi

  mkdir -p ~/.kube
  sudo cp -i /etc/kubernetes/admin.conf ~/.kube/config
  chown $(id -u):$(id -g) ~/.kube/config

  ### get platform arch for CNI
  PLATFORM=`uname -p`
  PLATFORM_ARCH="amd64"
  if [ "${PLATFORM}" == "aarch64" ]; then PLATFORM_ARCH="arm64"; fi

  ### CNI
  # #### Weave
  # if [ "$PLATFORM_ARCH" == "arm64" ]; then
  #   kubectl apply -f https://raw.githubusercontent.com/aariyant/advance-kubernetes-D1/refs/heads/init/weave/weave-k8s-arm64.yaml
  # else
  #   kubectl apply -f https://raw.githubusercontent.com/aariyant/advance-kubernetes-D1/refs/heads/init/weave/weave-k8s.yaml
  # fi
  # kubectl -n kube-system wait --for=condition=Ready pod -l name=weave-net --timeout=3600s || true

  #### Calico
  kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
  kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=calico-node --timeout=3600s || true

  ### Finished
  echo
  echo "### COMMAND TO ADD A WORKER NODE ###"
  kubeadm token create --print-join-command
}

add_master(){
  local new_hostname=$1
  local new_node=$2

  if [ -z "$new_hostname" ] || [ -z "$new_node" ]; then usage; fi

  set -ex
  echo "### Running initial_setup on ${new_node} ###"
  scp -o StrictHostKeyChecking=no "$0" "${new_node}:~/"
  scp -r /etc/kubernetes/pki "${new_node}:/tmp/"

  echo "### Syncing PKI certificates ###"
  ssh "${new_node}" "sudo mkdir -p /etc/kubernetes"
  ssh -o StrictHostKeyChecking=no "${new_node}" "bash ~/$0 initial_setup ${new_hostname} && sudo cp -rp /tmp/pki /etc/kubernetes/ && sudo chown -R root:root /etc/kubernetes/pki"

  echo "### Joining as control-plane ###"
  certificate_key=$(kubeadm init phase upload-certs --upload-certs | tail -1)
  join_command=$(kubeadm token create --print-join-command)
  # echo "sudo ${join_command} --control-plane --certificate-key ${certificate_key} --apiserver-advertise-address ${new_node}"
  ssh -o StrictHostKeyChecking=no "${new_node}" "sudo ${join_command} --control-plane --certificate-key ${certificate_key} --apiserver-advertise-address ${new_node}"
}

add_worker() {
  local new_hostname=$1
  local new_node=$2

  if [ -z "$new_hostname" ] || [ -z "$new_node" ]; then usage; fi

  set -ex
  echo "### Running initial_setup on ${new_node} ###"
  scp -o StrictHostKeyChecking=no "$0" "${new_node}:~//"
  ssh -o StrictHostKeyChecking=no "${new_node}" "bash ~/$0 initial_setup ${new_hostname}"

  echo "### Joining as worker ###"
  join_command=$(kubeadm token create --print-join-command)
  echo "sudo ${join_command}"
  # ssh -o StrictHostKeyChecking=no "${new_node}" "sudo ${join_command}"
}

install_haproxy() {
  local short_hostname=$1
  if [ -z "$short_hostname" ]; then echo "Hostname required"; exit 1; fi

  set -ex
  minimal_setup "$short_hostname"

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
}

# Main Logic
MODE=$1
shift

case "$MODE" in
  initial_setup)
    initial_setup "$1"
    ;;
  initial_cluster)
    echo "init $1 $2"
    initial_setup "$1"
    init_cluster "$2"
    ;;
  add_master)
    echo "add $1 $2"
    add_master "$1" "$2"
    ;;
  add_worker)
    echo "add $1 $2"
    add_worker "$1" "$2"
    ;;
  install_haproxy)
    echo "install haproxy"
    install_haproxy "$1"
    ;;
  *)
    usage
    ;;
esac