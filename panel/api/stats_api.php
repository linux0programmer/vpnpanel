<?php
require_once __DIR__ . '/../includes/guard.php';
vp_requireSession(true);
vp_requireCsrf(true);
header('Content-Type: application/json; charset=utf-8');

function safe_exec($cmd) {
    $output = [];
    $result = 0;
    exec($cmd . ' 2>/dev/null', $output, $result);
    return implode("\n", $output);
}

function getCpuUsage() {
    $cores = (int)safe_exec("nproc");
    if ($cores < 1) $cores = 1;
    $load = sys_getloadavg();

    $cacheFile = '/tmp/vpn-panel_cpu_cache';
    $percent = 0;

    $statLine = @file_get_contents('/proc/stat');
    if ($statLine) {

        if (preg_match('/^cpu\s+(.+)/m', $statLine, $rawMatch)) {
            $fields = preg_split('/\s+/', trim($rawMatch[1]));

            $idle = (float)($fields[3] ?? 0) + (float)($fields[4] ?? 0);
            $total = 0;
            foreach ($fields as $f) $total += (float)$f;

            $now = microtime(true);

            if (file_exists($cacheFile)) {
                $prev = json_decode(@file_get_contents($cacheFile), true);
                if ($prev && isset($prev['idle']) && isset($prev['total'])) {
                    $dIdle = $idle - $prev['idle'];
                    $dTotal = $total - $prev['total'];
                    if ($dTotal > 0) {
                        $percent = round((1 - $dIdle / $dTotal) * 100, 1);
                        if ($percent < 0) $percent = 0;
                        if ($percent > 100) $percent = 100;
                    }
                }
            }

            $tmp = $cacheFile . '.tmp';
            file_put_contents($tmp, json_encode(['idle' => $idle, 'total' => $total, 'time' => $now]));
            rename($tmp, $cacheFile);
        }
    }

    return [
        'percent' => $percent,
        'load_1' => round($load[0], 2),
        'load_5' => round($load[1], 2),
        'load_15' => round($load[2], 2),
        'cores' => $cores
    ];
}

function getMemoryUsage() {

    $meminfo = @file_get_contents('/proc/meminfo');
    if ($meminfo) {
        $vals = [];
        preg_match_all('/^(\w+):\s+(\d+)/m', $meminfo, $matches, PREG_SET_ORDER);
        foreach ($matches as $m) $vals[$m[1]] = (float)$m[2] * 1024;

        $total     = $vals['MemTotal']     ?? 0;
        $available = $vals['MemAvailable'] ?? ($vals['MemFree'] ?? 0);
        $used      = $total - $available;

        if ($total > 0) {
            return [
                'total'     => $total,
                'used'      => $used,
                'available' => $available,
                'percent'   => round(($used / $total) * 100, 1),
                'total_gb'  => round($total / 1073741824, 2),
                'used_gb'   => round($used  / 1073741824, 2),
            ];
        }
    }
    return ['percent' => 0, 'total_gb' => 0, 'used_gb' => 0, 'total' => 0, 'used' => 0, 'available' => 0];
}

function getDiskUsage() {
    $total = @disk_total_space('/');
    $free  = @disk_free_space('/');

    if ($total === false || $free === false || $total <= 0) {
        return ['percent' => 0, 'total_gb' => 0, 'used_gb' => 0, 'free_gb' => 0,
                'total' => 0, 'used' => 0, 'free' => 0];
    }

    $used = $total - $free;
    return [
        'total'    => $total,
        'used'     => $used,
        'free'     => $free,
        'percent'  => round(($used / $total) * 100, 1),
        'total_gb' => round($total / 1073741824, 2),
        'used_gb'  => round($used  / 1073741824, 2),
        'free_gb'  => round($free  / 1073741824, 2),
    ];
}

