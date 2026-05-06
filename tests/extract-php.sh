#!/usr/bin/env bash
# Extrahiert die in install.sh per Heredoc eingebetteten PHP-Dateien
# in tests/_extracted/*.php — damit php -l sie lintet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SH="${SCRIPT_DIR}/../install.sh"
OUT_DIR="${SCRIPT_DIR}/_extracted"

[[ -f "$INSTALL_SH" ]] || { echo "install.sh nicht gefunden: $INSTALL_SH" >&2; exit 1; }

mkdir -p "$OUT_DIR"
rm -f "${OUT_DIR}"/*.php

awk -v out="$OUT_DIR" '
    /cat > "\$\{INSTALL_DIR\}\/index.php" <<.EOPHP/    { name="index.php";  cap=1; next }
    /cat > "\$\{INSTALL_DIR\}\/login.php" <<.EOPHP/    { name="login.php";  cap=1; next }
    /cat > "\$\{INSTALL_DIR\}\/logout.php" <<.EOPHP/   { name="logout.php"; cap=1; next }
    /cat > "\$\{INSTALL_DIR\}\/lib\/auth.php" <<.EOPHP/{ name="auth.php";   cap=1; next }
    /cat > "\$\{INSTALL_DIR\}\/api.php" <<.EOPHP/      { name="api.php";    cap=1; next }
    /^EOPHP$/                                          { cap=0; name="";    next }
    cap && name != "" { print > (out "/" name) }
' "$INSTALL_SH"

extracted=$(find "$OUT_DIR" -maxdepth 1 -name '*.php' -type f | wc -l)
if [[ "$extracted" -lt 5 ]]; then
    echo "Erwartete 5 extrahierte PHP-Dateien, fand $extracted" >&2
    ls -la "$OUT_DIR" >&2
    exit 1
fi

echo "Extrahiert nach $OUT_DIR:"
ls -la "$OUT_DIR"
