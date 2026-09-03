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
require_once __DIR__ . '/../includes/vpn_helpers.php';

$raw = file_get_contents('php://input');
$body = [];
if (!empty($raw)) {
    $decoded = json_decode($raw, true);
    if (is_array($decoded)) $body = $decoded;
}
if (empty($body)) $body = $_POST;

$action    = (string)($body['action'] ?? '');
$configId  = (string)($body['config_id'] ?? '');

function respond(bool $ok, string $message = '', array $data = []): void {
    $out = ['ok' => $ok];
    if ($ok) {
        if ($message) $out['message'] = $message;
        if ($data)    $out['data']    = $data;
    } else {
        $out['error'] = $message;
    }
    echo json_encode($out, JSON_UNESCAPED_UNICODE);
    exit;
}

switch ($action) {

case 'activate':
    if (!vp_isValidConfigId($configId)) respond(false, 'Неверный ID конфига');
    $configs = vp_loadConfigs();
    if (!isset($configs[$configId])) respond(false, 'Конфиг не найден');

    $config     = $configs[$configId];
    $sourceFile = VP_CONFIG_PATH . '/' . $config['filename'];
    if (!file_exists($sourceFile)) respond(false, 'Файл конфига отсутствует');

    $prevState    = vp_readState();
    $prevActiveId = $prevState['ACTIVE_ID'];
    $prevConfig   = ($prevActiveId && isset($configs[$prevActiveId])) ? $configs[$prevActiveId] : null;
    $prevSource   = $prevConfig ? (VP_CONFIG_PATH . '/' . $prevConfig['filename']) : null;
    $canRollback  = $prevActiveId && $prevActiveId !== $configId && $prevSource && file_exists($prevSource);

    vp_saveState('restarting', $prevActiveId, $prevState['PRIMARY_ID'], $prevState['ACTIVATED_BY']);

    vp_stopAllServices();
    sleep(1);
    vp_cleanActiveConfigFiles();

    $copyOk = vp_activateServiceFromFile($sourceFile, $config['type']);
    if (!$copyOk) {
        vp_saveState('stopped', '', $prevState['PRIMARY_ID'], '');
        respond(false, 'Ошибка копирования конфига');
    }

    if (vp_pollVpnUp(15)) {

        uasort($configs, fn($a, $b) => ($a['priority'] ?? 99) - ($b['priority'] ?? 99));
        $newPriority = 2;
        foreach ($configs as $cid => &$c) {
            if ($cid === $configId) {
                $c['role']         = 'primary';
                $c['priority']     = 1;
                $c['last_used']    = date('Y-m-d H:i:s');
                $c['activated_by'] = 'manual';
            } else {
                if (($c['role'] ?? '') === 'primary')          $c['role'] = 'backup';
                if (($c['activated_by'] ?? '') === 'failover') $c['activated_by'] = '';
                $c['priority'] = $newPriority++;
            }
        }
        unset($c);
        vp_saveConfigs($configs);
        vp_saveState('running', $configId, $configId, 'manual');
        vp_logEvent('manual_activate', $configId);
        respond(true, "Конфиг '{$config['name']}' активирован");
    }

    if ($canRollback) {
        vp_stopAllServices();
        sleep(1);
        vp_cleanActiveConfigFiles();
        $rollbackOk = vp_activateServiceFromFile($prevSource, $prevConfig['type']);
        $prevRose = $rollbackOk ? vp_pollVpnUp(10) : false;

        if ($prevRose) {
            vp_saveState('running', $prevActiveId, $prevState['PRIMARY_ID'] ?: $prevActiveId, 'manual');
            vp_logEvent('rollback', $configId, $prevActiveId);
            respond(false, "Конфиг '{$config['name']}' не работает — вернулись на '{$prevConfig['name']}'");
        }
        vp_saveState('stopped', '', $prevState['PRIMARY_ID'], '');
        respond(false, 'Не удалось активировать конфиг, откат тоже не удался — VPN остановлен');
    }

    vp_saveState('stopped', '', $prevState['PRIMARY_ID'], '');
    respond(false, "Конфиг '{$config['name']}' не поднялся за 15 секунд — VPN остановлен");

case 'delete':
    if (!vp_isValidConfigId($configId)) respond(false, 'Неверный ID конфига');
    $configs = vp_loadConfigs();
    if (!isset($configs[$configId])) respond(false, 'Конфиг не найден');

    $vpnState = vp_readState();
    if ($vpnState['ACTIVE_ID'] === $configId) {
        vp_stopAllServices();
        vp_disableAllServices();
        vp_cleanActiveConfigFiles();
        $newPrimary = ($vpnState['PRIMARY_ID'] === $configId) ? '' : $vpnState['PRIMARY_ID'];
        vp_saveState('stopped', '', $newPrimary, '');
    } elseif ($vpnState['PRIMARY_ID'] === $configId) {
        vp_saveState($vpnState['STATE'], $vpnState['ACTIVE_ID'], '', $vpnState['ACTIVATED_BY']);
    }

    $filePath   = VP_CONFIG_PATH . '/' . $configs[$configId]['filename'];
    $nameSnap   = $configs[$configId]['name']   ?? '?';
    $serverSnap = $configs[$configId]['server'] ?? '';
    if (file_exists($filePath)) unlink($filePath);
    unset($configs[$configId]);
    vp_saveConfigs($configs);
    vp_logEvent('config_deleted', $configId, $nameSnap, $serverSnap);

    respond(true, 'Конфигурация удалена');

case 'rename':
    if (!vp_isValidConfigId($configId)) respond(false, 'Неверный ID конфига');
    $newName = vp_safeSubstr(trim((string)($body['new_name'] ?? '')), 0, VP_MAX_CONFIG_NAME);
    if (empty($newName)) respond(false, 'Название не может быть пустым');

    $configs = vp_loadConfigs();
    if (!isset($configs[$configId])) respond(false, 'Конфиг не найден');

    $oldName = $configs[$configId]['name'] ?? '?';
    $configs[$configId]['name'] = $newName;
    vp_saveConfigs($configs);
    vp_logEvent('config_renamed', $configId, $oldName, $newName);

    respond(true, 'Конфигурация переименована', ['new_name' => $newName]);

case 'move':
    if (!vp_isValidConfigId($configId)) respond(false, 'Неверный ID конфига');
    $direction = ($body['direction'] ?? '');
    if (!in_array($direction, ['up', 'down'], true)) respond(false, 'Неверное направление');

    $configs = vp_loadConfigs();
    if (!isset($configs[$configId])) respond(false, 'Конфиг не найден');

    uasort($configs, fn($a, $b) => ($a['priority'] ?? 99) - ($b['priority'] ?? 99));
    $ids = array_keys($configs);
    $currentIndex = array_search($configId, $ids);

    if ($direction === 'up' && $currentIndex > 0) {
        $swapId = $ids[$currentIndex - 1];
        [$configs[$configId]['priority'], $configs[$swapId]['priority']] =
        [$configs[$swapId]['priority'],   $configs[$configId]['priority']];
        vp_saveConfigs($configs);
    } elseif ($direction === 'down' && $currentIndex < count($ids) - 1) {
        $swapId = $ids[$currentIndex + 1];
        [$configs[$configId]['priority'], $configs[$swapId]['priority']] =
        [$configs[$swapId]['priority'],   $configs[$configId]['priority']];
        vp_saveConfigs($configs);
    }

    respond(true);

case 'reorder':
    $order = $body['order'] ?? [];
    if (!is_array($order) || empty($order)) respond(false, 'Пустой порядок');

    foreach ($order as $id) {
        if (!vp_isValidConfigId((string)$id)) respond(false, 'Неверный ID в порядке');
    }

    $configs = vp_loadConfigs();
    $priority = 1;
    foreach ($order as $id) {
        if (isset($configs[$id])) {
            $configs[$id]['priority'] = $priority++;
        }
    }
    vp_saveConfigs($configs);
    respond(true);

case 'toggle_role':
    if (!vp_isValidConfigId($configId)) respond(false, 'Неверный ID конфига');
    $configs  = vp_loadConfigs();
    $vpnState = vp_readState();
    if (!isset($configs[$configId])) respond(false, 'Конфиг не найден');

    $currentRole = $configs[$configId]['role'] ?? 'none';
    if ($currentRole === 'primary' || $configId === $vpnState['ACTIVE_ID']) {
        respond(false, 'Нельзя изменить роль активного конфига');
    }
    $newRole = ($currentRole === 'backup') ? 'none' : 'backup';
    $configs[$configId]['role'] = $newRole;
    vp_saveConfigs($configs);
    vp_logEvent('role_changed', $configId, $newRole);

    $roleName = $newRole === 'backup' ? 'резервный' : 'не участвует';
    respond(true, "'{$configs[$configId]['name']}' — {$roleName}", ['role' => $newRole]);

case 'stop':
    $vpnState  = vp_readState();
    $stoppedId = $vpnState['ACTIVE_ID'];
    vp_saveState('stopped', $vpnState['ACTIVE_ID'], $vpnState['PRIMARY_ID'], $vpnState['ACTIVATED_BY']);

    vp_stopAllServices();
    vp_disableAllServices();
    vp_cleanActiveConfigFiles();
    sleep(2);
    if ($stoppedId) vp_logEvent('vpn_stopped', $stoppedId);
    respond(true, 'VPN остановлен');

case 'restart':
    $activeConfig = vp_getActiveConfig();
    if (!$activeConfig) respond(false, 'Нет активного конфига для перезапуска');

    $vpnState = vp_readState();
    vp_saveState('restarting', $vpnState['ACTIVE_ID'], $vpnState['PRIMARY_ID'], $vpnState['ACTIVATED_BY']);

    if ($activeConfig['type'] === 'wireguard') {
        shell_exec('sudo systemctl restart wg-quick@tun0');
    } else {
        shell_exec('sudo systemctl restart openvpn@tun0');
    }
    sleep(3);

    if (vp_checkVPNStatus()) {
        vp_saveState('running', $vpnState['ACTIVE_ID'], $vpnState['PRIMARY_ID'], $vpnState['ACTIVATED_BY']);
        if (!empty($vpnState['ACTIVE_ID'])) vp_logEvent('vpn_restarted', $vpnState['ACTIVE_ID']);
        respond(true, 'VPN перезапущен');
    }
    vp_saveState('recovering', $vpnState['ACTIVE_ID'], $vpnState['PRIMARY_ID'], $vpnState['ACTIVATED_BY']);
    respond(false, 'VPN не поднялся, автовосстановление...');

case 'bulk_delete':
    $ids = $body['ids'] ?? [];
    if (!is_array($ids) || empty($ids)) respond(false, 'Пустой список для удаления');
    foreach ($ids as $id) {
        if (!vp_isValidConfigId((string)$id)) respond(false, 'Неверный ID в списке');
    }

    $configs  = vp_loadConfigs();
    $vpnState = vp_readState();
    $activeId = $vpnState['ACTIVE_ID'];
    $deleted  = [];
    $skipped  = [];

    foreach ($ids as $id) {
        if (!isset($configs[$id])) { $skipped[] = $id; continue; }
        if ($id === $activeId) {

            $skipped[] = $id;
            continue;
        }
        $filePath = VP_CONFIG_PATH . '/' . $configs[$id]['filename'];
        $nameSnap   = $configs[$id]['name']   ?? '?';
        $serverSnap = $configs[$id]['server'] ?? '';
        if (file_exists($filePath)) unlink($filePath);
        if ($vpnState['PRIMARY_ID'] === $id) {
            vp_saveState($vpnState['STATE'], $vpnState['ACTIVE_ID'], '', $vpnState['ACTIVATED_BY']);
            $vpnState['PRIMARY_ID'] = '';
        }
        unset($configs[$id]);
        vp_logEvent('config_deleted', $id, $nameSnap, $serverSnap);
        $deleted[] = $id;
    }
    vp_saveConfigs($configs);

    $msg = 'Удалено: ' . count($deleted);
    if (!empty($skipped)) $msg .= ' (пропущено активный: ' . count($skipped) . ')';
    respond(true, $msg, ['deleted' => $deleted, 'skipped' => $skipped]);

case 'status':
    $state    = vp_readState();
    $isUp     = vp_checkVPNStatus();
    respond(true, '', [
        'state'        => $state['STATE'],
        'active_id'    => $state['ACTIVE_ID'],
        'primary_id'   => $state['PRIMARY_ID'],
        'activated_by' => $state['ACTIVATED_BY'],
        'connected'    => $isUp,
    ]);

default:
    respond(false, 'Неизвестное действие: ' . $action);
}