function getActiveInterfaces() {
    static $cache = null;
    if ($cache !== null) return $cache;
    $list = [];
    foreach (scandir('/sys/class/net') as $iface) {
        if ($iface === '.' || $iface === '..' || $iface === 'lo') continue;
        if (preg_match('/^(docker|veth|br-)/', $iface)) continue;
        $list[] = $iface;
    }
    $cache = $list;
    return $list;
}

function getNetworkStats() {
    $interfaces = [];
    $iflist = getActiveInterfaces();

    foreach ($iflist as $iface) {
        $rx_file = "/sys/class/net/$iface/statistics/rx_bytes";
        $tx_file = "/sys/class/net/$iface/statistics/tx_bytes";

        if (file_exists($rx_file) && file_exists($tx_file)) {
            $rx = (float)trim(file_get_contents($rx_file));
            $tx = (float)trim(file_get_contents($tx_file));

            $interfaces[$iface] = [
                'rx_bytes' => $rx,
                'tx_bytes' => $tx,
                'rx_human' => formatBytes($rx),
                'tx_human' => formatBytes($tx),
                'total_bytes' => $rx + $tx,
                'total_human' => formatBytes($rx + $tx)
            ];
        }
    }

    return $interfaces;
}

function formatBytes($bytes, $precision = 2) {
    $units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];

    $bytes = max($bytes, 0);
    $pow = floor(($bytes ? log($bytes) : 0) / log(1024));
    $pow = min($pow, count($units) - 1);

    $bytes /= pow(1024, $pow);

    return round($bytes, $precision) . ' ' . $units[$pow];
}

function getUptime() {
    $uptime = (float)trim(file_get_contents('/proc/uptime'));
    $uptime = explode(' ', $uptime)[0];

    $days = floor($uptime / 86400);
    $hours = floor(($uptime % 86400) / 3600);
    $minutes = floor(($uptime % 3600) / 60);
    $seconds = floor($uptime % 60);

    $parts = [];
    if ($days > 0) $parts[] = $days . 'д';
    if ($hours > 0) $parts[] = $hours . 'ч';
    if ($minutes > 0) $parts[] = $minutes . 'м';
    if (empty($parts)) $parts[] = $seconds . 'с';

    return [
        'seconds' => (float)$uptime,
        'human' => implode(' ', $parts),
        'days' => $days,
        'hours' => $hours,
        'minutes' => $minutes
    ];
}

function getCurrentVpnConfig() {

    if (file_exists('/etc/wireguard/tun0.conf')) {
        $content = @file_get_contents('/etc/wireguard/tun0.conf');
        if (preg_match('/^#\s*Name:\s*(.+)$/m', $content, $m)) {
            return ['type' => 'WireGuard', 'name' => trim($m[1])];
        }
        if (preg_match('/Endpoint\s*=\s*([^:]+)/', $content, $m)) {
            return ['type' => 'WireGuard', 'name' => trim($m[1])];
        }
        return ['type' => 'WireGuard', 'name' => 'tun0'];
    }

    if (file_exists('/etc/openvpn/tun0.conf')) {
        $content = @file_get_contents('/etc/openvpn/tun0.conf');
        if (preg_match('/^#\s*Name:\s*(.+)$/m', $content, $m)) {
            return ['type' => 'OpenVPN', 'name' => trim($m[1])];
        }
        if (preg_match('/remote\s+(\S+)/', $content, $m)) {
            return ['type' => 'OpenVPN', 'name' => trim($m[1])];
        }
        return ['type' => 'OpenVPN', 'name' => 'tun0'];
    }

    return ['type' => 'none', 'name' => 'Не настроен'];
}

