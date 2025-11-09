# Shared iSCSI Storage Setup for Pacemaker/Corosync Cluster on openSUSE Leap 15.6 (Boss & Bobby)

## Overview
This document outlines the full procedure to:
1. Configure iSCSI targets on the storage server (`base-host-01`).  
2. Add new shared disks for cluster use (Boss & Bobby).  
3. Correctly map LUNs and ACLs for cluster nodes.  
4. Verify configuration and ensure persistence across reboots.  
5. Troubleshoot common issues during setup.

**Environment Summary**

| Hostname | Role | IP | iSCSI IQN |
|----------|------|----|-----------|
| `base-host-01` | Storage Server | 192.168.100.201 | target1, bossbobby-cluster |
| `pcs-cluster-node-01` | Cluster Node 1 | 192.168.100.202 | pcs-cluster-node-01 |
| `pcs-cluster-node-02` | Cluster Node 2 | 192.168.100.203 | pcs-cluster-node-02 |
| `boss` | Cluster Node 3 | 192.168.100.204 | boss |
| `bobby` | Cluster Node 4 | 192.168.100.205 | bobby |

---

## 1. Storage Server Setup (`base-host-01`)

### 1.1 Install iSCSI target
```bash
sudo zypper install -y targetcli-fb
sudo systemctl enable --now target
```

### 1.2 Verify existing disks
```bash
lsblk
```

**Initial state example:**
```
sda  32G  → OS
sdb  10G  → existing iSCSI target
```

### 1.3 Add new disks for cluster
- 1 × 5 GB → separate VG (config)  
- 4 × 4 GB → striped VG (shared storage)

Verify Linux sees new disks:
```bash
lsblk
```

Expected output:
```
sdc  5G
sdd  4G
sde  4G
sdf  4G
sdg  4G
```

> **Tip:** If disks do not appear, perform SCSI rescan:
```bash
echo "- - -" | sudo tee /sys/class/scsi_host/host*/scan
```

### 1.4 Create iSCSI backstores
```bash
sudo targetcli
/backstores/block> create device_bossbobby_cfg_1_5G_opensuse15 /dev/sdc
/backstores/block> create device_bossbobby_stripe_1_4G_opensuse15 /dev/sdd
/backstores/block> create device_bossbobby_stripe_2_4G_opensuse15 /dev/sde
/backstores/block> create device_bossbobby_stripe_3_4G_opensuse15 /dev/sdf
/backstores/block> create device_bossbobby_stripe_4_4G_opensuse15 /dev/sdg
```

### 1.5 Create iSCSI target for new cluster disks
```bash
/iscsi> create iqn.2025-11.localhost.storage:bossbobby-cluster
```
- Default portal: `0.0.0.0:3260`
- TPG created automatically

### 1.6 Map LUNs
```bash
/iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1/luns> create /backstores/block/device_bossbobby_stripe_1_4G_opensuse15
/iscsi/.../luns> create /backstores/block/device_bossbobby_stripe_2_4G_opensuse15
/iscsi/.../luns> create /backstores/block/device_bossbobby_stripe_3_4G_opensuse15
/iscsi/.../luns> create /backstores/block/device_bossbobby_stripe_4_4G_opensuse15
/iscsi/.../luns> create /backstores/block/device_bossbobby_cfg_1_5G_opensuse15
```

> **Note:** LUN0–3 = striped disks (`/dev/sdd`–`/dev/sdg`), LUN4 = config disk (`/dev/sdc`).

**Important:** If a backstore shows as "deactivated", activate it before creating the LUN:
```bash
/backstores/block/device_bossbobby_cfg_1_5G_opensuse15> set attribute emulate_tpu=1
```

### 1.7 Add ACLs for cluster nodes
Navigate to ACL path:
```bash
cd /iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1/acls
```

Create ACLs:
```bash
create iqn.2025-11.localhost.storage:boss
create iqn.2025-11.localhost.storage:bobby
```

The LUNs will be automatically mapped to each ACL when created.

### 1.8 Save configuration
```bash
/saveconfig
exit
```

Verify:
```bash
sudo targetcli ls
```

Expected output should show:
- All 5 backstores visible and activated
- 5 LUNs mapped (lun0–lun4)
- ACLs present for `boss` and `bobby` with all 5 LUNs mapped

---

## 2. Cluster Node Setup (`boss` and `bobby`)

### 2.1 Install iSCSI initiator
```bash
sudo zypper install -y open-iscsi
```

### 2.2 Configure initiator name

**Boss:**
```bash
echo "InitiatorName=iqn.2025-11.localhost.storage:boss" | sudo tee /etc/iscsi/initiatorname.iscsi
```

**Bobby:**
```bash
echo "InitiatorName=iqn.2025-11.localhost.storage:bobby" | sudo tee /etc/iscsi/initiatorname.iscsi
```

### 2.3 Enable and start iSCSI services
```bash
sudo systemctl enable --now iscsid iscsi
```

### 2.4 Discover the target
```bash
sudo iscsiadm -m discovery -t st -p 192.168.100.201
```

Expected output:
```
192.168.100.201:3260,1 iqn.2025-11.localhost.storage:bossbobby-cluster
```

