# High Availability Cluster with Pacemaker and Corosync on openSUSE Leap 15.6

**⚠️ IMPORTANT NOTICE:**
- ✅ This guide creates a **LAB/TESTING** cluster setup
- ❌ Current configuration is **NOT SAFE for production** (diskless SBD, no fencing)
- ⚠️ **HIGH SPLIT-BRAIN RISK** - can cause data corruption in production
- 📋 See "Production Requirements" section at the end for production-ready setup

---

## Prerequisites
- Two nodes: node1 and node2
- Shared storage (iSCSI or similar) accessible from both nodes
- Network connectivity between nodes
- Root access on both nodes

## 1. Verify Storage Layout

```bash
lsblk
```

Expected output similar to:
```
NAME            MAJ:MIN RM  SIZE RO TYPE MOUNTPOINT
sda               8:0    0    8G  0 disk 
├─sda1            8:1    0    1G  0 part /boot
└─sda2            8:2    0    7G  0 part 
  ├─system-root 253:0    0  6.2G  0 lvm  /
  └─system-swap 253:1    0  820M  0 lvm  [SWAP]
sdb               8:16   0    8G  0 disk  # Shared storage
```

---

## 2. Install High Availability Packages (on both nodes)

### Add HA Clustering Repository

```bash
# Check your openSUSE version
cat /etc/os-release

# Add the HA clustering repository
sudo zypper addrepo https://download.opensuse.org/repositories/network:/ha-clustering:/Stable/15.6/ network-ha-stable
sudo zypper refresh
```

### Accept GPG Key
When prompted, type `a` to always trust the repository key.

### Search for Required Packages

```bash
# Search for python-lxml (needed for crmsh)
sudo zypper search python3*lxml

# Search for libltdl (needed for cluster-glue)
sudo zypper search libltdl

# Search for libtool
sudo zypper search libtool
```

### Install Dependencies First

```bash
# Install common dependencies (adjust package names based on search results)
sudo zypper install -y python311-lxml libltdl7 libtool

# Or try:
sudo zypper install -y python3-lxml libltdl7
```

### Install Cluster Packages

```bash
sudo zypper install -y pacemaker corosync crmsh resource-agents cluster-glue
```

**Note:** openSUSE uses `crmsh` instead of `pcs` for cluster management.

### Enable and Start Services

```bash
sudo systemctl enable pacemaker
sudo systemctl enable corosync

# Note: Don't start services yet - we'll configure first
```

### Set Password for hacluster User

```bash
sudo passwd hacluster
```
Use the same password on both nodes (e.g., `hacluster123`).

---

## 3. Configure Cluster

### On Node1 ONLY - Initialize Cluster

```bash
# Initialize the cluster (run ONLY on pcs-cluster-node-01)
sudo crm cluster init --name storage_cluster
```

**When prompted, answer:**
- `WARNING: No NTP service found. Continue anyway?` → Type `y` and press Enter
- `Continue?` (regarding hacluster shell change) → Type `y` and press Enter
- `Address for ring0 [192.168.100.71]` → Press Enter (accept default)
- `Port for ring0 [5405]` → Press Enter (accept default)
- `Do you wish to use SBD?` → Type `y` and press Enter
- `Path to storage device` → Type `none` and press Enter (use diskless SBD)
- `Do you wish to configure a virtual IP address?` → Type `n` and press Enter
- `Do you want to configure QDevice?` → Type `n` and press Enter

**⚠️ IMPORTANT - SBD Configuration:**
- `none` = Diskless SBD (fencing simulated in memory)
- ✅ **Safe for:** Lab, testing, development
- ❌ **NOT safe for production:** No actual fencing happens - risk of data corruption in split-brain scenarios

**For Production Clusters:**
- Use a dedicated small disk/partition for SBD (minimum 1MB)
- Example: `/dev/disk/by-id/scsi-<your-disk-id>` or a separate LUN
- **DO NOT use `/dev/sdb`** - that's your data disk!
- Consider using a third small disk just for SBD fencing

### On Node2 ONLY - Join the Cluster

**⚠️ Prerequisites:**
- Ensure root SSH access is enabled on node-01, OR
- Have the root password ready for node-01

**Note:** openSUSE disables root SSH login by default. The join process needs root SSH access.

```bash
# Join node2 to the cluster (run ONLY on pcs-cluster-node-02)
sudo crm cluster join -c pcs-cluster-node-01
```

