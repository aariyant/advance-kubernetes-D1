# Kubernetes High Availability (HA) Cluster Setup
---
This guide provides step-by-step instructions for setting up a High Availability (HA) Kubernetes Cluster using `kubeadm` with a stacked `etcd` topology. This setup includes multiple control-plane nodes and a load balancer to ensure the API server is always accessible.

## HA Architecture (Stacked etcd)
In this topology, the `etcd` members are co-located on the same nodes as the control plane components. Each control plane node runs an instance of `kube-apiserver`, `kube-scheduler`, `kube-controller-manager`, and `etcd`.

- **Nodes**:
    - `kubelb`: Load Balancer (HAProxy) - `192.168.56.100`
    - `kubemaster01`: Control Plane 1 - `192.168.56.101`
    - `kubemaster02`: Control Plane 2 - `192.168.56.102`
    - `kubemaster03`: Control Plane 3 - `192.168.56.103`
    - `kubenode01`: Worker Node 1 - `192.168.56.111`
    - `kubenode02`: Worker Node 2 - `192.168.56.112`
- **Specification**:

| Role          | Host Name      | IP            | OS            | RAM   | CPU |
|---------------|----------------|---------------|---------------|-------|-----|
| Load Balancer | kubelb         | 192.168.56.100 | Rocky Linux 9 | 1G    | 2   |
| Control Plane | kubemaster01   | 192.168.56.101 | Rocky Linux 9 | 2G    | 2   |
| Control Plane | kubemaster02   | 192.168.56.102 | Rocky Linux 9 | 2G    | 2   |
| Control Plane | kubemaster03   | 192.168.56.103 | Rocky Linux 9 | 2G    | 2   |
| Worker        | kubenode01     | 192.168.56.111 | Rocky Linux 9 | 2G    | 2   |
| Worker        | kubenode02     | 192.168.56.112 | Rocky Linux 9 | 2G    | 2   |

---

## Pre-requirements
- Vagrant & VirtualBox
- Basic knowledge of Kubernetes components
- Access to terminal

---

## 1. Infrastructure Setup (Vagrant)

Create a `Vagrantfile` in your working directory and run `vagrant up`.

<details>
<summary><b><font size="4">Vagrantfile</font></b></summary>
<p>

```ruby
# -*- mode: ruby -*-
# vi:set ft=ruby sw=2 ts=2 sts=2:

Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/bionic64"
  
  # Load Balancer
  config.vm.define "kubelb" do |lb|
    lb.vm.hostname = "kubelb"
    lb.vm.network "private_network", ip: "192.168.56.10"
    lb.vm.provider "virtualbox" do |vb|
      vb.memory = "1024"
      vb.cpus = 1
    end
  end

  # Control Plane Nodes
  (1..3).each do |i|
    config.vm.define "kubemaster0#{i}" do |master|
      master.vm.hostname = "kubemaster0#{i}"
      master.vm.network "private_network", ip: "192.168.56.1#{i}"
      master.vm.provider "virtualbox" do |vb|
        vb.memory = "2048"
        vb.cpus = 2
      end
    end
  end

  # Worker Nodes
  (1..2).each do |i|
    config.vm.define "kubenode0#{i}" do |node|
      node.vm.hostname = "kubenode0#{i}"
      node.vm.network "private_network", ip: "192.168.56.2#{i}"
      node.vm.provider "virtualbox" do |vb|
        vb.memory = "2048"
        vb.cpus = 2
      end
    end
  end
end
```
</p>
</details>

```shell
vagrant up
```

---

## 2. Load Balancer Setup (HAProxy) - Control Plane HA

> [!NOTE]
> This external Load Balancer is used specifically for the **Kubernetes Control Plane (API Server)**. It must be configured *before* cluster initialization so that `kubeadm` has a stable virtual IP for the API Server.

Login to `kubelb` and setup HAProxy using Docker Compose.

### Install Docker on kubelb
```shell
vagrant ssh kubelb
sudo apt update && sudo apt install -y docker.io docker-compose
```

### Create HAProxy Configuration
Create a directory for HAProxy and the configuration file `haproxy.cfg`:

```shell
mkdir ~/haproxy && cd ~/haproxy
```

**haproxy.cfg**:
```haproxy
frontend kubernetes-frontend
    bind *:6443
    mode tcp
    option tcplog
    default_backend kubernetes-backend

backend kubernetes-backend
    mode tcp
    option tcp-check
    balance roundrobin
    server kubemaster01 192.168.56.11:6443 check
    server kubemaster02 192.168.56.12:6443 check
    server kubemaster03 192.168.56.13:6443 check
```

### Create Docker Compose File
**docker-compose.yml**:
```yaml
version: '3'

services:
  haproxy:
    image: haproxy:2.8
    container_name: haproxy
    ports:
      - "6443:6443"
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    restart: always
```