### 2.5 Log in to the target
```bash
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 -l
```

### 2.6 Verify disks
```bash
lsblk
```

Expected:
```
sdb  4G  → stripe disk 1
sdc  5G  → config VG
sdd  4G  → stripe disk 2
sde  4G  → stripe disk 3
sdf  4G  → stripe disk 4
```

**If not all disks appear**, rescan the iSCSI session:
```bash
sudo iscsiadm -m session --rescan
# Wait a moment
sleep 2
lsblk
```

If still missing, force SCSI rescan:
```bash
echo "- - -" | sudo tee /sys/class/scsi_host/host*/scan
lsblk
```

### 2.7 Enable auto-login for persistent disks (CRITICAL)

**This is the most important step to ensure disks appear automatically after reboot:**

```bash
# Set automatic login for the target
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 --op update -n node.startup -v automatic

# Verify the setting
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 -o show | grep node.startup
```

Expected output:
```
node.startup = automatic
```

**Ensure iSCSI services are enabled at boot:**
```bash
sudo systemctl enable iscsid
sudo systemctl enable iscsi
```

### 2.8 Test persistence
```bash
# Reboot the node
sudo reboot

# After reboot, verify disks are automatically present
lsblk
```

All 5 iSCSI disks (sdb through sdf) should be present without any manual intervention.

---

## 3. Troubleshooting Guide

### 3.1 Issue: Disks disappear after reboot

**Symptoms:**
- iSCSI disks are present after manual login
- After reboot, disks are missing
- Need to manually run connection script

**Diagnosis:**
```bash
# Check if automatic login is configured
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 -o show | grep node.startup

# Check if iSCSI services are enabled
sudo systemctl status iscsid
sudo systemctl status iscsi
```

**Solution:**

This was the exact issue encountered during setup. The fix requires:

```bash
# Stop iSCSI services
sudo systemctl stop iscsi iscsid

# Ensure correct initiator name
echo "InitiatorName=iqn.2025-11.localhost.storage:boss" | sudo tee /etc/iscsi/initiatorname.iscsi

# Remove cached configurations
sudo rm -rf /etc/iscsi/nodes/*
sudo rm -rf /etc/iscsi/send_targets/*

# Start initiator daemon
sudo systemctl start iscsid

# Discover targets
sudo iscsiadm -m discovery -t st -p 192.168.100.201

# Login to target
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 -l

# CRITICAL: Enable automatic login
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 --op update -n node.startup -v automatic

# Enable services at boot
sudo systemctl enable iscsid
sudo systemctl enable iscsi

# Verify disks
lsblk

# Test by rebooting
sudo reboot
```

**Real-world example from Boss node:**

Before fix (after reboot):
```
boss:~ # lsblk
NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
sda      8:0    0   32G  0 disk 
├─sda1   8:1    0    8M  0 part 
├─sda2   8:2    0   30G  0 part /var
└─sda3   8:3    0    2G  0 part [SWAP]
sr0     11:0    1  4.3G  0 rom
```

After running f1.sh (manual connection script):
```
boss:~ # bash f1.sh
Stopping 'iscsid.service', but its triggering units are still active:
iscsid.socket
InitiatorName=iqn.2025-11.localhost.storage:boss
192.168.100.201:3260,1 iqn.2025-10.localhost.storage:target1
192.168.100.201:3260,1 iqn.2025-11.localhost.storage:bossbobby-cluster
Logging in to [iface: default, target: iqn.2025-11.localhost.storage:bossbobby-cluster, portal: 192.168.100.201,3260]
Login to [iface: default, target: iqn.2025-11.localhost.storage:bossbobby-cluster, portal: 192.168.100.201,3260] successful.

boss:~ # lsblk
NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
sda      8:0    0   32G  0 disk 
├─sda1   8:1    0    8M  0 part 
├─sda2   8:2    0   30G  0 part /var
└─sda3   8:3    0    2G  0 part [SWAP]
sdb      8:16   0    4G  0 disk 
sdc      8:32   0    5G  0 disk 
sdd      8:48   0    4G  0 disk 
sde      8:64   0    4G  0 disk 
sdf      8:80   0    4G  0 disk 
sr0     11:0    1  4.3G  0 rom
```

After applying automatic login configuration and reboot - disks appear automatically without any manual intervention.

---

### 3.2 Issue: Missing 5GB disk on cluster nodes

**Symptoms:**
- Only 4 disks visible on cluster nodes (4×4GB)
- 5GB disk missing from `lsblk` output

**Diagnosis:**
```bash
# On storage server
sudo targetcli ls /iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1/luns
```

Check if:
1. The 5GB backstore shows as "deactivated"
2. The 5GB disk is not mapped to any LUN

**Solution:**
```bash
# On storage server (base-host-01)
sudo targetcli

# Activate the backstore
/backstores/block/device_bossbobby_cfg_1_5G_opensuse15> set attribute emulate_tpu=1

# Create the LUN
/iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1/luns> create /backstores/block/device_bossbobby_cfg_1_5G_opensuse15

# Save configuration
/> saveconfig
/> exit
```

On cluster nodes (Boss & Bobby):
```bash
# Rescan the iSCSI session
sudo iscsiadm -m session --rescan
lsblk
```

---

