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
    - `kubeworker01`: Worker Node 1 - `192.168.56.111`
    - `kubeworker02`: Worker Node 2 - `192.168.56.112`
- **Specification**:

| Role          | Host Name      | IP            | OS            | RAM   | CPU |
|---------------|----------------|---------------|---------------|-------|-----|
| Load Balancer | kubelb         | 192.168.56.100 | Rocky Linux 9 | 1G    | 2   |
| Control Plane | kubemaster01   | 192.168.56.101 | Rocky Linux 9 | 2G    | 2   |
| Control Plane | kubemaster02   | 192.168.56.102 | Rocky Linux 9 | 2G    | 2   |
| Control Plane | kubemaster03   | 192.168.56.103 | Rocky Linux 9 | 2G    | 2   |
| Worker        | kubeworker01     | 192.168.56.111 | Rocky Linux 9 | 2G    | 2   |
| Worker        | kubeworker02     | 192.168.56.112 | Rocky Linux 9 | 2G    | 2   |

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
    config.vm.define "kubeworker0#{i}" do |node|
      node.vm.hostname = "kubeworker0#{i}"
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

Run this command on `kubeworker01` and `kubeworker02`.

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
kubeworker01   Ready    <none>          5m      v1.31.0
kubeworker02   Ready    <none>          5m      v1.31.0
```

### Test High Availability
1. Stop the `kubemaster01` VM: `vagrant halt kubemaster01`.
2. Try running `kubectl get nodes` from `kubemaster02` or `kubemaster03`.
3. The cluster should still be operational because traffic is routed through the Load Balancer to the remaining healthy control plane nodes.

---

## 8. Service Load Balancing with MetalLB

While HAProxy handles the Control Plane HA, **MetalLB** is used to provide `Type: LoadBalancer` support for your applications running *inside* the cluster.

* __Install MetalLB__
Run these commands from your control plane node or any node with kubectl installed:

  * __Update kube-proxy configuration__
    ```shell
    kubectl edit configmap -n kube-system kube-proxy
    ```
    find and change this value:
    ```yaml
    apiVersion: v1
    data:
      config.conf: |-
        mode: ipvs
        strictARP: true
    ```

  * __Deploy MetalLB__
    ```shell
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
    ```

* __Configure IP Address Pool__
Create `metallb-config.yaml` to define the range of IPs MetalLB can assign to services. Use IPs that are in your `192.168.56.x` range but not used by your VMs.

  ```yaml
  apiVersion: metallb.io/v1beta1
  kind: IPAddressPool
  metadata:
    name: intranet
    namespace: metallb-system
  spec:
    addresses:
      - 192.168.56.10-192.168.56.99
    avoidBuggyIPs: true
  ---
  apiVersion: metallb.io/v1beta1
  kind: L2Advertisement
  metadata:
    name: layer2-intranet
    namespace: metallb-system
  spec:
    ipAddressPools:
      - intranet
  ```

  Apply the config:
  ```shell
  kubectl apply -f metallb-config.yaml
  ```

* __Verify with an Nginx Service__
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

* __Best Practices__
  - **Use meaningful pool names**: Name pools based on their purpose (e.g., `production-external`, `internal-services`)
  - **Disable auto-assign for production**: Require explicit pool selection for critical workloads
  - **Document IP ranges**: Maintain documentation of which IP ranges are used for what purpose
  - **Plan for growth**: Allocate larger ranges than immediately needed to avoid reconfiguration
  - **Use selectors**: Implement namespace and service selectors to prevent accidental IP allocation
  - **Monitor utilization**: Regularly check pool usage to avoid exhaustion
  - **Separate internal and external**: Use different pools for internal and external-facing services
  - **Test in non-production**: Validate pool configurations in development before production deployment

---
# Resources, Limits, and Quotas

Managing cluster resources is critical for stability and efficiency.

## Resource Requests and Limits
When you define a Pod, you can specify how much CPU and memory each container needs.
- **Requests**: Minimum resource guaranteed for the container.
- **Limits**: Maximum resource the container is allowed to consume.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-limits
  labels:
    app: nginx
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx-container
        image: nginx:latest
        resources:
          requests:
            memory: "64Mi"
            cpu: "250m"
          limits:
            memory: "128Mi"
            cpu: "501m"
```

## LimitRange
Use a **LimitRange** to enforce default resource requests/limits and constraints within a namespace.

### 1. Basic LimitRange
This LimitRange enforces default resource requests and limits for containers in a namespace `limit-range-basic.yaml`.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: basic-limit-range
  namespace: basic-limit-range
