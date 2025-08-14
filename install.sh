#!/bin/bash

################################################################################
# Caddy Reverse Proxy Admin Panel - Automatisches Installations-Script
# 
# Autor: Techie
# Website: https://callmetechie.de
# 
# Dieses Script installiert und konfiguriert:
# - Caddy v2 mit Let's Encrypt
# - PHP und Apache/Nginx
# - Admin Panel Web-GUI
# - Alle erforderlichen Berechtigungen und Konfigurationen
#
# Verwendung: sudo bash install.sh
################################################################################

set -e  # Bei Fehler abbrechen

# Farben für Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Konfigurationsvariablen
INSTALL_DIR="/var/www/caddy-admin"
CADDY_CONFIG_DIR="/etc/caddy"
BACKUP_DIR="/var/backups/caddy"
LOG_DIR="/var/log/caddy"
ADMIN_PORT="8080"
ADMIN_DOMAIN=""
ADMIN_EMAIL=""
USE_NGINX=false
ENABLE_SSL=false
ENABLE_FIREWALL=true

# Script muss als root ausgeführt werden
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Dieses Script muss als root ausgeführt werden!${NC}"
        echo "Verwendung: sudo bash install.sh"
        exit 1
    fi
}

# Banner anzeigen
show_banner() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                                                              ║${NC}"
    echo -e "${BLUE}║     ${GREEN}Caddy Reverse Proxy Admin Panel - Installer${BLUE}             ║${NC}"
    echo -e "${BLUE}║                      Version 1.0                             ║${NC}"
    echo -e "${BLUE}║                                                              ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Betriebssystem erkennen
detect_os() {
    echo -e "${YELLOW}→ Erkenne Betriebssystem...${NC}"
    
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        OS_VERSION=$VERSION_ID
        OS_ID=$ID
        
        echo -e "${GREEN}✓ Erkannt: $OS $OS_VERSION${NC}"
        
        case $OS_ID in
            ubuntu|debian)
                PKG_MANAGER="apt"
                PKG_UPDATE="apt update"
                PKG_INSTALL="apt install -y"
                PHP_VERSION=$(apt-cache show php | grep -E "^Version:" | head -1 | cut -d' ' -f2 | cut -d'+' -f1 | cut -d'.' -f1,2)
                ;;
            centos|rhel|fedora)
                PKG_MANAGER="yum"
                PKG_UPDATE="yum update -y"
                PKG_INSTALL="yum install -y"
                if [[ "$OS_ID" == "fedora" ]]; then
                    PKG_MANAGER="dnf"
                    PKG_UPDATE="dnf update -y"
                    PKG_INSTALL="dnf install -y"
                fi
                ;;
            *)
                echo -e "${RED}✗ Nicht unterstütztes Betriebssystem: $OS_ID${NC}"
                exit 1
                ;;
        esac
    else
        echo -e "${RED}✗ Betriebssystem konnte nicht erkannt werden${NC}"
        exit 1
    fi
}