### 3.3 Issue: Authorization failure (Error 24)

**Symptoms:**
```
iscsiadm: initiator reported error (24 - iSCSI login failed due to authorization failure)
```

**Diagnosis:**

Check what initiator name the node is actually using:
```bash
# On the failing cluster node
cat /etc/iscsi/initiatorname.iscsi
```

Check server logs to see what initiator name is being presented:
```bash
# On storage server
sudo dmesg | grep -i "initiator node" | tail -10
```

**Common Cause:** The iSCSI initiator may use a cached or default initiator name (e.g., `iqn.1996-04.de.suse:01:xxxxx`) instead of the configured one.

**Solution A - Fix the initiator name (Recommended):**
```bash
# On the failing cluster node

# Stop iSCSI services completely
sudo systemctl stop iscsi iscsid

# Ensure correct initiator name
echo "InitiatorName=iqn.2025-11.localhost.storage:boss" | sudo tee /etc/iscsi/initiatorname.iscsi

# Remove cached configurations
sudo rm -rf /etc/iscsi/nodes/*
sudo rm -rf /etc/iscsi/send_targets/*

# Start the initiator daemon
sudo systemctl start iscsid

# Rediscover targets
sudo iscsiadm -m discovery -t st -p 192.168.100.201

# Login to the target
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 -l

# Verify disks
lsblk
```

**Solution B - Add ACL for the actual initiator name:**

If the node continues to use a different initiator name (visible in dmesg on the server), add an ACL for it:
```bash
# On storage server
sudo targetcli /iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1/acls create iqn.1996-04.de.suse:01:xxxxx
sudo targetcli saveconfig
```

---

### 3.4 Issue: ACL exists but login still fails

**Diagnosis:**
```bash
# On storage server - verify ACL configuration
sudo targetcli ls /iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1/acls/iqn.2025-11.localhost.storage:boss

# Check authentication settings
sudo targetcli /iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1 get attribute authentication
sudo targetcli /iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1 get attribute generate_node_acls
```

**Solution - Recreate the ACL:**
```bash
# On storage server
sudo targetcli /iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1/acls delete iqn.2025-11.localhost.storage:boss
sudo targetcli /iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1/acls create iqn.2025-11.localhost.storage:boss
sudo targetcli saveconfig
```

On cluster node:
```bash
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 -l
```

---

### 3.5 Issue: Not all LUNs visible on cluster node

**Symptoms:**
- Some disks missing after successful login
- `lsblk` shows fewer disks than expected

**Diagnosis:**
```bash
# On cluster node - check session details
sudo iscsiadm -m session -P 3 | grep -E "Target:|Lun:|disk"

# On storage server - verify LUN mapping
sudo targetcli ls /iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1/acls/iqn.2025-11.localhost.storage:boss
```

**Solution:**
```bash
# On cluster node - rescan the session
sudo iscsiadm -m session --rescan
sleep 2
lsblk

# If still missing, force SCSI rescan
echo "- - -" | sudo tee /sys/class/scsi_host/host*/scan
lsblk
```

---

### 3.6 Issue: Connection timeout or network issues

**Symptoms:**
```
iscsiadm: Connection timeout
iscsiadm: Could not login to portal
```

**Diagnosis:**
```bash
# Test basic connectivity
ping -c 3 192.168.100.201

# Test iSCSI port
nc -zv 192.168.100.201 3260

# Check if target is listening on storage server
sudo ss -tulpn | grep 3260

# Check firewall on storage server
sudo firewall-cmd --list-all 2>/dev/null || sudo iptables -L -n -v | grep 3260
```

**Solution:**

If firewall is blocking:
```bash
# On storage server
sudo firewall-cmd --permanent --add-port=3260/tcp
sudo firewall-cmd --reload
```

If target service is not running:
```bash
# On storage server
sudo systemctl status target
sudo systemctl restart target
```

---

### 3.7 Useful diagnostic commands

**On Storage Server:**
```bash
# View all active sessions
sudo targetcli sessions

# View complete configuration tree
sudo targetcli ls

# Check target service logs
sudo journalctl -u target -n 100 --no-pager

# Check kernel logs for iSCSI events
sudo dmesg | grep -i iscsi | tail -20
```

**On Cluster Nodes:**
```bash
# View active iSCSI sessions
sudo iscsiadm -m session

# View detailed session information
sudo iscsiadm -m session -P 3

# Check iSCSI service logs
sudo journalctl -u iscsid -n 50 --no-pager

# Verify initiator name being used
cat /etc/iscsi/initiatorname.iscsi
cat -A /etc/iscsi/initiatorname.iscsi  # Check for hidden characters

# View node configuration
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 -o show

# Check if automatic login is enabled
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 -o show | grep node.startup
```

---

## 4. Notes & Best Practices

- **Disk Usage:**  
  - `/dev/sdc` (5GB) → VG for cluster configuration  
  - `/dev/sdb, sdd, sde, sdf` (4GB each) → VG striped for shared storage

- **Do not format striped disks individually**. Use **LVM with stripe** or cluster filesystem like **OCFS2** or **GFS2**.  

