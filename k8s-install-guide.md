# Kubernetes Installation Guide
## 3 Node Cluster Setup (1 Master + 2 Workers)

### Environment Overview
- **master**: Control plane node
- **node1**: Worker node
- **node2**: Worker node
- DNS configured (nodes can ping each other by hostname)
- No firewalls enabled
- SELinux disabled

### Important Security Notes for openSUSE 15

**Firewall:**
You mentioned firewalls are disabled. This is fine for testing, but if you need to enable `firewalld` later (for production), you must allow these ports:

**On Master node:**
- 6443 - Kubernetes API server
- 2379-2380 - etcd server client API
- 10250 - Kubelet API
- 10259 - kube-scheduler
- 10257 - kube-controller-manager

**On Worker nodes:**
- 10250 - Kubelet API
- 30000-32767 - NodePort Services

**How to configure firewalld on openSUSE:**

**On Master node:**
```bash
# Install and enable firewalld
sudo zypper install -y firewalld
sudo systemctl start firewalld
sudo systemctl enable firewalld

# Open required ports for master
sudo firewall-cmd --permanent --add-port=6443/tcp
sudo firewall-cmd --permanent --add-port=2379-2380/tcp
sudo firewall-cmd --permanent --add-port=10250/tcp
sudo firewall-cmd --permanent --add-port=10259/tcp
sudo firewall-cmd --permanent --add-port=10257/tcp

# Allow pod network (Flannel VXLAN)
sudo firewall-cmd --permanent --add-port=8472/udp

# Reload firewall rules
sudo firewall-cmd --reload

# Verify open ports
sudo firewall-cmd --list-all
```

**On Worker nodes (node1, node2):**
```bash
# Install and enable firewalld
sudo zypper install -y firewalld
sudo systemctl start firewalld
sudo systemctl enable firewalld

# Open required ports for workers
sudo firewall-cmd --permanent --add-port=10250/tcp
sudo firewall-cmd --permanent --add-port=30000-32767/tcp

# Allow pod network (Flannel VXLAN)
sudo firewall-cmd --permanent --add-port=8472/udp

# Reload firewall rules
sudo firewall-cmd --reload

# Verify open ports
sudo firewall-cmd --list-all
```

**AppArmor:**
openSUSE uses AppArmor (not SELinux). It's usually enabled by default but doesn't typically interfere with kubeadm. However, if you encounter strange container access errors, check AppArmor status:

**Check AppArmor status:**
```bash
# Check if AppArmor is running
sudo systemctl status apparmor

# View loaded profiles and their modes
sudo aa-status

# See which profiles are in enforce mode
sudo aa-status | grep enforce

# See which profiles are in complain mode
sudo aa-status | grep complain
```

**If AppArmor causes issues with containers:**
```bash
# Option 1: Set containerd profile to complain mode (recommended for troubleshooting)
sudo aa-complain /etc/apparmor.d/usr.bin.containerd

# Option 2: Temporarily disable AppArmor (NOT recommended for production)
sudo systemctl stop apparmor
sudo systemctl disable apparmor

# Option 3: Set all profiles to complain mode (logs but doesn't block)
sudo aa-complain /etc/apparmor.d/*

# Restart containerd after AppArmor changes
sudo systemctl restart containerd
```

**Re-enable AppArmor if disabled:**
```bash
sudo systemctl enable apparmor
sudo systemctl start apparmor
```

For this installation guide, we assume AppArmor is in its default state and firewalls are disabled during initial setup.

---

## PART 1: Prepare ALL Nodes (master, node1, node2)

Run these commands on **ALL THREE** nodes before proceeding to Part 2.

### Step 0: Verify System Information

```bash
# Check OS version
cat /etc/os-release

# Check kernel version
uname -r

# Check cgroup version (important for openSUSE)
stat -fc %T /sys/fs/cgroup/
```

**Expected cgroup output:**
- `cgroup2fs` = cgroup v2 (OK for Kubernetes 1.31+)
- `tmpfs` = cgroup v1 (also works)

---

### Step 1: Configure Time Synchronization

