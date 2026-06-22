# iw-fix-signup

[English](README.md) · **Čeština** · [Deutsch](README.de.md) · [Italiano](README.it.md)

Skripty pro zmírnění (mitigaci) problému se **samoregistrací uživatelů** a
**path traversal** ve WebClientu IceWarp. K dispozici jsou dvě rovnocenné
implementace:

| Platforma | Skript |
|-----------|--------|
| Linux     | `iw-fix-signup.sh` (Bash) |
| Windows   | `iw-fix-signup.ps1` (PowerShell 5.1 / 7+) |

Obě provádějí stejné změny a dávají stejný výsledek.

## Co skript dělá

**1. Konfigurace WebClientu — `config/_webmail/settings.xml`**

- `<restrictions>`: nastaví `disable_signup = 1` a `disable_signup_ip = 1`
- `<layout_settings>`: nastaví `disable_signup = 1`

Pokud soubor neexistuje, vytvoří se; pokud prvek chybí, doplní se; pokud už
existuje, jeho hodnota se nastaví na `1`.

**2. Ochrana proti path traversal — `html/_shared/tools/filesystem.php`**

Do funkce `downloadFile()` se vloží kontrola:

```php
if (preg_match('/\.\./',$path)) { throw new Exc('invalid_path'); }
```

## Požadavky

- **Linux:** Bash, Perl (přítomen prakticky na všech serverech), spouštět jako `root`.
- **Windows:** PowerShell 5.1+ spuštěný **jako správce (Administrator)**.

## Použití

```bash
# Linux
sudo ./iw-fix-signup.sh [volby]
```

```powershell
# Windows (PowerShell jako správce)
.\iw-fix-signup.ps1 [volby]
```

### Volby

| Linux | Windows | Význam |
|-------|---------|--------|
| `-p, --path DIR` | `-Path DIR` | Explicitní instalační složka IceWarpu |
| `--config DIR` | `-Config DIR` | Explicitní kořen webmail konfigurace (složka s `_webmail`) |
| `-n, --no-restart` | `-NoRestart` | Po změně nerestartovat |
| `--dry-run` | `-DryRun` | Zobrazit změny, nic nezapisovat |
| `-h, --help` | `Get-Help .\iw-fix-signup.ps1` | Nápověda |

## Automatická detekce instalace

Instalační složka se zjišťuje automaticky:

- **Linux:** `/etc/icewarp/icewarp.conf` (`IWS_INSTALL_DIR`) → `/opt/icewarp` →
  `icewarpd.sh` v `PATH` / systemd jednotka / běžící démon → běžné cesty.
- **Windows:** registry `HKLM\SOFTWARE\WOW6432Node\IceWarp\IceWarp Server\InstallDir`
  → cesta služby IceWarp → průchod registru → běžné cesty (`%ProgramFiles%\IceWarp`, …).

**Load-balanced clustery:** pokud existuje `<install>/path.dat`, použije se
sdílená konfigurační složka, na kterou ukazuje, pro `settings.xml` (PHP soubor
se vždy patchuje lokálně). Je-li sdílená konfigurace jen pro čtení, skript
upozorní a přesto aplikuje lokální PHP hotfix.

## Bezpečnost

- Před každou změnou se vytvoří časová záloha (`*.bak.<časová značka>`).
- **Idempotentní** — opakované spuštění už nic nemění.
- **Ověřené** — výsledek se po zápisu znovu načte a zkontroluje.
- `--dry-run` přesně ukáže, co by se změnilo, bez zápisu.

## Restart

Pro uplatnění změny je třeba restartovat modul Control (provede se automaticky,
pokud není zadáno `--no-restart` / `-NoRestart`):

- **Linux:** `icewarpd.sh --restart control` (jen modul Control).
- **Windows:** restartuje se služba IceWarp (Windows nemá CLI restart
  jednotlivého modulu, takže se krátce restartují všechny moduly). Případně přes
  Remote Console: *System → Services*.

## Návratové kódy

| Kód | Význam |
|-----|--------|
| 0 | Úspěch |
| 2 | Chybný argument |
| 3 | Instalace / sekce nenalezena (mitigace může být neúplná) |
| 4 | Chyba zápisu (oprávnění) |
| 5 | Verifikace selhala |

## Návrat zpět (rollback)

Obnovte časovou zálohu, např.:

```bash
cp -p config/_webmail/settings.xml.bak.<časová značka> config/_webmail/settings.xml
```

## Upozornění

Toto je **mitigace**. Jakmile bude k dispozici opravené sestavení IceWarpu, aktualizujte.
