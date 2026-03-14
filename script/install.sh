#!/bin/bash

# Global Variables
KUBE_VERSION=1.32.5

set -e

usage() {
  echo "Usage: $0 [mode] [args...]"
  echo "Modes:"
  echo "  initial_cluster <hostname> <haproxy_ip> <node_ip> [sans...]  Initialize a new cluster"
  echo "  add_master <hostname> <node_ip> [sans...]                    Add a new master node"
  echo "  add_worker <hostname> <node_ip>                              Add a new worker node"
  echo "  install_haproxy <hostname> [master_name:ip...]               Enable HAProxy load balancer"
  echo ""
  echo "Examples:"
  echo "  $0 initial_cluster kubemaster01 192.168.51.100 192.168.51.101 kubemaster02 kubemaster03 kubelb 192.168.51.102 192.168.51.103"
  echo "  $0 initial_cluster kubemaster01 192.168.51.100 192.168.51.101 kubemaster02,kubemaster03,kubelb,192.168.51.102,192.168.51.103"
  echo "  $0 install_haproxy kubelb kubemaster01:192.168.131.101 kubemaster02:192.168.131.102 kubemaster03:192.168.131.103"
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
  sed -i "/^127.0.0.1/s/$/ $short_hostname/" "/etc/hosts" || true
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
  sudo sed -i 's/disabled_plugins = \[\]/enabled_plugins = \["cri"\]/g' /etc/containerd/config.toml

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
  systemctl restart containerd
  systemctl enable --now kubelet
  systemctl restart kubelet
}