Kubernetes is very sensitive to time differences between nodes.

```bash
# Install and enable chrony
sudo zypper install -y chrony
sudo systemctl enable chronyd
sudo systemctl start chronyd

# Verify time sync
timedatectl
chronyc tracking
```

**All nodes must have synchronized time!**

---

### Step 2: Disable Swap
Kubernetes requires swap to be disabled.

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
```

**Verify swap is off:**
```bash
free -h
```
(Swap line should show 0)

---

### Step 2: Load Required Kernel Modules

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

**Verify modules loaded:**
```bash
lsmod | grep br_netfilter
lsmod | grep overlay
```

---

### Step 4: Configure Kernel Parameters

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

**Verify settings:**
```bash
sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward
```
(All should return = 1)

---

### Step 5: Install Container Runtime (containerd)

**For openSUSE 15:**
```bash
sudo zypper refresh
sudo zypper install -y containerd
```

**Configure containerd:**
```bash
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# Enable SystemdCgroup (CRITICAL for cgroup v2 on openSUSE)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Pin sandbox (pause) image to avoid warnings
sudo sed -i 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10"|' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd
```

**Verify containerd is running:**
```bash
sudo systemctl status containerd
```

**Verify sandbox image configuration:**
```bash
grep sandbox_image /etc/containerd/config.toml
```

---

### Step 6: Install Kubernetes Components (kubeadm, kubelet, kubectl)

**For openSUSE 15:**
```bash
# Add Kubernetes repository
cat <<EOF | sudo tee /etc/zypp/repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/repodata/repomd.xml.key
EOF

# Install packages
sudo zypper refresh
sudo zypper install -y kubelet kubeadm kubectl

# Enable kubelet
sudo systemctl enable kubelet
```

**Verify installation:**
```bash
kubeadm version
kubelet --version
kubectl version --client
```

---

## PART 2: Initialize Master Node

Run these commands **ONLY on the master node**.

### Step 6: Initialize Kubernetes Cluster

```bash
sudo kubeadm init --pod-network-cidr=10.244.0.0/16
```

**What happens during initialization:**
- Generates CA certificate and all necessary certificates automatically
- Creates `/etc/kubernetes/pki/` directory with all certificates
- Sets up etcd, API server, controller manager, and scheduler
- Generates admin kubeconfig file

**Wait for initialization to complete.** This takes 2-5 minutes.

When successful, you'll see output like:
```
Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

Then you can join any number of worker nodes by running the following on each as root:

kubeadm join 192.168.1.100:6443 --token abcdef.1234567890abcdef \
    --discovery-token-ca-cert-hash sha256:1234567890abcdef...
```

**SAVE THIS JOIN COMMAND** - you'll need it for the worker nodes!

---

### Step 7: Configure kubectl for Your User

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

**Verify kubectl works:**
```bash
kubectl get nodes
```
(You should see the master node in NotReady state - this is normal)

---

### Step 8: Install Pod Network (Flannel)

**IMPORTANT: Use pinned version instead of master branch**

```bash
# Use stable version instead of master branch
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

**Wait 30-60 seconds, then verify:**
```bash
kubectl get pods -n kube-flannel
kubectl get nodes
```
(Master should now show Ready status)

---

### Step 8a: (Optional) Configure IPVS Mode for kube-proxy

If you loaded IPVS modules in Step 3a, configure kube-proxy to use IPVS:

```bash
# Edit kube-proxy ConfigMap
kubectl edit configmap kube-proxy -n kube-system

# Find the line: mode: ""
# Change it to: mode: "ipvs"
# Save and exit

# Restart kube-proxy pods to apply changes
kubectl delete pod -n kube-system -l k8s-app=kube-proxy
```

**Verify IPVS mode:**
```bash
kubectl logs -n kube-system -l k8s-app=kube-proxy | grep "Using ipvs"
```

---

### Step 9: Get Join Command for Worker Nodes

If you didn't save the join command from Step 6, generate a new one:

```bash
kubeadm token create --print-join-command
```