function getVpnStatus() {
    $interface = file_exists('/sys/class/net/tun0') ? 'tun0' : null;

    if ($interface) {
        $state = trim(safe_exec("cat /sys/class/net/$interface/operstate"));
        $ip = trim(safe_exec("ip -4 addr show $interface | grep -oP '(?<=inet\\s)\\d+(\\.\\d+){3}'"));

        $reallyActive = false;
        if ($state === 'up') {
            $reallyActive = true;
        } elseif ($state === 'unknown') {

            $handshake = trim(safe_exec("wg show $interface latest-handshakes 2>/dev/null | awk '{print \$2}'"));
            if (!empty($handshake) && is_numeric($handshake) && $handshake > 0) {
                $reallyActive = (time() - (int)$handshake) < 180;
            } else {

                $reallyActive = (bool)trim(@file_get_contents("/sys/class/net/{$interface}/operstate") ?: '');

                $ip = trim(safe_exec("ip -4 addr show $interface 2>/dev/null | grep -oP '(?<=inet\\s)\\d+(\\.\\d+){3}'"));
                $reallyActive = !empty($ip);
            }
        }

        return [
            'active' => $reallyActive,
            'interface' => $interface,
            'state' => $state,
            'ip' => $ip ?: 'N/A'
        ];
    }

    return ['active' => false, 'interface' => null, 'state' => 'down', 'ip' => 'N/A'];
}