**When prompted, answer:**
- `WARNING: No NTP service found. Continue anyway?` → Type `y` and press Enter
- `(root@pcs-cluster-node-01) Password:` → Enter **root password** of node-01
- `Continue?` (regarding hacluster shell change) → Type `y` and press Enter
- `Address for ring0 [192.168.100.72]` → Press Enter (accept default)

**If SSH connection fails:**
```bash
# On node-01, temporarily enable root SSH (if needed)
sudo vi /etc/ssh/sshd_config
# Change: PermitRootLogin yes
sudo systemctl restart sshd

# After cluster setup, revert to: PermitRootLogin no
```

Wait for the join process to complete. You'll see "Done" when finished.

### Verify Cluster Status (on node-01)

```bash
sudo crm status
```

Expected output:
```
Cluster Summary:
  * Stack: corosync (Pacemaker is running)
  * Current DC: pcs-cluster-node-01
  * 2 nodes configured
  * 0 resource instances configured

Node List:
  * Online: [ pcs-cluster-node-01 pcs-cluster-node-02 ]

Full List of Resources:
  * No resources
```

### Configure Cluster Properties (on node-01)

```bash
# Disable STONITH (fencing)
sudo crm configure property stonith-enabled=false

# Disable watchdog timeout (important for diskless SBD)
sudo crm configure property stonith-watchdog-timeout=0

# Set quorum policy for 2-node cluster
sudo crm configure property no-quorum-policy=ignore

# Verify configuration
sudo crm configure show
```

### Verify Final Status

```bash
sudo crm status
```

Both nodes should show as "Online". Cluster is now ready for storage configuration!

---

## 4. Configure Cluster LVM and Filesystem

### Verify Shared Storage (on both nodes)

```bash
lsblk
```

You should see `/dev/sdb` (8GB shared disk) on both nodes.

### Create Partition on Shared Storage (node1 only)

```bash
sudo fdisk /dev/sdb
```

Commands in fdisk:
```
n       # New partition
p       # Primary
1       # Partition number
Enter   # First sector (default)
Enter   # Last sector (default)
w       # Write changes
```

### Create LVM Structure (node1 only)

```bash
sudo pvcreate /dev/sdb1
sudo vgcreate cluster_vg /dev/sdb1
sudo lvcreate -L 1G -n cluster_lv cluster_vg
sudo mkfs.xfs /dev/cluster_vg/cluster_lv
```

---

## 5. Configure LVM for Clustering (on both nodes)

### Check Current Volume Groups

```bash
sudo vgs
```

Example output:
```
  VG         #PV #LV #SN Attr   VSize  VFree 
  system       1   2   0 wz--n- <7.00g     0 
  cluster_vg   1   1   0 wz--n- <7.94g <6.94g
```

Note your system volume group name (probably `system` on openSUSE, not `centos`).

### Update LVM Configuration

Edit `/etc/lvm/lvm.conf` on **both nodes**:

```bash
sudo vi /etc/lvm/lvm.conf
```

**Important:** These settings must be in the correct sections to avoid warnings.

#### 1. Find the `global {` section and ensure it contains:

```conf
global {
    # Other settings...
    locking_type = 1
}
```

If `locking_type` doesn't exist in the `global` section, add it there.

#### 2. Find the `devices {` section and ensure it contains:

```conf
devices {
    # Other settings...
    use_lvmetad = 0
}
```

If `use_lvmetad` doesn't exist in the `devices` section, add it there.

#### 3. Find the `activation {` section and add volume_list:

```conf
activation {
    # Add ONLY your system volume group name here
    # Replace "system" with your actual VG name from 'vgs' command
    volume_list = [ "system" ]
    
    # DO NOT include cluster_vg in this list!
}
```

**Critical Points:**
- `locking_type = 1` must be inside `global { }` section
- `use_lvmetad = 0` must be inside `devices { }` section  
- `volume_list` must be inside `activation { }` section
- Only include your system/local VG in volume_list, NOT cluster_vg
- Use the exact VG name from `vgs` output

### Verify Configuration

```bash
# Check for configuration errors
sudo vgs

# Should show no "invalid" warnings if configured correctly
```

### Rebuild initramfs and Update Bootloader (on both nodes)

```bash
# Rebuild initramfs
sudo dracut -f -v

# Update GRUB configuration
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

# Reboot BOTH nodes
sudo reboot
```

