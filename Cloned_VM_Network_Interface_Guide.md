
# Handling Network Interface Names in Cloned Linux VMs

## Method 1: Change the MAC back to the old eth0
If you want the interface to be called `eth0` again, simply assign the clone the same MAC that was on VM 101:

```bash
qm set 100 --net0 rtl8139=<old_MAC>,bridge=vmbr0,firewall=1
```

Then restart the VM.

Linux will see the interface with the same MAC and assign it as `eth0` again.

⚠️ **Warning:** This can conflict with production VM 101 if both VMs are on the network simultaneously.

---

## Method 2: Rename the interface inside Linux
Linux remembers the MAC in `/etc/udev/rules.d/70-persistent-net.rules` (or `/etc/systemd/network/` for systemd).

1. Connect to VM 100.
2. Find the rule for the old MAC:

```bash
sudo cat /etc/udev/rules.d/70-persistent-net.rules
```

It will look something like this:

```
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="old_MAC", NAME="eth0"
```

3. Edit the rule to use the new MAC or rename `eth1` to `eth0`:

```bash
sudo nano /etc/udev/rules.d/70-persistent-net.rules
```

- Change `NAME="eth1"` to `NAME="eth0"` and `ATTR{address}` to the new MAC.

4. Reboot the VM:

```bash
sudo reboot
```

---

## Method 3: Use systemd-style renaming (for modern distributions)
If Linux uses `.link` or `.network` files in `/etc/systemd/network/`, you need to edit the interface configuration file or add a new `.link` rule with the desired name `eth0`.

---

💡 **Tip for clones:**  
- If VM 100 will be used outside the production network, the easiest way is to just leave it as `eth1` and rename services/configs to use `eth1`.  
- If `eth0` is required, it’s better to create a udev rule with the new MAC.