# Benutzereinstellungen abfragen
get_user_input() {
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Konfigurationseinstellungen:${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Admin Domain
    read -p "Domain für Admin Panel (z.B. admin.example.com) [localhost]: " ADMIN_DOMAIN
    ADMIN_DOMAIN=${ADMIN_DOMAIN:-localhost}
    
    # Admin E-Mail
    read -p "E-Mail für Let's Encrypt (erforderlich für SSL): " ADMIN_EMAIL
    
    # SSL aktivieren?
    if [[ "$ADMIN_DOMAIN" != "localhost" ]] && [[ -n "$ADMIN_EMAIL" ]]; then
        read -p "SSL für Admin Panel aktivieren? (j/n) [j]: " ssl_choice
        ssl_choice=${ssl_choice:-j}
        if [[ "$ssl_choice" == "j" ]] || [[ "$ssl_choice" == "J" ]]; then
            ENABLE_SSL=true
        fi
    fi
    
    # Webserver auswählen
    echo ""
    echo "Welchen Webserver möchten Sie verwenden?"
    echo "1) Apache (Standard)"
    echo "2) Nginx"
    read -p "Auswahl [1]: " webserver_choice
    webserver_choice=${webserver_choice:-1}
    
    if [[ "$webserver_choice" == "2" ]]; then
        USE_NGINX=true
    fi
    
    # Admin Port
    read -p "Port für Admin Panel [8080]: " ADMIN_PORT
    ADMIN_PORT=${ADMIN_PORT:-8080}
    
    # Firewall konfigurieren?
    read -p "Firewall automatisch konfigurieren? (j/n) [j]: " fw_choice
    fw_choice=${fw_choice:-j}
    if [[ "$fw_choice" == "n" ]] || [[ "$fw_choice" == "N" ]]; then
        ENABLE_FIREWALL=false
    fi
    
    echo ""
    echo -e "${GREEN}Konfiguration:${NC}"
    echo -e "  Domain: ${BLUE}$ADMIN_DOMAIN${NC}"
    echo -e "  E-Mail: ${BLUE}$ADMIN_EMAIL${NC}"
    echo -e "  SSL: ${BLUE}$(if $ENABLE_SSL; then echo "Ja"; else echo "Nein"; fi)${NC}"
    echo -e "  Webserver: ${BLUE}$(if $USE_NGINX; then echo "Nginx"; else echo "Apache"; fi)${NC}"
    echo -e "  Port: ${BLUE}$ADMIN_PORT${NC}"
    echo -e "  Firewall: ${BLUE}$(if $ENABLE_FIREWALL; then echo "Ja"; else echo "Nein"; fi)${NC}"
    echo ""
    
    read -p "Fortfahren mit diesen Einstellungen? (j/n) [j]: " confirm
    confirm=${confirm:-j}
    if [[ "$confirm" != "j" ]] && [[ "$confirm" != "J" ]]; then
        echo -e "${RED}Installation abgebrochen${NC}"
        exit 1
    fi
}

# System aktualisieren
update_system() {
    echo ""
    echo -e "${YELLOW}→ Aktualisiere System...${NC}"
    $PKG_UPDATE > /dev/null 2>&1
    echo -e "${GREEN}✓ System aktualisiert${NC}"
}

# Basis-Pakete installieren
install_base_packages() {
    echo -e "${YELLOW}→ Installiere Basis-Pakete...${NC}"
    
    PACKAGES="curl wget git sudo ufw software-properties-common gnupg2 lsb-release"
    
    if [[ "$OS_ID" == "ubuntu" ]] || [[ "$OS_ID" == "debian" ]]; then
        PACKAGES="$PACKAGES apt-transport-https ca-certificates"
    fi
    
    $PKG_INSTALL $PACKAGES > /dev/null 2>&1
    echo -e "${GREEN}✓ Basis-Pakete installiert${NC}"
}

# Caddy installieren
install_caddy() {
    echo -e "${YELLOW}→ Installiere Caddy...${NC}"
    
    if [[ "$OS_ID" == "ubuntu" ]] || [[ "$OS_ID" == "debian" ]]; then
        # Caddy GPG key und Repository hinzufügen
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
        
        $PKG_UPDATE > /dev/null 2>&1
        $PKG_INSTALL caddy > /dev/null 2>&1
        
    elif [[ "$OS_ID" == "centos" ]] || [[ "$OS_ID" == "rhel" ]] || [[ "$OS_ID" == "fedora" ]]; then
        # Caddy über COPR installieren
        if [[ "$OS_ID" == "fedora" ]]; then
            dnf copr enable @caddy/caddy -y > /dev/null 2>&1
            dnf install caddy -y > /dev/null 2>&1
        else
            yum copr enable @caddy/caddy -y > /dev/null 2>&1
            yum install caddy -y > /dev/null 2>&1
        fi
    fi
    
    # Caddy Service aktivieren
    systemctl enable caddy > /dev/null 2>&1
    
    echo -e "${GREEN}✓ Caddy installiert${NC}"
}

# PHP installieren
install_php() {
    echo -e "${YELLOW}→ Installiere PHP...${NC}"
    
    if [[ "$OS_ID" == "ubuntu" ]] || [[ "$OS_ID" == "debian" ]]; then
        $PKG_INSTALL php php-cli php-fpm php-json php-curl php-mbstring php-xml php-zip > /dev/null 2>&1
        
        # PHP-FPM für Nginx konfigurieren
        if $USE_NGINX; then
            PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
            systemctl enable $PHP_FPM_SERVICE > /dev/null 2>&1
            systemctl start $PHP_FPM_SERVICE > /dev/null 2>&1
        fi
        
    elif [[ "$OS_ID" == "centos" ]] || [[ "$OS_ID" == "rhel" ]] || [[ "$OS_ID" == "fedora" ]]; then
        $PKG_INSTALL php php-cli php-fpm php-json php-mbstring php-xml php-zip > /dev/null 2>&1
        
        if $USE_NGINX; then
            systemctl enable php-fpm > /dev/null 2>&1
            systemctl start php-fpm > /dev/null 2>&1
        fi
    fi
    
    echo -e "${GREEN}✓ PHP installiert${NC}"
}

# Webserver installieren
install_webserver() {
    if $USE_NGINX; then
        echo -e "${YELLOW}→ Installiere Nginx...${NC}"
        $PKG_INSTALL nginx > /dev/null 2>&1
        systemctl enable nginx > /dev/null 2>&1
        echo -e "${GREEN}✓ Nginx installiert${NC}"
    else
        echo -e "${YELLOW}→ Installiere Apache...${NC}"
        
        if [[ "$OS_ID" == "ubuntu" ]] || [[ "$OS_ID" == "debian" ]]; then
            $PKG_INSTALL apache2 libapache2-mod-php > /dev/null 2>&1
            systemctl enable apache2 > /dev/null 2>&1
            
            # Module aktivieren
            a2enmod rewrite > /dev/null 2>&1
            a2enmod proxy > /dev/null 2>&1
            a2enmod proxy_http > /dev/null 2>&1
            
        elif [[ "$OS_ID" == "centos" ]] || [[ "$OS_ID" == "rhel" ]] || [[ "$OS_ID" == "fedora" ]]; then
            $PKG_INSTALL httpd mod_php > /dev/null 2>&1
            systemctl enable httpd > /dev/null 2>&1
        fi
        
        echo -e "${GREEN}✓ Apache installiert${NC}"
    fi
}

# Admin Panel Dateien erstellen
create_admin_panel_files() {
    echo -e "${YELLOW}→ Erstelle Admin Panel Dateien...${NC}"
    
    # Verzeichnis erstellen
    mkdir -p $INSTALL_DIR
    
    # index.html erstellen
    cat > $INSTALL_DIR/index.html << 'EOHTML'
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Caddy Reverse Proxy Verwaltung</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.10.0/font/bootstrap-icons.css">
    <style>
        .domain-card {
            transition: transform 0.2s;
        }
        .domain-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 4px 15px rgba(0,0,0,0.1);
        }
        .status-badge {
            position: absolute;
            top: 10px;
            right: 10px;
        }
        .loading-spinner {
            display: none;
            position: fixed;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            z-index: 9999;
        }
        .toast-container {
            position: fixed;
            top: 20px;
            right: 20px;
            z-index: 9999;
        }
    </style>
</head>
<body>
    <!-- Navigation -->
    <nav class="navbar navbar-expand-lg navbar-dark bg-primary">
        <div class="container-fluid">
            <a class="navbar-brand" href="#">
                <i class="bi bi-server"></i> Caddy Proxy Manager
            </a>
            <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarNav">
                <span class="navbar-toggler-icon"></span>
            </button>
            <div class="collapse navbar-collapse" id="navbarNav">
                <ul class="navbar-nav ms-auto">
                    <li class="nav-item">
                        <button class="btn btn-success" onclick="reloadCaddy()">
                            <i class="bi bi-arrow-clockwise"></i> Caddy Neu Laden
                        </button>
                    </li>
                </ul>
            </div>
        </div>
    </nav>

    <!-- Main Container -->
    <div class="container mt-4">
        <!-- Statistics Cards -->
        <div class="row mb-4">
            <div class="col-md-4">
                <div class="card bg-info text-white">
                    <div class="card-body">
                        <h5 class="card-title"><i class="bi bi-globe"></i> Aktive Domains</h5>
                        <h2 class="card-text" id="activeDomains">0</h2>
                    </div>
                </div>
            </div>
            <div class="col-md-4">
                <div class="card bg-success text-white">
                    <div class="card-body">
                        <h5 class="card-title"><i class="bi bi-check-circle"></i> Online</h5>
                        <h2 class="card-text" id="onlineServices">0</h2>
                    </div>
                </div>
            </div>
            <div class="col-md-4">
                <div class="card bg-warning text-white">
                    <div class="card-body">
                        <h5 class="card-title"><i class="bi bi-exclamation-triangle"></i> Offline</h5>
                        <h2 class="card-text" id="offlineServices">0</h2>
                    </div>
                </div>
            </div>
        </div>

        <!-- Add New Domain Button -->
        <div class="row mb-3">
            <div class="col-12">
                <button class="btn btn-primary" data-bs-toggle="modal" data-bs-target="#addDomainModal">
                    <i class="bi bi-plus-circle"></i> Neue Domain hinzufügen
                </button>
                <button class="btn btn-secondary" onclick="loadDomains()">
                    <i class="bi bi-arrow-repeat"></i> Aktualisieren
                </button>
            </div>
        </div>

        <!-- Domains List -->
        <div class="row" id="domainsList">
            <!-- Domain cards will be loaded here -->
        </div>
    </div>

    <!-- Add/Edit Domain Modal -->
    <div class="modal fade" id="addDomainModal" tabindex="-1">
        <div class="modal-dialog modal-lg">
            <div class="modal-content">
                <div class="modal-header">
                    <h5 class="modal-title" id="modalTitle">Neue Domain hinzufügen</h5>
                    <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
                </div>
                <div class="modal-body">
                    <form id="domainForm">
                        <input type="hidden" id="domainId" name="id">
                        <div class="row">
                            <div class="col-md-6">
                                <div class="mb-3">
                                    <label for="domain" class="form-label">Domain</label>
                                    <input type="text" class="form-control" id="domain" name="domain" placeholder="beispiel.de" required>
                                    <small class="text-muted">Ohne http:// oder https://</small>
                                </div>
                            </div>
                            <div class="col-md-6">
                                <div class="mb-3">
                                    <label for="targetIp" class="form-label">Ziel IP-Adresse</label>
                                    <input type="text" class="form-control" id="targetIp" name="target_ip" placeholder="192.168.1.100" required>
                                </div>
                            </div>
                        </div>
                        <div class="row">
                            <div class="col-md-6">
                                <div class="mb-3">
                                    <label for="targetPort" class="form-label">Ziel Port</label>
                                    <input type="number" class="form-control" id="targetPort" name="target_port" placeholder="80" required>
                                </div>
                            </div>
                            <div class="col-md-6">
                                <div class="mb-3">
                                    <label for="protocol" class="form-label">Protokoll</label>
                                    <select class="form-select" id="protocol" name="protocol">
                                        <option value="http">HTTP</option>
                                        <option value="https">HTTPS</option>
                                    </select>
                                </div>
                            </div>
                        </div>
                        <div class="row">
                            <div class="col-md-12">
                                <div class="mb-3">
                                    <div class="form-check form-switch">
                                        <input class="form-check-input" type="checkbox" id="enableSsl" name="enable_ssl">
                                        <label class="form-check-label" for="enableSsl">
                                            SSL/TLS aktivieren (Let's Encrypt)
                                        </label>
                                    </div>
                                </div>
                            </div>
                        </div>
                        <div class="row">
                            <div class="col-md-12">
                                <div class="mb-3">
                                    <label for="additionalConfig" class="form-label">Zusätzliche Konfiguration (Optional)</label>
                                    <textarea class="form-control" id="additionalConfig" name="additional_config" rows="3" placeholder="Zusätzliche Caddy-Direktiven"></textarea>
                                </div>
                            </div>
                        </div>
                    </form>
                </div>
                <div class="modal-footer">
                    <button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Abbrechen</button>
                    <button type="button" class="btn btn-primary" onclick="saveDomain()">Speichern</button>
                </div>
            </div>
        </div>
    </div>

    <!-- Loading Spinner -->
    <div class="loading-spinner">
        <div class="spinner-border text-primary" role="status" style="width: 3rem; height: 3rem;">
            <span class="visually-hidden">Laden...</span>
        </div>
    </div>

    <!-- Toast Container -->
    <div class="toast-container"></div>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
    <script src="admin.js"></script>
</body>
</html>
EOHTML

    # admin.js erstellen (JavaScript separat für bessere Wartbarkeit)
    cat > $INSTALL_DIR/admin.js << 'EOJS'
// Initialize
document.addEventListener('DOMContentLoaded', function() {
    loadDomains();
    updateStatistics();
});

// Load all domains
function loadDomains() {
    showLoading();
    fetch('api.php?action=list')
        .then(response => response.json())
        .then(data => {
            hideLoading();
            if (data.success) {
                displayDomains(data.domains);
                updateStatistics();
            } else {
                showToast('Fehler beim Laden der Domains', 'danger');
            }
        })
        .catch(error => {
            hideLoading();
            showToast('Netzwerkfehler: ' + error, 'danger');
        });
}

// Display domains
function displayDomains(domains) {
    const container = document.getElementById('domainsList');
    container.innerHTML = '';
    
    if (!domains || domains.length === 0) {
        container.innerHTML = '<div class="col-12"><div class="alert alert-info">Keine Domains konfiguriert</div></div>';
        return;
    }

    domains.forEach(domain => {
        const card = createDomainCard(domain);
        container.innerHTML += card;
    });
}

// Create domain card HTML
function createDomainCard(domain) {
    const statusClass = domain.status === 'active' ? 'success' : 'warning';
    const statusText = domain.status === 'active' ? 'Aktiv' : 'Inaktiv';
    
    return `
        <div class="col-md-6 col-lg-4 mb-3">
            <div class="card domain-card">
                <div class="card-body">
                    <span class="badge bg-${statusClass} status-badge">${statusText}</span>
                    <h5 class="card-title"><i class="bi bi-globe"></i> ${domain.domain}</h5>
                    <p class="card-text">
                        <strong>Ziel:</strong> ${domain.target_ip}:${domain.target_port}<br>
                        <strong>Protokoll:</strong> ${domain.protocol.toUpperCase()}<br>
                        <strong>SSL:</strong> ${domain.ssl_enabled ? '<i class="bi bi-check-circle text-success"></i>' : '<i class="bi bi-x-circle text-danger"></i>'}
                    </p>
                    <div class="btn-group" role="group">
                        <button class="btn btn-sm btn-primary" onclick="editDomain(${domain.id})">
                            <i class="bi bi-pencil"></i> Bearbeiten
                        </button>
                        <button class="btn btn-sm btn-danger" onclick="deleteDomain(${domain.id})">
                            <i class="bi bi-trash"></i> Löschen
                        </button>
                        <button class="btn btn-sm btn-info" onclick="testConnection(${domain.id})">
                            <i class="bi bi-wifi"></i> Test
                        </button>
                    </div>
                </div>
            </div>
        </div>
    `;
}

// Save domain
function saveDomain() {
    const form = document.getElementById('domainForm');
    const formData = new FormData(form);
    const data = Object.fromEntries(formData);
    data.enable_ssl = document.getElementById('enableSsl').checked;
    
    const action = data.id ? 'update' : 'add';
    
    showLoading();
    fetch(`api.php?action=${action}`, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
        },
        body: JSON.stringify(data)
    })
    .then(response => response.json())
    .then(result => {
        hideLoading();
        if (result.success) {
            showToast('Domain erfolgreich gespeichert', 'success');
            bootstrap.Modal.getInstance(document.getElementById('addDomainModal')).hide();
            loadDomains();
            form.reset();
        } else {
            showToast('Fehler: ' + result.message, 'danger');
        }
    })
    .catch(error => {
        hideLoading();
        showToast('Netzwerkfehler: ' + error, 'danger');
    });
}