spec:
  limits:
  - default:
      cpu: "500m"
      memory: "256Mi"
    defaultRequest:
      cpu: "250m"
      memory: "128Mi"
    type: Container
```
This configuration sets the default Request to 250m CPU, 128Mi memory and default limit to 500m CPU, 256Mi memory.

### 2. Enforcing Minimum and Maximum Resource Constraints
This LimitRange restricts the range of CPU and memory resources for containers `limit-range-minimal-constraints.yaml`.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: range-limits
  namespace: default
spec:
  limits:
  - min:
      cpu: "100m"
      memory: "64Mi"
    max:
      cpu: "500m"
      memory: "500Mi"
    type: Container
```
With the above configuration, Containers must specify resource requests/limits(Min: 100m CPU, 64Mi memory) and Max(500m CPU, 500Mi memory). If it attempts to create containers outside this range, it results in an error.

### 3. Managing Pod Resource Limits
LimitRanges can also enforce total resource limits at the pod level `limit-range-pod.yaml`.
```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: limit-range-pod
  namespace: limit-range-pod
spec:
  limits:
  - max:
      cpu: "1"
      memory: "1Gi"
    type: Pod
```
With the above configuration, the total CPU and memory for a pod cannot exceed 4 cores and 4Gi memory. 

Create pod without resource limits or request `pod-no-resources.yaml`:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-no-resources
  namespace: default
spec:
  containers:
  - name: demo
    image: busybox
    command: ["sleep", "3600"]
```
Since Pod-level LimitRange (of type Pod) enforces that the total CPU and memory must be defined and within limits, the absence of these values causes the pod to be rejected.

Create pod that explicitly requests more resources than allowed `pod-out-of-range.yaml`:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-out-of-range
  namespace: default
spec:
  containers:
  - name: demo
    image: busybox
    command: ["sleep", "3600"]
    resources:
      requests:
        cpu: "5"      # Exceeds the pod limit of 4 CPU
        memory: "5Gi" # Exceeds the pod limit of 4Gi memory
      limits:
        cpu: "5"
        memory: "5Gi"
```

## ResourceQuota
Use a **ResourceQuota** to limit the total resource consumption in a namespace.

### 1. Basic Resource Quota
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: resource-quota-basic
  namespace: resource-quota-basic
spec:
  hard:
    pods: "2"
    requests.cpu: "500m"
    requests.memory: "500Mi"
    limits.cpu: "600m"
    limits.memory: "600Mi"
```
The above configuration sets quotas for CPU, memory, and the number of pods. In the given configuration, pods set the quota to 2 pods, requests.cpu and requests.memory set the total resource requests, limits.cpu and limits.memory define the maximum resource usage.

### 2. Scope-based Resource Quotas
You can restrict resource quotas to specific types of resources using scopes. For example, you can apply quotas to:

- Pods with no priority class
- Pods with a specific priority class
- Pods using cross-namespace affinity terms
- Resources related to specific storage classes

**Quota for Best-Effort Pods**
It limits the resources used by pods that do not specify resource requests or limits (Best-Effort pods).
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: resource-quota-best-effort
  namespace: resource-quota-best-effort
spec:
  hard:
    pods: "5"
  scopes:
  - BestEffort
```

**Quota for Pods with a Specific Priority Class**
It restricts pods with a specific priority class to ensure critical workloads have limited and controlled resource usage.
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: resource-quota-priority
  namespace: resource-quota-priority
spec:
  hard:
    pods: "2"
  scopeSelector:
    matchExpressions:
    - scopeName: PriorityClass
      operator: In
      values:
      - high
```
With this configuration, only 2 pods with the priority class high can be created in the namespace.

**Quota to Disable Cross-Namespace Pod Affinity**
Cross-Namespace Pod Affinity rule allows pods in one namespace to specify rules that depend on pods in another namespace. Disabling it prevents pods in a namespace from using cross-namespace affinity or anti-affinity.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: resource-quota-cross-namespace-affinity
  namespace: resource-quota-cross-namespace-affinity
spec:
  hard:
    pods: "0"
  scopeSelector:
    matchExpressions:
    - scopeName: CrossNamespacePodAffinity
      operator: Exists
```
With this configuration, Pods in example-namespace cannot specify namespaceSelector or namespaces in their pod affinity terms.

### 3. Quotas for Object Counts
Resource quotas can manage object counts(total number of one particular resource kind in the Kubernetes API) like ConfigMaps, Secrets, PersistentVolumeClaims (PVCs), and more.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: object-counts
  namespace: example-namespace
spec:
  hard:
    configmaps: "10"
    secrets: "5"
