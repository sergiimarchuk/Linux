# Shared iSCSI Storage Setup for Pacemaker/Corosync Cluster on openSUSE Leap 15.6

## Overview
This guide explains how to:

1. Configure an iSCSI target on the storage server.
2. Configure iSCSI initiators on cluster nodes (`pcs-cluster-node-01` and `pcs-cluster-node-02`).
3. Present a shared disk that is accessible by both nodes safely for cluster use.

---

## 1. Storage Server Setup

### 1.1 Install iSCSI target
```bash
sudo zypper install -y targetcli-fb
sudo systemctl enable --now target
```

### 1.2 Create a block storage object
```bash
sudo targetcli
/backstores/block> create device_cluster /dev/sdb
```
- `device_cluster` is the storage object name.
- `/dev/sdb` is the physical disk to export.

### 1.3 Create an iSCSI target
```bash
/iscsi> create iqn.2025-10.localhost.storage:cluster_target
```
- IQN format: `iqn.YYYY-MM.reversed_domain:target_name`
- Avoid spaces or special characters.

### 1.4 Map the LUN
```bash
/iscsi/iqn.2025-10.localhost.storage:cluster_target/tpg1/luns> create /backstores/block/device_cluster
```
- LUN 0 now points to `/dev/sdb`.

### 1.5 Add ACLs for cluster nodes
```bash
/iscsi/iqn.2025-10.localhost.storage:cluster_target/tpg1/acls> create iqn.2025-10.localhost.storage:pcs-cluster-node-01
/iscsi/iqn.2025-10.localhost.storage:cluster_target/tpg1/acls> create iqn.2025-10.localhost.storage:pcs-cluster-node-02
```

### 1.6 Verify configuration
```bash
ls
```
You should see:

- LUN 0 → `/dev/sdb`
- ACLs for both nodes
- Portal listening on `0.0.0.0:3260`

### 1.7 Exit `targetcli`
```bash
exit
```

---

## 2. Cluster Node Setup

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

### 2.3 Discover the iSCSI target
```bash
sudo iscsiadm -m discovery -t st -p <storage_server_ip>
```
- Expected output:
```
<storage_server_ip>:3260,1 iqn.2025-10.localhost.storage:cluster_target
```

### 2.4 Log in to the iSCSI target
```bash
sudo iscsiadm -m node -T iqn.2025-10.localhost.storage:cluster_target -p <storage_server_ip> -l
```

### 2.5 Verify the disk
```bash
lsblk
```
- Both nodes should see `/dev/sdb`.

### 2.6 Enable auto-login on boot
```bash
sudo systemctl enable --now iscsid iscsi
```

---

## 3. Cluster Usage Notes

- **Do NOT format `/dev/sdb`** with a standard filesystem if it is shared.
- Use a **clustered filesystem** (e.g., **GFS2** or **OCFS2**) or let Pacemaker manage the raw block device.
- Disk is now **ready for Pacemaker-managed resources**.

---

## 4. Verification Checklist

- [ ] Storage server has iSCSI target running (`ss -na | grep 3260`)
- [ ] LUN 0 mapped to `/dev/sdb`
- [ ] ACLs exist for both cluster nodes
- [ ] Cluster nodes can `lsblk` and see `/dev/sdb`
- [ ] Auto-login enabled on both nodes

---

**End of Guide**