init_cluster(){
  local HOSTNAME=$1
  local HAPROXY_IP=$2
  local NODE_IP=$3
  shift 3
  local EXTRA_SANS=("$@")

  if [ -z "$HAPROXY_IP" ]; then echo "HAProxy IP required"; exit 1; fi
  if [ -z "$NODE_IP" ]; then echo "Node IP required"; exit 1; fi

  local SAN_LIST="  - ${HOSTNAME}
  - ${HAPROXY_IP}
  - ${NODE_IP}"
  
  for san in "${EXTRA_SANS[@]}"; do
    IFS=',' read -ra S_ARR <<< "$san"
    for s in "${S_ARR[@]}"; do
      SAN_LIST="${SAN_LIST}
  - ${s}"
    done
  done

  local ETCD_SAN_LIST="    - ${HOSTNAME}
    - ${HAPROXY_IP}
    - ${NODE_IP}"
    
  for san in "${EXTRA_SANS[@]}"; do
    IFS=',' read -ra S_ARR <<< "$san"
    for s in "${S_ARR[@]}"; do
      ETCD_SAN_LIST="${ETCD_SAN_LIST}
    - ${s}"
    done
  done

  cat <<EOF > kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${NODE_IP}
  bindPort: 6443
nodeRegistration:
  name: ${HOSTNAME}
---
apiServer:
  certSANs:
${SAN_LIST}
apiVersion: kubeadm.k8s.io/v1beta4
caCertificateValidityPeriod: 87600h0m0s
certificateValidityPeriod: 8760h0m0s
certificatesDir: /etc/kubernetes/pki
clusterName: kubernetes
controlPlaneEndpoint: ${HAPROXY_IP}:6443
controllerManager: {}
dns: {}
encryptionAlgorithm: RSA-2048
etcd:
  local:
    dataDir: /var/lib/etcd
    serverCertSANs:
${ETCD_SAN_LIST}
    peerCertSANs:
${ETCD_SAN_LIST}
imageRepository: registry.k8s.io
kind: ClusterConfiguration
kubernetesVersion: v${KUBE_VERSION}
networking:
  dnsDomain: cluster.local
  podSubnet: 10.0.0.0/16
  serviceSubnet: 10.96.0.0/12
proxy: {}
scheduler: {}
EOF

  ### Init K8s
  rm -rf /root/.kube/config || true
  kubeadm init --config kubeadm-config.yaml --skip-token-print

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
  shift 2
  local EXTRA_SANS=("$@")

  if [ -z "$new_hostname" ] || [ -z "$new_node" ]; then usage; fi

  set -ex
  
  echo "### Updating SANs in kubeadm config map (if any) ###"
  if [ ${#EXTRA_SANS[@]} -gt 0 ]; then
    kubectl get configmap kubeadm-config -n kube-system -o yaml > /tmp/kubeadm-config.yaml
    
    # Process extra SANs to append
    for san in "${EXTRA_SANS[@]}"; do
      IFS=',' read -ra S_ARR <<< "$san"
      for s in "${S_ARR[@]}"; do
        # Add to certSANs if not exists
        if ! grep -q "\- $s" /tmp/kubeadm-config.yaml; then
          sed -i "/certSANs:/a\      - $s" /tmp/kubeadm-config.yaml
          sed -i "/serverCertSANs:/a\        - $s" /tmp/kubeadm-config.yaml
          sed -i "/peerCertSANs:/a\        - $s" /tmp/kubeadm-config.yaml
        fi
      done
    done
    
    # Apply updated config map
    kubectl apply -f /tmp/kubeadm-config.yaml
    
    # Regenerate certs on current master to include new SANs before uploading
    kubeadm init phase certs apiserver --config /tmp/kubeadm-config.yaml
    kubeadm init phase certs etcd-server --config /tmp/kubeadm-config.yaml
    kubeadm init phase certs etcd-peer --config /tmp/kubeadm-config.yaml
    
    # Restart apiserver & etcd to apply new certs locally
    docker rm -f $(docker ps -q -f 'name=k8s_kube-apiserver') || true
    docker rm -f $(docker ps -q -f 'name=k8s_etcd') || true
    crictl rm -f $(crictl ps -q --name kube-apiserver) || true
    crictl rm -f $(crictl ps -q --name etcd) || true
    sleep 5
  fi

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
  # echo "sudo ${join_command}"
  ssh -o StrictHostKeyChecking=no "${new_node}" "sudo ${join_command}"
}

install_haproxy() {
  local short_hostname=$1
  shift
  local MASTERS=("$@")

  if [ -z "$short_hostname" ]; then echo "Hostname required"; exit 1; fi
  if [ ${#MASTERS[@]} -eq 0 ]; then echo "At least one master node (name:ip) is required"; exit 1; fi

  set -ex
  minimal_setup "$short_hostname"

  ### Build HAProxy Backend Config
  local BACKEND_SERVERS=""
  for master in "${MASTERS[@]}"; do
    IFS=':' read -r m_name m_ip <<< "$master"
    if [ -z "$m_name" ] || [ -z "$m_ip" ]; then
      echo "Invalid master format: $master. Expected name:ip"
      exit 1
    fi
    BACKEND_SERVERS="${BACKEND_SERVERS}
    server ${m_name} ${m_ip}:6443 check"
  done

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
    balance roundrobin${BACKEND_SERVERS}
EOF

  ### Create compose
  cat <<EOF | sudo tee docker-compose.yml
version: '3.8'
services:
  haproxy:
    image: haproxy:latest
    restart: always
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
    echo "init $1 $2 $3 ${@:4}"
    if [ -z "$2" ]; then echo 'HAProxy IP required' && exit 1; fi
    if [ -z "$3" ]; then echo 'Node IP required' && exit 1; fi
    initial_setup "$1"
    init_cluster "$@"
    ;;
  add_master)
    echo "add $1 $2 ${@:3}"
    add_master "$@"
    ;;
  add_worker)
    echo "add $1 $2"
    add_worker "$1" "$2"
    ;;
  install_haproxy)
    echo "install haproxy $1 ${@:2}"
    install_haproxy "$@"
    ;;
  *)
    usage
    ;;
esac