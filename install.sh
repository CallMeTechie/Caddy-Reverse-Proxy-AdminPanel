#!/bin/bash
################################################################################
# Caddy Reverse Proxy Admin Panel - Hardened Installer (v2.0)
#
# Original-Idee: Techie (https://callmetechie.de)
# Hardened-Variante: behebt kritische Sicherheitsprobleme + Bugs des Originals.
#
# Was wurde gegenüber v1 geändert:
#   - Authentifizierung: Login-Form, bcrypt-Hash, PHP-Sessions, Brute-Force-Limit
#   - CSRF-Schutz für alle mutierenden API-Endpunkte
#   - Same-Origin: kein "Access-Control-Allow-Origin: *" mehr
#   - Caddyfile-Sanitizer: strikte Domain-/IP-/Port-Validierung, Logpfad escaped,
#     Direktiven-Injection ("additional_config") entfernt
#   - Sudoers ohne Argumente: Reload-Helper liest fixen Stage-Pfad
#   - Echtes Let's Encrypt via globaler email-Direktive (kein "tls internal" mehr)
#   - SSL-Verify in curl aktiviert
#   - flock() für domains.json gegen Race Conditions
#   - Caddy + PHP-FPM nativ (Apache/Nginx-Doppelstack entfernt)
#   - Login-Credentials und Konfiguration werden interaktiv abgefragt
#
# Verwendung: sudo bash install.sh
################################################################################

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# Konfigurationspfade (fest)
INSTALL_DIR="/var/www/caddy-admin"
CADDY_CONFIG_DIR="/etc/caddy"
CADDY_LIVE_FILE="${CADDY_CONFIG_DIR}/Caddyfile"
ADMIN_CONFIG_DIR="/etc/caddy-admin"
ADMIN_CONFIG_FILE="${ADMIN_CONFIG_DIR}/config.json"
ADMIN_AUTH_FILE="${ADMIN_CONFIG_DIR}/auth.json"
STAGE_DIR="/var/lib/caddy-admin"
STAGE_FILE="${STAGE_DIR}/Caddyfile.staged"
RATE_LIMIT_FILE="${STAGE_DIR}/rate-limit.json"
BACKUP_DIR="/var/backups/caddy"
LOG_DIR="/var/log/caddy"
RELOAD_HELPER="/usr/local/bin/caddy-admin-reload"
SUDOERS_FILE="/etc/sudoers.d/caddy-admin"

# Aus Eingaben befüllt
ADMIN_PORT=""
ADMIN_DOMAIN=""
ADMIN_EMAIL=""
ADMIN_USER=""
ADMIN_PASS=""
ENABLE_SSL=false
ENABLE_FIREWALL=true

# Aus detect_*-Schritten befüllt
OS_ID=""
PKG_INSTALL=""
PKG_UPDATE=""
PHP_VERSION=""
PHP_FPM_SOCK=""
PHP_FPM_SERVICE=""
WEB_USER=""
WEB_GROUP=""

# ---- Helper -----------------------------------------------------------------

err()  { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }
warn() { echo -e "${YELLOW}! $*${NC}" >&2; }
info() { echo -e "${YELLOW}→ $*${NC}"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
hr()   { echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"; }

check_root() {
    [[ $EUID -eq 0 ]] || err "Dieses Script muss als root ausgeführt werden (sudo bash install.sh)"
}

show_banner() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  ${GREEN}Caddy Reverse Proxy Admin Panel - Hardened Installer${BLUE}        ║${NC}"
    echo -e "${BLUE}║                       Version 2.0                            ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
}

detect_os() {
    info "Erkenne Betriebssystem..."
    [[ -f /etc/os-release ]] || err "Betriebssystem konnte nicht erkannt werden"
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    case "$OS_ID" in
        ubuntu|debian)
            PKG_INSTALL="apt-get install -y -q"
            PKG_UPDATE="apt-get update -q"
            ;;
        centos|rhel|rocky|almalinux)
            PKG_INSTALL="yum install -y -q"
            PKG_UPDATE="yum makecache -q"
            ;;
        fedora)
            PKG_INSTALL="dnf install -y -q"
            PKG_UPDATE="dnf makecache -q"
            ;;
        *)
            err "Nicht unterstütztes Betriebssystem: $OS_ID (unterstützt: Debian, Ubuntu, CentOS, RHEL, Rocky, AlmaLinux, Fedora)"
            ;;
    esac
    ok "Erkannt: ${PRETTY_NAME:-$OS_ID}"
}

# ---- Eingaben ---------------------------------------------------------------

is_valid_domain() {
    [[ "$1" =~ ^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]]
}

is_valid_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