### Start HAProxy
```shell
sudo docker-compose up -d
sudo docker ps
```

---

## 3. Preparing All Nodes (Master & Workers)

On **all** nodes (except `kubelb`), install the CRI (Docker + cri-dockerd) and Kubernetes tools (kubeadm, kubelet, kubectl). Refer to the [main guide](kubernetes-D1) for installation steps.

> [!IMPORTANT]
> Ensure all nodes have the same versions of kubeadm, kubelet, and kubectl.

---

## 4. Bootstrapping the HA Cluster

### Initialize the first Control Plane Node
Login to `kubemaster01`:
```shell
vagrant ssh kubemaster01
```

Run `kubeadm init` with the `--control-plane-endpoint` pointing to the Load Balancer IP:
```shell
sudo kubeadm init --control-plane-endpoint "192.168.56.10:6443" --upload-certs --pod-network-cidr=192.168.0.0/16
```

> [!TIP]
> `--upload-certs` is used to share certificates among control-plane nodes automatically.

### Configure kubectl for the first node
```shell
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### Install Weave Net CNI
```shell
kubectl apply -f https://raw.githubusercontent.com/killer-sh/cks-course-environment/master/cluster-setup/weave.yaml
```

---

## 5. Joining Additional Control Plane Nodes

After `kubeadm init` finishes, it will provide a join command for other control plane nodes. It looks like this:

```shell
sudo kubeadm join 192.168.56.10:6443 --token <token> \
    --discovery-token-ca-cert-hash sha256:<hash> \
    --control-plane --certificate-key <key>
```

Run this command on `kubemaster02` and `kubemaster03`.

---

## 6. Joining Worker Nodes

Use the worker join command provided in the `kubeadm init` output:

```shell
sudo kubeadm join 192.168.56.10:6443 --token <token> \
    --discovery-token-ca-cert-hash sha256:<hash>
```

Run this command on `kubenode01` and `kubenode02`.

---

## 7. Verification

Check the status of all nodes from `kubemaster01`:
```shell
kubectl get nodes
```

Expected output:
```text
NAME           STATUS   ROLES           AGE     VERSION
kubemaster01   Ready    control-plane   10m     v1.31.0
kubemaster02   Ready    control-plane   8m      v1.31.0
kubemaster03   Ready    control-plane   8m      v1.31.0
kubenode01     Ready    <none>          5m      v1.31.0
kubenode02     Ready    <none>          5m      v1.31.0
```

### Test High Availability
1. Stop the `kubemaster01` VM: `vagrant halt kubemaster01`.
2. Try running `kubectl get nodes` from `kubemaster02` or `kubemaster03`.
3. The cluster should still be operational because traffic is routed through the Load Balancer to the remaining healthy control plane nodes.

---

## 8. Service Load Balancing with MetalLB

While HAProxy handles the Control Plane HA, **MetalLB** is used to provide `Type: LoadBalancer` support for your applications running *inside* the cluster.

### Install MetalLB
Run these commands from your control plane node:

```shell
# 1. Update your kube-proxy configuration to enable ARP
kubectl edit configmap -n kube-system kube-proxy
# Set: strictARP: true

# 2. Deploy MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
```

### Configure IP Address Pool
Create `metallb-config.yaml` to define the range of IPs MetalLB can assign to services. Use IPs that are in your `192.168.56.x` range but not used by your VMs.

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.56.100-192.168.56.200
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: layer2-adv
  namespace: metallb-system
```

Apply the config:
```shell
kubectl apply -f metallb-config.yaml
```

### Verify with an Nginx Service
Deploy a sample application and expose it via MetalLB:

```shell
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80 --type=LoadBalancer
```

Check the external IP:
```shell
kubectl get svc
```

Expected output:
```text
NAME         TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)        AGE
nginx        LoadBalancer   10.103.1.200    192.168.56.100   80:32145/TCP   10s
```

You should now be able to access Nginx from your host machine at `http://192.168.56.100`.

---
# Resources, Limits, and Quotas

Managing cluster resources is critical for stability and efficiency.

## Resource Requests and Limits
When you define a Pod, you can specify how much CPU and memory each container needs.
- **Requests**: Minimum resource guaranteed for the container.
- **Limits**: Maximum resource the container is allowed to consume.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: resource-demo
spec:
  containers:
  - name: nginx
    image: nginx
    resources:
      requests:
        memory: "64Mi"
        cpu: "250m"
      limits:
        memory: "128Mi"
        cpu: "500m"
```

## LimitRange
Use a **LimitRange** to enforce default resource requests/limits and constraints within a namespace.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: cpu-min-max-demo-lr
spec:
  limits:
  - max:
      cpu: "800m"
      memory: "1Gi"
    min:
      cpu: "100m"
      memory: "100Mi"
    type: Container
```

