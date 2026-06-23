# iw-fix-signup

[English](README.md) · [Čeština](README.cs.md) · **Deutsch** · [Italiano](README.it.md) · [Türkçe](README.tr.md)

Skripte zur Eindämmung (Mitigation) des Problems der **Selbstregistrierung** und
des **Path-Traversal** im IceWarp WebClient. Es stehen zwei gleichwertige
Implementierungen zur Verfügung:

| Plattform | Skript |
|-----------|--------|
| Linux     | `iw-fix-signup.sh` (Bash) |
| Windows   | `iw-fix-signup.ps1` (PowerShell 5.1 / 7+) |

Beide führen dieselben Änderungen durch und liefern dasselbe Ergebnis.

## Was das Skript tut

**1. WebClient-Konfiguration — `config/_webmail/settings.xml`**

- `<restrictions>`: setzt `disable_signup = 1` und `disable_signup_ip = 1`
- `<layout_settings>`: setzt `disable_signup = 1`

Existiert die Datei nicht, wird sie erstellt; fehlt ein Element, wird es
eingefügt; existiert es bereits, wird sein Wert auf `1` gesetzt.

**2. Path-Traversal-Schutz — `html/_shared/tools/filesystem.php`**

In die Funktion `downloadFile()` wird eine Prüfung eingefügt:

```php
if (preg_match('/\.\./',$path)) { throw new Exc('invalid_path'); }
```

## Voraussetzungen

- **Linux:** Bash, Perl (auf praktisch allen Servern vorhanden), als `root` ausführen.
- **Windows:** PowerShell 5.1+ **als Administrator** ausführen.

## Verwendung

```bash
# Linux
sudo ./iw-fix-signup.sh [Optionen]
```

```powershell
# Windows (PowerShell als Administrator)
powershell -ExecutionPolicy Bypass -File .\iw-fix-signup.ps1 [Optionen]
```

### Optionen

| Linux | Windows | Bedeutung |
|-------|---------|-----------|
| `-p, --path DIR` | `-Path DIR` | Explizites IceWarp-Installationsverzeichnis |
| `--config DIR` | `-Config DIR` | Explizites Webmail-Konfigurationsverzeichnis (Ordner mit `_webmail`) |
| `-n, --no-restart` | `-NoRestart` | Nach der Änderung nicht neu starten |
| `--dry-run` | `-DryRun` | Änderungen anzeigen, nichts schreiben |
| `-h, --help` | `Get-Help .\iw-fix-signup.ps1` | Hilfe |

## Automatische Erkennung der Installation

Das Installationsverzeichnis wird automatisch ermittelt:

- **Linux:** `/etc/icewarp/icewarp.conf` (`IWS_INSTALL_DIR`) → `/opt/icewarp` →
  `icewarpd.sh` in `PATH` / systemd-Unit / laufender Daemon → übliche Pfade.
- **Windows:** Registry `HKLM\SOFTWARE\WOW6432Node\IceWarp\IceWarp Server\InstallDir`
  → Pfad des IceWarp-Dienstes → übliche Pfade (`%ProgramFiles%\IceWarp`, …).

**Load-Balanced-Cluster:** existiert `<install>/path.dat`, wird der dort
angegebene gemeinsame Konfigurationsordner für `settings.xml` verwendet (die
PHP-Datei wird immer lokal gepatcht). Ist die gemeinsame Konfiguration
schreibgeschützt, warnt das Skript und wendet dennoch den lokalen PHP-Hotfix an.

## Sicherheit

- Vor jeder Änderung wird eine Sicherung mit Zeitstempel **außerhalb des Web-Roots** in `<install>/iw-fix-signup-backup/` (Verzeichnis `700`, Dateien `600`) erstellt — eine Sicherung von `filesystem.php` ist somit nicht über das Web erreichbar.
- **Idempotent** — erneutes Ausführen ändert nichts weiter.
- **Verifiziert** — das Ergebnis wird nach dem Schreiben erneut gelesen und geprüft.
- `--dry-run` zeigt genau, was geändert würde, ohne zu schreiben.

## Neustart

Zum Anwenden der Änderung muss das Control-Modul neu gestartet werden
(automatisch, sofern nicht `--no-restart` / `-NoRestart` angegeben):

- **Linux:** `icewarpd.sh --restart control` (nur Control-Modul).
- **Windows:** der IceWarp-Dienst wird neu gestartet (Windows bietet keinen
  CLI-Neustart einzelner Module, daher starten kurz alle Module neu). Alternativ
  über die Remote Console: *System → Services*.

## Exit-Codes

| Code | Bedeutung |
|------|-----------|
| 0 | Erfolg |
| 2 | Ungültiges Argument |
| 3 | Installation / Abschnitt nicht gefunden (Mitigation evtl. unvollständig) |
| 4 | Schreibfehler (Berechtigungen) |
| 5 | Verifizierung fehlgeschlagen |

## Zurücksetzen (Rollback)

Stellen Sie aus dem Sicherungsverzeichnis (`<install>/iw-fix-signup-backup/`) wieder her, z. B.:

```bash
cp -p <install>/iw-fix-signup-backup/settings.xml.bak.<Zeitstempel>    <install>/config/_webmail/settings.xml
cp -p <install>/iw-fix-signup-backup/filesystem.php.bak.<Zeitstempel>  <install>/html/_shared/tools/filesystem.php
```

## Hinweis

Dies ist eine **Mitigation**. Aktualisieren Sie auf einen korrigierten
IceWarp-Build, sobald dieser verfügbar ist.