**Copy the entire output.** It will look like:
```
kubeadm join 192.168.1.100:6443 --token abcdef.1234567890abcdef --discovery-token-ca-cert-hash sha256:1234567890abcdef...
```

---

## PART 3: Join Worker Nodes

Run these commands on **node1 and node2** (NOT on master).

### Step 10: Join the Cluster

Paste the join command you copied from Step 9. Add `sudo` at the beginning:

```bash
sudo kubeadm join <master-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

**Wait for the join to complete** (takes 1-2 minutes per node).

---

## PART 4: Verify Installation

Run these commands **on the master node**.

### Step 11: Check All Nodes

```bash
kubectl get nodes
```

**Expected output:**
```
NAME     STATUS   ROLES           AGE   VERSION
master   Ready    control-plane   10m   v1.31.x
node1    Ready    <none>          5m    v1.31.x
node2    Ready    <none>          5m    v1.31.x
```

All nodes should show **Ready** status. If any show **NotReady**, wait 1-2 minutes and check again.

---

### Step 12: Verify System Pods

```bash
kubectl get pods -A
```

All pods should show **Running** status.

---

### Step 13: Test the Cluster

Deploy a test application:

```bash
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80 --type=NodePort
kubectl get svc nginx
```

**Get the NodePort:**
```bash
kubectl get svc nginx
```

Test access from master:
```bash
curl http://master:<NodePort>
curl http://node1:<NodePort>
curl http://node2:<NodePort>
```

(Replace `<NodePort>` with the actual port number shown, e.g., 30080)

---

### Step 14: (Optional) Allow Pods on Master Node

By default, the master node has a taint that prevents regular pods from being scheduled on it (only system pods run there).

**Check master node taints:**
```bash
kubectl describe node master | grep Taints
```

You'll see: `node-role.kubernetes.io/control-plane:NoSchedule`

**For lab/test environments, you can remove this taint to allow pods on master:**

```bash
kubectl taint nodes master node-role.kubernetes.io/control-plane-
```

⚠️ **NOT recommended for production!** In production, keep master dedicated to control plane components only.

---

## Advanced: Backup and Restore

### Backup etcd (Critical for Production)

⚠️ **Always backup etcd before upgrades or changes!**

```bash
# Create etcd snapshot
sudo ETCDCTL_API=3 etcdctl snapshot save /backup/etcd-snapshot-$(date +%Y%m%d-%H%M%S).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Verify snapshot
sudo ETCDCTL_API=3 etcdctl snapshot status /backup/etcd-snapshot-*.db --write-out=table
```

**Setup automatic etcd backups (recommended):**

```bash
# Create backup directory
sudo mkdir -p /backup/etcd

# Create backup script
cat <<'EOF' | sudo tee /usr/local/bin/etcd-backup.sh
#!/bin/bash
BACKUP_DIR="/backup/etcd"
RETENTION_DAYS=7

ETCDCTL_API=3 etcdctl snapshot save ${BACKUP_DIR}/etcd-snapshot-$(date +%Y%m%d-%H%M%S).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Remove old backups
find ${BACKUP_DIR} -name "etcd-snapshot-*.db" -mtime +${RETENTION_DAYS} -delete
EOF

sudo chmod +x /usr/local/bin/etcd-backup.sh

# Add to crontab (daily at 2 AM)
echo "0 2 * * * /usr/local/bin/etcd-backup.sh" | sudo crontab -
```

### Restore etcd from backup

⚠️ **Only use in emergency! This will restore cluster to backup state.**

```bash
# Stop kube-apiserver
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/

# Restore from snapshot
sudo ETCDCTL_API=3 etcdctl snapshot restore /backup/etcd-snapshot-XXXXXXXX.db \
  --data-dir=/var/lib/etcd-restore

# Replace etcd data
sudo rm -rf /var/lib/etcd
sudo mv /var/lib/etcd-restore /var/lib/etcd

# Restore kube-apiserver
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/