prompt_config() {
    hr
    echo -e "${YELLOW}Konfigurationseinstellungen:${NC}"
    hr
    echo

    while true; do
        read -r -p "Domain für Admin Panel (z.B. admin.example.com) [localhost]: " ADMIN_DOMAIN
        ADMIN_DOMAIN="${ADMIN_DOMAIN:-localhost}"
        if [[ "$ADMIN_DOMAIN" == "localhost" ]] || is_valid_domain "$ADMIN_DOMAIN"; then
            break
        fi
        echo -e "${RED}Ungültige Domain. Beispiel: admin.example.com${NC}"
    done

    while true; do
        read -r -p "E-Mail für Let's Encrypt: " ADMIN_EMAIL
        if is_valid_email "$ADMIN_EMAIL"; then
            break
        fi
        echo -e "${RED}Ungültige E-Mail-Adresse${NC}"
    done

    if [[ "$ADMIN_DOMAIN" != "localhost" ]]; then
        read -r -p "SSL via Let's Encrypt für Admin-Domain aktivieren? (j/n) [j]: " ans
        ans="${ans:-j}"
        if [[ "$ans" =~ ^[jJ]$ ]]; then
            ENABLE_SSL=true
        else
            ENABLE_SSL=false
        fi
    else
        ENABLE_SSL=false
        echo -e "${YELLOW}  (localhost → kein Let's Encrypt möglich; lokales TLS via 'tls internal')${NC}"
    fi

    while true; do
        read -r -p "Port für Admin Panel [8080]: " ADMIN_PORT
        ADMIN_PORT="${ADMIN_PORT:-8080}"
        if [[ "$ADMIN_PORT" =~ ^[0-9]+$ ]] && (( ADMIN_PORT >= 1024 && ADMIN_PORT <= 65535 )); then
            break
        fi
        echo -e "${RED}Port muss eine Zahl zwischen 1024 und 65535 sein${NC}"
    done

    echo
    echo -e "${BLUE}Login-Credentials für das Admin Panel:${NC}"

    while true; do
        read -r -p "Admin-Benutzername (3-32 Zeichen, a-z 0-9 _): " ADMIN_USER
        if [[ "$ADMIN_USER" =~ ^[a-z0-9_]{3,32}$ ]]; then
            break
        fi
        echo -e "${RED}Ungültiger Benutzername (nur Kleinbuchstaben, Zahlen, Unterstrich; 3-32 Zeichen)${NC}"
    done

    while true; do
        read -r -s -p "Admin-Passwort (mind. 12 Zeichen): " ADMIN_PASS
        echo
        if [[ ${#ADMIN_PASS} -lt 12 ]]; then
            echo -e "${RED}Passwort zu kurz (mindestens 12 Zeichen)${NC}"
            continue
        fi
        read -r -s -p "Passwort bestätigen: " confirm
        echo
        if [[ "$ADMIN_PASS" != "$confirm" ]]; then
            echo -e "${RED}Passwörter stimmen nicht überein${NC}"
            continue
        fi
        break
    done

    echo
    read -r -p "Firewall (UFW) automatisch konfigurieren? (j/n) [j]: " ans
    ans="${ans:-j}"
    if [[ "$ans" =~ ^[nN]$ ]]; then
        ENABLE_FIREWALL=false
    fi

    echo
    echo -e "${GREEN}Zusammenfassung:${NC}"
    echo -e "  Domain:    ${BLUE}${ADMIN_DOMAIN}${NC}"
    echo -e "  E-Mail:    ${BLUE}${ADMIN_EMAIL}${NC}"
    echo -e "  SSL:       ${BLUE}$($ENABLE_SSL && echo "Ja (Let's Encrypt)" || echo "Nein")${NC}"
    echo -e "  Port:      ${BLUE}${ADMIN_PORT}${NC}"
    echo -e "  Benutzer:  ${BLUE}${ADMIN_USER}${NC}"
    echo -e "  Passwort:  ${BLUE}(${#ADMIN_PASS} Zeichen, gehasht gespeichert)${NC}"
    echo -e "  Firewall:  ${BLUE}$($ENABLE_FIREWALL && echo Ja || echo Nein)${NC}"
    echo
    read -r -p "Mit diesen Einstellungen fortfahren? (j/n) [j]: " ans
    ans="${ans:-j}"
    [[ "$ans" =~ ^[jJ]$ ]] || err "Installation vom Benutzer abgebrochen"
}

# ---- Installation -----------------------------------------------------------

update_system() {
    info "Aktualisiere Paketindex..."
    $PKG_UPDATE >/dev/null
    ok "Paketindex aktualisiert"
}

install_caddy() {
    info "Installiere Caddy..."
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        $PKG_INSTALL curl gnupg ca-certificates apt-transport-https debian-keyring debian-archive-keyring >/dev/null
        if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
                | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        fi
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            >/etc/apt/sources.list.d/caddy-stable.list
        $PKG_UPDATE >/dev/null
        $PKG_INSTALL caddy >/dev/null
    else
        if [[ "$OS_ID" == "fedora" ]]; then
            $PKG_INSTALL 'dnf-command(copr)' >/dev/null 2>&1 || true
            dnf copr enable -y @caddy/caddy >/dev/null
        else
            yum install -y -q yum-plugin-copr >/dev/null 2>&1 || true
            yum copr enable -y @caddy/caddy >/dev/null
        fi
        $PKG_INSTALL caddy >/dev/null
    fi
    systemctl enable caddy >/dev/null
    ok "Caddy installiert"
}

install_php() {
    info "Installiere PHP-FPM..."
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        $PKG_INSTALL php-fpm php-cli php-curl php-mbstring php-xml >/dev/null
        WEB_USER="www-data"
        WEB_GROUP="www-data"
    else
        $PKG_INSTALL php php-fpm php-cli php-mbstring php-xml >/dev/null
        WEB_USER="apache"
        WEB_GROUP="apache"
    fi

    PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
    [[ -n "$PHP_VERSION" ]] || err "PHP-Version konnte nicht ermittelt werden"

    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
        PHP_FPM_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"
    else
        PHP_FPM_SERVICE="php-fpm"
        PHP_FPM_SOCK="/run/php-fpm/www.sock"
    fi

    systemctl enable "$PHP_FPM_SERVICE" >/dev/null
    systemctl restart "$PHP_FPM_SERVICE"

    if id caddy >/dev/null 2>&1; then
        usermod -a -G "$WEB_GROUP" caddy || true
    fi

    ok "PHP ${PHP_VERSION} mit FPM-Service ${PHP_FPM_SERVICE} installiert"
}

# ---- Verzeichnisse ---------------------------------------------------------

setup_directories() {
    info "Erstelle Verzeichnisse..."
    install -d -m 750 -o "$WEB_USER" -g "$WEB_GROUP" "$INSTALL_DIR"
    install -d -m 750 -o root        -g "$WEB_GROUP" "$ADMIN_CONFIG_DIR"
    install -d -m 750 -o "$WEB_USER" -g "$WEB_GROUP" "$STAGE_DIR"
    install -d -m 755 -o root        -g root         "$BACKUP_DIR"
    if id caddy >/dev/null 2>&1; then
        install -d -m 755 -o caddy -g caddy "$LOG_DIR"
    else
        install -d -m 755 "$LOG_DIR"
    fi
    ok "Verzeichnisse vorbereitet"
}

# ---- Konfigurationsdateien -------------------------------------------------

write_config_files() {
    info "Schreibe Konfiguration und Auth-Datei..."

    local pw_hash
    pw_hash="$(ADMIN_PASS_RAW="$ADMIN_PASS" php -r '
        echo password_hash(getenv("ADMIN_PASS_RAW"), PASSWORD_BCRYPT, ["cost" => 12]);
    ')"
    [[ -n "$pw_hash" ]] || err "Konnte Passwort-Hash nicht erzeugen"

    php -r '
        echo json_encode(["username" => $argv[1], "password_hash" => $argv[2]], JSON_PRETTY_PRINT);
    ' "$ADMIN_USER" "$pw_hash" > "$ADMIN_AUTH_FILE"
    chown "root:${WEB_GROUP}" "$ADMIN_AUTH_FILE"
    chmod 640 "$ADMIN_AUTH_FILE"

    php -r '
        $cfg = [
            "admin_domain"    => $argv[1],
            "admin_email"     => $argv[2],
            "admin_port"      => intval($argv[3]),
            "enable_ssl"      => $argv[4] === "true",
            "install_dir"     => $argv[5],
            "log_dir"         => $argv[6],
            "stage_file"      => $argv[7],
            "live_caddyfile"  => $argv[8],
            "rate_limit_file" => $argv[9],
        ];
        echo json_encode($cfg, JSON_PRETTY_PRINT);
    ' "$ADMIN_DOMAIN" "$ADMIN_EMAIL" "$ADMIN_PORT" "$($ENABLE_SSL && echo true || echo false)" \
      "$INSTALL_DIR" "$LOG_DIR" "$STAGE_FILE" "$CADDY_LIVE_FILE" "$RATE_LIMIT_FILE" \
      > "$ADMIN_CONFIG_FILE"
    chown "root:${WEB_GROUP}" "$ADMIN_CONFIG_FILE"
    chmod 640 "$ADMIN_CONFIG_FILE"

    ADMIN_PASS=""

    ok "Auth- und Konfigdatei geschrieben (Passwort als bcrypt-Hash, mode 0640)"
}

# ---- Panel-Dateien ----------------------------------------------------------

write_panel_files() {
    info "Schreibe Admin-Panel-Dateien..."

    cat > "${INSTALL_DIR}/index.php" <<'EOPHP'
<?php
require_once __DIR__ . '/lib/auth.php';
auth_init_session();

if (!auth_is_logged_in()) {
    header('Location: login.php');
    exit;
}

$csrf = auth_csrf_token();
?>
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="csrf-token" content="<?= htmlspecialchars($csrf, ENT_QUOTES) ?>">
    <title>Caddy Reverse Proxy Verwaltung</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.10.0/font/bootstrap-icons.css">
    <style>
        .domain-card { transition: transform 0.2s; }
        .domain-card:hover { transform: translateY(-3px); box-shadow: 0 4px 15px rgba(0,0,0,0.1); }
        .loading-spinner { display:none; position:fixed; top:50%; left:50%; transform:translate(-50%,-50%); z-index:9999; }
        .toast-container { position:fixed; top:20px; right:20px; z-index:9999; }
    </style>
</head>
<body>
<nav class="navbar navbar-expand-lg navbar-dark bg-primary">
    <div class="container-fluid">
        <a class="navbar-brand" href="#"><i class="bi bi-server"></i> Caddy Proxy Manager</a>
        <div class="ms-auto d-flex gap-2 align-items-center">
            <button class="btn btn-success" onclick="reloadCaddy()"><i class="bi bi-arrow-clockwise"></i> Caddy neu laden</button>
            <span class="navbar-text text-white-50">
                <i class="bi bi-person-circle"></i> <?= htmlspecialchars($_SESSION['username'] ?? '', ENT_QUOTES) ?>
            </span>
            <a class="btn btn-outline-light btn-sm" href="logout.php"><i class="bi bi-box-arrow-right"></i> Logout</a>
        </div>
    </div>
</nav>

<div class="container mt-4">
    <div class="row mb-4">
        <div class="col-md-4"><div class="card bg-info text-white"><div class="card-body">
            <h5 class="card-title"><i class="bi bi-globe"></i> Domains</h5><h2 id="activeDomains">0</h2>
        </div></div></div>
        <div class="col-md-4"><div class="card bg-success text-white"><div class="card-body">
            <h5 class="card-title"><i class="bi bi-check-circle"></i> Online</h5><h2 id="onlineServices">0</h2>
        </div></div></div>
        <div class="col-md-4"><div class="card bg-warning text-white"><div class="card-body">
            <h5 class="card-title"><i class="bi bi-exclamation-triangle"></i> Offline</h5><h2 id="offlineServices">0</h2>
        </div></div></div>
    </div>

    <div class="row mb-3"><div class="col-12">
        <button class="btn btn-primary" data-bs-toggle="modal" data-bs-target="#addDomainModal">
            <i class="bi bi-plus-circle"></i> Neue Domain hinzufügen
        </button>
        <button class="btn btn-secondary" onclick="loadDomains()"><i class="bi bi-arrow-repeat"></i> Aktualisieren</button>
    </div></div>

    <div class="row" id="domainsList"></div>
</div>

<div class="modal fade" id="addDomainModal" tabindex="-1"><div class="modal-dialog modal-lg"><div class="modal-content">
    <div class="modal-header">
        <h5 class="modal-title" id="modalTitle">Neue Domain hinzufügen</h5>
        <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
    </div>
    <div class="modal-body"><form id="domainForm">
        <input type="hidden" id="domainId" name="id">
        <div class="row">
            <div class="col-md-6 mb-3">
                <label class="form-label" for="domain">Domain</label>
                <input type="text" class="form-control" id="domain" name="domain" placeholder="beispiel.de" required>
                <small class="text-muted">Ohne Protokoll. Wildcards: *.beispiel.de</small>
            </div>
            <div class="col-md-6 mb-3">
                <label class="form-label" for="targetIp">Ziel IP</label>
                <input type="text" class="form-control" id="targetIp" name="target_ip" placeholder="192.168.1.100" required>
            </div>
            <div class="col-md-6 mb-3">
                <label class="form-label" for="targetPort">Ziel Port</label>
                <input type="number" class="form-control" id="targetPort" name="target_port" min="1" max="65535" placeholder="80" required>
            </div>
            <div class="col-md-6 mb-3">
                <label class="form-label" for="protocol">Protokoll zum Backend</label>
                <select class="form-select" id="protocol" name="protocol">
                    <option value="http">HTTP</option>
                    <option value="https">HTTPS</option>
                </select>
            </div>
        </div>
        <div class="form-check form-switch mb-3">
            <input class="form-check-input" type="checkbox" id="enableSsl" name="enable_ssl">
            <label class="form-check-label" for="enableSsl">Let's-Encrypt-Zertifikat (Domain muss öffentlich erreichbar sein)</label>
        </div>
    </form></div>
    <div class="modal-footer">
        <button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Abbrechen</button>
        <button type="button" class="btn btn-primary" onclick="saveDomain()">Speichern</button>
    </div>
</div></div></div>

<div class="loading-spinner"><div class="spinner-border text-primary" style="width:3rem;height:3rem"></div></div>
<div class="toast-container"></div>

<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
<script src="admin.js"></script>
</body>
</html>
EOPHP

    cat > "${INSTALL_DIR}/login.php" <<'EOPHP'
<?php
require_once __DIR__ . '/lib/auth.php';
auth_init_session();

if (auth_is_logged_in()) {
    header('Location: index.php');
    exit;
}

$error = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $user = trim($_POST['username'] ?? '');
    $pass = (string)($_POST['password'] ?? '');
    $ip   = $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0';

    if (auth_rate_limited($ip)) {
        $error = 'Zu viele Fehlversuche. Bitte 15 Minuten warten.';
    } elseif (auth_verify($user, $pass)) {
        auth_rate_reset($ip);
        session_regenerate_id(true);
        $_SESSION['logged_in'] = true;
        $_SESSION['username']  = $user;
        $_SESSION['login_at']  = time();
        header('Location: index.php');
        exit;
    } else {
        auth_rate_record($ip);
        $error = 'Ungültige Anmeldedaten';
        usleep(random_int(200000, 600000));
    }
}
?>
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Login — Caddy Admin</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
</head>
<body class="bg-light">
<div class="container" style="max-width:420px; margin-top:8vh">
    <div class="card shadow-sm"><div class="card-body p-4">
        <h4 class="mb-3 text-center">Caddy Admin Login</h4>
        <?php if ($error !== ''): ?>
            <div class="alert alert-danger py-2"><?= htmlspecialchars($error, ENT_QUOTES) ?></div>
        <?php endif; ?>
        <form method="post" autocomplete="on">
            <div class="mb-3">
                <label class="form-label">Benutzername</label>
                <input type="text" class="form-control" name="username" required autofocus>
            </div>
            <div class="mb-3">
                <label class="form-label">Passwort</label>
                <input type="password" class="form-control" name="password" required>
            </div>
            <button type="submit" class="btn btn-primary w-100">Anmelden</button>
        </form>
    </div></div>
</div>
</body>
</html>
EOPHP

    cat > "${INSTALL_DIR}/logout.php" <<'EOPHP'
<?php
require_once __DIR__ . '/lib/auth.php';
auth_init_session();
$_SESSION = [];
if (ini_get('session.use_cookies')) {
    $p = session_get_cookie_params();
    setcookie(session_name(), '', time() - 42000, $p['path'], $p['domain'], $p['secure'], $p['httponly']);
}
session_destroy();
header('Location: login.php');
EOPHP

    install -d -m 750 -o "$WEB_USER" -g "$WEB_GROUP" "${INSTALL_DIR}/lib"
    cat > "${INSTALL_DIR}/lib/auth.php" <<'EOPHP'
<?php
const AUTH_FILE        = '/etc/caddy-admin/auth.json';
const RATE_LIMIT_FILE  = '/var/lib/caddy-admin/rate-limit.json';
const RATE_LIMIT_MAX   = 5;
const RATE_LIMIT_WIN   = 900;
const SESSION_LIFETIME = 3600;

function auth_init_session(): void {
    if (session_status() === PHP_SESSION_ACTIVE) return;
    $secure = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off')
        || (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https');
    session_set_cookie_params([
        'lifetime' => 0,
        'path'     => '/',
        'domain'   => '',
        'secure'   => $secure,
        'httponly' => true,
        'samesite' => 'Strict',
    ]);
    ini_set('session.use_strict_mode', '1');
    ini_set('session.use_only_cookies', '1');
    session_start();

    if (!empty($_SESSION['login_at']) && (time() - $_SESSION['login_at']) > SESSION_LIFETIME) {
        $_SESSION = [];
        session_destroy();
        session_start();
    }
}

function auth_is_logged_in(): bool {
    return !empty($_SESSION['logged_in']) && !empty($_SESSION['username']);
}

function auth_require_login(): void {
    auth_init_session();
    if (!auth_is_logged_in()) {
        http_response_code(401);
        header('Content-Type: application/json');
        echo json_encode(['success' => false, 'message' => 'Nicht authentifiziert']);
        exit;
    }
}

function auth_csrf_token(): string {
    if (empty($_SESSION['csrf'])) {
        $_SESSION['csrf'] = bin2hex(random_bytes(32));
    }
    return $_SESSION['csrf'];
}

function auth_check_csrf(): void {
    $token = $_SERVER['HTTP_X_CSRF_TOKEN'] ?? '';
    if (!is_string($token) || empty($_SESSION['csrf']) || !hash_equals($_SESSION['csrf'], $token)) {
        http_response_code(403);
        header('Content-Type: application/json');
        echo json_encode(['success' => false, 'message' => 'CSRF-Token ungültig']);
        exit;
    }
}

function auth_load(): array {
    $raw = @file_get_contents(AUTH_FILE);
    if ($raw === false) return [];
    $data = json_decode($raw, true);
    return is_array($data) ? $data : [];
}

function auth_verify(string $user, string $pass): bool {
    $a = auth_load();
    if (empty($a['username']) || empty($a['password_hash'])) return false;
    if (!hash_equals((string)$a['username'], $user)) {
        password_verify($pass, '$2y$12$' . str_repeat('a', 53));
        return false;
    }
    return password_verify($pass, (string)$a['password_hash']);
}

function auth_rate_load(): array {
    $raw = @file_get_contents(RATE_LIMIT_FILE);
    if ($raw === false) return [];
    $data = json_decode($raw, true);
    return is_array($data) ? $data : [];
}

function auth_rate_save(array $data): void {
    $fp = @fopen(RATE_LIMIT_FILE, 'c+');
    if (!$fp) return;
    flock($fp, LOCK_EX);
    ftruncate($fp, 0);
    rewind($fp);
    fwrite($fp, json_encode($data));
    fflush($fp);
    flock($fp, LOCK_UN);
    fclose($fp);
}

function auth_rate_limited(string $ip): bool {
    $data = auth_rate_load();
    if (!isset($data[$ip])) return false;
    $now = time();
    $data[$ip] = array_filter($data[$ip], fn($t) => $t > $now - RATE_LIMIT_WIN);
    return count($data[$ip]) >= RATE_LIMIT_MAX;
}

function auth_rate_record(string $ip): void {
    $data = auth_rate_load();
    $now  = time();
    $data[$ip] ??= [];
    $data[$ip] = array_filter($data[$ip], fn($t) => $t > $now - RATE_LIMIT_WIN);
    $data[$ip][] = $now;
    auth_rate_save($data);
}

function auth_rate_reset(string $ip): void {
    $data = auth_rate_load();
    unset($data[$ip]);
    auth_rate_save($data);
}
EOPHP

    cat > "${INSTALL_DIR}/api.php" <<'EOPHP'
<?php
require_once __DIR__ . '/lib/auth.php';

header('Content-Type: application/json; charset=utf-8');
header('X-Content-Type-Options: nosniff');
header('X-Frame-Options: DENY');
header('Referrer-Policy: same-origin');

auth_require_login();

const CONFIG_FILE = '/etc/caddy-admin/config.json';
const RELOAD_HELPER_BIN = '/usr/local/bin/caddy-admin-reload';

function load_config(): array {
    static $cfg = null;
    if ($cfg !== null) return $cfg;
    $raw = @file_get_contents(CONFIG_FILE);
    if ($raw === false) {
        http_response_code(500);
        echo json_encode(['success' => false, 'message' => 'Config nicht lesbar']);
        exit;
    }
    $cfg = json_decode($raw, true);
    if (!is_array($cfg)) {
        http_response_code(500);
        echo json_encode(['success' => false, 'message' => 'Config korrupt']);
        exit;
    }
    return $cfg;
}

function db_file(): string { return load_config()['install_dir'] . '/domains.json'; }

function db_read(): array {
    $f = db_file();
    if (!file_exists($f)) return ['domains' => []];
    $fp = @fopen($f, 'r');
    if (!$fp) return ['domains' => []];
    flock($fp, LOCK_SH);
    $raw = stream_get_contents($fp);
    flock($fp, LOCK_UN);
    fclose($fp);
    $data = json_decode($raw, true);
    return is_array($data) && isset($data['domains']) ? $data : ['domains' => []];
}

function db_write(array $data): bool {
    $f = db_file();
    $fp = @fopen($f, 'c+');
    if (!$fp) return false;
    if (!flock($fp, LOCK_EX)) { fclose($fp); return false; }
    ftruncate($fp, 0);
    rewind($fp);
    fwrite($fp, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));
    fflush($fp);
    flock($fp, LOCK_UN);
    fclose($fp);
    return true;
}

function validate_domain(string $d): string {
    $d = strtolower(trim($d));
    if ($d === 'localhost') return $d;
    if (!preg_match('/^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$/', $d)) {
        throw new RuntimeException('Ungültige Domain');
    }
    return $d;
}

function validate_ip(string $ip): string {
    if (!filter_var($ip, FILTER_VALIDATE_IP)) {
        throw new RuntimeException('Ungültige IP-Adresse');
    }
    return $ip;
}

function validate_port($p): int {
    $p = (int)$p;
    if ($p < 1 || $p > 65535) throw new RuntimeException('Ungültiger Port');
    return $p;
}

function validate_protocol(string $p): string {
    if (!in_array($p, ['http', 'https'], true)) throw new RuntimeException('Ungültiges Protokoll');
    return $p;
}

function safe_log_name(string $domain): string {
    return preg_replace('/[^a-z0-9._-]/', '_', strtolower($domain));
}

function load_php_sock(): string {
    foreach (['/run/php/php-fpm.sock', '/run/php-fpm/www.sock'] as $p) {
        if (file_exists($p)) return $p;
    }
    foreach (glob('/run/php/php*-fpm.sock') ?: [] as $p) {
        return $p;
    }
    return '/run/php-fpm/www.sock';
}

function generate_caddyfile(array $domains): void {
    $cfg  = load_config();
    $email = preg_replace('/[^A-Za-z0-9@._+\-]/', '', $cfg['admin_email']);
    $out  = "# Auto-generiert vom Caddy Admin Panel\n";
    $out .= "# Manuelle Änderungen werden bei nächstem Reload überschrieben\n\n";
    $out .= "{\n";
    $out .= "    admin localhost:2019\n";
    $out .= "    email {$email}\n";
    $out .= "}\n\n";

    $admin = $cfg['admin_domain'];
    $port  = (int)$cfg['admin_port'];
    if (!empty($cfg['enable_ssl']) && $admin !== 'localhost') {
        $out .= "{$admin} {\n";
    } else {
        $out .= ":{$port} {\n";
        if ($admin === 'localhost') {
            $out .= "    tls internal\n";
        }
    }
    $out .= "    root * " . $cfg['install_dir'] . "\n";
    $out .= "    php_fastcgi unix/" . load_php_sock() . "\n";
    $out .= "    file_server\n";
    $out .= "    @denyPrivate path /lib/* /domains.json /.* \n";
    $out .= "    respond @denyPrivate 403\n";
    $out .= "}\n\n";

    foreach ($domains as $d) {
        $domain  = validate_domain($d['domain']);
        $proto   = validate_protocol($d['protocol'] ?? 'http');
        $ip      = validate_ip($d['target_ip']);
        $tport   = validate_port($d['target_port'] ?? 0);
        $logname = safe_log_name($domain);

        $out .= "{$domain} {\n";
        if ($domain === 'localhost') {
            $out .= "    tls internal\n";
        }
        $out .= "    reverse_proxy {$proto}://{$ip}:{$tport} {\n";
        $out .= "        header_up Host {host}\n";
        $out .= "        header_up X-Real-IP {remote_host}\n";
        $out .= "        header_up X-Forwarded-For {remote_host}\n";
        $out .= "        header_up X-Forwarded-Proto {scheme}\n";
        $out .= "    }\n";
        $out .= "    log {\n";
        $out .= "        output file " . $cfg['log_dir'] . "/{$logname}.log\n";
        $out .= "    }\n";
        $out .= "}\n\n";
    }

    if (file_put_contents($cfg['stage_file'], $out) === false) {
        throw new RuntimeException('Stage-Datei konnte nicht geschrieben werden');
    }
}

function reload_caddy(): array {
    $out = []; $rv = 0;
    exec('sudo -n ' . escapeshellcmd(RELOAD_HELPER_BIN) . ' 2>&1', $out, $rv);
    return ['success' => ($rv === 0), 'message' => implode("\n", $out)];
}

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$action = $_GET['action'] ?? '';

if (in_array($method, ['POST', 'PUT', 'DELETE', 'PATCH'], true)) {
    auth_check_csrf();
}

$writeActions = ['add', 'update', 'delete', 'reload'];
if (in_array($action, $writeActions, true) && $method === 'GET') {
    http_response_code(405);
    echo json_encode(['success' => false, 'message' => 'Method Not Allowed']);
    exit;
}

try {
    switch ($action) {
        case 'list':
            echo json_encode(['success' => true, 'domains' => array_values(db_read()['domains'] ?? [])]);
            break;
        case 'get': {
            $id = (int)($_GET['id'] ?? 0);
            foreach (db_read()['domains'] as $d) {
                if ((int)$d['id'] === $id) { echo json_encode(['success' => true, 'domain' => $d]); exit; }
            }
            http_response_code(404);
            echo json_encode(['success' => false, 'message' => 'Nicht gefunden']);
            break;
        }
        case 'add': {
            $in = json_decode(file_get_contents('php://input'), true);
            if (!is_array($in)) throw new RuntimeException('Ungültiger Body');
            $domain = validate_domain($in['domain'] ?? '');
            $proto  = validate_protocol($in['protocol'] ?? 'http');
            $ip     = validate_ip($in['target_ip'] ?? '');
            $port   = validate_port($in['target_port'] ?? 0);
            $ssl    = !empty($in['enable_ssl']);

            $data = db_read();
            foreach ($data['domains'] as $d) {
                if (strcasecmp($d['domain'], $domain) === 0) {
                    throw new RuntimeException('Domain existiert bereits');
                }
            }
            $maxId = 0;
            foreach ($data['domains'] as $d) { if ((int)$d['id'] > $maxId) $maxId = (int)$d['id']; }
            $now = date('c');
            $data['domains'][] = [
                'id' => $maxId + 1, 'domain' => $domain, 'target_ip' => $ip,
                'target_port' => $port, 'protocol' => $proto, 'ssl_enabled' => $ssl,
                'created_at' => $now, 'updated_at' => $now,
            ];
            if (!db_write($data)) throw new RuntimeException('Speichern fehlgeschlagen');
            generate_caddyfile($data['domains']);
            $r = reload_caddy();
            if (!$r['success']) throw new RuntimeException('Caddy-Reload: ' . $r['message']);
            echo json_encode(['success' => true]);
            break;
        }
        case 'update': {
            $in = json_decode(file_get_contents('php://input'), true);
            if (!is_array($in) || empty($in['id'])) throw new RuntimeException('Ungültiger Body');
            $id     = (int)$in['id'];
            $domain = validate_domain($in['domain'] ?? '');
            $proto  = validate_protocol($in['protocol'] ?? 'http');
            $ip     = validate_ip($in['target_ip'] ?? '');
            $port   = validate_port($in['target_port'] ?? 0);
            $ssl    = !empty($in['enable_ssl']);

            $data = db_read();
            $found = false;
            foreach ($data['domains'] as &$d) {
                if ((int)$d['id'] === $id) {
                    $d['domain'] = $domain; $d['target_ip'] = $ip; $d['target_port'] = $port;
                    $d['protocol'] = $proto; $d['ssl_enabled'] = $ssl;
                    $d['updated_at'] = date('c');
                    $found = true; break;
                }
            }
            unset($d);
            if (!$found) throw new RuntimeException('Nicht gefunden');
            if (!db_write($data)) throw new RuntimeException('Speichern fehlgeschlagen');
            generate_caddyfile($data['domains']);
            $r = reload_caddy();
            if (!$r['success']) throw new RuntimeException('Caddy-Reload: ' . $r['message']);
            echo json_encode(['success' => true]);
            break;
        }
        case 'delete': {
            $id = (int)($_GET['id'] ?? 0);
            $data = db_read();
            $new  = array_values(array_filter($data['domains'], fn($d) => (int)$d['id'] !== $id));
            if (count($new) === count($data['domains'])) throw new RuntimeException('Nicht gefunden');
            $data['domains'] = $new;
            if (!db_write($data)) throw new RuntimeException('Speichern fehlgeschlagen');
            generate_caddyfile($data['domains']);
            $r = reload_caddy();
            if (!$r['success']) throw new RuntimeException('Caddy-Reload: ' . $r['message']);
            echo json_encode(['success' => true]);
            break;
        }
        case 'test': {
            $id = (int)($_GET['id'] ?? 0);
            $found = null;
            foreach (db_read()['domains'] as $d) { if ((int)$d['id'] === $id) { $found = $d; break; } }
            if (!$found) throw new RuntimeException('Nicht gefunden');
            $url = $found['protocol'] . '://' . $found['target_ip'] . ':' . $found['target_port'];
            $ch = curl_init($url);
            curl_setopt_array($ch, [
                CURLOPT_RETURNTRANSFER => true,
                CURLOPT_TIMEOUT        => 5,
                CURLOPT_NOBODY         => true,
                CURLOPT_SSL_VERIFYPEER => true,
                CURLOPT_SSL_VERIFYHOST => 2,
                CURLOPT_FOLLOWLOCATION => false,
            ]);
            curl_exec($ch);
            $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
            $err  = curl_error($ch);
            curl_close($ch);
            echo json_encode([
                'success'   => true,
                'reachable' => ($code > 0),
                'http_code' => $code,
                'error'     => $err ?: null,
            ]);
            break;
        }
        case 'stats': {
            $domains = db_read()['domains'];
            $online = 0; $offline = 0;
            foreach ($domains as $d) {
                $url = $d['protocol'] . '://' . $d['target_ip'] . ':' . $d['target_port'];
                $ch = curl_init($url);
                curl_setopt_array($ch, [
                    CURLOPT_RETURNTRANSFER => true,
                    CURLOPT_TIMEOUT        => 2,
                    CURLOPT_NOBODY         => true,
                    CURLOPT_SSL_VERIFYPEER => true,
                    CURLOPT_SSL_VERIFYHOST => 2,
                ]);
                curl_exec($ch);
                $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
                curl_close($ch);
                if ($code > 0) $online++; else $offline++;
            }
            echo json_encode(['success' => true, 'stats' => [
                'total' => count($domains), 'online' => $online, 'offline' => $offline,
            ]]);
            break;
        }
        case 'reload':
            echo json_encode(reload_caddy());
            break;
        case 'health':
            echo json_encode(['success' => true, 'status' => 'healthy', 'timestamp' => time()]);
            break;
        default:
            http_response_code(400);
            echo json_encode(['success' => false, 'message' => 'Unbekannte Aktion']);
    }
} catch (Throwable $e) {
    http_response_code(400);
    echo json_encode(['success' => false, 'message' => $e->getMessage()]);
}
EOPHP

    cat > "${INSTALL_DIR}/admin.js" <<'EOJS'
const CSRF = document.querySelector('meta[name="csrf-token"]')?.content || '';

document.addEventListener('DOMContentLoaded', () => {
    loadDomains();
    updateStatistics();
});

async function api(action, opts = {}) {
    const init = {
        method: opts.method || 'GET',
        headers: { 'Accept': 'application/json' },
        credentials: 'same-origin',
    };
    if (opts.method && opts.method !== 'GET') {
        init.headers['X-CSRF-Token'] = CSRF;
    }
    if (opts.body !== undefined) {
        init.headers['Content-Type'] = 'application/json';
        init.body = JSON.stringify(opts.body);
    }
    const url = `api.php?action=${encodeURIComponent(action)}` +
        (opts.query ? '&' + new URLSearchParams(opts.query).toString() : '');
    const res = await fetch(url, init);
    if (res.status === 401) { window.location.href = 'login.php'; return; }
    return res.json();
}

function loadDomains() {
    showLoading();
    api('list').then(data => {
        hideLoading();
        if (!data || !data.success) return showToast('Fehler beim Laden', 'danger');
        displayDomains(data.domains);
        updateStatistics();
    }).catch(e => { hideLoading(); showToast('Netzwerkfehler: ' + e, 'danger'); });
}

function displayDomains(domains) {
    const c = document.getElementById('domainsList');
    c.innerHTML = '';
    if (!domains || !domains.length) {
        c.innerHTML = '<div class="col-12"><div class="alert alert-info">Keine Domains konfiguriert</div></div>';
        return;
    }
    domains.forEach(d => c.insertAdjacentHTML('beforeend', cardHTML(d)));
}

function cardHTML(d) {
    const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    return `
    <div class="col-md-6 col-lg-4 mb-3">
        <div class="card domain-card">
            <div class="card-body">
                <h5 class="card-title"><i class="bi bi-globe"></i> ${esc(d.domain)}</h5>
                <p class="card-text">
                    <strong>Ziel:</strong> ${esc(d.target_ip)}:${esc(d.target_port)}<br>
                    <strong>Protokoll:</strong> ${esc(d.protocol.toUpperCase())}<br>
                    <strong>SSL:</strong> ${d.ssl_enabled ? '<i class="bi bi-check-circle text-success"></i>' : '<i class="bi bi-x-circle text-danger"></i>'}
                </p>
                <div class="btn-group">
                    <button class="btn btn-sm btn-primary" onclick="editDomain(${d.id})"><i class="bi bi-pencil"></i> Bearbeiten</button>
                    <button class="btn btn-sm btn-danger"  onclick="deleteDomain(${d.id})"><i class="bi bi-trash"></i> Löschen</button>
                    <button class="btn btn-sm btn-info"    onclick="testConnection(${d.id})"><i class="bi bi-wifi"></i> Test</button>
                </div>
            </div>
        </div>
    </div>`;
}

function saveDomain() {
    const f = document.getElementById('domainForm');
    const fd = Object.fromEntries(new FormData(f));
    fd.enable_ssl = document.getElementById('enableSsl').checked;
    fd.target_port = parseInt(fd.target_port, 10);
    const action = fd.id ? 'update' : 'add';
    showLoading();
    api(action, { method: 'POST', body: fd }).then(r => {
        hideLoading();
        if (r && r.success) {
            showToast('Gespeichert', 'success');
            bootstrap.Modal.getInstance(document.getElementById('addDomainModal'))?.hide();
            f.reset();
            loadDomains();
        } else {
            showToast('Fehler: ' + (r?.message || 'unbekannt'), 'danger');
        }
    }).catch(e => { hideLoading(); showToast('Netzwerkfehler: ' + e, 'danger'); });
}

function editDomain(id) {
    showLoading();
    api('get', { query: { id } }).then(r => {
        hideLoading();
        if (!r || !r.success) return showToast('Fehler beim Laden', 'danger');
        const d = r.domain;
        document.getElementById('domainId').value = d.id;
        document.getElementById('domain').value = d.domain;
        document.getElementById('targetIp').value = d.target_ip;
        document.getElementById('targetPort').value = d.target_port;
        document.getElementById('protocol').value = d.protocol;
        document.getElementById('enableSsl').checked = !!d.ssl_enabled;
        document.getElementById('modalTitle').textContent = 'Domain bearbeiten';
        new bootstrap.Modal(document.getElementById('addDomainModal')).show();
    }).catch(e => { hideLoading(); showToast('Netzwerkfehler: ' + e, 'danger'); });
}

function deleteDomain(id) {
    if (!confirm('Domain wirklich löschen?')) return;
    showLoading();
    api('delete', { method: 'DELETE', query: { id } }).then(r => {
        hideLoading();
        if (r && r.success) { showToast('Gelöscht', 'success'); loadDomains(); }
        else showToast('Fehler: ' + (r?.message || 'unbekannt'), 'danger');
    }).catch(e => { hideLoading(); showToast('Netzwerkfehler: ' + e, 'danger'); });
}

function testConnection(id) {
    showLoading();
    api('test', { query: { id } }).then(r => {
        hideLoading();
        if (!r) return;
        if (r.success && r.reachable) showToast(`Erreichbar (HTTP ${r.http_code})`, 'success');
        else if (r.success) showToast('Nicht erreichbar', 'warning');
        else showToast('Fehler: ' + r.message, 'danger');
    }).catch(e => { hideLoading(); showToast('Netzwerkfehler: ' + e, 'danger'); });
}

function reloadCaddy() {
    if (!confirm('Caddy-Konfiguration jetzt neu laden?')) return;
    showLoading();
    api('reload', { method: 'POST' }).then(r => {
        hideLoading();
        if (r && r.success) showToast('Caddy neu geladen', 'success');
        else showToast('Fehler: ' + (r?.message || 'unbekannt'), 'danger');
    }).catch(e => { hideLoading(); showToast('Netzwerkfehler: ' + e, 'danger'); });
}

function updateStatistics() {
    api('stats').then(r => {
        if (!r || !r.success) return;
        document.getElementById('activeDomains').textContent = r.stats.total;
        document.getElementById('onlineServices').textContent = r.stats.online;
        document.getElementById('offlineServices').textContent = r.stats.offline;
    }).catch(() => {});
}

function showLoading() { document.querySelector('.loading-spinner').style.display = 'block'; }
function hideLoading() { document.querySelector('.loading-spinner').style.display = 'none'; }

function showToast(msg, type = 'info') {
    const id = 't' + Date.now();
    const html = `<div id="${id}" class="toast align-items-center text-white bg-${type} border-0">
        <div class="d-flex"><div class="toast-body">${msg}</div>
        <button class="btn-close btn-close-white me-2 m-auto" data-bs-dismiss="toast"></button></div></div>`;
    document.querySelector('.toast-container').insertAdjacentHTML('beforeend', html);
    const el = document.getElementById(id);
    new bootstrap.Toast(el).show();
    el.addEventListener('hidden.bs.toast', () => el.remove());
}

document.getElementById('addDomainModal').addEventListener('hidden.bs.modal', () => {
    document.getElementById('domainForm').reset();
    document.getElementById('domainId').value = '';
    document.getElementById('modalTitle').textContent = 'Neue Domain hinzufügen';
});
EOJS

    if [[ ! -f "${INSTALL_DIR}/domains.json" ]]; then
        echo '{"domains": []}' > "${INSTALL_DIR}/domains.json"
    fi
    if [[ ! -f "$RATE_LIMIT_FILE" ]]; then
        echo '{}' > "$RATE_LIMIT_FILE"
    fi

    chown -R "${WEB_USER}:${WEB_GROUP}" "$INSTALL_DIR"
    find "$INSTALL_DIR" -type d -exec chmod 750 {} \;
    find "$INSTALL_DIR" -type f -exec chmod 640 {} \;
    chmod 660 "${INSTALL_DIR}/domains.json"

    chown -R "${WEB_USER}:${WEB_GROUP}" "$STAGE_DIR"
    chmod 660 "$RATE_LIMIT_FILE" 2>/dev/null || true

    ok "Panel-Dateien geschrieben (Permissions restriktiv)"
}

# ---- Initiales Caddyfile + Reload-Helper -----------------------------------

write_caddyfile_initial() {
    info "Schreibe initiales Caddyfile..."
    {
        echo "# Initiales Caddyfile (vom Installer)"
        echo "{"
        echo "    admin localhost:2019"
        echo "    email ${ADMIN_EMAIL}"
        echo "}"
        echo
        if $ENABLE_SSL && [[ "$ADMIN_DOMAIN" != "localhost" ]]; then
            echo "${ADMIN_DOMAIN} {"
        else
            echo ":${ADMIN_PORT} {"
            if [[ "$ADMIN_DOMAIN" == "localhost" ]]; then
                echo "    tls internal"
            fi
        fi
        echo "    root * ${INSTALL_DIR}"
        echo "    php_fastcgi unix/${PHP_FPM_SOCK}"
        echo "    file_server"
        echo "    @denyPrivate path /lib/* /domains.json /.*"
        echo "    respond @denyPrivate 403"
        echo "}"
    } > "$CADDY_LIVE_FILE"

    chown root:caddy "$CADDY_LIVE_FILE" 2>/dev/null || chown root:root "$CADDY_LIVE_FILE"
    chmod 644 "$CADDY_LIVE_FILE"

    if ! caddy validate --config "$CADDY_LIVE_FILE" --adapter caddyfile >/dev/null 2>&1; then
        warn "Caddyfile-Validierung fehlgeschlagen — bitte $CADDY_LIVE_FILE prüfen"
    fi
    ok "Caddyfile geschrieben: $CADDY_LIVE_FILE"
}

write_reload_helper() {
    info "Schreibe Reload-Helper..."
    cat > "$RELOAD_HELPER" <<'EOSH'
#!/bin/bash
# Reload-Helper für das Caddy Admin Panel.
# Wird von www-data via sudo OHNE ARGUMENTE aufgerufen.
# Liest fix /var/lib/caddy-admin/Caddyfile.staged — keine Argumente von außen.

set -euo pipefail

STAGE="/var/lib/caddy-admin/Caddyfile.staged"
LIVE="/etc/caddy/Caddyfile"
BACKUP_DIR="/var/backups/caddy"
MAX_BACKUPS_PER_DAY=10

[[ -f "$STAGE" ]] || { echo "Kein gestagedes Caddyfile vorhanden: $STAGE" >&2; exit 1; }

if ! /usr/bin/caddy validate --config "$STAGE" --adapter caddyfile >/dev/null 2>&1; then
    /usr/bin/caddy validate --config "$STAGE" --adapter caddyfile >&2 || true
    echo "Caddyfile-Validierung fehlgeschlagen, Reload abgebrochen" >&2
    exit 2
fi

mkdir -p "$BACKUP_DIR"
TODAY="$(date +%Y%m%d)"
COUNT=$(find "$BACKUP_DIR" -maxdepth 1 -name "Caddyfile.${TODAY}_*" -type f | wc -l)
if [[ -f "$LIVE" && "$COUNT" -lt "$MAX_BACKUPS_PER_DAY" ]]; then
    cp -p "$LIVE" "${BACKUP_DIR}/Caddyfile.${TODAY}_$(date +%H%M%S)"
fi

install -m 644 -o root -g caddy "$STAGE" "$LIVE" 2>/dev/null \
    || install -m 644 -o root -g root  "$STAGE" "$LIVE"
/bin/systemctl reload caddy
echo "Caddy erfolgreich neu geladen"
EOSH
    chown root:root "$RELOAD_HELPER"
    chmod 750 "$RELOAD_HELPER"
    ok "Reload-Helper installiert: $RELOAD_HELPER"
}

setup_sudoers() {
    info "Konfiguriere Sudo (minimal, ohne Argumente)..."
    cat > "${SUDOERS_FILE}.tmp" <<EOSUDO
# Caddy Admin Panel — minimale Sudo-Rechte
# Reload-Helper akzeptiert KEINE Argumente. Stage-Pfad ist im Helper fest verdrahtet.
${WEB_USER} ALL=(root) NOPASSWD: ${RELOAD_HELPER}
Defaults!${RELOAD_HELPER} !requiretty, env_reset
EOSUDO
    chmod 440 "${SUDOERS_FILE}.tmp"
    if visudo -c -q -f "${SUDOERS_FILE}.tmp"; then
        mv "${SUDOERS_FILE}.tmp" "$SUDOERS_FILE"
    else
        rm -f "${SUDOERS_FILE}.tmp"
        err "Sudoers-Validierung fehlgeschlagen"
    fi
    ok "Sudoers geschrieben: $SUDOERS_FILE"
}

# ---- Firewall + Backup -----------------------------------------------------

setup_firewall() {
    if ! $ENABLE_FIREWALL; then
        ok "Firewall-Konfiguration übersprungen"
        return
    fi
    info "Konfiguriere Firewall..."
    if ! command -v ufw >/dev/null 2>&1; then
        $PKG_INSTALL ufw >/dev/null
    fi
    ufw allow 22/tcp  >/dev/null 2>&1 || true
    ufw allow 80/tcp  >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    ufw allow "${ADMIN_PORT}/tcp" >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1 || warn "ufw enable fehlgeschlagen"
    ok "Firewall konfiguriert (22, 80, 443, ${ADMIN_PORT})"
}

write_backup_script() {
    info "Schreibe Backup-Skript..."
    cat > /usr/local/bin/backup-caddy.sh <<EOBACKUP
#!/bin/bash
set -euo pipefail
BACKUP_DIR="${BACKUP_DIR}"
DATE="\$(date +%Y%m%d_%H%M%S)"
mkdir -p "\$BACKUP_DIR"
[[ -f "${CADDY_LIVE_FILE}" ]] && cp -p "${CADDY_LIVE_FILE}" "\$BACKUP_DIR/Caddyfile.\$DATE"
[[ -f "${INSTALL_DIR}/domains.json" ]] && cp -p "${INSTALL_DIR}/domains.json" "\$BACKUP_DIR/domains.\$DATE.json"
if [[ -d /var/lib/caddy ]]; then
    tar czf "\$BACKUP_DIR/certificates.\$DATE.tar.gz" /var/lib/caddy/ 2>/dev/null || true
fi
find "\$BACKUP_DIR" -type f -mtime +30 -delete
echo "Backup completed: \$BACKUP_DIR"
EOBACKUP
    chmod 750 /usr/local/bin/backup-caddy.sh
    echo "0 2 * * * root /usr/local/bin/backup-caddy.sh" > /etc/cron.d/caddy-backup
    chmod 644 /etc/cron.d/caddy-backup
    ok "Backup-Skript installiert (täglich 02:00)"
}

# ---- Services ---------------------------------------------------------------

start_services() {
    info "Starte Services..."
    systemctl restart "$PHP_FPM_SERVICE"
    systemctl restart caddy
    ok "Services gestartet"
}

check_services() {
    hr
    echo -e "${YELLOW}Service-Status:${NC}"
    hr
    for svc in caddy "$PHP_FPM_SERVICE"; do
        if systemctl is-active --quiet "$svc"; then
            echo -e "  $svc: ${GREEN}✓ läuft${NC}"
        else
            echo -e "  $svc: ${RED}✗ gestoppt${NC}"
        fi
    done
}

print_summary() {
    echo
    hr
    echo -e "${GREEN}Installation erfolgreich abgeschlossen!${NC}"
    hr
    echo -e "${BLUE}Zugriff auf das Admin Panel:${NC}"
    if [[ "$ADMIN_DOMAIN" == "localhost" ]]; then
        local ip; ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
        echo -e "  URL:  ${GREEN}https://${ip:-127.0.0.1}:${ADMIN_PORT}/${NC}"
        echo -e "        ${YELLOW}(self-signed Caddy-CA — beim ersten Zugriff im Browser akzeptieren)${NC}"
    elif $ENABLE_SSL; then
        echo -e "  URL:  ${GREEN}https://${ADMIN_DOMAIN}/${NC}"
        echo -e "        ${YELLOW}(DNS muss auf diese Maschine zeigen, sonst schlägt Let's Encrypt fehl)${NC}"
    else
        echo -e "  URL:  ${GREEN}http://${ADMIN_DOMAIN}:${ADMIN_PORT}/${NC}"
    fi
    echo -e "  User: ${BLUE}${ADMIN_USER}${NC}"
    echo
    echo -e "${BLUE}Wichtige Pfade:${NC}"
    echo -e "  Web-Dateien:   ${YELLOW}${INSTALL_DIR}${NC}"
    echo -e "  Caddyfile:     ${YELLOW}${CADDY_LIVE_FILE}${NC}"
    echo -e "  Auth/Config:   ${YELLOW}${ADMIN_CONFIG_DIR}${NC}"
    echo -e "  Stage:         ${YELLOW}${STAGE_DIR}${NC}"
    echo -e "  Logs:          ${YELLOW}${LOG_DIR}${NC}"
    echo -e "  Backups:       ${YELLOW}${BACKUP_DIR}${NC}"
    echo
    echo -e "${BLUE}Befehle:${NC}"
    echo -e "  Status:        ${YELLOW}systemctl status caddy ${PHP_FPM_SERVICE}${NC}"
    echo -e "  Caddy-Logs:    ${YELLOW}journalctl -u caddy -f${NC}"
    echo -e "  Backup:        ${YELLOW}/usr/local/bin/backup-caddy.sh${NC}"
    echo
    echo -e "${YELLOW}Sicherheits-Hinweise:${NC}"
    echo -e "  • Verwende öffentliche Erreichbarkeit nur mit aktiviertem Let's-Encrypt-SSL."
    echo -e "  • Bei localhost ohne TLS niemals direkt im Internet exponieren."
    echo -e "  • Passwort-Reset: ${ADMIN_AUTH_FILE} neu schreiben (bcrypt-Hash, mode 0640)."
}

# ---- Main -------------------------------------------------------------------

main() {
    check_root
    show_banner
    detect_os
    prompt_config

    hr
    echo -e "${YELLOW}Starte Installation...${NC}"
    hr

    update_system
    install_caddy
    install_php

    setup_directories
    write_panel_files
    write_config_files
    write_caddyfile_initial
    write_reload_helper
    setup_sudoers
    write_backup_script
    setup_firewall
    start_services

    check_services
    print_summary
}

# Nur ausführen, wenn das Skript direkt aufgerufen wird — nicht beim Sourcen
# (z.B. aus den Bats-Tests, die die Validierungs-Funktionen prüfen).
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    main "$@"
fi
