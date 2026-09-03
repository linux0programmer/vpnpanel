<?php
require_once __DIR__ . '/../includes/guard.php';
vp_requireSession(true);
vp_requireCsrf(true);

header('Content-Type: application/json');

$state = [
    'STATE' => 'stopped',
    'ACTIVE_ID' => '',
    'PRIMARY_ID' => '',
    'ACTIVATED_BY' => ''
];

$stateFile = '/var/www/vpn-state';
if (file_exists($stateFile)) {
    $allowed = ['STATE', 'ACTIVE_ID', 'PRIMARY_ID', 'ACTIVATED_BY'];
    $lines = @file($stateFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
    foreach ($lines as $line) {
        if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && in_array($m[1], $allowed, true)) {
            $state[$m[1]] = $m[2];
        }
    }
}

$tun0output = shell_exec("ip link show tun0 2>&1") ?? '';
$tun0up = (strpos($tun0output, 'does not exist') === false && strpos($tun0output, ',UP') !== false);

echo json_encode([
    'state' => $state['STATE'],
    'active_id' => $state['ACTIVE_ID'],
    'primary_id' => $state['PRIMARY_ID'],
    'activated_by' => $state['ACTIVATED_BY'],
    'connected' => $tun0up
], JSON_UNESCAPED_UNICODE);