# Wait for cluster to recover
kubectl get nodes
```

---

## Certificate Information

### Where are the certificates?

After `kubeadm init`, all certificates are automatically created in `/etc/kubernetes/pki/`:

```bash
# View certificates on master node
sudo ls -la /etc/kubernetes/pki/
```

You'll see:
- `ca.crt` and `ca.key` - Cluster CA certificate and key
- `apiserver.crt` and `apiserver.key` - API server certificate
- `apiserver-kubelet-client.crt` and `apiserver-kubelet-client.key`
- `front-proxy-ca.crt` and `front-proxy-ca.key`
- `sa.key` and `sa.pub` - Service account signing keys
- `etcd/` directory with etcd certificates

### Check certificate details:

```bash
# View CA certificate expiration
sudo openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -text | grep -A 2 Validity

# View all certificate expiration dates
sudo kubeadm certs check-expiration
```

**Note:** Kubernetes certificates expire after 1 year by default. You'll need to renew them before expiration.

---

## Troubleshooting

### If a node shows NotReady:
```bash
# On the problematic node:
sudo systemctl status kubelet
sudo journalctl -xeu kubelet

# Check if Flannel pods are running
kubectl get pods -n kube-flannel

# View Flannel logs
kubectl logs -n kube-flannel <flannel-pod-name>
```

**If master node stays NotReady after installing Flannel:**

This can happen if firewall blocks ICMP or network protocols needed for pod networking.

```bash
# Allow ICMP (ping) through firewall
sudo firewall-cmd --permanent --add-protocol=icmp
sudo firewall-cmd --reload

# Or add Flannel interface to trusted zone
sudo firewall-cmd --permanent --zone=trusted --add-interface=flannel.1
sudo firewall-cmd --permanent --zone=trusted --add-interface=cni0
sudo firewall-cmd --reload

# Check if CNI bridge exists
ip addr show cni0
ip addr show flannel.1

# Restart kubelet if needed
sudo systemctl restart kubelet

# Wait 30-60 seconds and check again
kubectl get nodes
```

**If still NotReady, check CNI configuration:**
```bash
# Verify CNI config exists
ls -la /etc/cni/net.d/

# Check for errors in containerd
sudo journalctl -u containerd -n 50

# Restart containerd and kubelet
sudo systemctl restart containerd
sudo systemctl restart kubelet
```

### If pods are not starting:
```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

### To reset a node and start over:

⚠️ **DANGER: This command deletes ALL cluster data including etcd!**

**Before running kubeadm reset:**
- Make sure you have etcd backups if this is master node
- Understand that ALL cluster data will be lost
- This cannot be undone

```bash
# Reset the node
sudo kubeadm reset --force

# Clean up all Kubernetes files and configurations
sudo rm -rf /etc/cni /etc/kubernetes /var/lib/dockershim /var/lib/etcd /var/lib/kubelet /var/run/kubernetes ~/.kube/*

# Clean up iptables rules
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X

# Clean up IPVS rules (if using IPVS)
sudo ipvsadm --clear

# Restart containerd
sudo systemctl restart containerd
```

Then restart from Part 1.

⚠️ **On master node**: `kubeadm reset` will delete the entire etcd database, destroying all cluster data, workloads, and configurations. Always backup etcd first!

---

## Quick Reference Commands

```bash
# Check cluster status
kubectl get nodes
kubectl get pods -A
kubectl cluster-info

# Check specific node details
kubectl describe node <node-name>

# View logs
kubectl logs -n kube-system <pod-name>

# Generate new join token (valid for 24 hours)
kubeadm token create --print-join-command
```

---

## Notes

- The join token expires after 24 hours. Generate a new one if needed.
- This setup uses Flannel for networking with pod CIDR 10.244.0.0/16
- All commands assume you have sudo privileges
- Kubernetes version used: 1.31 (stable)

---

Что можно добавить, если хочешь “10/10+”

Это уже не «надо», а «если хочется»:

kubeadm upgrade path

kubectl completion

kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl


Node labels / roles

Resource reservations

kubelet:
  systemReserved:
    cpu: "500m"
    memory: "1Gi"


**Installation complete!** Your 3-node Kubernetes cluster is ready to use.
