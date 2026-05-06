# Caddy Reverse Proxy Admin Panel

Ein selbst-gehostetes Web-Admin-Panel zur Verwaltung von Reverse-Proxy-Routen
über Caddy v2. Konfiguriert wird per UI; das Skript generiert das Caddyfile
und lädt Caddy atomar neu.

Diese Variante (`v2.0`) ist eine **gehärtete Neufassung** des Original-Skripts
von [Techie](https://callmetechie.de) — siehe
[Sicherheit](#sicherheit) für die wichtigsten Änderungen gegenüber v1.

---

## Features

- Web-UI zum Anlegen / Bearbeiten / Löschen von Reverse-Proxy-Domains
- Pro Domain wählbar: Backend-IP, Port, HTTP/HTTPS, Let's-Encrypt-Zertifikat
- Atomarer Caddyfile-Reload mit Validierung und automatischem Backup
- Login mit bcrypt-gehashtem Passwort, PHP-Session, Brute-Force-Limit
- CSRF-Schutz für alle mutierenden API-Endpunkte
- Reachability-Check pro Backend (TLS-Verify aktiv)
- Tägliches Backup von Caddyfile, `domains.json` und Zertifikaten via Cron

## Architektur

```
Browser ── HTTPS ──> Caddy ── php_fastcgi ──> PHP-FPM (Admin-Panel)
                       │
                       ├──> reverse_proxy ──> Backend 1
                       ├──> reverse_proxy ──> Backend 2
                       └──> ...
```

Caddy fungiert sowohl als Webserver für das Admin-Panel als auch als
Reverse-Proxy für die verwalteten Backends. Es gibt keine zusätzliche
Apache-/Nginx-Schicht.

| Pfad                                    | Zweck                                |
|-----------------------------------------|--------------------------------------|
| `/var/www/caddy-admin/`                 | Web-UI (`index.php`, `api.php`, …)   |
| `/etc/caddy-admin/auth.json`            | Username + bcrypt-Hash (`0640`)      |
| `/etc/caddy-admin/config.json`          | Domain, E-Mail, Pfade (`0640`)       |
| `/var/lib/caddy-admin/Caddyfile.staged` | vom Panel generiertes Caddyfile      |
| `/etc/caddy/Caddyfile`                  | Live-Caddyfile (vom Helper rotiert)  |
| `/usr/local/bin/caddy-admin-reload`     | Sudo-Reload-Helper (ohne Argumente)  |
| `/var/backups/caddy/`                   | tägliche Backups + Reload-Snapshots  |

## Voraussetzungen

- Debian 11/12, Ubuntu 22.04/24.04, CentOS/RHEL/Rocky/AlmaLinux 8/9 oder Fedora
- Root-Zugriff (`sudo`)
- Öffentlich erreichbarer Port 80/443, falls Let's Encrypt genutzt wird
- DNS-A-/AAAA-Records, die auf den Server zeigen

## Installation

```bash
wget https://raw.githubusercontent.com/CallMeTechie/Caddy-Reverse-Proxy-AdminPanel/main/install.sh
sudo bash install.sh
```

Während der Installation werden interaktiv abgefragt:

- Admin-Panel-Domain (oder `localhost`)
- E-Mail-Adresse für Let's Encrypt
- SSL ja/nein
- Port (1024–65535)
- **Admin-Benutzername** (3–32 Zeichen, `[a-z0-9_]`)
- **Admin-Passwort** (mind. 12 Zeichen, mit Bestätigung; wird nur als
  bcrypt-Hash gespeichert)
- Firewall (UFW) automatisch konfigurieren ja/nein

Nach Abschluss zeigt das Skript die URL zum Panel an.

## Bedienung

| Aktion                  | Wo                                      |
|-------------------------|-----------------------------------------|
| Login                   | `https://<panel-domain>/login.php`      |
| Domain anlegen          | UI → „Neue Domain hinzufügen"           |
| Caddy manuell reloaden  | UI → Button „Caddy neu laden"           |
| Logout                  | Navbar → Logout                         |

### Passwort zurücksetzen

```bash
NEW_PASS='neuesPasswortMindestens12Zeichen'
HASH=$(php -r "echo password_hash('$NEW_PASS', PASSWORD_BCRYPT, ['cost' => 12]);")
jq --arg h "$HASH" '.password_hash = $h' /etc/caddy-admin/auth.json \
  | sudo tee /etc/caddy-admin/auth.json.new >/dev/null
sudo mv /etc/caddy-admin/auth.json.new /etc/caddy-admin/auth.json
sudo chown root:www-data /etc/caddy-admin/auth.json
sudo chmod 640 /etc/caddy-admin/auth.json
```

## Sicherheit

Wichtige Änderungen gegenüber dem Original-Skript (`v1`):

| Bereich                 | v1                                  | v2 (diese Version)                          |
|-------------------------|-------------------------------------|---------------------------------------------|
| Authentifizierung       | keine                               | Login + bcrypt + Session                    |
| CORS                    | `Access-Control-Allow-Origin: *`    | Same-Origin only                            |
| CSRF                    | nicht vorhanden                     | Token in Session, `X-CSRF-Token`-Header     |
| Caddyfile-Injection     | `additional_config` ungefiltert     | Direktiven-Feld entfernt, alles validiert   |
| Logfile-Pfade           | Domain ungefiltert in Pfad          | Sanitizer (`[^a-z0-9._-]` → `_`)            |
| Sudoers                 | `*`-Argument für Reload-Skript      | Helper ohne Argumente, fixer Stage-Pfad     |
| TLS                     | `tls internal` trotz Let's Encrypt  | Auto-HTTPS via globaler `email`-Direktive   |
| Reachability-Check      | `CURLOPT_SSL_VERIFYPEER=false`      | Verify aktiv (`PEER`/`HOST=2`)              |
| Brute-Force-Schutz      | nicht vorhanden                     | 5 Versuche / 15 Min pro IP + Random-Delay   |
| Race Conditions         | `file_put_contents` ohne Lock       | `flock(LOCK_EX/LOCK_SH)` auf JSON-Stores    |

### Verbleibende Hinweise

- Panel niemals ohne TLS öffentlich erreichbar machen.
- Bei `localhost`-Setups verwendet Caddy ein selbst-signiertes Zertifikat
  (Caddy-CA) — der Browser warnt beim ersten Zugriff.
- Der Sudo-Helper rotiert nur den fest verdrahteten Stage-Pfad; jeder Reload
  validiert das Caddyfile via `caddy validate` zuerst.

## Tests / CI

Das Repo enthält eine GitHub-Actions-Pipeline mit fünf Jobs:

| Job                        | Was geprüft wird                                              |
|----------------------------|----------------------------------------------------------------|
| `Bash & ShellCheck`        | `bash -n install.sh` + `shellcheck -S error`                   |
| `Embedded PHP lint`        | `tests/extract-php.sh` extrahiert Heredocs, dann `php -l`      |
| `Bash unit tests (bats)`   | 25 Bats-Tests für `is_valid_domain`, `is_valid_email` u.a.     |
| `PHP validator unit tests` | 43 PHP-Tests für `validate_domain`/_ip/_port/_protocol/log_name|
| `Validate Caddyfile`       | `caddy validate` auf `tests/sample-caddyfile`                  |

Lokal ausführen:

```bash
bash -n install.sh
shellcheck -S error install.sh
bash tests/extract-php.sh && for f in tests/_extracted/*.php; do php -l "$f"; done
bats tests/install.bats
php tests/test-validators.php
caddy validate --config tests/sample-caddyfile --adapter caddyfile
```

## Deinstallation

```bash
sudo systemctl stop caddy php-fpm 2>/dev/null
sudo rm -rf /var/www/caddy-admin /etc/caddy-admin /var/lib/caddy-admin
sudo rm -f /etc/sudoers.d/caddy-admin /usr/local/bin/caddy-admin-reload \
           /usr/local/bin/backup-caddy.sh /etc/cron.d/caddy-backup
sudo apt-get purge --autoremove caddy php-fpm     # Debian/Ubuntu
# oder
sudo dnf remove caddy php-fpm                     # Fedora/RHEL
```

`/var/backups/caddy/` und `/var/log/caddy/` bleiben bewusst stehen.

## Ordnerstruktur

```
.
├── install.sh                  # Installer (Bash, Heredocs erzeugen Web-Stack)
├── tests/
│   ├── extract-php.sh          # Extrahiert eingebettete PHP-Dateien
│   ├── install.bats            # Bats-Tests für Bash-Funktionen
│   ├── test-validators.php     # PHP-Unit-Tests für Validatoren
│   └── sample-caddyfile        # Repräsentatives Caddyfile für `caddy validate`
└── .github/workflows/ci.yml    # CI-Pipeline (5 Jobs)
```

## Quellen / Inspiration

- Original-Skript und Idee: [Techie](https://callmetechie.de)
- Caddy: <https://caddyserver.com/docs/>
