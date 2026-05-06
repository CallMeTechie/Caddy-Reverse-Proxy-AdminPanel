<?php
/**
 * Unit-Tests für die Validierungs-Funktionen aus install.sh -> api.php.
 *
 * SYNCHRONISATIONSHINWEIS:
 * Die Funktionen unten sind eine 1:1-Kopie der Validatoren aus install.sh
 * (Heredoc-Block für api.php). Wird install.sh angepasst, müssen die Funktionen
 * hier mitgepflegt werden. CI prüft Bash + PHP getrennt; Drift wird entweder
 * im php-lint-Job oder als Test-Failure hier sichtbar.
 */

declare(strict_types=1);

// ---- Funktionen unter Test (Spiegel von install.sh / api.php) --------------

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

// ---- Mini-Test-Framework ---------------------------------------------------

$pass = 0;
$fail = 0;
$failures = [];

function ok(bool $cond, string $msg): void {
    global $pass, $fail, $failures;
    if ($cond) { $pass++; echo "  \033[32m✓\033[0m $msg\n"; }
    else       { $fail++; $failures[] = $msg; echo "  \033[31m✗\033[0m $msg\n"; }
}

function eq($expected, $actual, string $msg): void {
    ok($expected === $actual, "$msg (erwartet=" . var_export($expected, true) . ", erhalten=" . var_export($actual, true) . ')');
}

function throws(callable $fn, string $msg): void {
    try { $fn(); ok(false, "$msg (keine Exception)"); }
    catch (RuntimeException $e) { ok(true, $msg); }
    catch (Throwable $t) { ok(false, "$msg (falscher Exception-Typ: " . get_class($t) . ')'); }
}

// ---- Tests: validate_domain ------------------------------------------------

echo "validate_domain:\n";
eq('example.com',       validate_domain('example.com'),         'plain domain');
eq('example.com',       validate_domain('EXAMPLE.COM'),         'normalisiert auf lowercase');
eq('admin.example.com', validate_domain(' admin.example.com '), 'trimmt Whitespace');
eq('*.example.com',     validate_domain('*.example.com'),       'akzeptiert Wildcard');
eq('localhost',         validate_domain('localhost'),           'erlaubt localhost als Sonderfall');

throws(fn() => validate_domain(''),                       'leerer String wird abgelehnt');
throws(fn() => validate_domain('noTLD'),                  'fehlende TLD wird abgelehnt');
throws(fn() => validate_domain('-bad.com'),               'führender Bindestrich abgelehnt');
throws(fn() => validate_domain('bad-.com'),               'nachgestellter Bindestrich abgelehnt');
throws(fn() => validate_domain('foo.c'),                  'zu kurze TLD abgelehnt');
throws(fn() => validate_domain('foo bar.com'),            'Whitespace abgelehnt');
throws(fn() => validate_domain('evil.com { admin off }'), 'Caddyfile-Injection abgelehnt');
throws(fn() => validate_domain("foo.com\nrm -rf"),        'Newline-Injection abgelehnt');

// ---- Tests: validate_ip ----------------------------------------------------

echo "\nvalidate_ip:\n";
eq('192.168.1.1', validate_ip('192.168.1.1'), 'IPv4 akzeptiert');
eq('10.0.0.1',    validate_ip('10.0.0.1'),    'private IPv4 akzeptiert');
eq('::1',         validate_ip('::1'),         'IPv6 loopback akzeptiert');
eq('2001:db8::1', validate_ip('2001:db8::1'), 'IPv6 akzeptiert');

throws(fn() => validate_ip(''),                       'leere IP abgelehnt');
throws(fn() => validate_ip('999.999.999.999'),        'IP-Bereich abgelehnt');
throws(fn() => validate_ip('not.an.ip'),              'String abgelehnt');
throws(fn() => validate_ip('192.168.1'),              'unvollständige IP abgelehnt');
throws(fn() => validate_ip('192.168.1.1; rm -rf /'),  'Shell-Injection abgelehnt');

// ---- Tests: validate_port --------------------------------------------------

echo "\nvalidate_port:\n";
eq(80,    validate_port(80),    'Port 80');
eq(443,   validate_port('443'), 'Port als String');
eq(1,     validate_port(1),     'Port 1 (untere Grenze)');
eq(65535, validate_port(65535), 'Port 65535 (obere Grenze)');

throws(fn() => validate_port(0),     'Port 0 abgelehnt');
throws(fn() => validate_port(-1),    'negativer Port abgelehnt');
throws(fn() => validate_port(65536), 'Port > 65535 abgelehnt');
throws(fn() => validate_port(99999), 'Port viel zu groß abgelehnt');

// ---- Tests: validate_protocol ----------------------------------------------

echo "\nvalidate_protocol:\n";
eq('http',  validate_protocol('http'),  'http akzeptiert');
eq('https', validate_protocol('https'), 'https akzeptiert');

throws(fn() => validate_protocol(''),           'leeres Protokoll abgelehnt');
throws(fn() => validate_protocol('HTTP'),       'Großschreibung abgelehnt');
throws(fn() => validate_protocol('ftp'),        'ftp abgelehnt');
throws(fn() => validate_protocol('file'),       'file abgelehnt');
throws(fn() => validate_protocol('javascript'), 'javascript abgelehnt');

// ---- Tests: safe_log_name --------------------------------------------------

echo "\nsafe_log_name:\n";
eq('example.com',    safe_log_name('example.com'),    'normale Domain bleibt');
eq('_.example.com',  safe_log_name('*.example.com'),  'Wildcard durch _ ersetzt');
eq('a-b.example.io', safe_log_name('a-b.example.io'), 'Bindestrich erlaubt');
eq('foo___com',      safe_log_name('foo /\\com'),     'Path-Traversal-Versuch entschärft');
eq('foo_.._bar',     safe_log_name('foo/../bar'),     '../-Versuch nicht durchgelassen');
eq('foo.com',        safe_log_name('FOO.COM'),        'normalisiert auf lowercase');

// ---- Ergebnis --------------------------------------------------------------

echo "\n" . str_repeat('=', 60) . "\n";
echo "Ergebnis: \033[32m{$pass} bestanden\033[0m";
if ($fail > 0) {
    echo ", \033[31m{$fail} fehlgeschlagen\033[0m\n\nFehler:\n";
    foreach ($failures as $f) echo "  - $f\n";
    exit(1);
}
echo ", 0 fehlgeschlagen\n";
exit(0);
