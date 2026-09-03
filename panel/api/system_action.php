<?php
require_once __DIR__ . '/../includes/guard.php';
vp_requireSession(true);
vp_requireCsrf(true);

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    header('Content-Type: application/json');
    echo json_encode(['ok' => false, 'error' => 'Method not allowed']);
    exit;
}

header('Content-Type: application/json');

$raw = file_get_contents('php://input');
$body = [];
if (!empty($raw)) {
    $decoded = json_decode($raw, true);
    if (is_array($decoded)) $body = $decoded;
}
if (empty($body)) $body = $_POST;

$action = (string)($body['action'] ?? '');

function logSystemEvent(string $type, string $source = 'panel'): void {
    $logFile = '/var/log/vpn-panel/events.log';
    $time = date('Y-m-d H:i:s');
    $line = $time . '|system|' . $type . '|' . $source . "\n";
    @file_put_contents($logFile, $line, FILE_APPEND | LOCK_EX);
}

function respond(bool $ok, string $msg): void {
    echo json_encode(
        $ok ? ['ok' => true, 'message' => $msg] : ['ok' => false, 'error' => $msg],
        JSON_UNESCAPED_UNICODE
    );
    exit;
}

switch ($action) {

case 'reboot':
    logSystemEvent('reboot');

    exec('nohup bash -c "sleep 3 && /usr/bin/sudo /bin/systemctl reboot" > /dev/null 2>&1 &');
    respond(true, 'Сервер перезапускается. Панель будет недоступна 30-60 секунд.');
    break;

case 'poweroff':
    logSystemEvent('poweroff');
    exec('nohup bash -c "sleep 3 && /usr/bin/sudo /bin/systemctl poweroff" > /dev/null 2>&1 &');
    respond(true, 'Сервер выключается. Для включения нужен физический доступ.');
    break;

default:
    respond(false, 'Неизвестное действие: ' . htmlspecialchars($action));
}