// Edit domain
function editDomain(id) {
    showLoading();
    fetch(`api.php?action=get&id=${id}`)
        .then(response => response.json())
        .then(data => {
            hideLoading();
            if (data.success) {
                const domain = data.domain;
                document.getElementById('domainId').value = domain.id;
                document.getElementById('domain').value = domain.domain;
                document.getElementById('targetIp').value = domain.target_ip;
                document.getElementById('targetPort').value = domain.target_port;
                document.getElementById('protocol').value = domain.protocol;
                document.getElementById('enableSsl').checked = domain.ssl_enabled;
                document.getElementById('additionalConfig').value = domain.additional_config || '';
                document.getElementById('modalTitle').textContent = 'Domain bearbeiten';
                
                const modal = new bootstrap.Modal(document.getElementById('addDomainModal'));
                modal.show();
            } else {
                showToast('Fehler beim Laden der Domain', 'danger');
            }
        })
        .catch(error => {
            hideLoading();
            showToast('Netzwerkfehler: ' + error, 'danger');
        });
}

// Delete domain
function deleteDomain(id) {
    if (!confirm('Möchten Sie diese Domain wirklich löschen?')) {
        return;
    }
    
    showLoading();
    fetch(`api.php?action=delete&id=${id}`, {
        method: 'DELETE'
    })
    .then(response => response.json())
    .then(result => {
        hideLoading();
        if (result.success) {
            showToast('Domain erfolgreich gelöscht', 'success');
            loadDomains();
        } else {
            showToast('Fehler: ' + result.message, 'danger');
        }
    })
    .catch(error => {
        hideLoading();
        showToast('Netzwerkfehler: ' + error, 'danger');
    });
}

