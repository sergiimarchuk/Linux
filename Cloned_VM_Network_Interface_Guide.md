
# Handling Network Interface Names in Cloned Linux VMs

## Problem
When you clone a VM, Linux assigns a new interface name (like `eth1`) instead of `eth0` because the cloned VM has a new MAC address. Some services or scripts expect `eth0`, so you may want to restore the original name.

## Solution Options

### Method 1 – Change the MAC Back
Assign the cloned VM the **same MAC address** as the original.

**Command:**
```bash
qm set 100 --net0 rtl8139=<old_MAC>,bridge=vmbr0,firewall=1
```

**Pros:**
- Linux will see it as `eth0`.

**Cons:**
- Risk of conflict if both VMs are on the same network.

---

### Method 2 – Rename Interface via udev Rules
Linux remembers MAC → interface mapping in:

```
/etc/udev/rules.d/70-persistent-net.rules
```

You can edit this file to assign `eth0` to the new MAC.

**Command:**
```bash
sudo nano /etc/udev/rules.d/70-persistent-net.rules
```

- Modify `NAME` and `ATTR{address}` to match the desired interface name and MAC address.

---

### Method 3 – systemd-style Renaming (for Modern Distros)
Edit `.link` or `.network` files in:

```
/etc/systemd/network/
```

to set the interface name.

- This is a more modern approach for newer Linux versions.

---

## Practical Advice
- If the cloned VM is **not in production**, the easiest solution is to leave it as `eth1` and update configurations to use `eth1`.  
- If `eth0` is **required**, updating udev or systemd rules is safer.