- **Persistence:**  
  - Always run `saveconfig` in targetcli on the storage server  
  - **CRITICAL:** Enable `node.startup=automatic` on cluster nodes
  - Enable `iscsid` and `iscsi` services at boot

- **Initiator Names:**
  - Use consistent, descriptive initiator names
  - Verify the actual initiator name being used matches the ACL
  - Clear cached configurations when changing initiator names

- **LUN Ordering:**
  - Document which LUN corresponds to which purpose
  - Consider using consistent LUN ordering across deployments
  - Note that LUN order may not match `/dev/sdX` order

- **Testing:**
  - Always test failover scenarios
  - **Verify disks remain accessible after node reboots**
  - Test what happens when storage server reboots
  - Monitor iSCSI session stability over time

- **Common Pitfalls:**
  - Forgetting to set `node.startup=automatic` - most common issue
  - Not enabling `iscsid` and `iscsi` services at boot
  - Mismatched initiator names between configuration file and actual usage
  - Deactivated backstores on storage server

---

## 5. Verification Checklist

### Storage Server Checks
- [x] Storage server sees all disks (`lsblk`)  
- [x] Backstores created for all new disks  
- [x] All backstores are activated (not "deactivated")
- [x] iSCSI target `bossbobby-cluster` created  
- [x] All 5 LUNs mapped correctly (lun0–lun4)
- [x] ACLs present for both cluster nodes (`boss` & `bobby`)  
- [x] Each ACL shows all 5 mapped LUNs
- [x] Configuration saved on storage server (`saveconfig`)
- [x] Target service enabled and running
- [x] Firewall allows iSCSI traffic (port 3260)

### Cluster Node Checks
- [x] Cluster nodes discover the target successfully
- [x] Initiator names on cluster nodes match ACLs on server
- [x] Cluster nodes login to the target without errors
- [x] All 5 disks visible via `lsblk` (4×4GB + 1×5GB)
- [x] **`node.startup = automatic` is configured**
- [x] **`iscsid` service enabled at boot**
- [x] **`iscsi` service enabled at boot**
- [x] **Test reboot - disks auto-attach WITHOUT manual intervention**
- [x] Sessions remain stable during operation

---

## 6. Quick Reference Commands

### Storage Server Quick Commands
```bash
# Enter targetcli
sudo targetcli

# List all configuration
ls

# Check active sessions
sessions

# Save configuration
saveconfig

# Exit
exit
```

### Cluster Node Quick Commands
```bash
# Discover targets
sudo iscsiadm -m discovery -t st -p 192.168.100.201

# Login to target
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 -l

# Logout from target
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 -u

# Rescan session
sudo iscsiadm -m session --rescan

# View sessions
sudo iscsiadm -m session

# View detailed session info
sudo iscsiadm -m session -P 3

# Enable auto-login (CRITICAL FOR PERSISTENCE)
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 --op update -n node.startup -v automatic

# Disable auto-login
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 --op update -n node.startup -v manual

# Check auto-login status
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 -o show | grep node.startup

# Enable services at boot
sudo systemctl enable iscsid iscsi

# Check service status
sudo systemctl status iscsid
sudo systemctl status iscsi
```

---

## Appendix A: Complete Setup Script for Storage Server

```bash
#!/bin/bash
# Complete iSCSI target setup for bossbobby-cluster

# Create backstores
sudo targetcli /backstores/block create device_bossbobby_stripe_1_4G_opensuse15 /dev/sdd
sudo targetcli /backstores/block create device_bossbobby_stripe_2_4G_opensuse15 /dev/sde
sudo targetcli /backstores/block create device_bossbobby_stripe_3_4G_opensuse15 /dev/sdf
sudo targetcli /backstores/block create device_bossbobby_stripe_4_4G_opensuse15 /dev/sdg
sudo targetcli /backstores/block create device_bossbobby_cfg_1_5G_opensuse15 /dev/sdc

# Activate the 5GB disk
sudo targetcli /backstores/block/device_bossbobby_cfg_1_5G_opensuse15 set attribute emulate_tpu=1

# Create target
sudo targetcli /iscsi create iqn.2025-11.localhost.storage:bossbobby-cluster

# Create LUNs
sudo targetcli /iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1/luns create /backstores/block/device_bossbobby_stripe_1_4G_opensuse15
sudo targetcli /iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1/luns create /backstores/block/device_bossbobby_stripe_2_4G_opensuse15
sudo targetcli /iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1/luns create /backstores/block/device_bossbobby_stripe_3_4G_opensuse15
sudo targetcli /iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1/luns create /backstores/block/device_bossbobby_stripe_4_4G_opensuse15
sudo targetcli /iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1/luns create /backstores/block/device_bossbobby_cfg_1_5G_opensuse15

# Create ACLs
sudo targetcli /iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1/acls create iqn.2025-11.localhost.storage:boss
sudo targetcli /iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1/acls create iqn.2025-11.localhost.storage:bobby

# Save configuration
sudo targetcli saveconfig

# Display configuration
sudo targetcli ls
```

## Appendix B: Complete Setup Script for Cluster Nodes (With Persistence)

