# Shared iSCSI Storage Setup for Pacemaker/Corosync Cluster on openSUSE Leap 15.6

## Overview
This guide explains how to:

1. Configure an iSCSI target on the storage server.  
2. Configure iSCSI initiators on cluster nodes (`pcs-cluster-node-01` and `pcs-cluster-node-02`).  
3. Present a shared disk that is accessible by both nodes safely for cluster use.  
4. Recover and verify configuration after reboot.  

---

## 1. Storage Server Setup (`base-host-01`)

### 1.1 Install iSCSI target
```bash
sudo zypper install -y targetcli-fb
sudo systemctl enable --now target
```

### 1.2 Create a block storage object
```bash
sudo targetcli
/backstores/block> create device_pcs_cluster_prox_700x_opensuse15 /dev/sdb
```
- `/dev/sdb` is the physical disk exported via iSCSI (in this example, **10 GiB**).  
- The size is determined by the underlying disk — **it’s not configurable from iSCSI**.

### 1.3 Create an iSCSI target
```bash
/iscsi> create iqn.2025-10.localhost.storage:target1
```
> IQN format: `iqn.YYYY-MM.reversed_domain:target_name`  
> Example: `iqn.2025-10.localhost.storage:target1`

### 1.4 Map the LUN
```bash
/iscsi/iqn.2025-10.localhost.storage:target1/tpg1/luns> create /backstores/block/device_pcs_cluster_prox_700x_opensuse15
```

### 1.5 Add ACLs for both nodes
```bash
/iscsi/iqn.2025-10.localhost.storage:target1/tpg1/acls> create iqn.2025-10.localhost.storage:pcs-cluster-node-01
/iscsi/iqn.2025-10.localhost.storage:target1/tpg1/acls> create iqn.2025-10.localhost.storage:pcs-cluster-node-02
```

### 1.6 Verify configuration
```bash
ls
```
You should see:
```
LUN 0 → /dev/sdb
ACLs → node01, node02
Portal → 0.0.0.0:3260 [OK]
```

### 1.7 Persist configuration
Always save configuration changes before exiting:
```bash
/saveconfig
exit
```

---

## 2. Cluster Node Setup (`pcs-cluster-node-01` and `pcs-cluster-node-02`)

### 2.1 Install iSCSI initiator
```bash
sudo zypper install -y open-iscsi
```

### 2.2 Configure initiator name

**Node 1:**
```bash
echo "InitiatorName=iqn.2025-10.localhost.storage:pcs-cluster-node-01" | sudo tee /etc/iscsi/initiatorname.iscsi
```

**Node 2:**
```bash
echo "InitiatorName=iqn.2025-10.localhost.storage:pcs-cluster-node-02" | sudo tee /etc/iscsi/initiatorname.iscsi
```

### 2.3 Enable and start iSCSI services
```bash
sudo systemctl enable --now iscsid iscsi
```

### 2.4 Discover the iSCSI target
```bash
sudo iscsiadm -m discovery -t st -p 192.168.100.201
```
Expected output:
```
192.168.100.201:3260,1 iqn.2025-10.localhost.storage:target1
```

### 2.5 Log in to the target
```bash
sudo iscsiadm -m node -T iqn.2025-10.localhost.storage:target1 -p 192.168.100.201 -l
```

### 2.6 Verify the shared disk
```bash
lsblk
```
You should see a new disk (usually `/dev/sdb`, size 10 GiB).

### 2.7 Enable persistent connection on boot
```bash
sudo iscsiadm -m node -T iqn.2025-10.localhost.storage:target1 -p 192.168.100.201 --op update -n node.startup -v automatic
```

---

## 3. Recovery and Troubleshooting

If the shared disk is not visible on nodes after reboot:

### ✅ Step 1 — Check iSCSI target service
On the storage server:
```bash
systemctl status target
targetcli ls
```
Ensure the LUN and ACLs exist and `/dev/sdb` is visible.

If you modify anything in `targetcli`, **save configuration**:
```bash
saveconfig
```

### ✅ Step 2 — Verify ACLs
Inside `targetcli`:
```bash
cd /iscsi/iqn.2025-10.localhost.storage:target1/tpg1/acls
ls
```
You should see both:
```
iqn.2025-10.localhost.storage:pcs-cluster-node-01
iqn.2025-10.localhost.storage:pcs-cluster-node-02
```

### ✅ Step 3 — Re-discover and re-login from nodes
On each node:
```bash
iscsiadm -m discovery -t st -p 192.168.100.201
iscsiadm -m node -T iqn.2025-10.localhost.storage:target1 -p 192.168.100.201 -l
```

### ✅ Step 4 — Verify iSCSI port listening
On storage server:
```bash
ss -na | grep 3260
```
Expected:
```
tcp   LISTEN  0  256  *:3260   *:*
```

---

## 4. Notes and Clarifications

### 🧱 Disk Size
- The exported LUN’s size always equals the **underlying block device** (`/dev/sdb`).
- iSCSI does **not** control disk size — you must create or resize the disk in your virtualization or hardware layer.

### 💾 Persistence
- Always run `saveconfig` in `targetcli` to keep your target across reboots.
- Use `iscsiadm ... node.startup=automatic` for persistent initiator logins.

### 🧩 Cluster Filesystem
- Do **not** format `/dev/sdb` with ext4 or XFS on both nodes.  
  Use **OCFS2**, **GFS2**, or let **Pacemaker** manage the LVM/FS resource.

---

## 5. Verification Checklist

- [x] Storage server has iSCSI target running (`ss -na | grep 3260`)  
- [x] LUN 0 mapped to `/dev/sdb`  
- [x] ACLs exist for both cluster nodes  
- [x] Cluster nodes see `/dev/sdb` via `lsblk`  
- [x] Auto-login enabled (`node.startup=automatic`)  
- [x] Configuration saved via `targetcli saveconfig`

---

**✅ Environment Summary**

| Hostname | Role | Example IP | iSCSI IQN |
|-----------|------|-------------|-----------|
| `base-host-01` | Storage Server | 192.168.100.201 | iqn.2025-10.localhost.storage:target1 |
| `pcs-cluster-node-01` | Cluster Node 1 | 192.168.100.202 | iqn.2025-10.localhost.storage:pcs-cluster-node-01 |
| `pcs-cluster-node-02` | Cluster Node 2 | 192.168.100.203 | iqn.2025-10.localhost.storage:pcs-cluster-node-02 |

---

**End of Guide**  
_Last verified: 2025-10-27 (openSUSE Leap 15.6 environment)_
