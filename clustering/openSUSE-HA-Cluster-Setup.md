# 🧩 High Availability Cluster Setup (Pacemaker + Corosync + pcsd) on openSUSE Leap 15

## 🖥️ Environment

| Node | Hostname | IP Address |
|------|-----------|-------------|
| Node 1 | `pcs-cluster-node-01` | `192.168.100.71` |
| Node 2 | `pcs-cluster-node-02` | `192.168.100.72` |

**Cluster name:** `storage_cluster`  
**Shared storage:** `/dev/sdb` (iSCSI LUN)  
**Mount point:** `/mnt`

---

## 1️⃣ Install and Enable Cluster Packages

Run the following commands **on both nodes**:

```bash
sudo zypper refresh
sudo zypper install -y corosync pacemaker pcs
```

Enable and start the pcs daemon (`pcsd`):

```bash
sudo systemctl enable pcsd
sudo systemctl start pcsd
```

Set a password for the cluster management user:

```bash
sudo passwd hacluster
```

---

## 2️⃣ Authorize and Create the Cluster

Use **one node only** (`pcs-cluster-node-01`) to perform the cluster setup.

### Authorize both nodes:
```bash
sudo pcs cluster auth pcs-cluster-node-01 pcs-cluster-node-02
Username: hacluster
Password: ********
```

### Create and name the cluster:
```bash
sudo pcs cluster setup --name storage_cluster pcs-cluster-node-01 pcs-cluster-node-02
```

### Start and enable the cluster:
```bash
sudo pcs cluster start --all
sudo pcs cluster enable --all
```

---

## 3️⃣ Adjust Cluster Properties (for lab use)

Disable fencing and quorum enforcement (for testing only):

```bash
sudo pcs property set stonith-enabled=false
sudo pcs property set no-quorum-policy=ignore
sudo pcs property list
```

> ⚠️ **Note:** In production, **STONITH (fencing)** *must* be configured to prevent data corruption.

---

## 4️⃣ Configure Cluster-Aware LVM

### Create partition on iSCSI device (on node1):
```bash
sudo fdisk /dev/sdb
# n → p → 1 → Enter → Enter → w
```

### Create LVM structure and filesystem:
```bash
sudo pvcreate /dev/sdb1
sudo vgcreate cluster_vg /dev/sdb1
sudo lvcreate -L 1G -n cluster_lv cluster_vg
sudo mkfs.xfs /dev/cluster_vg/cluster_lv
```

---

## 5️⃣ Adjust LVM Configuration (on both nodes)

Edit `/etc/lvm/lvm.conf`:

```bash
sudo vi /etc/lvm/lvm.conf
```

Ensure these lines are set:
```ini
use_lvmetad = 0
locking_type = 1
```

Add **only local VG(s)** to the volume list — exclude the shared one (`cluster_vg`):

Example:
```ini
volume_list = [ "system" ]  # adjust "system" to your local VG name, e.g. "opensuse"
```

---

## 6️⃣ Apply Changes and Rebuild Initramfs (on both nodes)

```bash
sudo lvmconf --enable-halvm --services --startstopservices
sudo dracut -f
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
sudo reboot
```

> Reboot may take longer as LVM dependencies settle.

---

## 7️⃣ Create Cluster Resources

Once both nodes are back online, on **node1** run:

### Create resource group:
```bash
sudo pcs resource create my_lvm LVM volgrpname=cluster_vg exclusive=true --group my_group
sudo pcs resource create my_fs Filesystem device="/dev/mapper/cluster_vg-cluster_lv" directory="/mnt" fstype="xfs" --group my_group
```

(Optional) Add a **floating IP** for client access:
```bash
sudo pcs resource create ClusterIP ocf:heartbeat:IPaddr2 ip=192.168.100.100 cidr_netmask=24 --group my_group
```

---

## 8️⃣ Verify Cluster Status

```bash
sudo pcs status
sudo pcs resource show
```

Expected output:
```
Cluster name: storage_cluster
Stack: corosync
Current DC: pcs-cluster-node-01 (version ...)
2 nodes configured
3 resources configured

Online: [ pcs-cluster-node-01 pcs-cluster-node-02 ]

Full list of resources:

 Resource Group: my_group
     my_lvm (ocf::heartbeat:LVM):           Started pcs-cluster-node-02
     my_fs  (ocf::heartbeat:Filesystem):    Started pcs-cluster-node-02
     ClusterIP (ocf::heartbeat:IPaddr2):    Started pcs-cluster-node-02
```

---

## 9️⃣ Failover Test

To test failover:

```bash
sudo systemctl poweroff
```
or
```bash
sudo pcs cluster standby pcs-cluster-node-02
```

Then check again:
```bash
sudo pcs status
```

You should see:
```
my_group resources started on pcs-cluster-node-01
```

And verify mount:
```bash
df -h /mnt
```

---

## 🔐 10. Firewall & Network

Allow HA communication through firewall **on both nodes**:

```bash
sudo firewall-cmd --permanent --add-service=high-availability
sudo firewall-cmd --reload
```

---

## 🌐 11. (Optional) Web UI Access

`pcsd` provides a web interface at port **2224**.

Access:
```
https://pcs-cluster-node-01:2224
```

Login:
```
Username: hacluster
Password: <your-password>
```

---

## ✅ Verification Checklist

| Check | Command | Expected |
|--------|----------|-----------|
| Cluster nodes | `pcs cluster status` | Both nodes online |
| Corosync ring | `corosync-cfgtool -s` | ring0 active |
| Quorum | `corosync-quorumtool -l` | 2 nodes, quorate |
| Resource status | `pcs resource` | my_group running |
| Mount check | `df -h /mnt` | Mounted on active node |

---

## ⚙️ Optional: Re-enable STONITH Later

Once you add fencing hardware (IPMI, iDRAC, etc.), re-enable STONITH:

```bash
sudo pcs property set stonith-enabled=true
```

---

## 🎯 Summary

You now have a working **openSUSE 15 two-node HA cluster** with:

- Pacemaker + Corosync + pcsd  
- Shared LVM volume and filesystem  
- Automatic failover between nodes  
- Optional floating IP for client access  

---

## 🧭 (Optional) ASCII Architecture Diagram

```
           +--------------------------+
           |   Shared iSCSI Storage   |
           |        /dev/sdb          |
           +-------------+------------+
                         |
        +----------------+----------------+
        |                                 |
+--------------------+           +--------------------+
| pcs-cluster-node-01|           | pcs-cluster-node-02|
| IP: 192.168.100.71 |           | IP: 192.168.100.72 |
| Pacemaker + Corosync|          | Pacemaker + Corosync|
| /mnt (active node)  |          | /mnt (standby)      |
+--------------------+           +--------------------+
         \                                 /
          \                               /
           +----------- Cluster ---------+
               Name: storage_cluster
               Resources: my_lvm, my_fs, ClusterIP
```