```bash
#!/bin/bash
# iSCSI initiator setup for cluster node with automatic persistence
# Run this on Boss or Bobby (change initiator name accordingly)

# Variables - CHANGE THESE FOR EACH NODE
NODE_NAME="boss"  # Change to "bobby" for Bobby node
INITIATOR_IQN="iqn.2025-11.localhost.storage:${NODE_NAME}"
TARGET_IP="192.168.100.201"
TARGET_IQN="iqn.2025-11.localhost.storage:bossbobby-cluster"

echo "Setting up iSCSI initiator for node: ${NODE_NAME}"

# Install iSCSI initiator
echo "Installing open-iscsi..."
sudo zypper install -y open-iscsi

# Stop services to ensure clean setup
echo "Stopping iSCSI services..."
sudo systemctl stop iscsi iscsid 2>/dev/null || true

# Set initiator name
echo "Setting initiator name to: ${INITIATOR_IQN}"
echo "InitiatorName=${INITIATOR_IQN}" | sudo tee /etc/iscsi/initiatorname.iscsi

# Clean any old configurations
echo "Cleaning old configurations..."
sudo rm -rf /etc/iscsi/nodes/* 2>/dev/null || true
sudo rm -rf /etc/iscsi/send_targets/* 2>/dev/null || true

# Start initiator daemon
echo "Starting iscsid service..."
sudo systemctl start iscsid

# Discover targets
echo "Discovering targets on ${TARGET_IP}..."
sudo iscsiadm -m discovery -t st -p ${TARGET_IP}

# Login to target
echo "Logging in to target ${TARGET_IQN}..."
sudo iscsiadm -m node -T ${TARGET_IQN} -p ${TARGET_IP} -l

# CRITICAL: Enable auto-login for persistence
echo "Enabling automatic login at boot..."
sudo iscsiadm -m node -T ${TARGET_IQN} -p ${TARGET_IP} --op update -n node.startup -v automatic

# Enable services at boot
echo "Enabling iSCSI services at boot..."
sudo systemctl enable iscsid
sudo systemctl enable iscsi

# Verify setup
echo ""
echo "=== Verification ==="
echo "1. Checking node.startup setting:"
sudo iscsiadm -m node -T ${TARGET_IQN} -p ${TARGET_IP} -o show | grep "node.startup"

echo ""
echo "2. Checking service status:"
sudo systemctl is-enabled iscsid
sudo systemctl is-enabled iscsi

echo ""
echo "3. Current disks:"
lsblk

echo ""
echo "=== Setup Complete ==="
echo "Expected disks: 5 (4x 4GB + 1x 5GB)"
echo "The iSCSI disks will now persist across reboots automatically."
echo ""
echo "To test persistence:"
echo "  sudo reboot"
echo "After reboot, run 'lsblk' and all iSCSI disks should be present."
```

## Appendix C: Troubleshooting Script for Missing Disks After Reboot

```bash
#!/bin/bash
# Troubleshooting script for persistent iSCSI disk issues
# Run this if disks don't appear after reboot

TARGET_IP="192.168.100.201"
TARGET_IQN="iqn.2025-11.localhost.storage:bossbobby-cluster"

echo "=== iSCSI Persistence Troubleshooting ==="
echo ""

# Check 1: Initiator name
echo "1. Checking initiator name configuration:"
cat /etc/iscsi/initiatorname.iscsi
echo ""

# Check 2: Service status
echo "2. Checking iSCSI service status:"
systemctl status iscsid --no-pager | head -5
systemctl status iscsi --no-pager | head -5
echo ""

# Check 3: Services enabled at boot
echo "3. Checking if services are enabled at boot:"
systemctl is-enabled iscsid
systemctl is-enabled iscsi
echo ""

# Check 4: node.startup setting
echo "4. Checking node.startup configuration:"
sudo iscsiadm -m node -T ${TARGET_IQN} -p ${TARGET_IP} -o show 2>/dev/null | grep "node.startup"
echo ""

# Check 5: Active sessions
echo "5. Checking active iSCSI sessions:"
sudo iscsiadm -m session 2>/dev/null || echo "No active sessions found"
echo ""

# Check 6: Current disks
echo "6. Current disk configuration:"
lsblk
echo ""

# Check 7: Network connectivity
echo "7. Testing network connectivity to storage server:"
ping -c 2 ${TARGET_IP} 2>/dev/null && echo "Network connectivity: OK" || echo "Network connectivity: FAILED"
nc -zv ${TARGET_IP} 3260 2>&1 | grep -q "succeeded" && echo "Port 3260 access: OK" || echo "Port 3260 access: FAILED"
echo ""

# Suggested fixes
echo "=== Suggested Fixes ==="
echo ""
if ! systemctl is-enabled iscsid >/dev/null 2>&1; then
    echo "ISSUE: iscsid is not enabled at boot"
    echo "FIX: sudo systemctl enable iscsid"
    echo ""
fi

if ! systemctl is-enabled iscsi >/dev/null 2>&1; then
    echo "ISSUE: iscsi is not enabled at boot"
    echo "FIX: sudo systemctl enable iscsi"
    echo ""
fi

STARTUP_VALUE=$(sudo iscsiadm -m node -T ${TARGET_IQN} -p ${TARGET_IP} -o show 2>/dev/null | grep "node.startup" | awk '{print $3}')
if [ "$STARTUP_VALUE" != "automatic" ]; then
    echo "ISSUE: node.startup is set to '$STARTUP_VALUE' (should be 'automatic')"
    echo "FIX: sudo iscsiadm -m node -T ${TARGET_IQN} -p ${TARGET_IP} --op update -n node.startup -v automatic"
    echo ""
fi

if ! sudo iscsiadm -m session >/dev/null 2>&1; then
    echo "ISSUE: No active iSCSI sessions"
    echo "FIX: sudo iscsiadm -m node -T ${TARGET_IQN} -p ${TARGET_IP} -l"
    echo ""
fi

echo "=== Quick Fix Script ==="
echo "Run the following commands to fix common issues:"
echo ""
echo "sudo systemctl enable iscsid"
echo "sudo systemctl enable iscsi"
echo "sudo iscsiadm -m node -T ${TARGET_IQN} -p ${TARGET_IP} --op update -n node.startup -v automatic"
echo "sudo iscsiadm -m node -T ${TARGET_IQN} -p ${TARGET_IP} -l"
echo "lsblk"
```