// Test connection
function testConnection(id) {
    showLoading();
    fetch(`api.php?action=test&id=${id}`)
        .then(response => response.json())
        .then(result => {
            hideLoading();
            if (result.success) {
                if (result.reachable) {
                    showToast('Verbindung erfolgreich!', 'success');
                } else {
                    showToast('Ziel nicht erreichbar', 'warning');
                }
            } else {
                showToast('Test fehlgeschlagen: ' + result.message, 'danger');
            }
        })
        .catch(error => {
            hideLoading();
            showToast('Netzwerkfehler: ' + error, 'danger');
        });
}

// Reload Caddy configuration
function reloadCaddy() {
    if (!confirm('Möchten Sie die Caddy-Konfiguration neu laden?')) {
        return;
    }
    
    showLoading();
    fetch('api.php?action=reload', {
        method: 'POST'
    })
    .then(response => response.json())
    .then(result => {
        hideLoading();
        if (result.success) {
            showToast('Caddy erfolgreich neu geladen', 'success');
        } else {
            showToast('Fehler beim Neuladen: ' + result.message, 'danger');
        }
    })
    .catch(error => {
        hideLoading();
        showToast('Netzwerkfehler: ' + error, 'danger');
    });
}

// Update statistics
function updateStatistics() {
    fetch('api.php?action=stats')
        .then(response => response.json())
        .then(data => {
            if (data.success) {
                document.getElementById('activeDomains').textContent = data.stats.total;
                document.getElementById('onlineServices').textContent = data.stats.online;
                document.getElementById('offlineServices').textContent = data.stats.offline;
            }
        })
        .catch(error => console.error('Stats error:', error));
}

// Show loading spinner
function showLoading() {
    document.querySelector('.loading-spinner').style.display = 'block';
}

// Hide loading spinner
function hideLoading() {
    document.querySelector('.loading-spinner').style.display = 'none';
}

// Show toast notification
function showToast(message, type = 'info') {
    const toastId = 'toast-' + Date.now();
    const toastHTML = `
        <div id="${toastId}" class="toast align-items-center text-white bg-${type} border-0" role="alert">
            <div class="d-flex">
                <div class="toast-body">
                    ${message}
                </div>
                <button type="button" class="btn-close btn-close-white me-2 m-auto" data-bs-dismiss="toast"></button>
            </div>
        </div>
    `;
    
    document.querySelector('.toast-container').insertAdjacentHTML('beforeend', toastHTML);
    const toastElement = document.getElementById(toastId);
    const toast = new bootstrap.Toast(toastElement);
    toast.show();
    
    // Remove toast after it's hidden
    toastElement.addEventListener('hidden.bs.toast', () => {
        toastElement.remove();
    });
}

