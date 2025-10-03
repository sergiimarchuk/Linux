# BIND DNS Server and Client Setup (openSUSE Leap 15.6)

## 🎯 Goal

Set up a local BIND DNS server for the domain **ps-stat.org.local** in
the `192.168.100.0/24` network, and ensure name resolution on all
network clients.

------------------------------------------------------------------------

## 🧱 1. Install BIND

``` bash
sudo zypper install bind bind-utils
```

## 🔧 2. Configure BIND Service

``` bash
sudo systemctl enable named
sudo systemctl start named
```

## 📂 3. Zone Configuration

File: `/etc/named.d/zone.conf`

``` conf
zone "ps-stat.org.local" IN {
    type master;
    file "/var/lib/named/master/ps-stat.org.local.db";
    allow-update { none; };
};

zone "100.168.192.in-addr.arpa" IN {
    type master;
    file "/var/lib/named/master/100.168.192.in-addr.arpa.db";
    allow-update { none; };
};
```

Include the file in `/etc/named.conf`:

``` conf
include "/etc/named.d/zone.conf";
```

## 📄 4. Forward Zone File ps-stat.org.local

Path: `/var/lib/named/master/ps-stat.org.local.db`

``` dns
$TTL 3600
@   IN  SOA mx.ps-stat.org.local. root.ps-stat.org.local. (
        2025100301 ; Serial
        10800      ; Refresh
        3600       ; Retry
        604800     ; Expire
        86400 )    ; Minimum TTL

@   IN  NS   mx.ps-stat.org.local.
@   IN  A    192.168.100.205
@   IN  MX 10 mx.ps-stat.org.local.

www IN  CNAME @
mx  IN  A    192.168.100.205   ; primary DNS and mail server
base-host-01 IN A 192.168.100.201 ; file services and iSCSI server
```

## 🔁 5. Reverse Zone

Path: `/var/lib/named/master/100.168.192.in-addr.arpa.db`

``` dns
$TTL 3600
@   IN  SOA mx.ps-stat.org.local. root.ps-stat.org.local. (
        2025100301 ; Serial
        10800
        3600
        604800
        86400 )

@   IN  NS   mx.ps-stat.org.local.
205 IN  PTR  ps-stat.org.local.
201 IN  PTR  base-host-01.ps-stat.org.local.
```

## 🔒 6. Zone File Permissions

``` bash
sudo chown named:named /var/lib/named/master/*.db
sudo chmod 644 /var/lib/named/master/*.db
```

## ✅ 7. Check Configuration

``` bash
sudo named-checkconf
sudo named-checkzone ps-stat.org.local /var/lib/named/master/ps-stat.org.local.db
sudo named-checkzone 100.168.192.in-addr.arpa /var/lib/named/master/100.168.192.in-addr.arpa.db
```

## 🔄 8. Reload Configuration

``` bash
sudo rndc reload
```

## 🧠 9. Configure Clients

⚠️ Do not edit `/etc/resolv.conf` manually (it is automatically
overwritten by `netconfig`).

Correct way: configure `/etc/sysconfig/network/config`

``` bash
sudo vi /etc/sysconfig/network/config
```

Modify or add the following lines:

``` conf
NETCONFIG_DNS_STATIC_SERVERS="192.168.100.201 8.8.8.8"
NETCONFIG_DNS_STATIC_SEARCHLIST="ps-stat.org.local"
```

Apply settings:

``` bash
sudo netconfig update -f
```

Now `/etc/resolv.conf` will contain:

``` conf
nameserver 192.168.100.201
search ps-stat.org.local
nameserver 8.8.8.8
```

## 🧪 10. Testing

``` bash
ping base-host-01.ps-stat.org.local
ping base-host-01
dig base-host-01.ps-stat.org.local
dig -x 192.168.100.201
```

------------------------------------------------------------------------

## 📌 Notes

-   Always increase the **Serial** number when modifying zones.\

-   Use `rndc reload` to apply changes.\

-   Ensure BIND is listening on port 53:

    ``` bash
    sudo ss -tulpn | grep :53
    ```

-   View logs:

    ``` bash
    sudo journalctl -u named -f
    ```
