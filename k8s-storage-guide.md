# Kubernetes Storage Solutions Guide
## Persistent Storage for Your Cluster

**Prerequisites**: You must have a working Kubernetes cluster. If you haven't installed Kubernetes yet, follow the [Kubernetes Installation Guide](01-kubernetes-installation.md) first.

## Advanced: Longhorn Upgrade Path

**⚠️ CRITICAL: Never upgrade Longhorn without following proper procedure**

Wrong approach:
```bash
# ❌ DANGEROUS: Don't do this!
kubectl apply -f https://new-longhorn-version.yaml
# This can corrupt volumes and cause data loss!
```

**Correct upgrade procedure:**

### Step 1: Pre-Upgrade Preparation

```bash
# 1. Check current version
kubectl get settings.longhorn.io -n longhorn-system longhorn-manager-version -o jsonpath='{.value}'

# 2. Create full backup of all volumes
# In Longhorn UI: Select all volumes → Create Backup

# 3. Verify all volumes are healthy
kubectl get volumes -n longhorn-system -o json | jq -r '.items[] | select(.status.state != "attached" and .status.state != "detached") | .metadata.name'
# Should return empty (no unhealthy volumes)

# 4. Create etcd backup
sudo /usr/local/bin/etcd-backup.sh

# 5. Document current state
kubectl get pods -A > /backup/pre-upgrade-pods.txt
kubectl get pvc -A > /backup/pre-upgrade-pvcs.txt
```

### Step 2: Disable Scheduling

```bash
# Prevent new replicas during upgrade
kubectl patch -n longhorn-system settings.longhorn.io/allow-scheduling \
  --type=merge -p '{"value":"false"}'

# Wait for all operations to complete
kubectl get engines -n longhorn-system -w
# Wait until no engines are in "upgrading" state
```

### Step 3: Perform Upgrade

```bash
# Download new Longhorn version
wget https://raw.githubusercontent.com/longhorn/longhorn/v1.7.2/deploy/longhorn.yaml

# Review changes
diff <(kubectl get -n longhorn-system deployment longhorn-manager -o yaml) longhorn.yaml

# Apply upgrade
kubectl apply -f longhorn.yaml

# Monitor upgrade progress
kubectl get pods -n longhorn-system -w
```

### Step 4: Verify Upgrade

```bash
# 1. Check new version
kubectl get settings.longhorn.io -n longhorn-system longhorn-manager-version -o jsonpath='{.value}'

# 2. Verify all components running
kubectl get pods -n longhorn-system
# All pods should be Running

# 3. Check replica health
kubectl get replicas -n longhorn-system -o json | \
  jq -r '.items[] | select(.status.running != true) | .metadata.name'
# Should be empty

# 4. Verify volumes
kubectl get volumes -n longhorn-system
# All should be "Healthy"

# 5. Test volume operations
# Create test PVC, attach to pod, write data, verify
```

### Step 5: Re-enable Scheduling

```bash
# Re-enable new volume scheduling
kubectl patch -n longhorn-system settings.longhorn.io/allow-scheduling \
  --type=merge -p '{"value":"true"}'
```

### Step 6: Post-Upgrade Testing

```bash
# 1. Create test volume
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: upgrade-test-pvc
spec:
  storageClassName: longhorn
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

# 2. Create test pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: upgrade-test-pod
spec:
  containers:
  - name: test
    image: nginx
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: upgrade-test-pvc
EOF

# 3. Test write/read
kubectl exec upgrade-test-pod -- bash -c "echo 'upgrade test' > /data/test.txt"
kubectl exec upgrade-test-pod -- cat /data/test.txt

# 4. Cleanup
kubectl delete pod upgrade-test-pod
kubectl delete pvc upgrade-test-pvc
```

### Rollback Procedure (If Upgrade Fails)

```bash
# 1. Revert to previous version
kubectl apply -f /backup/longhorn-previous-version.yaml

# 2. Restore from backup if needed
# In Longhorn UI: Backup → Select backup → Restore

# 3. Verify rollback
kubectl get pods -n longhorn-system
kubectl get volumes -n longhorn-system
```

**Upgrade best practices:**
- ✅ Always upgrade in test environment first
- ✅ Take full backups before upgrade
- ✅ Upgrade during maintenance window
- ✅ Test volume operations after upgrade
- ✅ Have rollback plan ready
- ✅ Read release notes for breaking changes

---

## Understanding Kubernetes Storage Architecture

### CRITICAL: Storage vs Cluster State

**⚠️ IMPORTANT DISTINCTION:**

Kubernetes has TWO types of data that need protection:

| Type | What It Contains | Where It's Stored | Backup Solution |
|------|------------------|-------------------|-----------------|
| **Application Data** | Your files, databases, user uploads | Persistent Volumes (PV) | **Longhorn snapshots** |
| **Cluster State** | PVCs, Deployments, Secrets, Namespaces | **etcd database** | **etcd backup** |

**THIS IS CRITICAL TO UNDERSTAND:**

```
❌ WRONG: "I use Longhorn, so all my data is backed up"

✅ CORRECT: "Longhorn backs up my APPLICATION data,
            but I also need etcd backup for CLUSTER STATE"
```

**Real-world disaster scenario:**

```
Day 1: Production cluster with Longhorn + MySQL database
       - Application data: In Longhorn volumes ✅
       - Cluster state: In etcd ✅

Day 30: All 3 nodes lose power simultaneously
       - Longhorn volumes: Data intact on disks ✅
       - etcd corrupted during power loss ❌

Result without etcd backup:
→ Longhorn volumes exist but Kubernetes doesn't know about them
→ No PVCs, no Deployments, no Services
→ Cluster state is GONE, must rebuild from scratch
→ Even though data exists, you can't access it!

Result with etcd backup:
→ Restore etcd from backup
→ Kubernetes knows about all PVCs and volumes
→ All applications come back online
→ Data accessible again ✅
```