## Appendix D: Real-World Troubleshooting Case Study (Boss Node)

This section documents the actual troubleshooting process encountered during the setup of the Boss node, which required manual intervention after every reboot.

### Initial Problem

**Symptom:** After reboot, Boss node had no iSCSI disks visible:

```bash
boss:~ # lsblk
NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
sda      8:0    0   32G  0 disk 
├─sda1   8:1    0    8M  0 part 
├─sda2   8:2    0   30G  0 part /var
│                               /tmp
│                               /opt
│                               /usr/local
│                               /srv
│                               /root
│                               /boot/grub2/i386-pc
│                               /home
│                               /boot/grub2/x86_64-efi
│                               /.snapshots
│                               /
└─sda3   8:3    0    2G  0 part [SWAP]
sr0     11:0    1  4.3G  0 rom
```

### Temporary Workaround (Manual Script - f1.sh)

A manual connection script was needed after every reboot:

```bash
boss:~ # bash f1.sh
Stopping 'iscsid.service', but its triggering units are still active:
iscsid.socket
InitiatorName=iqn.2025-11.localhost.storage:boss
192.168.100.201:3260,1 iqn.2025-10.localhost.storage:target1
192.168.100.201:3260,1 iqn.2025-11.localhost.storage:bossbobby-cluster
Logging in to [iface: default, target: iqn.2025-11.localhost.storage:bossbobby-cluster, portal: 192.168.100.201,3260]
Login to [iface: default, target: iqn.2025-11.localhost.storage:bossbobby-cluster, portal: 192.168.100.201,3260] successful.
```

After running the script:

```bash
boss:~ # lsblk
NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
sda      8:0    0   32G  0 disk 
├─sda1   8:1    0    8M  0 part 
├─sda2   8:2    0   30G  0 part /var
│                               /tmp
│                               /opt
│                               /usr/local
│                               /srv
│                               /root
│                               /boot/grub2/i386-pc
│                               /home
│                               /boot/grub2/x86_64-efi
│                               /.snapshots
│                               /
└─sda3   8:3    0    2G  0 part [SWAP]
sdb      8:16   0    4G  0 disk 
sdc      8:32   0    5G  0 disk 
sdd      8:48   0    4G  0 disk 
sde      8:64   0    4G  0 disk 
sdf      8:80   0    4G  0 disk 
sr0     11:0    1  4.3G  0 rom
```

### Root Cause Analysis

The issue was caused by three missing configurations:

1. **node.startup was not set to automatic**
   - Default value: `manual`
   - Required value: `automatic`

2. **iscsid service was not enabled at boot**
   - Service existed but was not configured to start automatically

3. **iscsi service was not enabled at boot**
   - Service existed but was not configured to start automatically

### Permanent Solution Applied

```bash
# Step 1: Set automatic login
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 --op update -n node.startup -v automatic

# Step 2: Enable services at boot
sudo systemctl enable iscsid
sudo systemctl enable iscsi

# Step 3: Verify configuration
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 -o show | grep node.startup
# Expected output: node.startup = automatic

# Step 4: Test with reboot
sudo reboot
```

### Verification After Fix

After reboot, all disks appeared automatically without any manual intervention:

```bash
boss:~ # lsblk
NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
sda      8:0    0   32G  0 disk 
├─sda1   8:1    0    8M  0 part 
├─sda2   8:2    0   30G  0 part /var
└─sda3   8:3    0    2G  0 part [SWAP]
sdb      8:16   0    4G  0 disk 
sdc      8:32   0    5G  0 disk 
sdd      8:48   0    4G  0 disk 
sde      8:64   0    4G  0 disk 
sdf      8:80   0    4G  0 disk 
sr0     11:0    1  4.3G  0 rom
```

### Key Lessons Learned

1. **Always configure persistence explicitly** - iSCSI connections are not persistent by default
2. **Three components required for persistence:**
   - `node.startup = automatic` in iSCSI node configuration
   - `iscsid` service enabled at boot
   - `iscsi` service enabled at boot
3. **Test reboots early** - Don't wait until production to discover persistence issues
4. **Document the exact commands** - Manual scripts are a sign of missing automation

### Contents of f1.sh (For Reference)

