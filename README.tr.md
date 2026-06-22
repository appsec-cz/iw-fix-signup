# iw-fix-signup

[English](README.md) · [Čeština](README.cs.md) · [Deutsch](README.de.md) · [Italiano](README.it.md) · **Türkçe**

IceWarp WebClient **kendi kendine kayıt** ve **path traversal** açıklarına yönelik geçici çözüm betikleri. İki eşdeğer uygulama sunulmaktadır:

| Platform | Betik |
|----------|-------|
| Linux    | `iw-fix-signup.sh` (Bash) |
| Windows  | `iw-fix-signup.ps1` (PowerShell 5.1 / 7+) |

Her iki betik de aynı değişiklikleri uygular ve aynı sonucu üretir.

## Ne Yapar?

**1. WebClient yapılandırması — `config/_webmail/settings.xml`**

- `<restrictions>`: `disable_signup = 1` ve `disable_signup_ip = 1` değerlerini ayarlar
- `<layout_settings>`: `disable_signup = 1` değerini ayarlar

Dosya mevcut değilse oluşturulur; bir öğe eksikse eklenir; zaten varsa değeri `1` olarak güncellenir.

**2. Path traversal koruması — `html/_shared/tools/filesystem.php`**

`downloadFile()` fonksiyonuna aşağıdaki kontrol eklenir:

```php
if (preg_match('/\.\./',$path)) { throw new Exc('invalid_path'); }
```

## Gereksinimler

- **Linux:** Bash, Perl (neredeyse tüm sunucu kurulumlarında mevcuttur), `root` olarak çalıştırılmalıdır.
- **Windows:** PowerShell 5.1+, **Yönetici olarak** çalıştırılmalıdır.

## Kullanım

```bash
# Linux
sudo ./iw-fix-signup.sh [seçenekler]
```

```powershell
# Windows (yükseltilmiş PowerShell)
powershell -ExecutionPolicy Bypass -File .\iw-fix-signup.ps1 [seçenekler]
```

### Seçenekler

| Linux | Windows | Açıklama |
|-------|---------|----------|
| `-p, --path DIR` | `-Path DIR` | Açık IceWarp kurulum klasörü |
| `--config DIR` | `-Config DIR` | Açık webmail yapılandırma kökü (`_webmail` içeren klasör) |
| `-n, --no-restart` | `-NoRestart` | Değişiklikten sonra yeniden başlatma |
| `--dry-run` | `-DryRun` | Değişiklikleri göster, hiçbir şey yazma |
| `-h, --help` | `Get-Help .\iw-fix-signup.ps1` | Yardım |

## Kurulum Otomatik Tespiti

Kurulum dizini otomatik olarak tespit edilir:

- **Linux:** `/etc/icewarp/icewarp.conf` (`IWS_INSTALL_DIR`) → `/opt/icewarp` →
  `PATH`'teki / systemd ünitesindeki / çalışan servis üzerindeki `icewarpd.sh` → yaygın yollar.
- **Windows:** kayıt defteri `HKLM\SOFTWARE\WOW6432Node\IceWarp\IceWarp Server\InstallDir`
  → IceWarp servis yolu → kayıt defteri taraması → yaygın yollar (`%ProgramFiles%\IceWarp`, …).

**Yük dengeli kümeler:** `<kurulum>/path.dat` mevcutsa, içinde gösterilen paylaşılan yapılandırma
klasörü `settings.xml` için kullanılır (PHP dosyası her zaman yerel olarak yamalanır). Paylaşılan
yapılandırma salt okunursa betik uyarı verir ve yine de yerel PHP düzeltmesini uygular.

## Güvenlik

- Herhangi bir dosya değiştirilmeden önce, `<kurulum>/iw-fix-signup-backup/` dizinine (izinler: `700`, dosyalar: `600`) zaman damgalı bir yedek oluşturulur — bu sayede `filesystem.php` yedeği asla web'den erişilebilir olmaz.
- **Tekrar çalıştırılabilir (idempotent)** — yeniden çalıştırıldığında ek değişiklik yapmaz.
- **Doğrulanır** — yazma işleminin ardından sonuç yeniden okunup kontrol edilir.
- `--dry-run` seçeneği herhangi bir şey yazmadan tam olarak nelerin değişeceğini gösterir.

## Yeniden Başlatma

Değişikliğin geçerli olması için Control modülü yeniden başlatılmalıdır (aksi belirtilmedikçe otomatik yapılır):

- **Linux:** `icewarpd.sh --restart control` (yalnızca Control modülü).
- **Windows:** IceWarp servisi yeniden başlatılır (Windows'ta modül bazlı CLI yeniden başlatma
  yoktur, dolayısıyla tüm modüller kısa süreliğine yeniden başlar). Alternatif olarak Uzak
  Konsol kullanılabilir: *System → Services*.

## Çıkış Kodları

| Kod | Anlam |
|-----|-------|
| 0 | Başarılı |
| 2 | Hatalı argüman |
| 3 | Kurulum / bölüm bulunamadı (geçici çözüm tamamlanmamış olabilir) |
| 4 | Yazma hatası (izin sorunu) |
| 5 | Doğrulama başarısız |

## Geri Alma

Yedek dizininden geri yükleyin (`<kurulum>/iw-fix-signup-backup/`), örneğin:

```bash
cp -p <kurulum>/iw-fix-signup-backup/settings.xml.bak.<zaman_damgası>    <kurulum>/config/_webmail/settings.xml
cp -p <kurulum>/iw-fix-signup-backup/filesystem.php.bak.<zaman_damgası>  <kurulum>/html/_shared/tools/filesystem.php
```

## Sorumluluk Reddi

Bu bir **geçici çözümdür**. Düzeltilmiş bir IceWarp sürümü yayımlandığında sisteminizi güncelleyin.
