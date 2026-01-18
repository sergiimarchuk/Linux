# Linux System Administration & Infrastructure Guides

> A comprehensive collection of enterprise-grade Linux documentation, guides, and best practices for system administrators and DevOps engineers.

[![GitHub](https://img.shields.io/badge/GitHub-sergiimarchuk-blue?style=flat&logo=github)](https://github.com/sergiimarchuk/Linux)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Contributions Welcome](https://img.shields.io/badge/Contributions-Welcome-brightgreen.svg)](CONTRIBUTING.md)

---

## Table of Contents

- [About](#about)
- [Documentation Index](#documentation-index)
  - [DNS Infrastructure](#dns-infrastructure)
  - [High Availability & Clustering](#high-availability--clustering)
  - [Storage & iSCSI](#storage--iscsi)
  - [Container Orchestration](#container-orchestration)
  - [System Monitoring](#system-monitoring)
  - [Network Configuration](#network-configuration)
  - [General Linux Tips](#general-linux-tips)
- [Quick Start](#quick-start)
- [Prerequisites](#prerequisites)
- [Contributing](#contributing)
- [Support](#support)
- [License](#license)

---

## About

This repository serves as a centralized knowledge base for Linux system administration, covering critical infrastructure components including DNS services, high availability clustering, storage solutions, Kubernetes orchestration, and system monitoring. Each guide is production-tested and follows industry best practices.

**Target Audience:** System Administrators, DevOps Engineers, Site Reliability Engineers (SREs), and Linux enthusiasts looking to implement enterprise-grade infrastructure.

---

## Documentation Index

### DNS Infrastructure

**BIND DNS Server Setup & Configuration**

- **[BIND DNS Setup (openSUSE Leap 15.6)](./dns/BIND-setup-openSUSE-15.6-EN-with-serial.md)**  
  Complete guide for configuring a local BIND DNS server with serial number management. Includes zone file configuration, forward/reverse DNS, and testing procedures.

- **[BIND DNS Setup with Backup (openSUSE Leap 15.6)](./dns/BIND-setup-openSUSE-15.6-EN-with-serial-bckp.md)**  
  Enhanced BIND setup guide featuring backup strategies, redundancy configuration, and disaster recovery procedures.

---

### High Availability & Clustering

**Enterprise HA Solutions with Pacemaker & Corosync**

- **[openSUSE HA Cluster Setup](./clustering/openSUSE-HA-Cluster-Setup.md)**  
  Comprehensive documentation for building production-ready HA clusters on openSUSE, including network setup, shared storage, and monitoring.

---

### Storage & iSCSI

**SAN Storage & iSCSI Configuration**

- **[iSCSI Cluster Setup (Extended Documentation)](./storage/iscsi_cluster_setup_doc.md)**  
  Complete reference material with iSCSI configurations, initiator/target setup, multipath I/O, troubleshooting steps, and performance tuning.

---

### Container Orchestration

**Kubernetes Implementation & Management**

- **[Kubernetes Storage Guide](./kubernetes/k8s-storage-guide.md)**  
  Comprehensive overview of Kubernetes storage solutions including Persistent Volumes (PV), Persistent Volume Claims (PVC), Storage Classes, and dynamic provisioning.

---

### System Monitoring

**Hardware Monitoring & Performance**

Documentation coming soon. This section will cover CPU temperature monitoring, fan speed control, and system performance tools.

---

### Network Configuration

**Network Interface Management**

- **[Cloned VM Network Interface Guide](./networking/Cloned-VM-Network-Interface-Guide.md)**  
  Troubleshooting and fixing network interface issues in cloned virtual machines. Resolves MAC address conflicts and interface naming problems.

---

### General Linux Tips

**Best Practices & Quick References**

Documentation coming soon. This section will include useful commands, shortcuts, and best practices for daily Linux administration tasks.

---

## Quick Start

1. **Clone the repository:**
   ```bash
   git clone https://github.com/sergiimarchuk/Linux.git
   cd Linux
   ```

2. **Browse the documentation:**
   Navigate to any guide that matches your needs using the links in the [Documentation Index](#documentation-index).

3. **Follow the guides:**
   Each document contains step-by-step instructions, configuration examples, and troubleshooting tips.

---

## Prerequisites

Most guides in this repository assume familiarity with:

- Linux command line fundamentals
- Basic networking concepts (IP addressing, DNS, routing)
- Text editors (vim, nano, or similar)
- Package management (zypper for openSUSE, apt/yum for other distros)

**Recommended Linux Distributions:**
- openSUSE Leap 15.6+ (primary focus)
- RHEL/CentOS 8+
- Ubuntu Server 20.04+

---

## Contributing

Contributions are welcome! Whether you want to:

- Fix typos or improve documentation
- Add new guides
- Share best practices
- Report issues

Please feel free to:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-guide`)
3. Commit your changes (`git commit -m 'Add amazing guide'`)
4. Push to the branch (`git push origin feature/amazing-guide`)
5. Open a Pull Request

---

## Support

If you have questions or need help:

- **Issues:** Open an issue on [GitHub Issues](https://github.com/sergiimarchuk/Linux/issues)
- **Discussions:** Start a discussion in [GitHub Discussions](https://github.com/sergiimarchuk/Linux/discussions)

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## Acknowledgments

Special thanks to the open-source community and all contributors who help make these guides better.

---

**If you find these guides helpful, please consider giving the repository a star!**

---

<div align="center">
Made with care for the Linux community
</div>