// Reset modal when closed
document.getElementById('addDomainModal').addEventListener('hidden.bs.modal', function () {
    document.getElementById('domainForm').reset();
    document.getElementById('domainId').value = '';
    document.getElementById('modalTitle').textContent = 'Neue Domain hinzufügen';
});
EOJS

    # api.php erstellen (mit angepassten Pfaden)
    cat > $INSTALL_DIR/api.php << 'EOPHP'
<?php
header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(200);
    exit();
}

define('DB_FILE', '/var/www/caddy-admin/domains.json');
define('CADDYFILE_PATH', '/etc/caddy/Caddyfile');
define('CADDY_API_URL', 'http://localhost:2019');

if (!file_exists(DB_FILE)) {
    file_put_contents(DB_FILE, json_encode(['domains' => []]));
}

$action = $_GET['action'] ?? '';
$response = ['success' => false, 'message' => 'Invalid action'];

switch ($action) {
    case 'list':
        $response = listDomains();
        break;
    case 'get':
        $id = $_GET['id'] ?? 0;
        $response = getDomain($id);
        break;
    case 'add':
        $data = json_decode(file_get_contents('php://input'), true);
        $response = addDomain($data);
        break;
    case 'update':
        $data = json_decode(file_get_contents('php://input'), true);
        $response = updateDomain($data);
        break;
    case 'delete':
        $id = $_GET['id'] ?? 0;
        $response = deleteDomain($id);
        break;
    case 'test':
        $id = $_GET['id'] ?? 0;
        $response = testConnection($id);
        break;
    case 'reload':
        $response = reloadCaddy();
        break;
    case 'stats':
        $response = getStatistics();
        break;
    case 'health':
        $response = ['success' => true, 'status' => 'healthy', 'timestamp' => time()];
        break;
    default:
        $response = ['success' => false, 'message' => 'Unknown action'];
}

echo json_encode($response);

function listDomains() {
    $data = json_decode(file_get_contents(DB_FILE), true);
    return ['success' => true, 'domains' => array_values($data['domains'] ?? [])];
}

function getDomain($id) {
    $data = json_decode(file_get_contents(DB_FILE), true);
    foreach ($data['domains'] as $domain) {
        if ($domain['id'] == $id) {
            return ['success' => true, 'domain' => $domain];
        }
    }
    return ['success' => false, 'message' => 'Domain not found'];
}

function addDomain($input) {
    if (!validateDomainInput($input)) {
        return ['success' => false, 'message' => 'Invalid input data'];
    }
    
    $data = json_decode(file_get_contents(DB_FILE), true);
    
    foreach ($data['domains'] as $domain) {
        if ($domain['domain'] === $input['domain']) {
            return ['success' => false, 'message' => 'Domain already exists'];
        }
    }
    
    $maxId = 0;
    foreach ($data['domains'] as $domain) {
        if ($domain['id'] > $maxId) {
            $maxId = $domain['id'];
        }
    }
    
    $newDomain = [
        'id' => $maxId + 1,
        'domain' => $input['domain'],
        'target_ip' => $input['target_ip'],
        'target_port' => $input['target_port'],
        'protocol' => $input['protocol'] ?? 'http',
        'ssl_enabled' => $input['enable_ssl'] ?? false,
        'additional_config' => $input['additional_config'] ?? '',
        'status' => 'active',
        'created_at' => date('Y-m-d H:i:s'),
        'updated_at' => date('Y-m-d H:i:s')
    ];
    
    $data['domains'][] = $newDomain;
    
    if (file_put_contents(DB_FILE, json_encode($data, JSON_PRETTY_PRINT))) {
        generateCaddyfile($data['domains']);
        return ['success' => true, 'message' => 'Domain added successfully', 'domain' => $newDomain];
    }
    
    return ['success' => false, 'message' => 'Failed to save domain'];
}

function updateDomain($input) {
    if (!isset($input['id']) || !validateDomainInput($input)) {
        return ['success' => false, 'message' => 'Invalid input data'];
    }
    
    $data = json_decode(file_get_contents(DB_FILE), true);
    $found = false;
    
    foreach ($data['domains'] as &$domain) {
        if ($domain['id'] == $input['id']) {
            $domain['domain'] = $input['domain'];
            $domain['target_ip'] = $input['target_ip'];
            $domain['target_port'] = $input['target_port'];
            $domain['protocol'] = $input['protocol'] ?? 'http';
            $domain['ssl_enabled'] = $input['enable_ssl'] ?? false;
            $domain['additional_config'] = $input['additional_config'] ?? '';
            $domain['updated_at'] = date('Y-m-d H:i:s');
            $found = true;
            break;
        }
    }
    
    if (!$found) {
        return ['success' => false, 'message' => 'Domain not found'];
    }
    
    if (file_put_contents(DB_FILE, json_encode($data, JSON_PRETTY_PRINT))) {
        generateCaddyfile($data['domains']);
        return ['success' => true, 'message' => 'Domain updated successfully'];
    }
    
    return ['success' => false, 'message' => 'Failed to update domain'];
}

function deleteDomain($id) {
    $data = json_decode(file_get_contents(DB_FILE), true);
    $newDomains = [];
    $found = false;
    
    foreach ($data['domains'] as $domain) {
        if ($domain['id'] != $id) {
            $newDomains[] = $domain;
        } else {
            $found = true;
        }
    }
    
    if (!$found) {
        return ['success' => false, 'message' => 'Domain not found'];
    }
    
    $data['domains'] = $newDomains;
    
    if (file_put_contents(DB_FILE, json_encode($data, JSON_PRETTY_PRINT))) {
        generateCaddyfile($data['domains']);
        return ['success' => true, 'message' => 'Domain deleted successfully'];
    }
    
    return ['success' => false, 'message' => 'Failed to delete domain'];
}