**Note:** Reboot may take 2-3 minutes longer than usual. Wait for both nodes to come back online.

---

## 6. Create Cluster Resources (node1 only - after reboot)

After both nodes are back online, verify cluster status first:

```bash
# Check cluster status
sudo crm status

# Both nodes should show as "Online"
```

### Create LVM and Filesystem Resources

```bash
# Create LVM resource
sudo crm configure primitive my_lvm LVM \
    params volgrpname=cluster_vg exclusive=true \
    op monitor interval=30s

# Create Filesystem resource
sudo crm configure primitive my_fs Filesystem \
    params device="/dev/mapper/cluster_vg-cluster_lv" \
        directory="/mnt" \
        fstype="xfs" \
    op monitor interval=20s

# Group resources together (ensures they run on same node)
sudo crm configure group my_group my_lvm my_fs

# Commit configuration
sudo crm configure commit
```

### Verify Resources

```bash
# Check resource status
sudo crm status
```

Expected output:
```
Cluster Summary:
  * 2 nodes configured
  * 2 resource instances configured

Node List:
  * Online: [ pcs-cluster-node-01 pcs-cluster-node-02 ]

Full List of Resources:
  * Resource Group: my_group
    * my_lvm  (ocf::heartbeat:LVM):       Started pcs-cluster-node-01
    * my_fs   (ocf::heartbeat:Filesystem): Started pcs-cluster-node-01
```

### Verify Mounted Filesystem

```bash
# Check if filesystem is mounted
df -h /mnt

# Should show:
# /dev/mapper/cluster_vg-cluster_lv  1014M  33M  982M  4% /mnt
```

---

## 7. Test Cluster Failover

### Test 1: Stop Cluster on Active Node

```bash
# If resources are on node1, stop cluster service
sudo crm cluster stop

# On node2, check status
sudo crm status
```

Resources should now be running on node2:
```
Resource Group: my_group
    my_lvm  (ocf::heartbeat:LVM):   Started node2
    my_fs   (ocf::heartbeat:Filesystem):    Started node2
```

### Test 2: Simulate Node Failure

```bash
# Power off or disconnect network on active node
sudo poweroff
```

Resources should automatically migrate to the other node.

### Test 3: Manual Resource Migration

```bash
# Move resources to specific node
sudo crm resource move my_group node2

# Or let cluster decide
sudo crm resource unmove my_group
```

---

## 8. Useful Commands

### Cluster Management

```bash
# Check cluster status
sudo crm status

# View detailed configuration
sudo crm configure show

# Interactive cluster shell
sudo crm

# Check node status
sudo crm node list

# Check corosync status
sudo corosync-cfgtool -s
```

### Resource Management

```bash
# List all resources
sudo crm resource list

# Start/stop resources
sudo crm resource start my_group
sudo crm resource stop my_group

# Cleanup failed resources
sudo crm resource cleanup my_group

# Show resource configuration
sudo crm configure show my_group
```

### Troubleshooting

```bash
# Check logs
sudo journalctl -u pacemaker -f
sudo journalctl -u corosync -f

# Verify LVM configuration
sudo vgs
sudo lvs
sudo pvs

# Check if filesystem is mounted
mount | grep cluster_vg
df -h /mnt

# Test manual LVM activation (for troubleshooting only)
sudo vgchange -ay cluster_vg
sudo mount /dev/cluster_vg/cluster_lv /mnt
```

---

## Key Differences from CentOS/RHEL

1. **Package Manager**: Use `zypper` instead of `yum`
2. **Cluster Tool**: Use `crmsh` (crm command) instead of `pcs`
3. **Repository**: Need to add HA clustering repository manually
4. **Service Names**: Same (pacemaker, corosync)
5. **Configuration Files**: Same locations (/etc/lvm/lvm.conf, etc.)

---

## Common Issues and Solutions

### Issue: "Configuration setting invalid. It's not part of any section"

**Problem:** LVM settings are placed outside their proper sections in `/etc/lvm/lvm.conf`

**Solution:** 
```bash
# Verify settings are in correct sections:
# - locking_type should be in global { } section
# - use_lvmetad should be in devices { } section
# - volume_list should be in activation { } section

# Check placement:
grep -B5 -A5 "locking_type" /etc/lvm/lvm.conf
grep -B5 -A5 "use_lvmetad" /etc/lvm/lvm.conf

# Move settings to correct sections if needed
```

