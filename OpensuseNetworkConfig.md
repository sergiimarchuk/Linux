# OpenSUSE Network Configuration Guide

This guide explains where OpenSUSE stores network configuration files and how to modify them to set static IP addresses or adjust network settings.

## 1. Network Configuration Files

### 1.1 Interface Configuration (ifcfg)

OpenSUSE uses `wicked` or legacy ifcfg scripts for network interfaces. Each interface has its own configuration file:

```
/etc/sysconfig/network/ifcfg-<interface_name>
```

**Example:** `/etc/sysconfig/network/ifcfg-eth0`

```
BOOTPROTO='static'
STARTMODE='auto'
IPADDR='192.168.1.100/24'
GATEWAY='192.168.1.1'
```

* `BOOTPROTO` – method of obtaining IP (`static` or `dhcp`).
* `STARTMODE` – whether to start automatically (`auto`) or manually.
* `IPADDR` – static IP address.
* `GATEWAY` – default gateway.

### 1.2 Global Network Configuration

File for global network parameters:

```
/etc/sysconfig/network/config
```

Contains options like hostname, default route behavior, etc.

### 1.3 DNS Configuration

The DNS resolver is configured in:

```
/etc/resolv.conf
```

Example:

```
nameserver 8.8.8.8
nameserver 8.8.4.4
```

### 1.4 systemd-networkd (optional)

Some setups use `systemd-networkd`. In that case, interface configs are stored in:

```
/etc/systemd/network/*.network
```

Example:

```
[Match]
Name=eth0

[Network]
Address=192.168.1.100/24
Gateway=192.168.1.1
DNS=8.8.8.8
```

## 2. Checking Current Network Status

Use the following commands:

```bash
ip addr show       # Show all IP addresses
ip route show      # Show routing table
```

Or check ifcfg files for static IPs:

```bash
cat /etc/sysconfig/network/ifcfg-eth0
```

## 3. Changing IP Address

1. Edit the interface config file:

   ```bash
   sudo nano /etc/sysconfig/network/ifcfg-eth0
   ```
2. Set `BOOTPROTO='static'` and specify `IPADDR` and `GATEWAY`.
3. Restart the network service:

   ```bash
   sudo systemctl restart network
   ```

## 4. Notes

* Cloned VMs may see new interface names (eth1 instead of eth0) due to MAC changes.
* To maintain `eth0` naming, update `/etc/udev/rules.d/70-persistent-net.rules` with the new MAC.
* Avoid editing live production interface names without proper testing.

---

**End of OpenSUSE Network Configuration Guide**