```
With this configuration, You can create up to 10 ConfigMaps and 5 Secrets in example-namespace.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name:  quota-test
  namespace: default
  labels:
    app:  deployment-label
spec:
  selector:
    matchLabels:
      app: deployment-label
  replicas: 2
  template:
    metadata:
      labels:
        app: deployment-label
    spec:
      containers:
      - name:  nginx-deploy
        image:  nginx:latest
        resources:
          requests:
            cpu: 100m
            memory: 100Mi
          limits:
            cpu: 100m
            memory: 100Mi
        ports:
        - containerPort:  80
          name:  nginx-deploy
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
  name: scheduling-node-selector
  namespace: scheduling
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
  name: scheduling-taint-toleration-pod
  namespace: scheduling
spec:
  containers:
  - name: nginx
    image: nginx
  tolerations:
  - key: "env"
    operator: "Equal"
    value: "prod"
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
  name: scheduling-affinity-pod
  namespace: scheduling
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
  name: scheduling-anti-affinity-pod
  namespace: scheduling
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

## 3. Hands-on Practice: Jobs & CronJobs

1. **Run a basic Job**:
   ```shell
   kubectl apply -f manifest/jobs/sample-job.yaml
   ```

2. **Check Job status and logs**:
   ```shell
   kubectl get jobs
   kubectl get pods --selector=job-name=sample-job
   kubectl logs <pod-name>
   ```

3. **Deploy a CronJob**:
   ```shell
   kubectl apply -f manifest/jobs/sample-cronjob.yaml
   ```

4. **Observe CronJob execution**:
   ```shell
   kubectl get cronjobs -w
   kubectl get jobs
   ```

---

```yaml
spec:
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
```

---
**Congratulations!** You've learned how to manage batch and scheduled tasks in Kubernetes.

---

# Autoscaling
Kubernetes provides several layers of autoscaling to handle varying loads and optimize resource usage.

## 1. Metrics Server Setup
Before testing Horizontal Pod Autoscaler (HPA) and Vertical Pod Autoscaler (VPA), it’s essential to have the Metrics Server installed in your Kubernetes cluster. The Metrics Server collects resource usage metrics from the cluster’s nodes and pods, which are necessary for autoscaling decisions.

### Install Metrics Server
```shell
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

If there is an error like `tls: failed to verify certificate: x509: cannot validate certificate for <IP_ADDRESS>` we can edit ehe deployment to disable tls verification.

```yaml
    spec:
      containers:
      - args:
        - --cert-dir=/tmp
        - --kubelet-insecure-tls # add this args to disable tls verification
```

#### Verify Metrics Server Installation
Once the Metrics Server is up and running, you can confirm that it’s collecting metrics by querying the API. For example, you can retrieve the CPU and memory usage metrics for nodes and pods:
```shell
kubectl get deployment metrics-server -n kube-system
kubectl top nodes
kubectl top pods
```

## 2. Horizontal Pod Autoscaler (HPA)
HPA automatically scales the number of Pods in a replication controller, deployment, replica set, or stateful set based on observed CPU utilization or other metrics.

- **How it works**: The HPA controller periodically queries the metrics API to check resource utilization and adjusts the number of replicas to match the target.
- **Requirement**: Requires `metrics-server` to be installed.

### Deploy a Deployment
Create a file named `hpa-deployment.yaml` with the following content:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: autoscaling-hpa
spec:
  replicas: 1
  selector:
    matchLabels:
      app: autoscaling-hpa
  template:
    metadata:
      labels:
        app: autoscaling-hpa
    spec:
      containers:
      - name: nginx
        image: nginx
        resources:
          requests:
            cpu: "25m"
          limits:
            cpu: "200m"
---
apiVersion: v1
kind: Service
metadata:
  name: autoscaling-hpa
  labels:
    app: autoscaling-hpa
spec:
  ports:
  - port: 80
  selector:
    app: autoscaling-hpa
```
### Create an HPA
Create a file named `hpa.yaml` with the following content:
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: autoscaling-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: autoscaling-hpa
  minReplicas: 1
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
```
With this setup, the HPA will automatically scale the number of nginx pods between 1 and 10 based on the CPU utilization, aiming to keep it around 50%.

### Load Testing
We'll use the following command to create a new pod that generates load on the target deployment and observe if the number of pods increases accordingly.

1. Pod status before generate load:
```shell
➜ kubectl top pods -l app=autoscaling-hpa
NAME                               CPU(cores)   MEMORY(bytes)
autoscaling-hpa-76fd84c8fc-swxbx   0m           3Mi
```

2. Run this command to generate load:
```shell
echo "GET http://autoscaling-hpa" | kubectl run vegeta --rm -i --restart=Never --image="jauderho/vegeta" -- attack -rate=100 -duration=2m
```