The temporary workaround script that should NOT be needed after proper configuration:

```bash
#!/bin/bash
# Temporary manual connection script - should not be needed after proper setup

# Stop services
sudo systemctl stop iscsi iscsid

# Set initiator name
echo "InitiatorName=iqn.2025-11.localhost.storage:boss" | sudo tee /etc/iscsi/initiatorname.iscsi

# Clean cached configurations
sudo rm -rf /etc/iscsi/nodes/*
sudo rm -rf /etc/iscsi/send_targets/*

# Start initiator daemon
sudo systemctl start iscsid

# Discover targets
sudo iscsiadm -m discovery -t st -p 192.168.100.201

# Login to target
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 -l

# Display disks
lsblk
```

**Note:** This script should be replaced with proper persistence configuration as documented in Section 2.7.

---

## Appendix E: Post-Setup Disk Usage Planning

### Recommended Disk Layout

After successful iSCSI setup, the disks should be used as follows:

#### Configuration Disk (5GB - /dev/sdc)
```bash
# Create separate VG for cluster configuration
sudo pvcreate /dev/sdc
sudo vgcreate vg_cluster_config /dev/sdc

# Create LVs for cluster components
sudo lvcreate -L 1G -n lv_dlm vg_cluster_config        # DLM lock space
sudo lvcreate -L 1G -n lv_cluster vg_cluster_config    # Cluster metadata
sudo lvcreate -L 2G -n lv_quorum vg_cluster_config     # Quorum disk

# Format for cluster use
sudo mkfs.gfs2 -j2 -p lock_dlm -t bossbobby:dlm /dev/vg_cluster_config/lv_dlm
```

#### Striped Disks (4x 4GB - /dev/sdb, sdd, sde, sdf)
```bash
# Create striped VG for performance
sudo pvcreate /dev/sdb /dev/sdd /dev/sde /dev/sdf
sudo vgcreate vg_cluster_data /dev/sdb /dev/sdd /dev/sde /dev/sdf

# Create striped LV for shared storage
sudo lvcreate -L 15G -i 4 -I 64 -n lv_shared vg_cluster_data

# Format with cluster filesystem
sudo mkfs.gfs2 -j2 -p lock_dlm -t bossbobby:shared /dev/vg_cluster_data/lv_shared
```

### Important Notes

- **Do not format individual iSCSI disks with regular filesystems** (ext4, xfs)
- Use cluster-aware filesystems: **GFS2** or **OCFS2**
- The `-j2` option creates journals for 2 nodes (Boss and Bobby)
- Adjust journal count if adding more nodes
- Test failover before putting into production

---

## 7. Security Considerations

### 7.1 CHAP Authentication (Optional)

For enhanced security, consider enabling CHAP authentication:

**On Storage Server:**
```bash
sudo targetcli

# Set CHAP authentication
/iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1> set attribute authentication=1
/iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1/acls/iqn.2025-11.localhost.storage:boss> set auth userid=boss_user
/iscsi/iqn.2025-11.localhost.storage:bossbobby-cluster/tpg1/acls/iqn.2025-11.localhost.storage:boss> set auth password=SecurePassword123

# Save configuration
/> saveconfig
/> exit
```

**On Cluster Nodes:**
```bash
# Configure CHAP credentials
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 --op update -n node.session.auth.authmethod -v CHAP
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 --op update -n node.session.auth.username -v boss_user
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 --op update -n node.session.auth.password -v SecurePassword123

# Login with CHAP
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 -l
```

### 7.2 Network Isolation

- Use a dedicated storage network (VLAN)
- Separate iSCSI traffic from management and production traffic
- Configure firewall rules to restrict iSCSI access
- Use jumbo frames for better performance (MTU 9000)

### 7.3 Firewall Configuration

**On Storage Server:**
```bash
# Allow iSCSI traffic from cluster nodes only
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.100.204" port port="3260" protocol="tcp" accept'
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.100.205" port port="3260" protocol="tcp" accept'
sudo firewall-cmd --reload
```

---

## 8. Performance Tuning

### 8.1 iSCSI Initiator Tuning

```bash
# On cluster nodes - increase queue depth
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 --op update -n node.session.queue_depth -v 128

# Increase outstanding R2T
sudo iscsiadm -m node -T iqn.2025-11.localhost.storage:bossbobby-cluster -p 192.168.100.201 --op update -n node.session.iscsi.MaxOutstandingR2T -v 16
```

### 8.2 Network Tuning

```bash
# On all nodes - enable jumbo frames (if supported)
sudo ip link set dev eth0 mtu 9000

# TCP tuning for iSCSI
sudo sysctl -w net.core.rmem_max=16777216
sudo sysctl -w net.core.wmem_max=16777216
sudo sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"
sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216"

# Make permanent
echo "net.core.rmem_max=16777216" | sudo tee -a /etc/sysctl.conf
echo "net.core.wmem_max=16777216" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_rmem=4096 87380 16777216" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_wmem=4096 65536 16777216" | sudo tee -a /etc/sysctl.conf
```

### 8.3 Storage Server Tuning

```bash
# On storage server - optimize I/O scheduler for SSDs
echo noop | sudo tee /sys/block/sd*/queue/scheduler

# For HDDs use deadline
echo deadline | sudo tee /sys/block/sd*/queue/scheduler
```