### Issue: Packages not found

**Solution:** Ensure you've added the correct repository:
```bash
sudo zypper lr -d | grep ha
```

### Issue: Dependency errors (python3-lxml, libltdl)

**Solution:** Search for the correct package name:
```bash
sudo zypper search lxml
sudo zypper search libltdl
```

Then install with the correct name (e.g., `python311-lxml`, `libltdl7`).

### Issue: Resources won't start

**Solution:** Check logs and cleanup:
```bash
sudo journalctl -u pacemaker -n 100
sudo crm resource cleanup my_group
```

### Issue: Split-brain scenario

**Solution:** Use fencing (STONITH) in production:
```bash
sudo crm configure property stonith-enabled=true
# Configure fencing device
```

---

---

## 🚨 SPLIT-BRAIN PROTECTION - Required for Production

**What is Split-Brain?**
- When network fails between nodes, each node thinks the other is dead
- Both nodes try to take over resources and mount the same filesystem
- **Result: Data corruption, file system damage, cluster failure**

**Your Current Risk Level: 🔴 HIGH**
- Diskless SBD = no real fencing
- STONITH disabled = nodes cannot force-shutdown each other
- 2-node cluster without QDevice = no tie-breaker

### Required Actions (Priority Order)

#### 1️⃣ CRITICAL: Enable STONITH Fencing

**Without fencing, DO NOT run in production!**

**Option A: SBD Fencing** (Recommended if you have shared storage)

```bash
# ⚠️ You need a SEPARATE small disk/LUN for SBD (NOT /dev/sdb!)
# Minimum 1MB, use persistent device path

# Create SBD device
sudo sbd -d /dev/disk/by-id/scsi-XXXXXXXXX create

# Configure in cluster (on node-01)
sudo crm configure property stonith-enabled=true
sudo crm configure property stonith-watchdog-timeout=5

sudo crm configure primitive stonith-sbd stonith:external/sbd \
    params sbd_device="/dev/disk/by-id/scsi-XXXXXXXXX" \
    op monitor interval=60s

# Verify
sudo crm status
sudo sbd -d /dev/disk/by-id/scsi-XXXXXXXXX list
```

**Option B: IPMI/iLO/iDRAC Fencing** (If servers have management interfaces)

```bash
# Install fence agents
sudo zypper install -y fence-agents

# Get IPMI info from your servers
# Node-01 IPMI: 192.168.1.10
# Node-02 IPMI: 192.168.1.11

# Configure fencing for node-01
sudo crm configure primitive stonith-node1 stonith:fence_ipmilan \
    params ipaddr="192.168.1.10" \
        login="admin" \
        passwd="ipmi_password" \
        pcmk_host_list="pcs-cluster-node-01" \
        lanplus=1 \
    op monitor interval=60s

# Configure fencing for node-02
sudo crm configure primitive stonith-node2 stonith:fence_ipmilan \
    params ipaddr="192.168.1.11" \
        login="admin" \
        passwd="ipmi_password" \
        pcmk_host_list="pcs-cluster-node-02" \
        lanplus=1 \
    op monitor interval=60s

# CRITICAL: Prevent nodes from fencing themselves
sudo crm configure location loc-stonith-node1 stonith-node1 -inf: pcs-cluster-node-01
sudo crm configure location loc-stonith-node2 stonith-node2 -inf: pcs-cluster-node-02

# Enable STONITH
sudo crm configure property stonith-enabled=true
sudo crm configure property stonith-watchdog-timeout=0

# Test fencing (⚠️ This will reboot node-02!)
sudo stonith_admin --reboot pcs-cluster-node-02

# Verify status
sudo crm status
```

#### 2️⃣ HIGHLY RECOMMENDED: Add QDevice (2-Node Clusters)

**Why:** Provides third vote, prevents 50/50 split situations

```bash
# Setup Requirements:
# - Third server (VM is fine) - NOT a cluster node
# - Network access from both cluster nodes
# - Hostname: qdevice.example.com (or use IP)

# On QDevice Server (third machine)
sudo zypper install -y corosync-qnetd
sudo systemctl enable corosync-qnetd
sudo systemctl start corosync-qnetd

# Open firewall
sudo firewall-cmd --permanent --add-port=5403/tcp
sudo firewall-cmd --reload

# On Cluster Node-01
sudo zypper install -y corosync-qdevice

# Initialize qdevice
sudo crm cluster init qdevice \
    --qnetd-hostname=qdevice.example.com \
    --qdevice-port=5403

# Verify qdevice status
sudo crm status
# Should show: qdevice votes: 1

# Change quorum policy (now safe with 3 votes)
sudo crm configure property no-quorum-policy=stop

# Test: Stop node-02 - node-01 should continue (2 votes: node1 + qdevice)
```