## ResourceQuota
Use a **ResourceQuota** to limit the total resource consumption in a namespace.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: mem-cpu-demo
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
    pods: "10"
```

---
**Congratulations!** You have successfully setup a Kubernetes HA cluster with MetalLB and learned how to manage cluster resources.
---
# Kubernetes Scheduling Strategies
---
This guide covers advanced scheduling techniques in Kubernetes to control how Pods are assigned to nodes. These strategies allow you to isolate workloads, ensure high availability, and optimize resource usage.

## 1. NodeSelector
The simplest way to constrain a Pod to run on particular nodes. It uses labels on nodes and matches them with the `nodeSelector` field in the Pod specification.

**Label a node**:
```shell
kubectl label nodes <node-name> disktype=ssd
```

**Pod definition**:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
spec:
  containers:
  - name: nginx
    image: nginx
  nodeSelector:
    disktype: ssd
```

---

## 2. Taints and Tolerations
Taints allow a node to **repel** a set of pods. Tolerations are applied to pods, and allow (but do not require) the pods to schedule onto nodes with matching taints.

**Apply a taint to a node**:
```shell
kubectl taint nodes <node-name> key=value:NoSchedule
```
Effects:
- `NoSchedule`: No new pods will be scheduled unless they tolerate the taint.
- `PreferNoSchedule`: System will try to avoid placement but it's not guaranteed.
- `NoExecute`: Existing pods will be evicted if they don't tolerate the taint.

**Pod with Toleration**:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
spec:
  containers:
  - name: nginx
    image: nginx
  tolerations:
  - key: "key"
    operator: "Equal"
    value: "value"
    effect: "NoSchedule"
```

---

## 3. Node Affinity
Node affinity is conceptually similar to `nodeSelector` but it's more expressive.

- `requiredDuringSchedulingIgnoredDuringExecution`: Hard requirement (must be met).
- `preferredDuringSchedulingIgnoredDuringExecution`: Soft requirement (best effort).

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: affinity-pod
spec:
  containers:
  - name: nginx
    image: nginx
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: kubernetes.io/os
            operator: In
            values:
            - linux
```

---

## 4. Pod Affinity and Anti-affinity
Allows you to constrain which nodes your pod is eligible to be scheduled based on labels on pods that are **already running** on the node.

- **Pod Affinity**: "Run this pod near pods that have label X".
- **Pod Anti-affinity**: "Don't run this pod near pods that have label X".

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: anti-affinity-pod
spec:
  containers:
  - name: nginx
    image: nginx
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: app
            operator: In
            values:
            - store
        topologyKey: "kubernetes.io/hostname"
```

---
**Congratulations!** You've learned how to control Pod placement using advanced scheduling strategies.
---
# Kubernetes Jobs and CronJobs
---
This guide covers how to run batch workloads and scheduled tasks in Kubernetes using Jobs and CronJobs.

## 1. Jobs
A Job creates one or more Pods and ensures that a specified number of them successfully terminate. It is used for finite tasks like data processing or migrations.

### Basic Job definition
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: pi
spec:
  template:
    spec:
      containers:
      - name: pi
        image: perl:5.34
        command: ["perl",  "-Mbignum=bpi", "-wle", "print bpi(2000)"]
      restartPolicy: Never
  backoffLimit: 4
```

### Completions and Parallelism
- `completions`: The number of successfully finished pods needed to satisfy the Job.
- `parallelism`: The maximum number of pods that should run at once.

```yaml
spec:
  completions: 5
  parallelism: 2
```

---

## 2. CronJobs
A CronJob manages time-based Jobs. One CronJob object is like one line of a crontab (cron table) file.

### Basic CronJob definition
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: hello
spec:
  schedule: "* * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: hello
            image: busybox:1.28
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - date; echo Hello from the Kubernetes cluster
          restartPolicy: OnFailure
```

### Schedule Syntax
The schedule is in standard cron format:
`# ┌───────────── minute (0 - 59)`
`# │ ┌───────────── hour (0 - 23)`
`# │ │ ┌───────────── day of the month (1 - 31)`
`# │ │ │ ┌───────────── month (1 - 12)`
`# │ │ │ │ ┌───────────── day of the week (0 - 6) (Sunday to Saturday)`
`# │ │ │ │ │`
`# * * * * *`

### History Limits
- `successfulJobsHistoryLimit`: Number of successful finished jobs to retain (default 3).
- `failedJobsHistoryLimit`: Number of failed finished jobs to retain (default 1).

```yaml
spec:
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
```

---
**Congratulations!** You've learned how to manage batch and scheduled tasks in Kubernetes.