---

## 9. Monitoring and Maintenance

### 9.1 Monitor iSCSI Sessions

```bash
# Check session health
watch -n 5 'sudo iscsiadm -m session -P 1'

# Monitor connection statistics
sudo iscsiadm -m session -P 3 | grep -A 20 "Current Portal"
```

### 9.2 Check for Errors

```bash
# On cluster nodes
sudo journalctl -u iscsid -f

# On storage server
sudo journalctl -u target -f
sudo dmesg -T | grep -i iscsi
```

### 9.3 Regular Maintenance Tasks

- **Weekly:** Check iSCSI session stability and error logs
- **Monthly:** Verify backup/restore procedures for cluster data
- **Quarterly:** Test failover scenarios and disaster recovery
- **Annually:** Review and update security credentials (if using CHAP)

---

## 10. Disaster Recovery

### 10.1 Backup Strategy

```bash
# Backup iSCSI target configuration
sudo cp /etc/target/saveconfig.json /backup/target-config-$(date +%Y%m%d).json

# Backup initiator configuration
sudo tar czf /backup/iscsi-initiator-$(date +%Y%m%d).tar.gz /etc/iscsi/
```

### 10.2 Recovery Procedures

**If Storage Server Fails:**
1. Restore hardware or provision new server
2. Install targetcli-fb
3. Restore configuration: `sudo targetcli restoreconfig /backup/target-config-YYYYMMDD.json`
4. Verify: `sudo targetcli ls`

**If Cluster Node Fails:**
1. Provision new node with same hostname and IP
2. Install open-iscsi
3. Restore /etc/iscsi/ from backup
4. Start services: `sudo systemctl start iscsid iscsi`
5. Verify disks: `lsblk`

---

## 11. Common Questions and Answers

### Q1: Can I add more cluster nodes later?
**A:** Yes. Simply create additional ACLs on the storage server and configure the new nodes following Section 2.

### Q2: What happens if the storage server reboots?
**A:** The target configuration persists. All cluster nodes will automatically reconnect when the storage server comes back online.

### Q3: Can I use different size disks for striping?
**A:** Yes, but the stripe will be limited to the smallest disk size. For best performance, use identically sized disks.

### Q4: How do I safely remove a disk from the cluster?
**A:** 
1. Unmount any filesystems using the disk
2. Remove from VG: `sudo vgreduce vg_name /dev/sdX`
3. Remove PV: `sudo pvremove /dev/sdX`
4. Logout from iSCSI: `sudo iscsiadm -m node -u`
5. Delete LUN on storage server
6. Delete backstore on storage server

### Q5: What's the difference between node.startup=automatic and manual?
**A:** 
- `automatic`: iSCSI initiator logs in automatically at boot
- `manual`: Requires manual `iscsiadm -m node -l` command after each boot

### Q6: Why do my disk device names change (sdb, sdc, etc.)?
**A:** Linux assigns device names dynamically. Use `/dev/disk/by-id/` or `/dev/disk/by-path/` for persistent naming, or use LVM which provides consistent naming.

### Q7: Can I use these disks for non-cluster purposes?
**A:** Yes, but you lose the benefits of cluster awareness. For cluster setups, always use cluster filesystems (GFS2/OCFS2).

---

## 12. Additional Resources

### Official Documentation
- [Linux-iSCSI.org Target Documentation](http://linux-iscsi.org/wiki/Main_Page)
- [open-iscsi Initiator Documentation](https://github.com/open-iscsi/open-iscsi)
- [openSUSE iSCSI Guide](https://doc.opensuse.org/documentation/leap/reference/html/book-reference/cha-iscsi.html)
- [GFS2 Filesystem Documentation](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/7/html/global_file_system_2/index)

### Community Resources
- iSCSI Mailing Lists
- openSUSE Forums
- Linux-HA Mailing List

### Tools
- `targetcli` - iSCSI target configuration tool
- `iscsiadm` - iSCSI initiator administration utility
- `lsscsi` - List SCSI devices
- `multipath` - For multipath iSCSI configurations

---

## Change Log

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-11-04 | SysAdmin Team | Initial documentation |
| 2.0 | 2025-11-09 | SysAdmin Team | Added troubleshooting section, persistence configuration |
| 2.1 | 2025-11-09 | SysAdmin Team | Added Boss node case study, complete scripts, security section |

---

**Document Version:** 2.1  
**Last Updated:** 2025-11-09  
**Authors:** System Administrator Team  
**Status:** Production Ready

---

## Summary

This document provides comprehensive guidance for setting up shared iSCSI storage for a Pacemaker/Corosync cluster on openSUSE Leap 15.6. The most critical aspects for success are:

1. **Proper backstore activation** - Ensure all backstores are activated before mapping
2. **Complete LUN mapping** - Map all disks to both cluster nodes
3. **Correct initiator names** - Verify actual vs configured initiator names
4. **Persistence configuration** - Set `node.startup=automatic` and enable services
5. **Testing** - Always verify with a reboot before production use

Following these steps will result in a stable, persistent shared storage configuration that survives reboots and provides the foundation for a highly available cluster.