function testConnection($id) {
    $domainData = getDomain($id);
    
    if (!$domainData['success']) {
        return $domainData;
    }
    
    $domain = $domainData['domain'];
    $url = $domain['protocol'] . '://' . $domain['target_ip'] . ':' . $domain['target_port'];
    
    $ch = curl_init($url);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_TIMEOUT, 5);
    curl_setopt($ch, CURLOPT_NOBODY, true);
    curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
    curl_setopt($ch, CURLOPT_SSL_VERIFYHOST, false);
    
    $result = curl_exec($ch);
    $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    
    return ['success' => true, 'reachable' => ($httpCode > 0), 'http_code' => $httpCode, 'url_tested' => $url];
}

function generateCaddyfile($domains) {
    global $ADMIN_EMAIL;
    $email = getenv('ADMIN_EMAIL') ?: 'admin@example.com';
    
    $caddyfile = "# Caddy Reverse Proxy Configuration\n";
    $caddyfile .= "# Generated by Caddy Admin Panel\n";
    $caddyfile .= "# " . date('Y-m-d H:i:s') . "\n\n";
    $caddyfile .= "{\n";
    $caddyfile .= "    admin localhost:2019\n";
    $caddyfile .= "    email " . $email . "\n";
    $caddyfile .= "}\n\n";
    
    foreach ($domains as $domain) {
        $caddyfile .= $domain['domain'] . " {\n";
        
        if ($domain['ssl_enabled']) {
            $caddyfile .= "    tls internal\n";
        }
        
        $target = $domain['protocol'] . '://' . $domain['target_ip'] . ':' . $domain['target_port'];
        $caddyfile .= "    reverse_proxy " . $target . " {\n";
        $caddyfile .= "        header_up Host {host}\n";
        $caddyfile .= "        header_up X-Real-IP {remote}\n";
        $caddyfile .= "        header_up X-Forwarded-For {remote}\n";
        $caddyfile .= "        header_up X-Forwarded-Proto {scheme}\n";
        $caddyfile .= "    }\n";
        
        if (!empty($domain['additional_config'])) {
            $caddyfile .= "\n    # Custom configuration\n";
            $lines = explode("\n", $domain['additional_config']);
            foreach ($lines as $line) {
                $caddyfile .= "    " . $line . "\n";
            }
        }
        
        $caddyfile .= "\n    log {\n";
        $caddyfile .= "        output file /var/log/caddy/" . $domain['domain'] . ".log\n";
        $caddyfile .= "    }\n";
        $caddyfile .= "}\n\n";
    }
    
    $tempFile = sys_get_temp_dir() . '/Caddyfile.' . time();
    file_put_contents($tempFile, $caddyfile);
    exec('sudo /usr/local/bin/update-caddyfile.sh ' . escapeshellarg($tempFile));
    
    return true;
}

function reloadCaddy() {
    exec('sudo systemctl reload caddy 2>&1', $output, $return_var);
    
    if ($return_var === 0) {
        return ['success' => true, 'message' => 'Caddy reloaded successfully'];
    }
    
    return ['success' => false, 'message' => 'Failed to reload Caddy'];
}

function getStatistics() {
    $data = json_decode(file_get_contents(DB_FILE), true);
    $domains = $data['domains'] ?? [];
    
    $stats = ['total' => count($domains), 'online' => 0, 'offline' => 0];
    
    foreach ($domains as $domain) {
        $url = $domain['protocol'] . '://' . $domain['target_ip'] . ':' . $domain['target_port'];
        
        $ch = curl_init($url);
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_TIMEOUT, 2);
        curl_setopt($ch, CURLOPT_NOBODY, true);
        curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
        curl_setopt($ch, CURLOPT_SSL_VERIFYHOST, false);
        
        curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);
        
        if ($httpCode > 0) {
            $stats['online']++;
        } else {
            $stats['offline']++;
        }
    }
    
    return ['success' => true, 'stats' => $stats];
}

function validateDomainInput($input) {
    if (empty($input['domain']) || empty($input['target_ip']) || empty($input['target_port'])) {
        return false;
    }
    
    if (!preg_match('/^([a-z0-9]+(-[a-z0-9]+)*\.)+[a-z]{2,}$/i', $input['domain'])) {
        return false;
    }
    
    if (!filter_var($input['target_ip'], FILTER_VALIDATE_IP)) {
        return false;
    }
    
    $port = intval($input['target_port']);
    if ($port < 1 || $port > 65535) {
        return false;
    }
    
    return true;
}
?>
EOPHP

    # Environment Variable für E-Mail setzen
    echo "ADMIN_EMAIL=$ADMIN_EMAIL" >> $INSTALL_DIR/.env
    
    echo -e "${GREEN}✓ Admin Panel Dateien erstellt${NC}"
}

# Webserver konfigurieren
configure_webserver() {
    if $USE_NGINX; then
        configure_nginx
    else
        configure_apache
    fi
}

# Nginx konfigurieren
configure_nginx() {
    echo -e "${YELLOW}→ Konfiguriere Nginx...${NC}"
    
    # Nginx Konfiguration erstellen
    cat > /etc/nginx/sites-available/caddy-admin << EONGINX
server {
    listen $ADMIN_PORT;
    server_name $ADMIN_DOMAIN;
    root $INSTALL_DIR;
    index index.html index.php;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }

    access_log /var/log/nginx/caddy-admin-access.log;
    error_log /var/log/nginx/caddy-admin-error.log;
}
EONGINX

    # Site aktivieren
    ln -sf /etc/nginx/sites-available/caddy-admin /etc/nginx/sites-enabled/
    
    # Default site deaktivieren
    rm -f /etc/nginx/sites-enabled/default
    
    # Nginx neustarten
    systemctl restart nginx
    
    echo -e "${GREEN}✓ Nginx konfiguriert${NC}"
}

