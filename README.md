# iw-fix-signup

**English** · [Čeština](README.cs.md) · [Deutsch](README.de.md) · [Italiano](README.it.md)

Mitigation scripts for the IceWarp WebClient **self-registration** and
**path-traversal** issue. Two equivalent implementations are provided:

| Platform | Script |
|----------|--------|
| Linux    | `iw-fix-signup.sh` (Bash) |
| Windows  | `iw-fix-signup.ps1` (PowerShell 5.1 / 7+) |

Both perform the same changes and produce the same result.

## What it does

**1. WebClient configuration — `config/_webmail/settings.xml`**

- `<restrictions>`: sets `disable_signup = 1` and `disable_signup_ip = 1`
- `<layout_settings>`: sets `disable_signup = 1`

If the file does not exist it is created; if an element is missing it is
inserted; if it already exists its value is set to `1`.

**2. Path-traversal guard — `html/_shared/tools/filesystem.php`**

A check is injected into the `downloadFile()` function:

```php
if (preg_match('/\.\./',$path)) { throw new Exc('invalid_path'); }
```

## Requirements

- **Linux:** Bash, Perl (present on virtually all server installs), run as `root`.
- **Windows:** PowerShell 5.1+ run **as Administrator**.

## Usage

```bash
# Linux
sudo ./iw-fix-signup.sh [options]
```

```powershell
# Windows (elevated PowerShell)
.\iw-fix-signup.ps1 [options]
```

### Options

| Linux | Windows | Meaning |
|-------|---------|---------|
| `-p, --path DIR` | `-Path DIR` | Explicit IceWarp install folder |
| `--config DIR` | `-Config DIR` | Explicit webmail config root (folder containing `_webmail`) |
| `-n, --no-restart` | `-NoRestart` | Do not restart after the change |
| `--dry-run` | `-DryRun` | Show changes, write nothing |
| `-h, --help` | `Get-Help .\iw-fix-signup.ps1` | Help |

## Install auto-detection

The installation directory is detected automatically:

- **Linux:** `/etc/icewarp/icewarp.conf` (`IWS_INSTALL_DIR`) → `/opt/icewarp` →
  `icewarpd.sh` on `PATH` / systemd unit / running daemon → common paths.
- **Windows:** registry `HKLM\SOFTWARE\WOW6432Node\IceWarp\IceWarp Server\InstallDir`
  → IceWarp service path → registry scan → common paths (`%ProgramFiles%\IceWarp`, …).

**Load-balanced clusters:** if `<install>/path.dat` exists, the shared config
folder it points to is used for `settings.xml` (the PHP file is always patched
locally). If the shared config is read-only, the script warns and still applies
the local PHP hotfix.

## Safety

- A timestamped backup is created **outside the web root**, in `<install>/iw-fix-signup-backup/` (dir `700`, files `600`), before any file is changed — so a backup of `filesystem.php` is never web-accessible.
- **Idempotent** — re-running makes no further changes.
- **Verified** — the result is re-read and checked after writing.
- `--dry-run` shows exactly what would change without writing.

## Restart

The Control module must be restarted to apply the change (done automatically
unless `--no-restart` / `-NoRestart`):

- **Linux:** `icewarpd.sh --restart control` (Control module only).
- **Windows:** the IceWarp service is restarted (Windows has no per-module CLI
  restart, so all modules briefly restart). Alternatively use the Remote
  Console: *System → Services*.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 2 | Bad argument |
| 3 | Installation / section not found (mitigation may be incomplete) |
| 4 | Write error (permissions) |
| 5 | Verification failed |

## Rollback

Restore from the backup directory (`<install>/iw-fix-signup-backup/`), e.g.:

```bash
cp -p <install>/iw-fix-signup-backup/settings.xml.bak.<timestamp>    <install>/config/_webmail/settings.xml
cp -p <install>/iw-fix-signup-backup/filesystem.php.bak.<timestamp>  <install>/html/_shared/tools/filesystem.php
```

## Disclaimer

This is a **mitigation**. Upgrade to a fixed IceWarp build when one is available.
