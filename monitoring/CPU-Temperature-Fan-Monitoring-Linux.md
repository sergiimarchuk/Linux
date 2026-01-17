```bash
sudo apt install lm-sensors hddtemp       # Ubuntu/Debian
sudo zypper install lm_sensors            # openSUSE
sudo yum install lm_sensors               # CentOS/RHEL

sudo sensors-detect
sensors
watch sensors
ipmitool sensor   # if server supports IPMI

sudo apt install tlp tlp-rdw      # install TLP (Ubuntu/Debian)
sudo zypper install tlp            # openSUSE
sudo yum install tlp               # CentOS/RHEL

sudo tlp start                     # start TLP
sudo tlp-stat                      # check CPU temp, battery, fans

