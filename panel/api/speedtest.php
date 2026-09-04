<?php

require_once __DIR__ . '/../includes/guard.php';
require_once __DIR__ . '/../includes/vpn_helpers.php';
vp_requireSession(true);
vp_requireCsrf(true);

header('Content-Type: application/json; charset=utf-8');

define('ST_BIN',     '/usr/local/bin/speedtest');
define('ST_DIR',     '/var/www/speedtest');
define('ST_OUT',     ST_DIR . '/out.json');
define('ST_ERR',     ST_DIR . '/err.txt');
define('ST_RC',      ST_DIR . '/rc');
define('ST_STATE',   ST_DIR . '/state.json');
define('ST_HISTORY', ST_DIR . '/history.json');
define('ST_TIMEOUT', 180);
define('ST_KEEP',    20);

function st_reply(array $payload, int $code = 200): void {
    http_response_code($code);
    echo json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

function st_readJson(string $path) {
    if (!is_file($path)) return null;
    $raw = @file_get_contents($path);
    if ($raw === false || trim($raw) === '') return null;
    $decoded = json_decode($raw, true);
    return is_array($decoded) ? $decoded : null;
}

function st_channels(): array {
    return vp_speedChannels();
}

function st_allowedIfaces(): array {
    $allowed = [];
    foreach (st_channels() as $c) $allowed[] = $c['iface'];
    return $allowed;
}

function st_running(): bool {
    $state = st_readJson(ST_STATE);
    if ($state === null) return false;
    if (is_file(ST_RC)) return false;
    return (time() - (int)($state['started'] ?? 0)) < ST_TIMEOUT;
}

function st_history(): array {
    $rows = st_readJson(ST_HISTORY);
    return is_array($rows) ? $rows : [];
}

function st_writeHistory(array $rows): void {
    @file_put_contents(ST_HISTORY, json_encode(array_values($rows), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
    @chmod(ST_HISTORY, 0664);
}

function st_pushHistory(array $row): void {
    $rows = st_history();
    array_unshift($rows, $row);
    st_writeHistory(array_slice($rows, 0, ST_KEEP));
}

function st_shapeResult(array $raw, string $iface): array {
    $mbit = static function ($bandwidth) {
        return $bandwidth > 0 ? round(((int)$bandwidth * 8) / 1000000, 2) : 0.0;
    };
    return [
        'id'       => bin2hex(random_bytes(6)),
        'time'     => date('Y-m-d H:i:s'),
        'iface'    => $iface !== '' ? $iface : ($raw['interface']['name'] ?? ''),
        'download' => $mbit($raw['download']['bandwidth'] ?? 0),
        'upload'   => $mbit($raw['upload']['bandwidth'] ?? 0),
        'ping'     => round((float)($raw['ping']['latency'] ?? 0), 1),
        'jitter'   => round((float)($raw['ping']['jitter'] ?? 0), 1),
        'loss'     => round((float)($raw['packetLoss'] ?? 0), 1),
        'server'   => trim(($raw['server']['name'] ?? '') . ' — ' . ($raw['server']['location'] ?? ''), ' —'),
        'isp'      => $raw['isp'] ?? '',
        'external' => $raw['interface']['externalIp'] ?? '',
        'url'      => $raw['result']['url'] ?? '',
    ];
}

$action = $_REQUEST['action'] ?? '';

if (!is_file(ST_BIN) || !is_executable(ST_BIN)) {
    st_reply([
        'ok'     => false,
        'state'  => 'no-binary',
        'error'  => 'Speedtest CLI не установлен',
        'hint'   => 'Клиент ставится сам при обновлении: sudo vpn-panel-deploy deploy',
    ]);
}

if ($action === 'channels') {
    st_reply(['ok' => true, 'channels' => st_channels(), 'tunnel' => is_dir('/sys/class/net/tun0')]);
}

if ($action === 'history') {
    $rows = st_history();
    st_reply(['ok' => true, 'history' => $rows, 'last' => $rows[0] ?? null]);
}

if ($action === 'forget') {
    $id = trim((string)($_REQUEST['id'] ?? ''));
    if ($id === '' || !preg_match('/^[a-zA-Z0-9:\- ]{1,32}$/', $id)) {
        st_reply(['ok' => false, 'error' => 'Не указано, какой замер удалить'], 400);
    }

    $rows = st_history();
    $kept = [];
    $removed = 0;
    foreach ($rows as $row) {
        $rowId = (string)($row['id'] ?? '');
        $match = $rowId !== '' ? ($rowId === $id) : (($row['time'] ?? '') === $id);
        if ($match && $removed === 0) { $removed++; continue; }
        $kept[] = $row;
    }

    if ($removed === 0) {
        st_reply(['ok' => false, 'error' => 'Замер не найден — возможно, он уже удалён'], 404);
    }

    st_writeHistory($kept);
    st_reply(['ok' => true, 'history' => $kept, 'last' => $kept[0] ?? null]);
}

if ($action === 'forget-all') {
    st_writeHistory([]);
    st_reply(['ok' => true, 'history' => [], 'last' => null]);
}

if ($action === 'start') {
    if (st_running()) {
        st_reply(['ok' => false, 'state' => 'running', 'error' => 'Замер уже идёт'], 409);
    }

    $iface = trim((string)($_REQUEST['iface'] ?? ''));
    if ($iface !== '' && !in_array($iface, st_allowedIfaces(), true)) {
        st_reply(['ok' => false, 'error' => 'Неизвестный интерфейс'], 400);
    }

    if (!is_dir(ST_DIR)) { @mkdir(ST_DIR, 0775, true); }
    @unlink(ST_OUT); @unlink(ST_ERR); @unlink(ST_RC);

    @file_put_contents(ST_STATE, json_encode(['iface' => $iface, 'started' => time()]));
    @chmod(ST_STATE, 0664);

    $bind = $iface !== '' ? ' --interface=' . escapeshellarg($iface) : '';
    $cmd  = 'sudo -n ' . ST_BIN . ' --accept-license --accept-gdpr --format=json' . $bind;
    $shell = '(' . $cmd . ' > ' . escapeshellarg(ST_OUT) . ' 2> ' . escapeshellarg(ST_ERR) . '; '
           . 'echo $? > ' . escapeshellarg(ST_RC) . ') > /dev/null 2>&1 &';
    @shell_exec($shell);

    st_reply(['ok' => true, 'state' => 'running', 'iface' => $iface]);
}

if ($action === 'status') {
    $state = st_readJson(ST_STATE);
    if ($state === null) {
        st_reply(['ok' => true, 'state' => 'idle']);
    }

    $iface   = (string)($state['iface'] ?? '');
    $started = (int)($state['started'] ?? 0);

    if (is_file(ST_RC)) {
        $rc  = (int)trim((string)@file_get_contents(ST_RC));
        $raw = st_readJson(ST_OUT);
        @unlink(ST_STATE);

        if ($rc === 0 && is_array($raw) && isset($raw['download'])) {
            $row = st_shapeResult($raw, $iface);
            st_pushHistory($row);
            st_reply(['ok' => true, 'state' => 'done', 'result' => $row]);
        }

        $err = trim((string)@file_get_contents(ST_ERR));
        if ($err === '' && is_array($raw) && isset($raw['error'])) $err = (string)$raw['error'];
        if ($err === '') $err = 'Speedtest завершился с кодом ' . $rc;
        st_reply(['ok' => false, 'state' => 'failed', 'error' => mb_substr($err, 0, 400)]);
    }

    if (time() - $started >= ST_TIMEOUT) {
        @unlink(ST_STATE);
        st_reply(['ok' => false, 'state' => 'failed', 'error' => 'Замер не уложился в ' . ST_TIMEOUT . ' секунд']);
    }

    st_reply(['ok' => true, 'state' => 'running', 'iface' => $iface, 'elapsed' => time() - $started]);
}

st_reply(['ok' => false, 'error' => 'Неизвестное действие'], 400);