This command will continuously generate requests to the nginx-svc service, thereby increasing the CPU utilization of the nginx pods.

To observe the CPU utilization and the status of the HPA, use the following commands:
```shell
kubectl top pods -l app=autoscaling-hpa
```

3. Monitor the HPA status:
```shell
➜ kubectl get hpa -l app=autoscaling-hpa -w
NAME              REFERENCE                    TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
autoscaling-hpa   Deployment/autoscaling-hpa   cpu: 0%/50%   1         10        1          6s
autoscaling-hpa   Deployment/autoscaling-hpa   cpu: 8%/50%   1         10        1          45s
autoscaling-hpa   Deployment/autoscaling-hpa   cpu: 80%/50%   1         10        1          75s
autoscaling-hpa   Deployment/autoscaling-hpa   cpu: 88%/50%   1         10        2          90s
autoscaling-hpa   Deployment/autoscaling-hpa   cpu: 120%/50%   1         10        2          105s
```

## 3. Vertical Pod Autoscaler (VPA)
VPA automatically adjusts the CPU and memory reservations for your Pods. It can "right-size" your applications by increasing or decreasing resources based on historical usage.

- **How it works**: VPA observes the actual resource usage of containers and updates the `requests` and `limits` in the Pod specification.
- **Modes**:
    - `Initial`: Only sets resources at creation.
    - `Recommender`: Only provides recommendations (doesn't apply changes).
    - `Auto`: Restarts Pods to apply new resource requests.

> [!WARNING]
> Use VPA with caution on production workloads. In `Auto` mode, VPA will restart pods to apply resource changes, which may cause downtime if not handled by a deployment with multiple replicas.

### Install VPA
Before creating VPA objects first we need to install VPA in our cluster using the below steps:
1. Clone the VPA Source Code: Use Git to clone the VPA source code repository to your local machine. Run the following command:
```shell
git clone https://github.com/kubernetes/autoscaler.git
```
2. Navigate to the VPA Directory: Change your current directory to the `autoscaler` directory, which contains the VPA source code and run the installation script:
```shell
git clone https://github.com/kubernetes/autoscaler.git
cd autoscaler/vertical-pod-autoscaler
git checkout origin/vpa-release-1.0
./hack/vpa-up.sh
```
This script will deploy the necessary components, including the VPA Admission Controller, Recommender, and Updater. 
```shell
vpa-admission-controller-5dc96b4dfc-9jhws   1/1     Running   0          7m29s
vpa-recommender-7748dbd648-mxtjk            1/1     Running   0          7m30s
vpa-updater-65549bdcc5-gh6gc                1/1     Running   0          7m30s
```

### Deploy a Deployment
Create a file named `vpa-deployment.yaml` with the following content:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: autoscaling-vpa
spec:
  replicas: 1
  selector:
    matchLabels:
      app: autoscaling-vpa
  template:
    metadata:
      labels:
        app: autoscaling-vpa
    spec:
      containers:
      - name: nginx
        image: nginx
        resources:
          requests:
            cpu: "25m"
          limits:
            cpu: "200m"
---
apiVersion: v1
kind: Service
metadata:
  name: autoscaling-vpa
  labels:
    app: autoscaling-vpa
spec:
  ports:
  - port: 80
  selector:
    app: autoscaling-vpa
```

### Create an VPA
Create a file named `vpa.yaml` with the following content:
```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: autoscaling-vpa
spec:
  targetRef:
    apiVersion: "apps/v1"
    kind: Deployment
    name: autoscaling-vpa
  updatePolicy:
    updateMode: "Auto"
  resourcePolicy:
    containerPolicies:
    - containerName: '*'
      minAllowed:
        cpu: 100m
        memory: 50Mi
      maxAllowed:
        cpu: 1
        memory: 500Mi
      controlledResources: ["cpu", "memory"]
```

### Load Testing
1. Run load testing like hpa, but change the url to `autoscaling-vpa`.
```shell
echo "GET http://autoscaling-vpa" | kubectl run vegeta --rm -i --restart=Never --image="jauderho/vegeta" -- attack -rate=100 -duration=1m
```
2. 

## 4. Cluster Autoscaler
Cluster Autoscaler automatically adjusts the size of the Kubernetes cluster (adding or removing nodes) when:
- Pods fail to run in the cluster due to insufficient resources.
- Nodes in the cluster are underutilized for a period and their pods can be placed on other existing nodes.

---
> [!TIP]
> Always set resource `requests` and `limits` for your containers. Autoscalers (like HPA and VPA) rely on these values to make scaling decisions.
---