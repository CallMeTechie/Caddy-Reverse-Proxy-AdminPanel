#!/usr/bin/env bats
# Bats-Unit-Tests für die Validierungsfunktionen aus install.sh.
# install.sh wird gesourct — main() läuft nur, wenn die Datei direkt aufgerufen
# wird (BASH_SOURCE-Guard am Ende von install.sh).

setup() {
    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../install.sh"
}

# ---- is_valid_domain --------------------------------------------------------

@test "is_valid_domain: akzeptiert Standard-Domain" {
    is_valid_domain "example.com"
}

@test "is_valid_domain: akzeptiert Subdomain" {
    is_valid_domain "admin.example.com"
}

@test "is_valid_domain: akzeptiert mehrstufige Subdomain" {
    is_valid_domain "a.b.c.example.org"
}

@test "is_valid_domain: akzeptiert Bindestriche" {
    is_valid_domain "my-app.example.io"
}

@test "is_valid_domain: akzeptiert Wildcard" {
    is_valid_domain "*.example.com"
}

@test "is_valid_domain: lehnt leeren String ab" {
    run is_valid_domain ""
    [ "$status" -ne 0 ]
}

@test "is_valid_domain: lehnt fehlende TLD ab" {
    run is_valid_domain "noTLD"
    [ "$status" -ne 0 ]
}

@test "is_valid_domain: lehnt führenden Bindestrich ab" {
    run is_valid_domain "-bad.com"
    [ "$status" -ne 0 ]
}

@test "is_valid_domain: lehnt nachgestellten Bindestrich ab" {
    run is_valid_domain "bad-.com"
    [ "$status" -ne 0 ]
}

@test "is_valid_domain: lehnt zu kurze TLD ab" {
    run is_valid_domain "foo.c"
    [ "$status" -ne 0 ]
}

@test "is_valid_domain: lehnt Großbuchstaben ab" {
    run is_valid_domain "Example.com"
    [ "$status" -ne 0 ]
}

@test "is_valid_domain: lehnt Whitespace ab" {
    run is_valid_domain "exa mple.com"
    [ "$status" -ne 0 ]
}

@test "is_valid_domain: lehnt Caddyfile-Injection-Versuch ab" {
    run is_valid_domain "evil.com { admin off }"
    [ "$status" -ne 0 ]
}

# ---- is_valid_email ---------------------------------------------------------

@test "is_valid_email: akzeptiert Standardformat" {
    is_valid_email "user@example.com"
}

@test "is_valid_email: akzeptiert Plus-Tag" {
    is_valid_email "user+tag@example.com"
}

@test "is_valid_email: akzeptiert Dot in Local-Part" {
    is_valid_email "first.last@example.co.uk"
}

@test "is_valid_email: lehnt leeren String ab" {
    run is_valid_email ""
    [ "$status" -ne 0 ]
}

@test "is_valid_email: lehnt fehlendes @ ab" {
    run is_valid_email "noatsign.com"
    [ "$status" -ne 0 ]
}

@test "is_valid_email: lehnt leeren Local-Part ab" {
    run is_valid_email "@example.com"
    [ "$status" -ne 0 ]
}

@test "is_valid_email: lehnt fehlende Domain ab" {
    run is_valid_email "user@"
    [ "$status" -ne 0 ]
}

@test "is_valid_email: lehnt fehlende TLD ab" {
    run is_valid_email "user@example"
    [ "$status" -ne 0 ]
}

# ---- Konstanten / Pfad-Setup ------------------------------------------------

@test "Pfade: alle wichtigen Konstanten gesetzt" {
    [ -n "$INSTALL_DIR" ]
    [ -n "$ADMIN_CONFIG_DIR" ]
    [ -n "$ADMIN_AUTH_FILE" ]
    [ -n "$STAGE_FILE" ]
    [ -n "$RELOAD_HELPER" ]
    [ -n "$SUDOERS_FILE" ]
}

@test "Pfade: STAGE_FILE liegt unter STAGE_DIR" {
    [[ "$STAGE_FILE" == "$STAGE_DIR"/* ]]
}

@test "Pfade: ADMIN_AUTH_FILE liegt außerhalb INSTALL_DIR (DocumentRoot)" {
    [[ "$ADMIN_AUTH_FILE" != "$INSTALL_DIR"/* ]]
}

@test "Defaults: ENABLE_FIREWALL true, ENABLE_SSL false" {
    [ "$ENABLE_FIREWALL" = "true" ]
    [ "$ENABLE_SSL" = "false" ]
}
