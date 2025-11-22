# Linux Tips: Access Docker Application via SSH Tunnel

## Goal
Connect to a web application inside a Docker container on a remote server, if port 8080 is listening only on localhost of the server.

---

## 1. Create an SSH Tunnel

On your local computer (where the browser is), run:

```bash
ssh -L 8080:localhost:8080 user@192.168.100.60
```
### and now we can get access to web http://localhost:8080/ here we go 