function getVpnHistory() {
    $eventsFile  = '/var/log/vpn-panel/events.log';
    $configsFile = '/var/www/vpn-configs/configs.json';
    $stateFile   = '/var/www/vpn-state';

    $configs = [];
    if (file_exists($configsFile)) {
        $configs = json_decode(file_get_contents($configsFile), true) ?: [];
    }

    $cfgLabel = function($cfgId, $nameOverride = null, $serverOverride = null) use ($configs) {
        if (!$cfgId && !$nameOverride) return 'неизвестный конфиг';
        $c = $configs[$cfgId] ?? null;
        $name   = $nameOverride   ?? ($c['name']   ?? $cfgId);
        $server = $serverOverride ?? ($c['server'] ?? '');
        return $server ? "$name ($server)" : $name;
    };

    $translateReason = function($raw) {
        $map = [
            'No connectivity'    => 'нет связи',
            'No IP'              => 'нет IP',
            'Interface lost'     => 'интерфейс пропал',
            'WG fwmark rule lost'=> 'WG маршрут потерян',
            'OVPN routes lost'   => 'маршруты потеряны',
            'iptables rules lost'=> 'сброс iptables',
            'restart'            => 'перезапуск',
            'VPN unreachable after WAN recovery' => 'VPN-сервер недоступен после возвращения интернета',
        ];
        if (isset($map[$raw])) return $map[$raw];
        if (strpos($raw, 'IP leak') === 0) return 'утечка IP';
        return $raw ?: 'неизвестно';
    };

    $style = function($kind) {
        static $s = [
            'success'    => ['icon' => '✅', 'badge' => 'OK',             'color' => 'green'],
            'activate'   => ['icon' => '⚡', 'badge' => 'Активация',     'color' => 'green'],
            'failover'   => ['icon' => '🔄', 'badge' => 'Резерв',         'color' => 'yellow'],
            'restore'    => ['icon' => '↩️',  'badge' => 'Восстановлен',  'color' => 'green'],
            'rollback'   => ['icon' => '↪️',  'badge' => 'Откат',          'color' => 'orange'],
            'stop'       => ['icon' => '⏹️',  'badge' => 'Остановлен',    'color' => 'slate'],
            'restart'    => ['icon' => '🔄', 'badge' => 'Перезапуск',    'color' => 'blue'],
            'down'       => ['icon' => '⚠️',  'badge' => 'Проблема',      'color' => 'red'],
            'recovery'   => ['icon' => '🔧', 'badge' => 'Восстановление', 'color' => 'yellow'],
            'recovered'  => ['icon' => '✅', 'badge' => 'Восстановлен',  'color' => 'green'],
            'firewall'   => ['icon' => '🛡️',  'badge' => 'Защита',         'color' => 'green'],
            'failed'     => ['icon' => '❌', 'badge' => 'Неудача',        'color' => 'red'],
            'added'      => ['icon' => '➕', 'badge' => 'Добавлен',       'color' => 'blue'],
            'deleted'    => ['icon' => '🗑️', 'badge' => 'Удалён',         'color' => 'slate'],
            'renamed'    => ['icon' => '✏️',  'badge' => 'Переименован',  'color' => 'slate'],
            'role'       => ['icon' => '🔗', 'badge' => 'Резерв',         'color' => 'blue'],
            'isp_down'   => ['icon' => '🌐', 'badge' => 'Интернет',       'color' => 'purple'],
            'isp_ok'     => ['icon' => '🌐', 'badge' => 'Интернет',       'color' => 'green'],
            'wan_switch' => ['icon' => '🔀', 'badge' => 'Канал',          'color' => 'orange'],
            'update_ok'  => ['icon' => '⬆️',  'badge' => 'Обновление',     'color' => 'blue'],
            'update_bad' => ['icon' => '↩️',  'badge' => 'Откат',          'color' => 'red'],
            'sys_reboot' => ['icon' => '🔄', 'badge' => 'Перезагрузка',   'color' => 'blue'],
            'sys_off'    => ['icon' => '⏻',  'badge' => 'Выключение',     'color' => 'slate'],
            'other'      => ['icon' => '•',  'badge' => '',                'color' => 'slate'],
        ];
        return $s[$kind] ?? $s['other'];
    };

    $rawEvents = [];
    if (file_exists($eventsFile)) {
        $lines = @file($eventsFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
        foreach ($lines as $line) {
            $parts = explode('|', $line);
            if (count($parts) < 2) continue;
            $rawEvents[] = $parts;
        }
    }

    $events = [];
    $activations = [];
    $lastClearedTime = null;

    foreach ($rawEvents as $p) {
        $time = $p[0] ?? '';
        $type = $p[1] ?? '';
        $f1 = $p[2] ?? ''; $f2 = $p[3] ?? ''; $f3 = $p[4] ?? '';

        $kind = 'other'; $text = '';

        switch ($type) {

            case 'auto_start':
                $kind = 'activate';
                $text = "Автоматически запущен " . $cfgLabel($f1);
                $activations[] = ['time' => $time, 'cfg' => $f1];
                break;

            case 'failover':

                $kind = 'failover';
                $text = "Активирован резерв " . $cfgLabel($f1)
                      . " вместо основного " . $cfgLabel($f2)
                      . ". Причина: " . $translateReason($f3);
                $activations[] = ['time' => $time, 'cfg' => $f1];
                break;

            case 'failover_restored':
                $kind = 'restore';
                $text = "Возвращение на основной " . $cfgLabel($f1);
                $activations[] = ['time' => $time, 'cfg' => $f1];
                break;

            case 'vpn_down':
                $kind = 'down';
                $text = "VPN " . $cfgLabel($f1) . " потерял связь (" . $translateReason($f2) . ")";
                break;

            case 'recovery_attempt':
                $kind = 'recovery';
                $text = "Попытка восстановить " . $cfgLabel($f1) . ". Причина: " . $translateReason($f2);
                break;

            case 'recovery_succeeded':

                $kind = 'recovered';
                $text = "VPN " . $cfgLabel($f1) . " восстановлен после перезапуска";
                break;

            case 'firewall_restored':

                $kind = 'firewall';
                $text = "Защита от утечек восстановлена автоматически";
                break;

            case 'recovery_failed':
                $kind = 'failed';
                $text = "Восстановление не удалось: " . $translateReason($f1);
                break;

            case 'update_started':
                $kind = 'update_ok';
                $text = "Начато обновление до " . ($f1 !== '' ? $f1 : 'новой версии');
                break;

            case 'update_ok':
                $kind = 'update_ok';
                $text = "Обновление установлено: " . ($f1 !== '' ? $f1 : 'новая версия')
                      . ($f2 !== '' ? " ($f2)" : '');
                break;

            case 'update_failed':
                $kind = 'update_bad';
                $text = "Обновление не удалось на шаге «" . ($f2 !== '' ? $f2 : 'неизвестно') . "»";
                break;

            case 'update_rollback':
                $kind = 'update_bad';
                $reasons = [
                    'migrations'  => 'миграции завершились с ошибкой',
                    'healthcheck' => 'проверка после обновления провалена',
                    'manual'      => 'запрошен вручную',
                ];
                $why = $reasons[$f2] ?? ($f2 !== '' ? $f2 : 'причина неизвестна');
                $text = "Откат на предыдущую версию: $why";
                break;

            case 'wan_switch':
                $kind = 'wan_switch';
                $from = $f1 !== '' ? $f1 : 'неизвестно';
                $to   = $f2 !== '' ? $f2 : 'неизвестно';
                $text = "Переключение канала: $from → $to";
                break;

            case 'isp_down':

                $kind = 'isp_down';
                $text = "Пропал интернет провайдера — VPN не трогаем, ждём возвращения";
                break;

            case 'isp_restored':

                $kind = 'isp_ok';
                $dur = (int)$f1;
                if ($dur > 0) {
                    $durText = $dur < 60 ? "{$dur} сек" : (($dur < 3600) ? round($dur / 60) . " мин" : round($dur / 3600, 1) . " ч");
                    $text = "Интернет провайдера восстановлен (отсутствовал $durText)";
                } else {
                    $text = "Интернет провайдера восстановлен";
                }
                break;

            case 'system':

                if ($f1 === 'reboot') {
                    $kind = 'sys_reboot';
                    $text = ($f2 === 'panel') ? "Сервер перезапущен из панели" : "Сервер перезапущен";
                } elseif ($f1 === 'poweroff') {
                    $kind = 'sys_off';
                    $text = ($f2 === 'panel') ? "Сервер выключен из панели" : "Сервер выключен";
                } else {
                    continue 2;
                }
                break;

            case 'manual_activate':
                $kind = 'activate';
                $text = "Конфиг " . $cfgLabel($f1) . " активирован вручную";
                $activations[] = ['time' => $time, 'cfg' => $f1];
                break;

            case 'rollback':

                $kind = 'rollback';
                $text = "Конфиг " . $cfgLabel($f1) . " не заработал — возврат на " . $cfgLabel($f2);
                $activations[] = ['time' => $time, 'cfg' => $f2];
                break;

            case 'vpn_stopped':
                $kind = 'stop';
                $text = "Конфиг " . $cfgLabel($f1) . " остановлен пользователем";
                break;

            case 'vpn_restarted':
                $kind = 'restart';
                $text = "Конфиг " . $cfgLabel($f1) . " перезапущен пользователем";
                break;

            case 'config_added':
                $kind = 'added';
                $text = "Добавлен новый конфиг " . $cfgLabel($f1);
                break;

            case 'config_deleted':

                $kind = 'deleted';
                $text = "Конфиг " . $cfgLabel($f1, $f2, $f3) . " удалён";
                break;

            case 'config_renamed':

                $kind = 'renamed';
                $text = "Конфиг «" . ($f2 ?: '?') . "» переименован в «" . ($f3 ?: '?') . "»";
                break;

            case 'role_changed':

                $kind = 'role';
                if ($f2 === 'backup') {
                    $text = "Конфиг " . $cfgLabel($f1) . " добавлен в резерв";
                } else {
                    $text = "Конфиг " . $cfgLabel($f1) . " убран из резерва";
                }
                break;

            case 'events_cleared':

                $kind = 'other';
                $text = 'Журнал событий очищен пользователем';

                $t = strtotime($time);
                if ($t !== false) $lastClearedTime = $t;
                break;

            case 'disconnect':
                $kind = 'down';

                $text = "VPN потерял связь (" . $translateReason($f1) . ")";
                break;

            case 'config_change':

                $kind = ($f2 === 'failover') ? 'failover' : 'activate';
                $prefix = ($f2 === 'failover') ? 'Активирован резерв ' : 'Активирован ';
                $text = $prefix . $cfgLabel($f1);
                $activations[] = ['time' => $time, 'cfg' => $f1];
                break;

            default:

                continue 2;
        }

        $st = $style($kind);
        $events[] = [
            'time'        => $time,
            'kind'        => $kind,
            'text'        => $text,
            'icon'        => $st['icon'],
            'badge'       => $st['badge'],
            'badge_color' => $st['color'],
        ];
    }

    $events = array_slice($events, -200);

    $stats = [];
    $prevCfg = null; $prevTime = null;
    foreach ($activations as $a) {
        $curTime = strtotime($a['time']);
        if ($curTime === false) continue;

        if ($prevCfg !== null && $prevTime !== null) {
            $duration = $curTime - $prevTime;
            if ($duration > 0 && $duration < 86400) {
                if (!isset($stats[$prevCfg])) $stats[$prevCfg] = ['total_seconds' => 0, 'sessions' => 0];
                $stats[$prevCfg]['total_seconds'] += $duration;
            }
        }
        if (!isset($stats[$a['cfg']])) $stats[$a['cfg']] = ['total_seconds' => 0, 'sessions' => 0];
        $stats[$a['cfg']]['sessions']++;

        $prevCfg = $a['cfg'];
        $prevTime = $curTime;
    }

    $state = [];
    if (file_exists($stateFile)) {
        $allowed = ['STATE', 'ACTIVE_ID', 'PRIMARY_ID', 'ACTIVATED_BY'];
        $stateLines = @file($stateFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
        foreach ($stateLines as $line) {
            if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && in_array($m[1], $allowed, true)) {
                $state[$m[1]] = $m[2];
            }
        }
    }
    $activeId = $state['ACTIVE_ID'] ?? '';
    $vpnState = $state['STATE'] ?? 'stopped';

    if ($prevCfg === null && $activeId && $vpnState === 'running' && $lastClearedTime) {
        $prevCfg  = $activeId;
        $prevTime = $lastClearedTime;
        if (!isset($stats[$activeId])) $stats[$activeId] = ['total_seconds' => 0, 'sessions' => 0];
        $stats[$activeId]['sessions']++;
    }

    if ($activeId && $vpnState === 'running' && $prevCfg === $activeId && $prevTime) {
        $sessionSeconds = time() - $prevTime;
        if ($sessionSeconds > 0 && $sessionSeconds < 86400 * 7) {
            if (!isset($stats[$activeId])) $stats[$activeId] = ['total_seconds' => 0, 'sessions' => 0];
            $stats[$activeId]['total_seconds'] += $sessionSeconds;
            $stats[$activeId]['current_session'] = $sessionSeconds;
        }
    }

    $resolved = [];
    foreach ($stats as $id => $s) {
        if (isset($configs[$id]['name'])) {
            $resolved[$configs[$id]['name']] = $s;
        }
    }

    return [
        'events'       => $events,
        'config_stats' => $resolved,
    ];
}

function getLastDisconnection() {
    $logFile = '/var/log/vpn-panel/vpn.log';
    $lastDisconnect = null;

    if (!file_exists($logFile)) {
        return ['timestamp' => null, 'ago_human' => 'Нет данных'];
    }

    $fp = @fopen($logFile, 'rb');
    if (!$fp) {
        return ['timestamp' => null, 'ago_human' => 'Нет данных'];
    }

    $chunkSize = 8192;
    fseek($fp, 0, SEEK_END);
    $fileSize = ftell($fp);
    $pos      = $fileSize;
    $buffer   = '';
    $found    = null;

    while ($pos > 0 && $found === null) {
        $readSize = min($chunkSize, $pos);
        $pos -= $readSize;
        fseek($fp, $pos);
        $buffer = fread($fp, $readSize) . $buffer;

        if (strlen($buffer) > 102400) $buffer = substr($buffer, -102400);

        $lines = explode("\n", $buffer);

        for ($i = count($lines) - 1; $i >= 0; $i--) {
            $line = $lines[$i];
            if (strpos($line, 'WARN') !== false || strpos($line, 'CRIT') !== false) {
                if (preg_match('/\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]/', $line, $m)) {
                    $found = $m[1];
                    break;
                }
            }
        }
    }
    fclose($fp);

    if ($found) {
        $timestamp = strtotime($found);
        $diff = time() - $timestamp;
        return [
            'timestamp'   => $found,
            'ago_seconds' => $diff,
            'ago_human'   => formatTimeDiff($diff),
        ];
    }

    return ['timestamp' => null, 'ago_human' => 'Нет данных'];
}

function formatTimeDiff($seconds) {
    if ($seconds < 60) return $seconds . ' сек назад';
    if ($seconds < 3600) return floor($seconds / 60) . ' мин назад';
    if ($seconds < 86400) return floor($seconds / 3600) . ' ч назад';
    return floor($seconds / 86400) . ' дн назад';
}

function getServerTime() {
    return [
        'timestamp' => time(),
        'datetime' => date('Y-m-d H:i:s'),
        'timezone' => date_default_timezone_get()
    ];
}

function getBandwidth() {
    $cacheFile = '/tmp/vpn-panel_bandwidth_cache';
    $now = microtime(true);

    $currentStats = [];
    $interfaces = getActiveInterfaces();

    foreach ($interfaces as $iface) {
        $rx_file = "/sys/class/net/$iface/statistics/rx_bytes";
        $tx_file = "/sys/class/net/$iface/statistics/tx_bytes";

        if (file_exists($rx_file)) {
            $currentStats[$iface] = [
                'rx' => (float)trim(file_get_contents($rx_file)),
                'tx' => (float)trim(file_get_contents($tx_file)),
                'time' => $now
            ];
        }
    }

    $bandwidth = [];

    if (file_exists($cacheFile)) {
        $prevData = json_decode(file_get_contents($cacheFile), true);

        if ($prevData && isset($prevData['stats'])) {
            foreach ($currentStats as $iface => $current) {
                if (isset($prevData['stats'][$iface])) {
                    $prev = $prevData['stats'][$iface];
                    $timeDiff = $current['time'] - $prev['time'];

                    if ($timeDiff > 0) {
                        $rxSpeed = ($current['rx'] - $prev['rx']) / $timeDiff;
                        $txSpeed = ($current['tx'] - $prev['tx']) / $timeDiff;

                        if ($rxSpeed < 0) $rxSpeed = 0;
                        if ($txSpeed < 0) $txSpeed = 0;

                        $bandwidth[$iface] = [
                            'rx_speed' => $rxSpeed,
                            'tx_speed' => $txSpeed,
                            'rx_speed_human' => formatBytes($rxSpeed) . '/с',
                            'tx_speed_human' => formatBytes($txSpeed) . '/с'
                        ];
                    }
                }
            }
        }
    }

    $tmp = $cacheFile . '.tmp';
    file_put_contents($tmp, json_encode(['stats' => $currentStats, 'time' => $now]));
    rename($tmp, $cacheFile);

    return $bandwidth;
}

$action = $_GET['action'] ?? 'all';

switch ($action) {

    case 'clear_events':
        if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
            http_response_code(405);
            echo json_encode(['ok' => false, 'error' => 'Method not allowed']);
            break;
        }
        $eventsFile = '/var/log/vpn-panel/events.log';

        if (!file_exists($eventsFile)) {

            echo json_encode(['ok' => true, 'message' => 'Журнал событий уже пуст']);
            break;
        }

        $truncated = @file_put_contents($eventsFile, '', LOCK_EX);
        if ($truncated === false) {
            http_response_code(500);
            echo json_encode(['ok' => false, 'error' => 'Не удалось очистить журнал (права доступа?)']);
            break;
        }

        $line = date('Y-m-d H:i:s') . '|events_cleared' . "\n";
        @file_put_contents($eventsFile, $line, FILE_APPEND | LOCK_EX);
        echo json_encode(['ok' => true, 'message' => 'Журнал событий очищен']);
        break;

    case 'cpu':
        echo json_encode(getCpuUsage());
        break;
    case 'memory':
        echo json_encode(getMemoryUsage());
        break;
    case 'disk':
        echo json_encode(getDiskUsage());
        break;
    case 'network':
        echo json_encode(getNetworkStats());
        break;
    case 'bandwidth':
        echo json_encode(getBandwidth());
        break;
    case 'uptime':
        echo json_encode(getUptime());
        break;
    case 'vpn':
        echo json_encode([
            'status' => getVpnStatus(),
            'config' => getCurrentVpnConfig()
        ]);
        break;
    case 'history':
        echo json_encode(getVpnHistory());
        break;

    case 'live':
        echo json_encode([
            'cpu'         => getCpuUsage(),
            'memory'      => getMemoryUsage(),
            'disk'        => getDiskUsage(),
            'network'     => getNetworkStats(),
            'bandwidth'   => getBandwidth(),
            'server_time' => getServerTime(),
            'vpn'         => [
                'status' => getVpnStatus(),
                'config' => getCurrentVpnConfig(),
            ],
        ]);
        break;

    case 'slow':

        $mtimes = array_filter([
            @filemtime('/var/log/vpn-panel/events.log'),
            @filemtime('/var/log/vpn-panel/vpn.log'),
        ]);
        $lastMtime = $mtimes ? max($mtimes) : time();

        $ifMod = $_SERVER['HTTP_IF_MODIFIED_SINCE'] ?? '';
        if ($ifMod) {
            $ifModTs = strtotime($ifMod);

            if ($ifModTs !== false && $ifModTs >= $lastMtime) {
                http_response_code(304);
                exit;
            }
        }

        header('Last-Modified: ' . gmdate('D, d M Y H:i:s', $lastMtime) . ' GMT');
        header('Cache-Control: private, must-revalidate');

        $history = getVpnHistory();
        $eventsAll = $history['events'] ?? [];
        $totalEvents = count($eventsAll);

        $offset = isset($_GET['events_offset']) ? max(0, (int)$_GET['events_offset']) : 0;
        $limit  = isset($_GET['events_limit'])  ? max(1, min(100, (int)$_GET['events_limit'])) : 20;

        $eventsReversed = array_reverse($eventsAll);
        $eventsSlice    = array_slice($eventsReversed, $offset, $limit);

        echo json_encode([
            'uptime'             => getUptime(),
            'last_disconnection' => getLastDisconnection(),
            'events'             => $eventsSlice,
            'events_total'       => $totalEvents,
            'events_offset'      => $offset,
            'events_limit'       => $limit,
            'events_has_more'    => ($offset + $limit) < $totalEvents,
            'config_stats'       => $history['config_stats'] ?? [],
        ]);
        break;

    case 'all':
    default:
        echo json_encode([
            'cpu' => getCpuUsage(),
            'memory' => getMemoryUsage(),
            'disk' => getDiskUsage(),
            'network' => getNetworkStats(),
            'bandwidth' => getBandwidth(),
            'uptime' => getUptime(),
            'server_time' => getServerTime(),
            'vpn' => [
                'status' => getVpnStatus(),
                'config' => getCurrentVpnConfig()
            ],
            'last_disconnection' => getLastDisconnection(),
            'history' => getVpnHistory()
        ]);
        break;
}