# Apache konfigurieren
configure_apache() {
    echo -e "${YELLOW}→ Konfiguriere Apache...${NC}"
    
    # Apache Konfiguration erstellen
    if [[ "$OS_ID" == "ubuntu" ]] || [[ "$OS_ID" == "debian" ]]; then
        APACHE_SITES="/etc/apache2/sites-available"
        APACHE_CONF="/etc/apache2/apache2.conf"
        
        # Port hinzufügen
        if ! grep -q "Listen $ADMIN_PORT" /etc/apache2/ports.conf; then
            echo "Listen $ADMIN_PORT" >> /etc/apache2/ports.conf
        fi
        
    elif [[ "$OS_ID" == "centos" ]] || [[ "$OS_ID" == "rhel" ]] || [[ "$OS_ID" == "fedora" ]]; then
        APACHE_SITES="/etc/httpd/conf.d"
        APACHE_CONF="/etc/httpd/conf/httpd.conf"
        
        # Port hinzufügen
        if ! grep -q "Listen $ADMIN_PORT" $APACHE_CONF; then
            echo "Listen $ADMIN_PORT" >> $APACHE_CONF
        fi
    fi
    
    # Virtual Host erstellen
    cat > $APACHE_SITES/caddy-admin.conf << EOAPACHE
<VirtualHost *:$ADMIN_PORT>
    ServerName $ADMIN_DOMAIN
    DocumentRoot $INSTALL_DIR
    
    <Directory $INSTALL_DIR>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/caddy-admin-error.log
    CustomLog \${APACHE_LOG_DIR}/caddy-admin-access.log combined
</VirtualHost>
EOAPACHE

    # Site aktivieren und Apache neustarten
    if [[ "$OS_ID" == "ubuntu" ]] || [[ "$OS_ID" == "debian" ]]; then
        a2ensite caddy-admin > /dev/null 2>&1
        a2dissite 000-default > /dev/null 2>&1
        systemctl restart apache2
    else
        systemctl restart httpd
    fi
    
    echo -e "${GREEN}✓ Apache konfiguriert${NC}"
}

# Caddy konfigurieren
configure_caddy() {
    echo -e "${YELLOW}→ Konfiguriere Caddy...${NC}"
    
    # Basis Caddyfile erstellen
    cat > $CADDY_CONFIG_DIR/Caddyfile << EOCADDY
{
    admin localhost:2019
    email $ADMIN_EMAIL
}

# Admin Panel (falls SSL aktiviert)
EOCADDY

    if $ENABLE_SSL && [[ "$ADMIN_DOMAIN" != "localhost" ]]; then
        cat >> $CADDY_CONFIG_DIR/Caddyfile << EOCADDY
$ADMIN_DOMAIN {
    reverse_proxy localhost:$ADMIN_PORT
}

EOCADDY
    fi

    # Caddy neustarten
    systemctl restart caddy
    
    echo -e "${GREEN}✓ Caddy konfiguriert${NC}"
}

# Sudo-Berechtigungen konfigurieren
configure_sudo() {
    echo -e "${YELLOW}→ Konfiguriere Sudo-Berechtigungen...${NC}"
    
    # Update-Script erstellen
    cat > /usr/local/bin/update-caddyfile.sh << 'EOSCRIPT'
#!/bin/bash
TEMP_FILE=$1
CADDY_FILE="/etc/caddy/Caddyfile"
BACKUP_DIR="/var/backups/caddy"

mkdir -p $BACKUP_DIR
cp $CADDY_FILE "$BACKUP_DIR/Caddyfile.$(date +%Y%m%d_%H%M%S)"

if caddy validate --config $TEMP_FILE 2>/dev/null; then
    cp $TEMP_FILE $CADDY_FILE
    systemctl reload caddy
    echo "Caddyfile updated successfully"
    exit 0
else
    echo "Invalid Caddyfile"
    exit 1
fi
EOSCRIPT

    chmod +x /usr/local/bin/update-caddyfile.sh
    
    # Sudoers Datei erstellen
    cat > /etc/sudoers.d/caddy-admin << EOSUDO
# Caddy Admin Panel Permissions
www-data ALL=(ALL) NOPASSWD: /usr/bin/caddy reload
www-data ALL=(ALL) NOPASSWD: /usr/bin/caddy validate
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/update-caddyfile.sh
www-data ALL=(ALL) NOPASSWD: /bin/systemctl reload caddy
www-data ALL=(ALL) NOPASSWD: /bin/systemctl restart caddy
EOSUDO

    chmod 440 /etc/sudoers.d/caddy-admin
    
    echo -e "${GREEN}✓ Sudo-Berechtigungen konfiguriert${NC}"
}