**What you LOSE if etcd is lost:**
- All PVC definitions (Kubernetes won't know volumes exist)
- All Deployments, Services, ConfigMaps, Secrets
- All namespaces and RBAC
- VolumeSnapshot references
- Longhorn CRDs and configuration

**Bottom line:** You need BOTH Longhorn backups AND etcd backups for complete protection.

We'll cover etcd backup in the Best Practices section.

---

## Why Do You Need Storage in Kubernetes?

### The Problem

By default, when a pod restarts or gets deleted, **ALL data inside it is lost**. This is because containers use ephemeral (temporary) storage.

**Example of the problem:**
```bash
# Create a pod with nginx
kubectl run nginx --image=nginx

# Write a file inside the pod
kubectl exec nginx -- bash -c "echo 'Hello World' > /usr/share/nginx/html/test.txt"

# Verify file exists
kubectl exec nginx -- cat /usr/share/nginx/html/test.txt
# Output: Hello World

# Delete and recreate the pod
kubectl delete pod nginx
kubectl run nginx --image=nginx

# Try to read the file - IT'S GONE!
kubectl exec nginx -- cat /usr/share/nginx/html/test.txt
# Output: cat: /usr/share/nginx/html/test.txt: No such file or directory
```

### The Solution: Persistent Volumes

Kubernetes provides **Persistent Volumes (PV)** and **Persistent Volume Claims (PVC)** to solve this problem.

**Think of it like this:**
- **PV** = External hard drive (actual storage)
- **PVC** = Request for storage ("I need 10GB of space")
- **Pod** = Computer that uses the hard drive

---

## Understanding Kubernetes Storage Concepts

### 1. StorageClass

Defines **HOW** storage is provisioned (like different types of hard drives: SSD, HDD, NFS).

```yaml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: fast-storage
provisioner: example.com/fast-ssd  # Who creates the actual storage
parameters:
  type: ssd
```

### 2. PersistentVolume (PV)

The **actual storage** available in the cluster (like a real hard drive connected to your system).

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: my-pv
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce  # Only one pod can write at a time
  hostPath:
    path: /data/storage  # Where data is actually stored
```

### 3. PersistentVolumeClaim (PVC)

A **request for storage** from a pod (like saying "I need a 10GB hard drive").

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi  # I need 5GB
```

### 4. Using PVC in a Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app
spec:
  containers:
  - name: app
    image: nginx
    volumeMounts:
    - name: storage
      mountPath: /data  # Where to mount inside container
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: my-pvc  # Use the PVC we created
```

---

## Access Modes Explained

**Important**: Choose the right access mode for your use case!

| Mode | Abbreviation | Description | Use Case |
|------|--------------|-------------|----------|
| ReadWriteOnce | RWO | One pod can read/write | Databases, single app |
| ReadOnlyMany | ROX | Many pods can read | Shared config files |
| ReadWriteMany | RWX | Many pods can read/write | Shared file system |

**Important for openSUSE 3-node cluster:**
- Most simple solutions only support **RWO** (ReadWriteOnce)
- For **RWX** (multiple pods writing), you need NFS or distributed storage like Longhorn

---

## Storage Solutions Comparison

| Solution | Complexity | RWO | RWX | Best For | Production Ready |
|----------|------------|-----|-----|----------|------------------|
| **local-path** | ⭐ Easy | ✅ | ❌ | Lab, testing | ❌ No |
| **hostPath** | ⭐ Easy | ✅ | ❌ | Development | ❌ No |
| **NFS** | ⭐⭐ Medium | ✅ | ✅ | Small prod | ✅ Yes |
| **Longhorn** | ⭐⭐⭐ Advanced | ✅ | ✅ | **Production** | ✅ Yes |
| **Rook-Ceph** | ⭐⭐⭐⭐ Expert | ✅ | ✅ | Large prod | ✅ Yes |

**⚠️ IMPORTANT FOR PRODUCTION:**

For your 3-node openSUSE cluster, **Longhorn is the recommended solution** for production use. It provides:
- Automatic data replication across all 3 nodes
- High availability (survives node failures)
- Native integration with SUSE/Rancher ecosystem
- Built-in snapshots and disaster recovery

**For your 3-node openSUSE cluster, we'll cover:**
1. **local-path-provisioner** - For learning and understanding concepts ONLY
2. **NFS with dynamic provisioner** - For shared storage (ReadWriteMany)
3. **Longhorn** - **RECOMMENDED for production** - Cloud-native, HA storage

---

## Solution 1: Local Path Provisioner (Easiest)

**Best for**: Learning, development, testing
**NOT for production**: Data is lost if node fails!

### What is it?

Creates storage directly on the node's local disk. Very simple, but data is tied to one specific node.

### Installation

**On master node:**

```bash
# Install local-path-provisioner
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml

# Verify installation
kubectl get pods -n local-path-storage

# Check StorageClass
kubectl get storageclass
```

You should see: `local-path` StorageClass

### Set as Default StorageClass

```bash
# Make local-path the default
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Verify (should show "default" next to local-path)
kubectl get storageclass
```

### Test It!

**Create a test PVC:**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF
```

**Check PVC status:**
```bash
kubectl get pvc test-pvc
# Should show: STATUS = Bound
```

**Create a pod that uses the PVC:**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
spec:
  containers:
  - name: test
    image: nginx
    volumeMounts:
    - name: storage
      mountPath: /data
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: test-pvc
EOF
```

**Test persistence:**

```bash
# Write data to the volume
kubectl exec test-pod -- bash -c "echo 'Data persists!' > /data/test.txt"

# Delete the pod
kubectl delete pod test-pod

# Recreate the pod (using same YAML)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
spec:
  containers:
  - name: test
    image: nginx
    volumeMounts:
    - name: storage
      mountPath: /data
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: test-pvc
EOF

# Check if data is still there
kubectl exec test-pod -- cat /data/test.txt
# Output: Data persists!
```

**Success!** 🎉 Data survived pod restart!

### Where is Data Stored?

```bash
# Find which node the pod is running on
kubectl get pod test-pod -o wide

# SSH to that node and check
ls -la /opt/local-path-provisioner/
```

### Cleanup

```bash
kubectl delete pod test-pod
kubectl delete pvc test-pvc
```

### Limitations

❌ Data is lost if the node fails
❌ Can only be used by pods on the same node
❌ No replication or backup
✅ Perfect for learning and testing

**⚠️ CRITICAL WARNING FOR PRODUCTION:**

**NEVER use local-path-provisioner in production!** When a node fails, all data on that node is permanently lost. This includes:
- Databases
- User uploads
- Application state
- Configuration files

**Real-world scenario:**
```
Day 1: Deploy application with local-path storage on node1
Day 30: node1 hardware fails
Result: ALL data is gone forever, no recovery possible
```

For production, use **Longhorn** (recommended for 3-node clusters) or **NFS** with proper backup strategy.

---

## Solution 2: NFS Storage (Shared Storage)

**Best for**: Small production environments, shared data
**Supports**: ReadWriteMany (multiple pods can write)

### What is NFS?

Network File System - allows multiple machines to access the same storage over the network. Like a shared folder on your network.

### Architecture

```
┌─────────────┐
│ NFS Server  │ ← Stores all data
│ (master)    │
└─────────────┘
       ↑
       │ Network
       ↓
┌──────────────────────────┐
│  Kubernetes Cluster      │
│  ┌────┐ ┌────┐ ┌────┐  │
│  │Pod1│ │Pod2│ │Pod3│  │ ← All can access same data
│  └────┘ └────┘ └────┘  │
└──────────────────────────┘
```

### Step 1: Install NFS Server (on master node)

```bash
# Install NFS server on openSUSE
sudo zypper install -y nfs-kernel-server

# Create directory for NFS exports
sudo mkdir -p /srv/nfs/kubedata

# Set permissions (very permissive for simplicity)
sudo chmod 777 /srv/nfs/kubedata

# Configure NFS export
echo "/srv/nfs/kubedata *(rw,sync,no_subtree_check,no_root_squash,insecure)" | sudo tee -a /etc/exports

# Apply changes
sudo exportfs -rav

# Enable and start NFS server
sudo systemctl enable nfsserver
sudo systemctl start nfsserver

# Check NFS is running
sudo systemctl status nfsserver

# Verify exports
showmount -e localhost
```

### Step 2: Install NFS Client on ALL Nodes

**Run on master, node1, and node2:**

```bash
# Install NFS client utilities on openSUSE
# IMPORTANT: Use nfs-utils for complete NFS client functionality
sudo zypper install -y nfs-client nfs-utils

# Verify installation
rpm -qa | grep nfs

# Test NFS mount (use master's IP or hostname)
sudo mkdir -p /mnt/test
sudo mount -t nfs master:/srv/nfs/kubedata /mnt/test

# If mount works, unmount test
sudo umount /mnt/test
sudo rmdir /mnt/test
```

**Troubleshooting NFS mount:**

If mount fails, check:
```bash
# On master (NFS server)
sudo systemctl status nfsserver
sudo exportfs -v
showmount -e localhost

# Test network connectivity from worker to master
ping master
telnet master 2049

# Check if NFS ports are accessible
sudo ss -tlnp | grep -E ':(2049|111)'
```

### Step 3: Install NFS Subdir External Provisioner

**Why do we need this?**

Without a provisioner, when you create a PVC, it will stay in `Pending` state forever. The provisioner automatically:
- Creates subdirectories on the NFS server for each PVC
- Manages the lifecycle of volumes
- Allows dynamic provisioning (no manual PV creation needed)

**On master node:**

```bash
# Add Helm repository (we'll use Helm for easy installation)
# First, install Helm if not already installed
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify Helm is installed
helm version

# Add NFS provisioner Helm chart
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm repo update

# Install NFS provisioner
# Replace "master" with your actual NFS server IP if DNS doesn't work
helm install nfs-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  --set nfs.server=master \
  --set nfs.path=/srv/nfs/kubedata \
  --set storageClass.name=nfs-storage \
  --set storageClass.defaultClass=false \
  --set storageClass.reclaimPolicy=Retain

# IMPORTANT: We set reclaimPolicy=Retain to prevent accidental data loss

# Verify installation
kubectl get pods -l app=nfs-subdir-external-provisioner

# Check StorageClass
kubectl get storageclass nfs-storage
```

**Understanding Reclaim Policy:**

The `reclaimPolicy` determines what happens to data when a PVC is deleted:

| Policy | What Happens | Use Case |
|--------|-------------|----------|
| **Delete** | Data is deleted automatically | Testing, temporary data |
| **Retain** | Data is kept, manual cleanup needed | **Production** (prevents accidents) |

**⚠️ PRODUCTION RECOMMENDATION:** Always use `Retain` policy to prevent accidental data loss. You can manually clean up old volumes when needed.

### Step 4: Test NFS Storage

**Create PVC:**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-test-pvc
spec:
  storageClassName: nfs-storage
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
EOF

# Check PVC
kubectl get pvc nfs-test-pvc
```

**Create two pods using the same PVC (testing ReadWriteMany):**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nfs-pod1
spec:
  containers:
  - name: app
    image: nginx
    volumeMounts:
    - name: nfs-storage
      mountPath: /data
  volumes:
  - name: nfs-storage
    persistentVolumeClaim:
      claimName: nfs-test-pvc
---
apiVersion: v1
kind: Pod
metadata:
  name: nfs-pod2
spec:
  containers:
  - name: app
    image: nginx
    volumeMounts:
    - name: nfs-storage
      mountPath: /data
  volumes:
  - name: nfs-storage
    persistentVolumeClaim:
      claimName: nfs-test-pvc
EOF
```

**Test shared access:**

```bash
# Write from pod1
kubectl exec nfs-pod1 -- bash -c "echo 'Written by pod1' > /data/shared.txt"

# Read from pod2
kubectl exec nfs-pod2 -- cat /data/shared.txt
# Output: Written by pod1

# Write from pod2
kubectl exec nfs-pod2 -- bash -c "echo 'Written by pod2' >> /data/shared.txt"

# Read from pod1
kubectl exec nfs-pod1 -- cat /data/shared.txt
# Output:
# Written by pod1
# Written by pod2
```

**Success!** 🎉 Both pods can read and write to the same storage!

**Check data on NFS server:**

```bash
# On master node
ls -la /srv/nfs/kubedata/
cat /srv/nfs/kubedata/*/shared.txt
```

### Cleanup

```bash
kubectl delete pod nfs-pod1 nfs-pod2
kubectl delete pvc nfs-test-pvc
```

### NFS Production Considerations

✅ Supports ReadWriteMany
✅ Simple to setup
✅ Good for small/medium workloads
⚠️ Single point of failure (NFS server)
⚠️ Performance depends on network
⚠️ No built-in replication

**For production NFS:**
- Use dedicated NFS server (not master node)
- Setup NFS server HA (High Availability)
- Configure backup for /srv/nfs/kubedata
- Monitor disk space

---

## Solution 3: Longhorn (Cloud-Native Storage) ⭐ RECOMMENDED

**Best for**: Production on 3-node clusters, automatic replication, snapshots
**Complexity**: More complex setup, but worth it for production

**⚠️ THIS IS THE RECOMMENDED SOLUTION FOR YOUR 3-NODE OPENSUSE CLUSTER**

### Why Longhorn for Your Setup?

1. **Made by SUSE/Rancher**: Native integration with openSUSE ecosystem
2. **Perfect for 3 nodes**: Automatically replicates data across all nodes
3. **High Availability**: If one node dies, your data survives on the other two
4. **Enterprise Features**: Snapshots, backups, disaster recovery, web UI
5. **Free and Open Source**: No licensing costs

### What is Longhorn?

Longhorn is a distributed block storage system for Kubernetes created by Rancher (now part of SUSE). It provides:
- Automatic replication across nodes
- Snapshots and backups
- Web UI for management
- High availability

### Architecture

```
┌──────────────────────────────────────┐
│         Kubernetes Cluster           │
│                                      │
│  ┌──────┐    ┌──────┐    ┌──────┐  │
│  │Node1 │    │Node2 │    │Node3 │  │
│  │      │    │      │    │      │  │
│  │ 📦   │ ←→ │ 📦   │ ←→ │ 📦   │  │
│  │Data  │    │Data  │    │Data  │  │
│  │Replica    │Replica    │Replica  │
│  └──────┘    └──────┘    └──────┘  │
│                                      │
│  All 3 nodes store copies of data   │
│  If node1 fails, data is still on   │
│  node2 and node3!                    │
└──────────────────────────────────────┘
```

### Prerequisites

**⚠️ CRITICAL: Install on ALL nodes (master, node1, node2) before Longhorn installation**

```bash
# Install required packages for Longhorn on openSUSE
sudo zypper install -y open-iscsi nfs-client nfs-utils

# Enable and start iSCSI (required by Longhorn for block storage)
sudo systemctl enable iscsid
sudo systemctl start iscsid

# Verify iSCSI is running
sudo systemctl status iscsid

# Test iSCSI configuration
sudo iscsiadm -m node

# Install additional dependencies
sudo zypper install -y curl util-linux grep gawk
```

**Why these packages?**
- `open-iscsi`: Longhorn uses iSCSI protocol for block storage
- `nfs-client` + `nfs-utils`: Needed for RWX (ReadWriteMany) volumes
- Other tools: Required for Longhorn's health checks and operations

### Step 1: Install Longhorn

**On master node:**

```bash
# Method 1: Using kubectl (simplest)
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.7.2/deploy/longhorn.yaml

# This will take 2-3 minutes to download and start all components

# Check installation progress
kubectl get pods -n longhorn-system --watch

# Wait until all pods are Running (press Ctrl+C to stop watching)
```

**Verify installation:**

```bash
# Check all Longhorn components
kubectl get pods -n longhorn-system

# Check StorageClass
kubectl get storageclass longhorn
```

### Step 2: Access Longhorn UI (Optional but Recommended)

```bash
# Create port-forward to access UI
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80 --address=0.0.0.0

# Now open in browser: http://master:8080
# (or http://<master-ip>:8080)
```

**In the Longhorn UI you can see:**
- All volumes
- Nodes and their storage
- Volume health and replicas
- Create snapshots and backups

### Step 3: Set Longhorn as Default StorageClass (RECOMMENDED)

**For production clusters, make Longhorn the default:**

```bash
# Make Longhorn the default StorageClass
kubectl patch storageclass longhorn -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Remove default from local-path if it was set
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true

# Verify (longhorn should have "(default)" next to it)
kubectl get storageclass
```

**Why make it default?**
- When you create a PVC without specifying `storageClassName`, it will automatically use Longhorn
- Prevents accidental use of local-path in production
- Ensures all data has replication by default

### Step 4: Configure Longhorn Settings (Production Hardening)

**Access Longhorn UI and configure these settings:**

```bash
# Create port-forward to access UI
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80 --address=0.0.0.0 &

# Open in browser: http://master:8080
```

**In Longhorn UI, configure these production settings:**

1. **Settings → General → Default Replica Count**: Set to `3` (uses all your nodes)
2. **Settings → General → Create Default Disk on Labeled Nodes**: `false` (manual control)
3. **Settings → Scheduling → Allow Scheduling On Cordoned Node**: `false` (safety)
4. **Settings → General → Storage Minimal Available Percentage**: Set to `15`
5. **Settings → Backups**: Configure S3-compatible backup target if available

**⚠️ CRITICAL: Disk Pressure and Eviction**

Kubernetes kubelet will evict pods when disk space is low. This can cause:
- Pods being killed
- Longhorn replicas marked as Failed
- Volumes entering Degraded state

**Configure disk pressure thresholds:**

```bash
# Set Longhorn minimum free space (stop scheduling if < 15%)
kubectl patch -n longhorn-system settings.longhorn.io/storage-minimal-available-percentage \
  --type=merge -p '{"value":"15"}'

# Set Longhorn reserved space per disk
kubectl patch -n longhorn-system settings.longhorn.io/storage-reserved-percentage-for-default-disk \
  --type=merge -p '{"value":"25"}'
```

**What these settings do:**

| Setting | Value | Effect |
|---------|-------|--------|
| `storage-minimal-available-percentage` | 15% | Stop creating new replicas if disk < 15% free |
| `storage-reserved-percentage` | 25% | Reserve 25% of disk for system operations |

**Monitor disk usage to prevent eviction:**

```bash
# Check node disk pressure status
kubectl get nodes -o json | jq -r '.items[] | {name: .metadata.name, diskPressure: .status.conditions[] | select(.type=="DiskPressure") | .status}'

# Check Longhorn disk usage
# In Longhorn UI: Node → View disk usage
```

**Or configure via kubectl:**

```bash
# Set default replica count to 3
kubectl patch -n longhorn-system settings.longhorn.io/default-replica-count --type=merge -p '{"value":"3"}'

# Set guarantee engine CPU
kubectl patch -n longhorn-system settings.longhorn.io/guaranteed-engine-manager-cpu --type=merge -p '{"value":"12"}'

# Set guarantee replica CPU  
kubectl patch -n longhorn-system settings.longhorn.io/guaranteed-replica-manager-cpu --type=merge -p '{"value":"12"}'
```

### Step 5: Verify Storage Capacity

```bash
# Check Longhorn nodes and their storage
kubectl get nodes.longhorn.io -n longhorn-system

# Or use Longhorn UI to see:
# - Available space on each node
# - Disk health status
# - Schedulable status
```

**Expected output:** All 3 nodes should show as "Schedulable" with available disk space.

**Create PVC:**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: longhorn-test-pvc
spec:
  storageClassName: longhorn
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
EOF

# Check PVC
kubectl get pvc longhorn-test-pvc
```

**Create pod:**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: longhorn-test-pod
spec:
  containers:
  - name: app
    image: nginx
    volumeMounts:
    - name: storage
      mountPath: /data
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: longhorn-test-pvc
EOF
```

**Test data persistence:**

```bash
# Write data
kubectl exec longhorn-test-pod -- bash -c "echo 'Longhorn storage works!' > /data/test.txt"

# Check in Longhorn UI
# You should see the volume with 3 replicas across nodes

# Delete pod
kubectl delete pod longhorn-test-pod

# Recreate pod
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: longhorn-test-pod
spec:
  containers:
  - name: app
    image: nginx
    volumeMounts:
    - name: storage
      mountPath: /data
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: longhorn-test-pvc
EOF

# Verify data persists
kubectl exec longhorn-test-pod -- cat /data/test.txt
# Output: Longhorn storage works!
```

### Step 7: Test Node Failure Resilience (CRITICAL TEST)

**This is the key test that proves Longhorn protects your data!**

```bash
# Find which node the pod is on
NODE=$(kubectl get pod longhorn-test-pod -o jsonpath='{.spec.nodeName}')
echo "Pod is running on: $NODE"

# Check data before failure
kubectl exec longhorn-test-pod -- cat /data/test.txt

# Simulate node failure: cordon and drain the node
kubectl cordon $NODE
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --force

# Wait for pod to reschedule to another node (watch the process)
kubectl get pods -w
# Press Ctrl+C after pod is Running on different node

# Verify pod is now on a different node
kubectl get pod longhorn-test-pod -o wide

# CRITICAL CHECK: Verify data is still there after "node failure"
kubectl exec longhorn-test-pod -- cat /data/test.txt
# Output: Longhorn storage works!
```

**What just happened?**
1. Your pod was running on node1 with data
2. You "failed" node1 (cordoned + drained it)
3. Kubernetes rescheduled pod to node2 or node3
4. **Data was still there!** Because Longhorn had replicas on other nodes

**This is why Longhorn is production-ready and local-path is NOT.**

**Restore the node:**

```bash
kubectl uncordon $NODE

# In Longhorn UI, you'll see:
# - Replicas rebuilding on the restored node
# - Volume health returning to "Healthy"
```

**Real-world scenario:**
```
Production database with Longhorn:
- Day 1: Deploy MySQL on node1, Longhorn creates replicas on all 3 nodes
- Day 30: node1 hardware fails (power supply dies)
- Day 30 + 2 minutes: Kubernetes reschedules MySQL to node2
- Result: Database comes back online with ALL data intact!

Same scenario with local-path:
- Day 30: node1 fails
- Result: ALL database data is PERMANENTLY LOST
```

### Step 6: Create Volume Snapshot

**Create VolumeSnapshotClass:**

```bash
cat <<EOF | kubectl apply -f -
kind: VolumeSnapshotClass
apiVersion: snapshot.storage.k8s.io/v1
metadata:
  name: longhorn-snapshot-class
driver: driver.longhorn.io
deletionPolicy: Delete
EOF
```

**Create snapshot:**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: longhorn-test-snapshot
spec:
  volumeSnapshotClassName: longhorn-snapshot-class
  source:
    persistentVolumeClaimName: longhorn-test-pvc
EOF

# Check snapshot
kubectl get volumesnapshot
```

**Restore from snapshot:**

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: restored-pvc
spec:
  storageClassName: longhorn
  dataSource:
    name: longhorn-test-snapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
EOF

# Verify restored data
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: restored-pod
spec:
  containers:
  - name: app
    image: nginx
    volumeMounts:
    - name: storage
      mountPath: /data
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: restored-pvc
EOF

kubectl exec restored-pod -- cat /data/test.txt
```

### Cleanup

```bash
kubectl delete pod longhorn-test-pod restored-pod
kubectl delete pvc longhorn-test-pvc restored-pvc
kubectl delete volumesnapshot longhorn-test-snapshot
```

### Longhorn Production Features

✅ Automatic replication (default 3 copies across nodes)
✅ Snapshots and backups
✅ Web UI for management and monitoring
✅ **Survives node failures** (CRITICAL for production)
✅ ReadWriteOnce (RWO) support
✅ ReadWriteMany (RWX) via NFS backing
✅ Volume expansion (resize PVCs without downtime)
✅ Disaster recovery (backup to S3/NFS)
⚠️ Uses 3x disk space (3 replicas)
⚠️ Network overhead for replication

### Longhorn vs Other Solutions

**Why Longhorn over local-path?**
- ✅ Survives node failures (local-path does NOT)
- ✅ Automatic replication (local-path has NONE)
- ✅ Snapshots and backups (local-path has NONE)
- ✅ Production-ready (local-path is NOT)

**Why Longhorn over NFS?**
- ✅ No single point of failure (NFS server can die)
- ✅ Better performance (local storage + replication)
- ✅ Built-in backup and disaster recovery
- ✅ Automatic management via web UI

**When to use Longhorn:**
- ✅ Production environments
- ✅ 3+ node clusters (like yours!)
- ✅ When data loss is unacceptable
- ✅ When you need HA (High Availability)

**When NOT to use Longhorn:**
- ❌ Single node clusters (no benefit from replication)
- ❌ When you have less than 3 nodes (can't achieve proper HA)
- ❌ Development/testing on laptop (use local-path instead)

### Longhorn Configuration Tips

**Change replication count (in Longhorn UI or via StorageClass):**

```bash
# Create StorageClass with 2 replicas instead of 3
cat <<EOF | kubectl apply -f -
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: longhorn-2-replicas
provisioner: driver.longhorn.io
allowVolumeExpansion: true
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "2880"
  fromBackup: ""
EOF
```

---

## Comparison Table: Which Solution to Choose?

| Feature | local-path | NFS | Longhorn |
|---------|-----------|-----|----------|
| **Setup Difficulty** | ⭐ Easy | ⭐⭐ Medium | ⭐⭐⭐ Advanced |
| **ReadWriteOnce (RWO)** | ✅ Yes | ✅ Yes | ✅ Yes |
| **ReadWriteMany (RWX)** | ❌ No | ✅ Yes | ✅ Yes (via NFS) |
| **Survives Node Failure** | ❌ **NO** | ⚠️ If NFS HA | ✅ **YES** |
| **Data Replication** | ❌ None | ❌ Manual | ✅ Auto (3x) |
| **Snapshots** | ❌ No | ❌ No | ✅ Yes |
| **Web UI** | ❌ No | ❌ No | ✅ Yes |
| **Performance** | 🚀 Fast | ⚡ Medium | ⚡ Good |
| **Disk Usage** | 1x | 1x | 3x |
| **Production Ready** | ❌ **NO** | ⚠️ Limited | ✅ **YES** |
| **Best For** | Learning only | Shared files | **Production** |
| **Data Loss Risk** | 🔴 **HIGH** | 🟡 Medium | 🟢 **LOW** |

### Decision Matrix for Your 3-Node Cluster

**Choose local-path if:**
- ❌ You're just learning Kubernetes
- ❌ Data loss is acceptable (test environment)
- ❌ You understand the risks

**Choose NFS if:**
- ⚠️ You need ReadWriteMany for shared files
- ⚠️ You have NFS expertise and HA setup
- ⚠️ Legacy applications require NFS

**Choose Longhorn if:** ⭐ **RECOMMENDED**
- ✅ This is a production cluster
- ✅ Data loss is unacceptable
- ✅ You have 3 nodes (perfect for replication)
- ✅ You want automatic HA and disaster recovery
- ✅ You're using openSUSE (native SUSE/Rancher product)

**⚠️ PRODUCTION MANDATE:**

For any production workload on your 3-node openSUSE cluster:
1. **Primary storage**: Longhorn (HA, replicated, safe)
2. **Shared files (if needed)**: NFS with Longhorn backup
3. **Never use**: local-path (data loss guarantee)

---

## Practical Example: WordPress with Persistent Storage

Let's deploy WordPress with MySQL using persistent storage and production best practices!

### Using Longhorn with StatefulSet (Production Pattern):

**Why StatefulSet instead of Deployment for databases?**
- Stable, persistent pod identity
- Ordered deployment and scaling
- Stable network identifiers
- Automatic PVC management per pod

```bash
# Create namespace
kubectl create namespace wordpress

# Create PodDisruptionBudget for MySQL (CRITICAL for production)
cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: mysql-pdb
  namespace: wordpress
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: mysql
EOF

# MySQL StatefulSet with Longhorn persistent storage
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: mysql
  namespace: wordpress
spec:
  ports:
  - port: 3306
  clusterIP: None  # Headless service for StatefulSet
  selector:
    app: mysql
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
  namespace: wordpress
spec:
  serviceName: mysql
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
      - name: mysql
        image: mysql:8.0
        env:
        - name: MYSQL_ROOT_PASSWORD
          value: "rootpassword"
        - name: MYSQL_DATABASE
          value: "wordpress"
        - name: MYSQL_USER
          value: "wpuser"
        - name: MYSQL_PASSWORD
          value: "wppassword"
        ports:
        - containerPort: 3306
          name: mysql
        volumeMounts:
        - name: mysql-storage
          mountPath: /var/lib/mysql
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "500m"
  volumeClaimTemplates:
  - metadata:
      name: mysql-storage
    spec:
      accessModes: [ "ReadWriteOnce" ]
      storageClassName: longhorn
      resources:
        requests:
          storage: 10Gi
EOF

# Create PodDisruptionBudget for WordPress
cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: wordpress-pdb
  namespace: wordpress
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: wordpress
EOF

# WordPress Deployment with Longhorn persistent storage
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: wordpress-pvc
  namespace: wordpress
spec:
  storageClassName: longhorn
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wordpress
  namespace: wordpress
spec:
  replicas: 2
  selector:
    matchLabels:
      app: wordpress
  template:
    metadata:
      labels:
        app: wordpress
    spec:
      containers:
      - name: wordpress
        image: wordpress:latest
        env:
        - name: WORDPRESS_DB_HOST
          value: "mysql-0.mysql:3306"  # StatefulSet pod name
        - name: WORDPRESS_DB_NAME
          value: "wordpress"
        - name: WORDPRESS_DB_USER
          value: "wpuser"
        - name: WORDPRESS_DB_PASSWORD
          value: "wppassword"
        ports:
        - containerPort: 80
        volumeMounts:
        - name: wordpress-storage
          mountPath: /var/www/html
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
      volumes:
      - name: wordpress-storage
        persistentVolumeClaim:
          claimName: wordpress-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: wordpress
  namespace: wordpress
spec:
  type: NodePort
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30080
  selector:
    app: wordpress
EOF
```

**Why PodDisruptionBudget is CRITICAL:**

Without PDB, `kubectl drain` during maintenance can:
- Kill MySQL and WordPress simultaneously
- Cause downtime even though Longhorn protects data
- Violate SLA requirements

With PDB:
- `kubectl drain` waits for safe pod eviction
- Ensures at least 1 replica stays running
- Graceful maintenance without downtime

**Access WordPress:**

```bash
# Wait for pods to be ready
kubectl get pods -n wordpress -w

# Get NodePort
kubectl get svc -n wordpress wordpress

# Open in browser: http://<any-node-ip>:30080
# Complete WordPress installation

# Check in Longhorn UI:
# You should see 2 volumes (mysql-storage and wordpress-pvc)
# Each with 3 replicas across your nodes
```

**Test Production Resilience with PodDisruptionBudget:**

```bash
# After WordPress is configured, test graceful drain
# Find which node MySQL is on
NODE=$(kubectl get pod -n wordpress mysql-0 -o jsonpath='{.spec.nodeName}')
echo "MySQL is on: $NODE"

# Try to drain the node (PDB will prevent immediate kill)
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data

# Watch what happens:
# 1. kubectl drain respects PDB
# 2. Waits for safe eviction window
# 3. MySQL moves gracefully to another node
# 4. No downtime!

kubectl get pods -n wordpress -w

# Refresh WordPress in browser - it stays online!

# Restore node
kubectl uncordon $NODE
```

**This demonstrates real production-grade HA:**
- Longhorn protects data across nodes
- StatefulSet provides stable identity
- PodDisruptionBudget prevents unsafe eviction
- Application survives maintenance without downtime

**Cleanup:**

```bash
kubectl delete namespace wordpress
```

---

## Storage Best Practices

### 1. Always Use StorageClass with Dynamic Provisioning

❌ **Don't** manually create PersistentVolumes
✅ **Do** use StorageClass for automatic provisioning

```yaml
# Bad - manual PV creation
apiVersion: v1
kind: PersistentVolume
metadata:
  name: my-manual-pv
spec:
  capacity:
    storage: 10Gi
  ...

# Good - just create PVC, let StorageClass handle PV
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
spec:
  storageClassName: longhorn  # StorageClass creates PV automatically
  resources:
    requests:
      storage: 10Gi
```

### 2. Always Use Retain Policy for Production

**⚠️ CRITICAL FOR PRODUCTION**

```bash
# Check reclaim policy of your StorageClass
kubectl get storageclass longhorn -o yaml | grep reclaimPolicy

# If it shows "Delete", patch it to "Retain"
kubectl patch storageclass longhorn -p '{"reclaimPolicy":"Retain"}'
```

**Why Retain policy?**

| Scenario | Delete Policy | Retain Policy |
|----------|--------------|---------------|
| Developer accidentally deletes PVC | ❌ Data GONE forever | ✅ Data saved, manual cleanup needed |
| Automation script bug deletes PVC | ❌ Production data LOST | ✅ Data preserved, disaster avoided |
| Testing cleanup gone wrong | ❌ Customer data deleted | ✅ Data safe, can restore PVC |

**Real-world example:**
```bash
# Day 1: Create production database
kubectl apply -f mysql-pvc.yaml

# Day 30: Someone runs cleanup script
kubectl delete namespace production  # Oops!

# With Delete policy:
# → ALL database data is permanently deleted
# → No recovery possible
# → Business impact: SEVERE

# With Retain policy:
# → PVC deleted but PV remains with data intact
# → Can create new PVC pointing to same PV
# → Data recovered, business continues
```

### 3. Use Appropriate Access Modes

- Database? → ReadWriteOnce (RWO)
- Shared config? → ReadOnlyMany (ROX)
- Shared files? → ReadWriteMany (RWX)

### 4. Monitor Storage Usage

```bash
# Check PVC usage across all namespaces
kubectl get pvc -A

# Check PV status
kubectl get pv

# Check node disk space
kubectl get nodes -o custom-columns=NAME:.metadata.name,STORAGE:.status.capacity.ephemeral-storage

# For Longhorn, use the UI for detailed monitoring:
# - Per-volume usage
# - Replica health
# - Node capacity
# - I/O statistics
```

**Set up monitoring alerts for:**
- Disk usage > 80%
- Unhealthy replicas
- Failed backups
- PVC in Pending state

### 5. Implement Backup Strategy

**⚠️ CRITICAL: You need TWO types of backups**

| Backup Type | What It Protects | Tool | Frequency |
|-------------|------------------|------|-----------|
| **Application Data** | Your files, databases | Longhorn snapshots | Hourly/Daily |
| **Cluster State** | PVCs, Deployments, Secrets | **etcd backup** | Daily |

**Why you need BOTH:**

```
Scenario: Complete cluster failure

With only Longhorn backups:
❌ Application data exists
❌ But Kubernetes doesn't know about PVCs
❌ Can't mount volumes to pods
❌ Manual recovery required

With both Longhorn + etcd backups:
✅ Application data exists
✅ Cluster state restored
✅ Kubernetes knows about all PVCs
✅ Automatic recovery possible
```

#### Backup 1: Application Data (Longhorn)

**Configure Longhorn backup target:**

```bash
# In Longhorn UI:
# 1. Go to Settings → Backup Target
# 2. Configure S3 or NFS backup location
# 3. Enable automatic recurring backups

# Or configure via kubectl:
kubectl patch -n longhorn-system settings.longhorn.io/backup-target \
  --type=merge -p '{"value":"s3://my-bucket@region/backups"}'

# Create manual backup of a volume
# (In Longhorn UI, select volume → Create Backup)
```

**Automated Longhorn backup schedule:**

```bash
# Create recurring backup job
cat <<EOF | kubectl apply -f -
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: backup-daily
  namespace: longhorn-system
spec:
  cron: "0 2 * * *"  # 2 AM daily
  task: "backup"
  groups:
  - default
  retain: 7  # Keep 7 days
  concurrency: 2
  labels:
    backup-type: daily
EOF
```

#### Backup 2: Cluster State (etcd) - CRITICAL!

**⚠️ WITHOUT etcd BACKUP, YOU CANNOT RECOVER YOUR CLUSTER**

**Method 1: Manual etcd backup (Basic)**

```bash
# On master node - create etcd snapshot
sudo ETCDCTL_API=3 etcdctl snapshot save /backup/etcd-snapshot-$(date +%Y%m%d-%H%M%S).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Verify snapshot
sudo ETCDCTL_API=3 etcdctl snapshot status /backup/etcd-snapshot-*.db --write-out=table
```

**Method 2: Automated etcd backups (Production)**

```bash
# Create backup directory
sudo mkdir -p /backup/etcd

# Create backup script
cat <<'EOF' | sudo tee /usr/local/bin/etcd-backup.sh
#!/bin/bash
BACKUP_DIR="/backup/etcd"
RETENTION_DAYS=30

ETCDCTL_API=3 etcdctl snapshot save ${BACKUP_DIR}/etcd-snapshot-$(date +%Y%m%d-%H%M%S).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Verify backup
if [ $? -eq 0 ]; then
  echo "$(date): etcd backup successful" >> /var/log/etcd-backup.log
else
  echo "$(date): etcd backup FAILED" >> /var/log/etcd-backup.log
  exit 1
fi

# Remove old backups
find ${BACKUP_DIR} -name "etcd-snapshot-*.db" -mtime +${RETENTION_DAYS} -delete

# Copy to remote location (CRITICAL for DR)
# rsync -a ${BACKUP_DIR}/ user@backup-server:/backups/k8s-etcd/
EOF

sudo chmod +x /usr/local/bin/etcd-backup.sh

# Test backup script
sudo /usr/local/bin/etcd-backup.sh

# Add to crontab (daily at 2 AM)
echo "0 2 * * * /usr/local/bin/etcd-backup.sh" | sudo crontab -
```

#### Method 3: Velero (Enterprise-Grade Solution) - RECOMMENDED

**Why Velero?**
- ✅ Backs up BOTH application data AND cluster state
- ✅ Backs up PVCs, Deployments, Secrets, ConfigMaps
- ✅ Integrates with Longhorn
- ✅ Supports scheduled backups
- ✅ Easy restore process

```bash
# Install Velero CLI
wget https://github.com/vmware-tanzu/velero/releases/download/v1.14.0/velero-v1.14.0-linux-amd64.tar.gz
tar -xvf velero-v1.14.0-linux-amd64.tar.gz
sudo mv velero-v1.14.0-linux-amd64/velero /usr/local/bin/

# Install Velero with S3 backup location
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.10.0 \
  --bucket k8s-backups \
  --secret-file ./credentials-velero \
  --backup-location-config region=us-west-2 \
  --snapshot-location-config region=us-west-2 \
  --use-node-agent

# Create backup schedule
velero schedule create daily-backup \
  --schedule="0 2 * * *" \
  --ttl 720h0m0s

# Manual backup
velero backup create manual-backup-$(date +%Y%m%d)

# List backups
velero backup get

# Restore from backup
velero restore create --from-backup <backup-name>
```

**Backup schedule recommendation:**

| Data Type | Solution | Frequency | Retention |
|-----------|----------|-----------|-----------|
| **Critical DB** | Longhorn | Every 6h | 30 days |
| **Application** | Longhorn | Daily | 14 days |
| **Cluster State** | etcd backup | Daily | 30 days |
| **Full Cluster** | Velero | Daily | 30 days |

**For NFS (if using):**

```bash
# Automated NFS backup script
#!/bin/bash
BACKUP_DIR="/backup/nfs"
SOURCE="/srv/nfs/kubedata"
DATE=$(date +%Y%m%d-%H%M%S)

# Create backup
tar -czf ${BACKUP_DIR}/nfs-backup-${DATE}.tar.gz ${SOURCE}

# Remove backups older than 30 days
find ${BACKUP_DIR} -name "nfs-backup-*.tar.gz" -mtime +30 -delete

# Add to cron: 0 2 * * * /path/to/backup-script.sh
```

### 6. Plan for Capacity

**Calculate storage needs:**

```bash
# Current usage
kubectl get pvc -A -o json | jq -r '.items[] | "\(.metadata.name): \(.spec.resources.requests.storage)"'

# With Longhorn (3x replication):
# Actual disk usage = PVC size × 3
# Example: 100Gi PVC = 300Gi actual disk space
```

**Storage planning for 3-node cluster:**

| Node Disk Size | Usable for PVCs | With Longhorn (3x) |
|----------------|-----------------|---------------------|
| 100 GB | ~80 GB | ~26 GB PVC space |
| 500 GB | ~400 GB | ~133 GB PVC space |
| 1 TB | ~800 GB | ~266 GB PVC space |

**⚠️ Leave 20% free space for:**
- Operating system
- Kubernetes components
- Log files
- Temporary data

### 7. Use Volume Snapshots for Testing

**Before major changes, take snapshots:**

```bash
# Create snapshot (Longhorn)
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: pre-upgrade-snapshot
  namespace: production
spec:
  volumeSnapshotClassName: longhorn-snapshot-class
  source:
    persistentVolumeClaimName: production-db-pvc
EOF

# Perform upgrade/changes

# If something goes wrong, restore from snapshot
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: production-db-pvc-restored
  namespace: production
spec:
  storageClassName: longhorn
  dataSource:
    name: pre-upgrade-snapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
EOF
```

### 8. Security Best Practices

**Pod Security Context:**

```yaml
# Use security contexts for pods
apiVersion: v1
kind: Pod
metadata:
  name: secure-pod
spec:
  securityContext:
    runAsUser: 1000
    runAsGroup: 3000
    fsGroup: 2000  # Files created in volume will have this group
  containers:
  - name: app
    image: myapp
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: secure-pvc
```

**Network Security:**

**⚠️ IMPORTANT: Secure storage traffic in production**

```bash
# Create NetworkPolicy to restrict access to storage services

# 1. Restrict access to NFS server (if using)
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: nfs-server-policy
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: nfs-server
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          storage-access: "true"
    ports:
    - protocol: TCP
      port: 2049
EOF

# 2. Restrict access to Longhorn UI
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: longhorn-ui-policy
  namespace: longhorn-system
spec:
  podSelector:
    matchLabels:
      app: longhorn-ui
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: TCP
      port: 8000
EOF

# 3. Restrict iSCSI access (port 3260)
# This should be done at firewall level for better security
```

**Additional security measures:**

```bash
# Disable Longhorn UI access from outside cluster
kubectl patch svc longhorn-frontend -n longhorn-system -p '{"spec":{"type":"ClusterIP"}}'

# Enable authentication for Longhorn UI (in production)
# Configure in Longhorn Settings → General → Authentication
```

### 9. Test Disaster Recovery Regularly

**Monthly DR drill checklist:**

```bash
# 1. Create test volume with data
kubectl apply -f test-pvc.yaml
kubectl exec test-pod -- bash -c "echo 'DR test data' > /data/test.txt"

# 2. Create snapshot
kubectl apply -f test-snapshot.yaml

# 3. Delete original PVC and pod
kubectl delete pod test-pod
kubectl delete pvc test-pvc

# 4. Restore from snapshot
kubectl apply -f restored-pvc.yaml
kubectl apply -f test-pod.yaml

# 5. Verify data
kubectl exec test-pod -- cat /data/test.txt
# Should output: DR test data

# 6. Document time to recover (SLA target: < 15 minutes)
```

### 10. Production Readiness Checklist

Before going to production with your storage:

**Longhorn Configuration:**
- ✅ Longhorn installed on all 3 nodes
- ✅ 3 replicas configured (default)
- ✅ Retain reclaim policy set
- ✅ Backup target configured (S3 or NFS)
- ✅ Recurring backups enabled
- ✅ Storage minimal available percentage set (15%)
- ✅ Reserved storage percentage set (25%)

**Cluster State Backup:**
- ✅ etcd backup script created
- ✅ etcd backup cron job configured
- ✅ etcd backups stored remotely (not on cluster)
- ✅ etcd restore procedure tested

**Monitoring & Operations:**
- ✅ Monitoring alerts configured
- ✅ Disk pressure thresholds set
- ✅ PodDisruptionBudgets created for critical apps
- ✅ NetworkPolicies configured for storage services

**Disaster Recovery:**
- ✅ DR procedure tested and documented
- ✅ Velero installed (optional but recommended)
- ✅ Full backup/restore tested successfully
- ✅ RTO/RPO targets defined and tested

**Infrastructure:**
- ✅ Capacity planning completed (20% free space)
- ✅ All nodes have iSCSI enabled and running
- ✅ Network between nodes tested (> 1Gbps recommended)
- ✅ CSI snapshot CRDs installed

**Validation command:**

```bash
# Check CSI snapshot CRDs
kubectl get crd | grep snapshot
# Should show:
# volumesnapshotclasses.snapshot.storage.k8s.io
# volumesnapshotcontents.snapshot.storage.k8s.io
# volumesnapshots.snapshot.storage.k8s.io

# Run this on master to verify production readiness
cat << 'EOF' | bash
echo "=== Storage Production Readiness Check ==="
echo ""

echo "1. Checking Longhorn installation..."
kubectl get pods -n longhorn-system | grep -v Running && echo "❌ Some pods not running" || echo "✅ All Longhorn pods running"

echo ""
echo "2. Checking replica count..."
kubectl get settings.longhorn.io -n longhorn-system default-replica-count -o jsonpath='{.value}' | grep 3 && echo "✅ 3 replicas configured" || echo "❌ Replica count not set to 3"

echo ""
echo "3. Checking StorageClass reclaim policy..."
kubectl get storageclass longhorn -o jsonpath='{.reclaimPolicy}' | grep Retain && echo "✅ Retain policy set" || echo "⚠️ Reclaim policy is Delete - CHANGE TO RETAIN!"

echo ""
echo "4. Checking disk pressure settings..."
kubectl get settings.longhorn.io -n longhorn-system storage-minimal-available-percentage -o jsonpath='{.value}' | grep -E '^(10|15|20)

---

## Troubleshooting Storage Issues

### PVC Stuck in Pending

```bash
# Check PVC events
kubectl describe pvc <pvc-name>

# Common issues:
# - StorageClass doesn't exist
# - No available storage
# - Provisioner not running
```

**Fix:**
```bash
# Check StorageClass exists
kubectl get storageclass

# Check provisioner pods
kubectl get pods -n <provisioner-namespace>
```

### Pod Can't Mount Volume

```bash
# Check pod events
kubectl describe pod <pod-name>

# Common issues:
# - PVC doesn't exist
# - Access mode mismatch
# - Node doesn't have required drivers
```

**Fix for NFS:**
```bash
# On worker nodes, ensure NFS client is installed
sudo zypper install -y nfs-client
```

**Fix for Longhorn:**
```bash
# Ensure iSCSI is running on all nodes
sudo systemctl status iscsid
```

### Storage Full

```bash
# Check disk usage on nodes
df -h

# For Longhorn, check in UI or:
kubectl get nodes -o json | jq '.items[] | {name: .metadata.name, storage: .status.capacity.storage}'
```

**Fix:**
```bash
# Delete unused PVCs
kubectl get pvc -A
kubectl delete pvc <unused-pvc>

# For Longhorn, clean old snapshots in UI
```

### Performance Issues

```bash
# Check I/O wait on nodes
top
# Look at "wa" (wait) percentage

# Test disk speed
dd if=/dev/zero of && echo "✅ Disk pressure threshold configured" || echo "⚠️ Set storage-minimal-available-percentage!"

echo ""
echo "5. Checking backup target..."
kubectl get settings.longhorn.io -n longhorn-system backup-target -o jsonpath='{.value}' | grep -q 's3\|nfs' && echo "✅ Backup target configured" || echo "⚠️ No backup target configured!"

echo ""
echo "6. Checking etcd backup..."
[ -f /backup/etcd/etcd-snapshot-*.db ] && echo "✅ etcd backups exist" || echo "❌ No etcd backups found!"

echo ""
echo "7. Checking iSCSI on nodes..."
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "  Checking $node..."
done

echo ""
echo "8. Checking disk space..."
kubectl get nodes -o json | jq -r '.items[] | .metadata.name + ": " + (.status.capacity.storage // "unknown")' 

echo ""
echo "9. Checking PodDisruptionBudgets..."
kubectl get pdb -A | grep -q "." && echo "✅ PDBs configured" || echo "⚠️ No PodDisruptionBudgets found"

echo ""
echo "10. Checking CSI Snapshot CRDs..."
kubectl get crd | grep -q volumesnapshot && echo "✅ CSI Snapshot CRDs installed" || echo "❌ CSI Snapshot CRDs missing"

echo ""
echo "=== Check complete ==="
EOF
```

---

## Troubleshooting Storage Issues

### PVC Stuck in Pending

```bash
# Check PVC events
kubectl describe pvc <pvc-name>

# Common issues:
# - StorageClass doesn't exist
# - No available storage
# - Provisioner not running
```

**Fix:**
```bash
# Check StorageClass exists
kubectl get storageclass

# Check provisioner pods
kubectl get pods -n <provisioner-namespace>
```

### Pod Can't Mount Volume

```bash
# Check pod events
kubectl describe pod <pod-name>

# Common issues:
# - PVC doesn't exist
# - Access mode mismatch
# - Node doesn't have required drivers
```

**Fix for NFS:**
```bash
# On worker nodes, ensure NFS client is installed
sudo zypper install -y nfs-client
```

**Fix for Longhorn:**
```bash
# Ensure iSCSI is running on all nodes
sudo systemctl status iscsid
```

### Storage Full

```bash
# Check disk usage on nodes
df -h

# For Longhorn, check in UI or:
kubectl get nodes -o json | jq '.items[] | {name: .metadata.name, storage: .status.capacity.storage}'
```

**Fix:**
```bash
# Delete unused PVCs
kubectl get pvc -A
kubectl delete pvc <unused-pvc>

# For Longhorn, clean old snapshots in UI
```

### Performance Issues

```bash
# Check I/O wait on nodes
top
# Look at "wa" (wait) percentage

# Test disk speed
dd if=/dev/zero of