#### 3️⃣ IMPORTANT: Network Redundancy

**Why:** If primary network fails, cluster can continue on secondary

```bash
# Requirements:
# - Two physical network interfaces on each node
# - Different network subnets
# - Example: eth0 (192.168.100.x), eth1 (10.0.0.x)

# On both nodes, edit corosync config
sudo vi /etc/corosync/corosync.conf

# Find the interface section and modify:
totem {
    version: 2
    cluster_name: storage_cluster
    transport: knet
    
    # Ring 0 - Primary network
    interface {
        ringnumber: 0
        bindnetaddr: 192.168.100.0
        mcastport: 5405
        ttl: 1
    }
    
    # Ring 1 - Secondary network (ADD THIS)
    interface {
        ringnumber: 1
        bindnetaddr: 10.0.0.0
        mcastport: 5407
        ttl: 1
    }
}

# Restart corosync on both nodes
sudo systemctl restart corosync

# Verify both rings are active
sudo corosync-cfgtool -s
# Should show: ring 0 active, ring 1 active

# Test: Disconnect primary network - cluster should stay online via ring 1
```

#### 4️⃣ Resource-Level Protection

```bash
# Prevent unnecessary resource migrations
sudo crm configure rsc_defaults resource-stickiness=100

# Set failure thresholds
sudo crm configure rsc_defaults migration-threshold=3

# Configure proper timeouts
sudo crm configure op_defaults timeout=60s on-fail=block

# Verify
sudo crm configure show
```

#### 5️⃣ Enable Time Synchronization

**Why:** Time drift causes cluster coordination failures

```bash
# On both nodes
sudo zypper install -y chrony

# Configure NTP servers
sudo vi /etc/chrony.conf
# Add your NTP servers:
# server ntp1.example.com iburst
# server ntp2.example.com iburst

# Start and enable
sudo systemctl enable chronyd
sudo systemctl start chronyd

# Verify sync
chronyc tracking
chronyc sources
```

#### 6️⃣ Install Monitoring (Hawk Web UI)

```bash
# On both nodes
sudo zypper install -y hawk2

# Start and enable
sudo systemctl enable hawk
sudo systemctl start hawk

# Open firewall
sudo firewall-cmd --permanent --add-port=7630/tcp
sudo firewall-cmd --reload

# Access: https://node-ip:7630
# Login: hacluster / <your-password>
```

---

## ✅ Production Readiness Checklist

Before going to production, verify:

- [ ] **STONITH enabled** (`stonith-enabled=true`)
- [ ] **Fencing tested** (successfully rebooted a node via cluster)
- [ ] **QDevice configured** (for 2-node clusters)
- [ ] **Network redundancy** (2+ corosync rings on different networks)
- [ ] **Time sync enabled** (chrony/NTP running on all nodes)
- [ ] **Resource constraints** configured (stickiness, thresholds)
- [ ] **Monitoring installed** (Hawk or external monitoring)
- [ ] **Backup procedures** documented and tested
- [ ] **Failover tested** multiple times successfully
- [ ] **Split-brain recovery** procedure documented
- [ ] **Root SSH disabled** (security hardening)
- [ ] **Firewall rules** configured for cluster ports
- [ ] **Documentation** complete (runbooks, contact info)

**🔴 If any item is unchecked, cluster is NOT production-ready!**

---

## Production Recommendations

1. **Enable STONITH**: Configure proper fencing for split-brain protection
2. **Use Quorum**: For 3+ node clusters, enable quorum
3. **Network Redundancy**: Configure multiple corosync rings
4. **Monitoring**: Set up proper monitoring and alerting
5. **Backup**: Regular backup of cluster configuration
6. **Testing**: Test failover scenarios regularly

---

## Next Steps

- Configure additional resources (IP addresses, services)
- Set up monitoring (Hawk web interface)
- Configure fencing devices
- Implement backup procedures
- Document your specific cluster configuration