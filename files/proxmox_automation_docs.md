# Proxmox Automated VM Creation Documentation

## Overview
This documentation covers the complete setup for automated VM creation on Proxmox using Ubuntu Cloud Images and Cloud-Init. VMs can be deployed in approximately 30 seconds, fully configured and ready to use.

---

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [Initial Setup](#initial-setup)
3. [Network Configuration](#network-configuration)
4. [Creating VMs](#creating-vms)
5. [Post-Creation Tasks](#post-creation-tasks)
6. [Troubleshooting](#troubleshooting)
7. [Reference Commands](#reference-commands)

---

## Prerequisites

### System Information
- **Proxmox Host**: 192.168.100.100
- **Network**: 192.168.100.0/24
- **Gateway**: 192.168.100.108
- **Bridge**: vmbr0
- **DNS**: 8.8.8.8, 1.1.1.1

### Required Files
- Ubuntu Cloud Image: `ubuntu-22.04-server-cloudimg-amd64.img`
- Location: `/root/creation_vm/`
- Creation Script: `03-creation-vm.sh`

---

## Initial Setup

### 1. Fix Proxmox Repository Configuration

Proxmox enterprise repositories require a subscription. For no-subscription use:

```bash
# Disable enterprise repositories
mv /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/pve-enterprise.sources.disabled
mv /etc/apt/sources.list.d/ceph.sources /etc/apt/sources.list.d/ceph.sources.disabled

# Add no-subscription repository
echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list

# Update package lists
apt update
```

**Verification:**
```bash
apt update
# Should complete without 401 errors
```

### 2. Download Ubuntu Cloud Image

**One-time download** (reused for all VMs):

```bash
# Create directory
mkdir -p /root/creation_vm
cd /root/creation_vm

# Download Ubuntu 22.04 cloud image
wget https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img

# Verify download
ls -lh ubuntu-22.04-server-cloudimg-amd64.img
```

**Note:** This 2.2GB file is downloaded once and reused for all VM creations.

---

## Network Configuration

### Network Details
```
Network: 192.168.100.0/24
Proxmox Host: 192.168.100.100
Gateway: 192.168.100.108
Bridge: vmbr0
```

### IP Address Assignment
- VMs use static IP addresses
- Suggested pattern: VM ID = Last octet of IP
  - VM 911 → 192.168.100.111
  - VM 912 → 192.168.100.112
  - VM 300 → 192.168.100.300 (if in range)

### Verify Network Configuration

```bash
# Check Proxmox host network
ip addr show vmbr0
ip route show

# Expected output:
# default via 192.168.100.108 dev vmbr0
# 192.168.100.0/24 dev vmbr0
```

---

## Creating VMs

### Automated Creation Script

Save this as `/root/creation_vm/03-creation-vm.sh`:

```bash
#!/bin/bash

# Path to your downloaded cloud image
IMAGE_PATH="/root/creation_vm/ubuntu-22.04-server-cloudimg-amd64.img"

echo "=== Automated Ubuntu Cloud-Init VM Creation ==="
echo ""

# Check if image exists
if [ ! -f "$IMAGE_PATH" ]; then
    echo "ERROR: Cloud image not found at $IMAGE_PATH"
    exit 1
fi

read -p "Enter VM ID (e.g., 300): " VMID
read -p "Enter VM Name (e.g., test-vm-01): " VMNAME
read -p "Enter Memory in MB (default 2048): " MEMORY
MEMORY=${MEMORY:-2048}
read -p "Enter CPU Cores (default 2): " CORES
CORES=${CORES:-2}
read -p "Enter Disk Size in GB (default 32): " DISKSIZE
DISKSIZE=${DISKSIZE:-32}
read -sp "Enter root password: " PASSWORD
echo ""

echo ""
echo "Creating VM with:"
echo "  ID: $VMID"
echo "  Name: $VMNAME"
echo "  Memory: $MEMORY MB"
echo "  Cores: $CORES"
echo "  Disk: ${DISKSIZE}G"
echo "  OS: Ubuntu 22.04 (Cloud-Init)"
echo ""

read -p "Proceed? (y/n): " CONFIRM

if [ "$CONFIRM" = "y" ]; then
    echo "Creating VM $VMID..."
    
    # Create VM
    qm create $VMID \
      --name $VMNAME \
      --memory $MEMORY \
      --cores $CORES \
      --sockets 1 \
      --cpu host \
      --numa 0 \
      --ostype l26 \
      --scsihw virtio-scsi-single \
      --net0 virtio,bridge=vmbr0,firewall=1 \
      --agent enabled=1
    
    echo "Importing cloud image disk..."
    # Import the cloud image
    qm importdisk $VMID $IMAGE_PATH local-lvm
    
    echo "Configuring disk and boot..."
    # Attach the imported disk
    qm set $VMID --scsi0 local-lvm:vm-$VMID-disk-0
    
    # Set boot order
    qm set $VMID --boot order=scsi0
    
    # Add Cloud-Init drive
    qm set $VMID --ide2 local-lvm:cloudinit
    
    # Add serial console for access
    qm set $VMID --serial0 socket --vga serial0
    
    # Configure Cloud-Init settings
    echo "Configuring Cloud-Init..."
    
    # Get next available IP (you can customize this)
    read -p "Enter IP address (default: 192.168.100.$((VMID))): " IPADDR
    IPADDR=${IPADDR:-192.168.100.$VMID}
    
    qm set $VMID --ciuser root
    qm set $VMID --cipassword "$PASSWORD"
    qm set $VMID --ipconfig0 ip=$IPADDR/24,gw=192.168.100.108
    qm set $VMID --nameserver "8.8.8.8 1.1.1.1"
    
    # Add SSH key if exists
    if [ -f ~/.ssh/id_rsa.pub ]; then
        qm set $VMID --sshkeys ~/.ssh/id_rsa.pub
        echo "✓ SSH key added"
    fi
    
    # Resize disk to requested size
    if [ "$DISKSIZE" -gt 2 ]; then
        RESIZE=$((DISKSIZE - 2))
        echo "Resizing disk to ${DISKSIZE}G..."
        qm resize $VMID scsi0 +${RESIZE}G
    fi
    
    echo ""
    echo "✓ VM $VMNAME created successfully!"
    echo "✓ Config: /etc/pve/qemu-server/${VMID}.conf"
    echo ""
    
    read -p "Start VM now? (y/n): " START
    if [ "$START" = "y" ]; then
        qm start $VMID
        echo "✓ VM $VMID started!"
        echo ""
        echo "VM will be ready in ~30 seconds"
        echo "Login: root / [your password]"
        echo "IP: $IPADDR"
        echo ""
        echo "Access methods:"
        echo "  SSH: ssh root@$IPADDR"
        echo "  Console: qm terminal $VMID"
    fi
fi
```

### Usage

```bash
# Make script executable
chmod +x /root/creation_vm/03-creation-vm.sh

# Run script
cd /root/creation_vm
./03-creation-vm.sh
```

**Example Session:**
```
Enter VM ID: 912
Enter VM Name: test-vm-02
Enter Memory in MB (default 2048): 4096
Enter CPU Cores (default 2): 4
Enter Disk Size in GB (default 32): 64
Enter root password: ********
Enter IP address (default: 192.168.100.912): 192.168.100.112

Creating VM with:
  ID: 912
  Name: test-vm-02
  Memory: 4096 MB
  Cores: 4
  Disk: 64G
  OS: Ubuntu 22.04 (Cloud-Init)

Proceed? (y/n): y
```

---

## Post-Creation Tasks

### 1. Access the VM

**Wait 30-60 seconds** for cloud-init to complete first boot, then:

#### Via SSH (Recommended)
```bash
ssh root@192.168.100.111
```

#### Via Serial Console
```bash
qm terminal 911
# Press Enter to see login prompt
# Login: root
# Password: [your password]
# Exit: Ctrl+O
```

#### Via Web UI
1. Open Proxmox web interface: `https://192.168.100.100:8006`
2. Navigate to VM → Console

### 2. Install Additional Software

Inside the VM:

```bash
# Update packages
apt update && apt upgrade -y

# Install common tools
apt install -y vim curl wget htop net-tools

# Install QEMU Guest Agent (if not already installed)
apt install -y qemu-guest-agent openssh-server
systemctl enable --now qemu-guest-agent
systemctl enable --now ssh
```

### 3. Verify Configuration

```bash
# Check IP configuration
ip addr show eth0

# Check internet connectivity
ping -c 3 google.com

# Check DNS resolution
nslookup google.com

# View cloud-init logs
cat /var/log/cloud-init.log
cat /var/log/cloud-init-output.log

# Check cloud-init status
cloud-init status
```

### 4. Test Guest Agent (from Proxmox host)

```bash
# Ping agent
qm agent 911 ping

# Get network info
qm agent 911 network-get-interfaces

# Get OS info
qm agent 911 get-osinfo

# Get hostname
qm agent 911 get-host-name

# Get filesystem info
qm guest cmd 911 get-fsinfo

# Get timezone
qm guest cmd 911 get-timezone

# Get vCPU info
qm guest cmd 911 get-vcpus
```

---

## Troubleshooting

### VM Won't Boot / Stuck at Console

**Symptom:** Serial console shows "Wait for network" or blank screen

**Solution:**
1. Check if VM is actually running:
   ```bash
   qm status 911
   ```

2. Verify network configuration:
   ```bash
   qm config 911 | grep -E "ipconfig|nameserver|net0"
   ```

3. Restart VM:
   ```bash
   qm stop 911
   qm start 911
   sleep 30
   qm terminal 911
   ```

### SSH Connection Refused

**Symptom:** `ssh: connect to host X.X.X.X port 22: Connection refused`

**Causes:**
1. VM still booting (wait 60 seconds)
2. SSH server not installed

**Solution:**
```bash
# Access via console
qm terminal 911

# Inside VM, install SSH
apt update
apt install openssh-server -y
systemctl enable --now ssh
```

### No Internet Access in VM

**Symptom:** Cannot ping external hosts

**Check:**
1. Gateway configuration:
   ```bash
   # Inside VM
   ip route show
   # Should show: default via 192.168.100.108
   ```

2. DNS configuration:
   ```bash
   # Inside VM
   cat /etc/resolv.conf
   # Should contain: nameserver 8.8.8.8
   ```

**Fix:**
```bash
# Inside VM
# Fix gateway
ip route del default
ip route add default via 192.168.100.108

# Fix DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# Test
ping -c 3 8.8.8.8
ping -c 3 google.com
```

**Permanent Fix (from Proxmox host):**
```bash
qm stop 911
qm set 911 --ipconfig0 ip=192.168.100.111/24,gw=192.168.100.108
qm set 911 --nameserver "8.8.8.8 1.1.1.1"
qm start 911
```

### Guest Agent Not Working

**Symptom:** `qm agent 911 ping` returns "No QEMU guest agent configured"

**Solution:**
```bash
# Enable agent in VM config
qm set 911 --agent enabled=1

# Restart VM
qm stop 911
qm start 911

# Wait 30 seconds, then test
sleep 30
qm agent 911 ping
```

If still not working, install inside VM:
```bash
ssh root@192.168.100.111
apt install qemu-guest-agent -y
systemctl start qemu-guest-agent
```

### Cloud-Init Stuck on apt update

**Symptom:** Can't run `apt update` - locked by process

**Cause:** Cloud-init is running `apt update` in background

**Solution:**
```bash
# Wait for cloud-init to finish
cloud-init status --wait

# Or check status
cloud-init status

# When it shows "status: done", you can proceed
```

### Disk Space Warnings

**Symptom:** LVM warnings about thin pool exceeding volume group

**This is normal** when using thin provisioning. VMs share a pool and warnings appear when total allocated space exceeds physical space.

**Monitor:**
```bash
# Check actual usage
lvs
pvs

# See VM disk usage
qm list
```

**If truly running out of space:**
- Add more physical storage
- Delete unused VMs
- Reduce VM disk sizes

---

## Reference Commands

### VM Management

```bash
# List all VMs
qm list

# Show VM status
qm status <vmid>

# Start VM
qm start <vmid>

# Stop VM (forced)
qm stop <vmid>

# Shutdown gracefully (requires guest agent)
qm shutdown <vmid>

# Restart VM
qm reboot <vmid>

# Delete VM
qm destroy <vmid>

# Clone VM
qm clone <source-vmid> <new-vmid> --name <new-name>
```

### VM Configuration

```bash
# View VM config
qm config <vmid>

# View specific VM config file
cat /etc/pve/qemu-server/<vmid>.conf

# Modify VM settings
qm set <vmid> --memory 4096
qm set <vmid> --cores 4
qm set <vmid> --name new-name

# Resize disk
qm resize <vmid> scsi0 +10G

# Add network interface
qm set <vmid> --net1 virtio,bridge=vmbr0
```

### Cloud-Init Configuration

```bash
# View cloud-init config
qm cloudinit dump <vmid> user

# Update cloud-init settings
qm set <vmid> --ipconfig0 ip=192.168.100.X/24,gw=192.168.100.108
qm set <vmid> --nameserver "8.8.8.8"
qm set <vmid> --ciuser root
qm set <vmid> --cipassword "newpassword"
qm set <vmid> --sshkeys ~/.ssh/id_rsa.pub
```

### Console Access

```bash
# Serial console (text-based)
qm terminal <vmid>
# Exit with: Ctrl+O

# VNC console (via web UI)
# Access through Proxmox web interface

# Monitor console
qm monitor <vmid>
```

### Guest Agent Commands

```bash
# Test agent connectivity
qm agent <vmid> ping

# Get network interfaces
qm agent <vmid> network-get-interfaces

# Get OS information
qm agent <vmid> get-osinfo

# Get hostname
qm agent <vmid> get-host-name

# Available guest commands
qm guest cmd <vmid> get-fsinfo
qm guest cmd <vmid> get-users
qm guest cmd <vmid> get-timezone
qm guest cmd <vmid> get-vcpus
qm guest cmd <vmid> shutdown
```

### Network Diagnostics

```bash
# From Proxmox host
ping <vm-ip>
arp -a | grep <mac-address>
nmap -sn 192.168.100.0/24

# Inside VM
ip addr show
ip route show
ping 8.8.8.8
ping google.com
cat /etc/resolv.conf
```

---

## Advanced Topics

### Creating a VM Template

Instead of importing the cloud image each time, create a template:

```bash
# Create template VM (one time)
TEMPLATE_ID=9000

qm create $TEMPLATE_ID --name ubuntu22-template --memory 2048 --cores 2 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-single --agent enabled=1

qm importdisk $TEMPLATE_ID /root/creation_vm/ubuntu-22.04-server-cloudimg-amd64.img local-lvm

qm set $TEMPLATE_ID --scsi0 local-lvm:vm-$TEMPLATE_ID-disk-0
qm set $TEMPLATE_ID --boot order=scsi0
qm set $TEMPLATE_ID --ide2 local-lvm:cloudinit
qm set $TEMPLATE_ID --serial0 socket --vga serial0
qm set $TEMPLATE_ID --ipconfig0 ip=dhcp
qm set $TEMPLATE_ID --ciuser root

# Convert to template
qm template $TEMPLATE_ID

# Clone template (fast - ~10 seconds)
qm clone 9000 300 --name test-vm-01 --full
qm set 300 --ipconfig0 ip=192.168.100.111/24,gw=192.168.100.108
qm set 300 --nameserver "8.8.8.8"
qm set 300 --cipassword "yourpassword"
qm start 300
```

### Bulk VM Creation

```bash
#!/bin/bash
# Create 5 VMs automatically

for i in {1..5}; do
  VMID=$((910 + i))
  IP=$((110 + i))
  
  echo "Creating VM $VMID with IP 192.168.100.$IP"
  
  qm create $VMID --name "test-vm-$i" --memory 2048 --cores 2 \
    --cpu host --ostype l26 --scsihw virtio-scsi-single \
    --net0 virtio,bridge=vmbr0,firewall=1 --agent enabled=1
  
  qm importdisk $VMID /root/creation_vm/ubuntu-22.04-server-cloudimg-amd64.img local-lvm
  qm set $VMID --scsi0 local-lvm:vm-$VMID-disk-0
  qm set $VMID --boot order=scsi0
  qm set $VMID --ide2 local-lvm:cloudinit
  qm set $VMID --serial0 socket --vga serial0
  qm set $VMID --ciuser root
  qm set $VMID --cipassword "12345678"
  qm set $VMID --ipconfig0 ip=192.168.100.$IP/24,gw=192.168.100.108
  qm set $VMID --nameserver "8.8.8.8 1.1.1.1"
  qm resize $VMID scsi0 +30G
  qm start $VMID
  
  echo "VM $VMID created and started"
  sleep 2
done
```

### SSH Key Setup (Passwordless Login)

```bash
# On Proxmox host, generate SSH key if not exists
[ ! -f ~/.ssh/id_rsa ] && ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa

# Add to VM during creation (already in script)
qm set <vmid> --sshkeys ~/.ssh/id_rsa.pub

# After VM creation, test
ssh root@192.168.100.111
# Should login without password
```

---

## Best Practices

### Security
1. **Change default passwords** immediately after VM creation
2. **Use SSH keys** instead of passwords when possible
3. **Enable firewall** on VMs
4. **Keep systems updated**: `apt update && apt upgrade -y`
5. **Disable root SSH** after creating non-root user (optional)

### Performance
1. **Use virtio drivers** for network and disk (already configured)
2. **Enable QEMU guest agent** for better VM management
3. **Allocate appropriate resources** - don't over-provision
4. **Use SSD storage** for better I/O performance if available

### Maintenance
1. **Regular backups**: Use Proxmox backup functionality
2. **Document VM purposes** using descriptions/tags
3. **Monitor disk usage**: Check thin pool allocation
4. **Keep cloud images updated**: Download new images quarterly
5. **Test disaster recovery** procedures periodically

### Naming Conventions
- **VM IDs**: Use ranges for different purposes
  - 100-199: Templates
  - 200-299: Production
  - 300-399: Development
  - 900-999: Testing
- **Hostnames**: Use descriptive names (app-server-01, db-primary, etc.)
- **IP Addresses**: Match VM ID to last octet when possible

---

## Summary

### What Was Accomplished

1.  Fixed Proxmox repository configuration
2.  Downloaded Ubuntu 22.04 cloud image
3.  Created automated VM creation script
4.  Configured proper networking (static IP, gateway, DNS)
5.  Enabled SSH access
6.  Enabled QEMU guest agent
7.  Tested full deployment workflow

### Deployment Time
- **Manual Installation**: 20-30 minutes
- **Automated with Cloud-Init**: ~30 seconds

### Key Files
- **Cloud Image**: `/root/creation_vm/ubuntu-22.04-server-cloudimg-amd64.img`
- **Creation Script**: `/root/creation_vm/03-creation-vm.sh`
- **VM Configs**: `/etc/pve/qemu-server/<vmid>.conf`

### Network Configuration
- **Network**: 192.168.100.0/24
- **Gateway**: 192.168.100.108
- **DNS**: 8.8.8.8, 1.1.1.1
- **Bridge**: vmbr0

---

## Support and Resources

### Official Documentation
- Proxmox VE: https://pve.proxmox.com/wiki/
- Cloud-Init: https://cloudinit.readthedocs.io/
- Ubuntu Cloud Images: https://cloud-images.ubuntu.com/

### Useful Commands Reference
```bash
# Quick VM creation
./03-creation-vm.sh

# Quick SSH access
ssh root@192.168.100.<vmid>

# Quick console access
qm terminal <vmid>

# Quick status check
qm list

# Quick agent test
qm agent <vmid> ping
```


```bash

#!/bin/bash

# Path to your downloaded cloud image
IMAGE_PATH="/root/creation_vm/ubuntu-22.04-server-cloudimg-amd64.img"

echo "=== Automated Ubuntu Cloud-Init VM Creation ==="
echo ""

# Check if image exists
if [ ! -f "$IMAGE_PATH" ]; then
    echo "ERROR: Cloud image not found at $IMAGE_PATH"
    exit 1
fi

read -p "Enter VM ID (e.g., 300): " VMID
read -p "Enter VM Name (e.g., test-vm-01): " VMNAME
read -p "Enter Memory in MB (default 2048): " MEMORY
MEMORY=${MEMORY:-2048}
read -p "Enter CPU Cores (default 2): " CORES
CORES=${CORES:-2}
read -p "Enter Disk Size in GB (default 32): " DISKSIZE
DISKSIZE=${DISKSIZE:-32}
read -sp "Enter root password: " PASSWORD
echo ""

echo ""
echo "Creating VM with:"
echo "  ID: $VMID"
echo "  Name: $VMNAME"
echo "  Memory: $MEMORY MB"
echo "  Cores: $CORES"
echo "  Disk: ${DISKSIZE}G"
echo "  OS: Ubuntu 22.04 (Cloud-Init)"
echo ""

read -p "Proceed? (y/n): " CONFIRM

if [ "$CONFIRM" = "y" ]; then
    echo "Creating VM $VMID..."
    
    # Create VM
    qm create $VMID \
      --name $VMNAME \
      --memory $MEMORY \
      --cores $CORES \
      --sockets 1 \
      --cpu host \
      --numa 0 \
      --ostype l26 \
      --scsihw virtio-scsi-single \
      --net0 virtio,bridge=vmbr0,firewall=1 \
      --agent enabled=1
    
    echo "Importing cloud image disk..."
    # Import the cloud image
    qm importdisk $VMID $IMAGE_PATH local-lvm
    
    echo "Configuring disk and boot..."
    # Attach the imported disk
    qm set $VMID --scsi0 local-lvm:vm-$VMID-disk-0
    
    # Set boot order
    qm set $VMID --boot order=scsi0
    
    # Add Cloud-Init drive
    qm set $VMID --ide2 local-lvm:cloudinit
    
    # Add serial console for access
    qm set $VMID --serial0 socket --vga serial0
    
    # Configure Cloud-Init settings
    echo "Configuring Cloud-Init..."
    
    # Get next available IP (you can customize this)
    read -p "Enter IP address (default: 192.168.100.$((VMID))): " IPADDR
    IPADDR=${IPADDR:-192.168.100.$VMID}
    
    qm set $VMID --ciuser root
    qm set $VMID --cipassword "$PASSWORD"
    qm set $VMID --ipconfig0 ip=$IPADDR/24,gw=192.168.100.108
    qm set $VMID --nameserver "8.8.8.8 1.1.1.1"
    
    # Add SSH key if exists
    if [ -f ~/.ssh/id_rsa.pub ]; then
        qm set $VMID --sshkeys ~/.ssh/id_rsa.pub
        echo "✓ SSH key added"
    fi
    
    # Resize disk to requested size
    if [ "$DISKSIZE" -gt 2 ]; then
        RESIZE=$((DISKSIZE - 2))
        echo "Resizing disk to ${DISKSIZE}G..."
        qm resize $VMID scsi0 +${RESIZE}G
    fi
    
    echo ""
    echo "✓ VM $VMNAME created successfully!"
    echo "✓ Config: /etc/pve/qemu-server/${VMID}.conf"
    echo ""
    
    read -p "Start VM now? (y/n): " START
    if [ "$START" = "y" ]; then
        qm start $VMID
        echo "✓ VM $VMID started!"
        echo ""
        echo "VM will be ready in ~30 seconds"
        echo "Login: root / $PASSWORD"
        echo ""
        echo "To get IP address after boot:"
        echo "  qm guest cmd $VMID network-get-interfaces"
    fi
fi

```


---

**Last Updated**: 2026-01-24  
**Proxmox Version**: 8.x (Trixie)  
**Ubuntu Version**: 22.04.5 LTS (Jammy Jellyfish)