# Dateiberechtigungen setzen
set_permissions() {
    echo -e "${YELLOW}→ Setze Dateiberechtigungen...${NC}"
    
    # Verzeichnisse erstellen
    mkdir -p $LOG_DIR
    mkdir -p $BACKUP_DIR
    
    # Berechtigungen setzen
    chown -R www-data:www-data $INSTALL_DIR
    chmod 755 $INSTALL_DIR
    chmod 644 $INSTALL_DIR/*
    chmod 755 $INSTALL_DIR/api.php
    
    # Log-Verzeichnis
    chown caddy:caddy $LOG_DIR
    chmod 755 $LOG_DIR
    
    # Backup-Verzeichnis
    chown www-data:www-data $BACKUP_DIR
    chmod 755 $BACKUP_DIR
    
    # JSON Datei erstellen
    touch $INSTALL_DIR/domains.json
    chown www-data:www-data $INSTALL_DIR/domains.json
    chmod 664 $INSTALL_DIR/domains.json
    
    echo -e "${GREEN}✓ Dateiberechtigungen gesetzt${NC}"
}

# Firewall konfigurieren
configure_firewall() {
    if $ENABLE_FIREWALL; then
        echo -e "${YELLOW}→ Konfiguriere Firewall...${NC}"
        
        # UFW installieren falls nicht vorhanden
        if ! command -v ufw &> /dev/null; then
            $PKG_INSTALL ufw > /dev/null 2>&1
        fi
        
        # Firewall-Regeln
        ufw allow 22/tcp > /dev/null 2>&1  # SSH
        ufw allow 80/tcp > /dev/null 2>&1  # HTTP
        ufw allow 443/tcp > /dev/null 2>&1 # HTTPS
        ufw allow $ADMIN_PORT/tcp > /dev/null 2>&1 # Admin Panel
        
        # Firewall aktivieren
        ufw --force enable > /dev/null 2>&1
        
        echo -e "${GREEN}✓ Firewall konfiguriert${NC}"
    fi
}

# SSL Zertifikat einrichten
setup_ssl() {
    if $ENABLE_SSL && [[ "$ADMIN_DOMAIN" != "localhost" ]]; then
        echo -e "${YELLOW}→ Richte SSL-Zertifikat ein...${NC}"
        
        # Certbot installieren
        if [[ "$OS_ID" == "ubuntu" ]] || [[ "$OS_ID" == "debian" ]]; then
            $PKG_INSTALL certbot > /dev/null 2>&1
            
            if $USE_NGINX; then
                $PKG_INSTALL python3-certbot-nginx > /dev/null 2>&1
                certbot --nginx -d $ADMIN_DOMAIN --non-interactive --agree-tos -m $ADMIN_EMAIL > /dev/null 2>&1
            else
                $PKG_INSTALL python3-certbot-apache > /dev/null 2>&1
                certbot --apache -d $ADMIN_DOMAIN --non-interactive --agree-tos -m $ADMIN_EMAIL > /dev/null 2>&1
            fi
        fi
        
        echo -e "${GREEN}✓ SSL-Zertifikat eingerichtet${NC}"
    fi
}

# Backup-Script erstellen
create_backup_script() {
    echo -e "${YELLOW}→ Erstelle Backup-Script...${NC}"
    
    cat > /usr/local/bin/backup-caddy.sh << 'EOBACKUP'
#!/bin/bash
BACKUP_DIR="/var/backups/caddy"
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p $BACKUP_DIR

# Konfiguration sichern
cp /etc/caddy/Caddyfile $BACKUP_DIR/Caddyfile.$DATE
cp /var/www/caddy-admin/domains.json $BACKUP_DIR/domains.$DATE.json

# Zertifikate sichern
if [ -d /var/lib/caddy ]; then
    tar czf $BACKUP_DIR/certificates.$DATE.tar.gz /var/lib/caddy/
fi

# Alte Backups löschen (älter als 30 Tage)
find $BACKUP_DIR -type f -mtime +30 -delete

echo "Backup completed: $BACKUP_DIR"
EOBACKUP

    chmod +x /usr/local/bin/backup-caddy.sh
    
    # Cron-Job für tägliches Backup
    echo "0 2 * * * root /usr/local/bin/backup-caddy.sh" > /etc/cron.d/caddy-backup
    
    echo -e "${GREEN}✓ Backup-Script erstellt${NC}"
}

# Service Status überprüfen
check_services() {
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Service Status:${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
    
    # Caddy
    if systemctl is-active --quiet caddy; then
        echo -e "  Caddy: ${GREEN}✓ Läuft${NC}"
    else
        echo -e "  Caddy: ${RED}✗ Gestoppt${NC}"
    fi
    
    # Webserver
    if $USE_NGINX; then
        if systemctl is-active --quiet nginx; then
            echo -e "  Nginx: ${GREEN}✓ Läuft${NC}"
        else
            echo -e "  Nginx: ${RED}✗ Gestoppt${NC}"
        fi
    else
        if [[ "$OS_ID" == "ubuntu" ]] || [[ "$OS_ID" == "debian" ]]; then
            if systemctl is-active --quiet apache2; then
                echo -e "  Apache: ${GREEN}✓ Läuft${NC}"
            else
                echo -e "  Apache: ${RED}✗ Gestoppt${NC}"
            fi
        else
            if systemctl is-active --quiet httpd; then
                echo -e "  Apache: ${GREEN}✓ Läuft${NC}"
            else
                echo -e "  Apache: ${RED}✗ Gestoppt${NC}"
            fi
        fi
    fi
}

# Installation abschließen
finish_installation() {
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}           Installation erfolgreich abgeschlossen!              ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BLUE}Zugriff auf Admin Panel:${NC}"
    
    if [[ "$ADMIN_DOMAIN" == "localhost" ]]; then
        echo -e "  URL: ${GREEN}http://$(hostname -I | awk '{print $1}'):$ADMIN_PORT${NC}"
    else
        if $ENABLE_SSL; then
            echo -e "  URL: ${GREEN}https://$ADMIN_DOMAIN${NC}"
        else
            echo -e "  URL: ${GREEN}http://$ADMIN_DOMAIN:$ADMIN_PORT${NC}"
        fi
    fi
    
    echo ""
    echo -e "${BLUE}Wichtige Pfade:${NC}"
    echo -e "  Web-Dateien: ${YELLOW}$INSTALL_DIR${NC}"
    echo -e "  Caddy Config: ${YELLOW}$CADDY_CONFIG_DIR/Caddyfile${NC}"
    echo -e "  Logs: ${YELLOW}$LOG_DIR${NC}"
    echo -e "  Backups: ${YELLOW}$BACKUP_DIR${NC}"
    
    echo ""
    echo -e "${BLUE}Nützliche Befehle:${NC}"
    echo -e "  Status prüfen: ${YELLOW}systemctl status caddy${NC}"
    echo -e "  Logs anzeigen: ${YELLOW}journalctl -u caddy -f${NC}"
    echo -e "  Backup erstellen: ${YELLOW}/usr/local/bin/backup-caddy.sh${NC}"
    
    echo ""
    echo -e "${YELLOW}Hinweis: Vergessen Sie nicht, die DNS-Einträge für Ihre Domains${NC}"
    echo -e "${YELLOW}auf die öffentliche IP dieses Servers zu zeigen!${NC}"
    echo ""
}

# Main Installation
main() {
    check_root
    show_banner
    detect_os
    get_user_input
    
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Starte Installation...${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
    
    update_system
    install_base_packages
    install_caddy
    install_php
    install_webserver
    create_admin_panel_files
    configure_webserver
    configure_caddy
    configure_sudo
    set_permissions
    configure_firewall
    setup_ssl
    create_backup_script
    check_services
    finish_installation
}

# Script starten
main
