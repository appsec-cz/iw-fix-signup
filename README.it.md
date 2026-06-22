# iw-fix-signup

[English](README.md) · [Čeština](README.cs.md) · [Deutsch](README.de.md) · **Italiano**

Script per la mitigazione del problema di **auto-registrazione** e di
**path traversal** nel WebClient IceWarp. Sono disponibili due implementazioni
equivalenti:

| Piattaforma | Script |
|-------------|--------|
| Linux       | `iw-fix-signup.sh` (Bash) |
| Windows     | `iw-fix-signup.ps1` (PowerShell 5.1 / 7+) |

Entrambe effettuano le stesse modifiche e producono lo stesso risultato.

## Cosa fa lo script

**1. Configurazione del WebClient — `config/_webmail/settings.xml`**

- `<restrictions>`: imposta `disable_signup = 1` e `disable_signup_ip = 1`
- `<layout_settings>`: imposta `disable_signup = 1`

Se il file non esiste viene creato; se un elemento manca viene inserito; se
esiste già il suo valore viene impostato a `1`.

**2. Protezione contro il path traversal — `html/_shared/tools/filesystem.php`**

Nella funzione `downloadFile()` viene inserito un controllo:

```php
if (preg_match('/\.\./',$path)) { throw new Exc('invalid_path'); }
```

## Requisiti

- **Linux:** Bash, Perl (presente praticamente su tutti i server), eseguire come `root`.
- **Windows:** PowerShell 5.1+ eseguito **come amministratore**.

## Utilizzo

```bash
# Linux
sudo ./iw-fix-signup.sh [opzioni]
```

```powershell
# Windows (PowerShell come amministratore)
.\iw-fix-signup.ps1 [opzioni]
```

### Opzioni

| Linux | Windows | Significato |
|-------|---------|-------------|
| `-p, --path DIR` | `-Path DIR` | Cartella di installazione IceWarp esplicita |
| `--config DIR` | `-Config DIR` | Radice di configurazione webmail esplicita (cartella con `_webmail`) |
| `-n, --no-restart` | `-NoRestart` | Non riavviare dopo la modifica |
| `--dry-run` | `-DryRun` | Mostra le modifiche senza scrivere |
| `-h, --help` | `Get-Help .\iw-fix-signup.ps1` | Aiuto |

## Rilevamento automatico dell'installazione

La cartella di installazione viene rilevata automaticamente:

- **Linux:** `/etc/icewarp/icewarp.conf` (`IWS_INSTALL_DIR`) → `/opt/icewarp` →
  `icewarpd.sh` in `PATH` / unit systemd / daemon in esecuzione → percorsi comuni.
- **Windows:** registro `HKLM\SOFTWARE\WOW6432Node\IceWarp\IceWarp Server\InstallDir`
  → percorso del servizio IceWarp → scansione del registro → percorsi comuni (`%ProgramFiles%\IceWarp`, …).

**Cluster con bilanciamento del carico:** se esiste `<install>/path.dat`, viene
usata la cartella di configurazione condivisa indicata per `settings.xml` (il
file PHP viene sempre patchato localmente). Se la configurazione condivisa è di
sola lettura, lo script avvisa e applica comunque l'hotfix PHP locale.

## Sicurezza

- Prima di ogni modifica viene creato un backup con marca temporale **al di fuori della web root**, in `<install>/iw-fix-signup-backup/` (cartella `700`, file `600`) — un backup di `filesystem.php` non è quindi accessibile dal web.
- **Idempotente** — rieseguire non comporta ulteriori modifiche.
- **Verificato** — il risultato viene riletto e controllato dopo la scrittura.
- `--dry-run` mostra esattamente cosa cambierebbe senza scrivere.

## Riavvio

Per applicare la modifica è necessario riavviare il modulo Control (eseguito
automaticamente se non si specifica `--no-restart` / `-NoRestart`):

- **Linux:** `icewarpd.sh --restart control` (solo modulo Control).
- **Windows:** viene riavviato il servizio IceWarp (Windows non dispone di un
  riavvio da CLI del singolo modulo, quindi tutti i moduli si riavviano
  brevemente). In alternativa tramite la Remote Console: *System → Services*.

## Codici di uscita

| Codice | Significato |
|--------|-------------|
| 0 | Successo |
| 2 | Argomento non valido |
| 3 | Installazione / sezione non trovata (mitigazione forse incompleta) |
| 4 | Errore di scrittura (permessi) |
| 5 | Verifica non riuscita |

## Ripristino (rollback)

Ripristinare dalla cartella dei backup (`<install>/iw-fix-signup-backup/`), ad es.:

```bash
cp -p <install>/iw-fix-signup-backup/settings.xml.bak.<marca temporale>    <install>/config/_webmail/settings.xml
cp -p <install>/iw-fix-signup-backup/filesystem.php.bak.<marca temporale>  <install>/html/_shared/tools/filesystem.php
```

## Avvertenza

Questa è una **mitigazione**. Aggiornare a una build IceWarp corretta non appena
disponibile.
