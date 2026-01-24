# Linux Tips: Access Docker Application via SSH Tunnel

## Goal
Connect to a web application inside a Docker container on a remote server, if port 8080 is listening only on localhost of the server.

---

## 1. Create an SSH Tunnel

On your local computer (where the browser is), run:

```bash
ssh -L 8080:localhost:8080 user@192.168.100.60
```
and now we can get access to web http://localhost:8080/ here we go 

#
#

# Linux Tips: rsync - пояснення / Explanation

## 1️⃣ Основний синтаксис  
**Basic syntax**

```bash
rsync [options] SOURCE DESTINATION
```

- **SOURCE** — що копіюємо  
  **SOURCE** — what you want to copy
- **DESTINATION** — куди копіюємо (`user@host:/path`)  
  **DESTINATION** — where to copy it (`user@host:/path`)
- `-a` → архівний режим (зберігає права, часові мітки, симлінки)  
  `-a` → archive mode (preserves permissions, timestamps, symlinks)
- `-v` → verbose, показує процес копіювання  
  `-v` → verbose, shows the copy progress

---

## 2️⃣ Вплив слешу `/` на SOURCE  
**Effect of the trailing slash `/` on SOURCE**

### **A. `my-tracker/`**

```bash
rsync -av my-tracker/ root@192.168.100.60:/opt/dev-py/tempo_Go/my-tracker
```

- Слеш на кінці SOURCE означає: копіювати **вміст каталогу**, а не сам каталог.  
  Trailing slash on SOURCE means: copy **the contents of the directory**, not the directory itself.
- На сервері буде:  
  On the server, you get:

```
/opt/dev-py/tempo_Go/my-tracker/<всі файли та папки з my-tracker>
/opt/dev-py/tempo_Go/my-tracker/<all files and folders inside my-tracker>
```

- Каталог `my-tracker` **не буде вкладено ще раз**.  
  The `my-tracker` directory is **not nested again**.

---

### **B. `my-tracker` (без слешу)**

```bash
rsync -av my-tracker root@192.168.100.60:/opt/dev-py/tempo_Go/my-tracker
```

- Без слешу rsync копіює **сам каталог разом з усім вмістом**.  
  Without the slash, rsync copies **the directory itself with all its contents**.
- На сервері буде:  
  On the server, you get:

```
/opt/dev-py/tempo_Go/my-tracker/my-tracker/<всі файли та папки>
/opt/dev-py/tempo_Go/my-tracker/my-tracker/<all files and folders>
```

- Тобто каталог `my-tracker` **вкладеться всередину**.  
  So the `my-tracker` directory is **nested inside**.

---

### **C. `my-tracker/` → `.../my-tracker/`**

```bash
rsync -av my-tracker/ root@192.168.100.60:/opt/dev-py/tempo_Go/my-tracker/
```

- Слеш на кінці і SOURCE, і DESTINATION.  
  Trailing slashes on both SOURCE and DESTINATION.
- Результат майже такий самий, як варіант **A**: копіюється **вміст SOURCE всередину DESTINATION**, структура зберігається.  
  Result is almost the same as **A**: **contents of SOURCE are copied into DESTINATION**, structure preserved.

> Якщо DESTINATION не існує, rsync його створить. Слеш уточнює, що це каталог.  
> If DESTINATION doesn’t exist, rsync will create it. The slash clarifies it is a directory.

---

### **D. `my-tracker/*`**

```bash
rsync -av my-tracker/* root@192.168.100.60:/opt/dev-py/tempo_Go/my-tracker
```

- `*` — це **розгортання shell**: всі файли та папки всередині `my-tracker` передаються як окремі аргументи.  
  `*` is **shell expansion**: all files and folders inside `my-tracker` are passed as separate arguments.
- Результат схожий на варіант **A**, але є нюанс:  
  Result is similar to **A**, but with a caveat:
  - Якщо є **приховані файли** (починаються з `.`) — вони **не скопіюються**, бо `*` їх не захоплює.  
    If there are **hidden files** (starting with `.`) — they **won’t be copied**, because `*` does not match them.

---

## ✅ Підсумкова таблиця  
**Summary Table**

| Команда                                      | Що копіюється                                | Результат на сервері                                     |
|---------------------------------------------|-----------------------------------------------|----------------------------------------------------------|
| `my-tracker/`                               | Тільки вміст каталогу `my-tracker`           | `/opt/.../my-tracker/<вміст>`                            |
|                                             | Only the contents of `my-tracker`            | `/opt/.../my-tracker/<contents>`                        |
| `my-tracker`                                | Каталог разом із вмістом                      | `/opt/.../my-tracker/my-tracker/<вміст>`                |
|                                             | Directory itself + contents                   | `/opt/.../my-tracker/my-tracker/<contents>`             |
| `my-tracker/` → `.../my-tracker/`          | Вміст, структура збережена                     | `/opt/.../my-tracker/<вміст>`                            |
|                                             | Contents, structure preserved                 | `/opt/.../my-tracker/<contents>`                        |
| `my-tracker/*`                              | Усі видимі файли та папки                     | `/opt/.../my-tracker/<файли та папки без прихованих>`   |
|                                             | All visible files/folders                     | `/opt/.../my-tracker/<files/folders, hidden excluded>`  |

---

💡 **Правило / Rule of thumb**:

- **Слеш на кінці SOURCE (`my-tracker/`)** → копіювати тільки вміст.  
  **Trailing slash on SOURCE (`my-tracker/`)** → copy only the contents.
- **Без слешу (`my-tracker`)** → копіювати каталог разом із вмістом.  
  **Without slash (`my-tracker`)** → copy the directory itself with contents.
- **`*`** → тільки видимі файли, приховані файли пропадають.  
  `*` → only visible files, hidden files are skipped.
- Слеш на DESTINATION зазвичай необов’язковий, але краще ставити для ясності.  
  Slash on DESTINATION is usually optional, but better to include f

Quick Fixes to Try First
1. Restart the File Manager (Nautilus)
Open a terminal (Ctrl+Alt+T) and run:
bash 

```bash killall nautilus
Then try opening directories again. The file manager may freeze and need to be restarted Zorin Forum.

2. Check Double-Click Settings
By default, you need to double-click folders to open them in the file manager Ubuntu Community. Make sure you're double-clicking, not single-clicking.

3. Verify File Manager is Running
Try opening the file manager directly:

Press the Super key and search for "Files" or "Nautilus"
Or click the Files icon in the Ubuntu Dock

If the Problem Persists
Check for WSL or Desktop Extensions Issues
Some users found that WSL (Windows Subsystem for Linux) or the GNOME shell extension DING (desktop icons) caused issues where files and folders couldn't be opened Launchpad. If you have desktop icons enabled, try disabling the desktop icons extension.
Reset Nautilus Settings
bash

```bash gsettings reset-recursively org.gnome.nautilus
Reinstall Nautilus
bash

```bash sudo apt update

```bash sudo apt install --reinstall nautilus
