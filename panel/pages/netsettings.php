<?php

require_once __DIR__ . '/../includes/vpn_helpers.php';
require_once __DIR__ . '/../includes/guard.php';

if (!isset($_SESSION["authenticated"]) || $_SESSION["authenticated"] !== true) {
    header("Location: login.php");
    exit();
}

$netsettingsAssetsVer = '6.5.0';

$netplanDir   = '/etc/netplan/';
$yamlFilePath = null;

if (is_dir($netplanDir)) {
    $files = glob($netplanDir . '*.yaml') ?: glob($netplanDir . '*.yml') ?: [];
    if (!empty($files)) {
        foreach ($files as $file) {
            if (strpos($file, 'vpn-panel') !== false) { $yamlFilePath = $file; break; }
        }
        if (!$yamlFilePath) $yamlFilePath = $files[0];
    }
}

if (!$yamlFilePath || !file_exists($yamlFilePath)) {
    ?>
    <link rel="stylesheet" href="assets/css/pages/netsettings.css?v=<?php echo $netsettingsAssetsVer; ?>">
    <div class="card card--accent-rose">
        <div class="empty-state">
            <div class="empty-state-title text-rose">Файл конфигурации сети не найден</div>
            <div class="empty-state-text">
                Не удалось найти netplan-файл в директории
                <code class="mono">/etc/netplan/</code>
            </div>
        </div>
    </div>
    <?php
    return;
}

function readYamlFile(string $filePath): ?array {
    if (!file_exists($filePath)) return null;
    return yaml_parse_file($filePath) ?: null;
}

function netplanFiles(string $dir): array {
    $files = array_merge(glob($dir . '*.yaml') ?: [], glob($dir . '*.yml') ?: []);
    sort($files);
    return $files;
}

function readAllNetplanEthernets(string $dir): array {
    $merged = [];

    $dump = vp_routing('netplan-dump');
    if (trim($dump) !== '') {
        $parsed = @yaml_parse($dump);
        if (is_array($parsed) && !empty($parsed['network']['ethernets'])) {
            foreach ($parsed['network']['ethernets'] as $iface => $config) {
                if (is_array($config)) $merged[$iface] = $config;
            }
        }
    }

    foreach (netplanFiles($dir) as $file) {
        $parsed = @yaml_parse_file($file);
        if (!is_array($parsed) || empty($parsed['network']['ethernets'])) continue;
        foreach ($parsed['network']['ethernets'] as $iface => $config) {
            if (!is_array($config)) $config = [];
            $merged[$iface] = array_merge($merged[$iface] ?? [], $config);
        }
    }
    return $merged;
}

function netplanFileFor(string $dir, string $iface): string {
    $viaHelper = trim(vp_routing('netplan-owner ' . escapeshellarg($iface)));
    if ($viaHelper !== '' && strpos($viaHelper, '/etc/netplan/') === 0) {
        return $viaHelper;
    }

    $found = '';
    foreach (netplanFiles($dir) as $file) {
        $parsed = @yaml_parse_file($file);
        if (is_array($parsed) && isset($parsed['network']['ethernets'][$iface])) {
            $found = $file;
        }
    }
    return $found;
}

function wanFormData(string $iface, string $fallbackGateway, array $allEthernets, string $netplanDir, string $ownFile): array {
    $cfg   = $allEthernets[$iface] ?? [];
    $known = array_key_exists($iface, $allEthernets);

    $addr = ''; $mask = ''; $gw = ''; $dns = '';

    if (isset($cfg['addresses'][0])) {
        $parts = explode('/', $cfg['addresses'][0]);
        $addr  = $parts[0];
        $mask  = $parts[1] ?? '';
    }
    if (isset($cfg['routes']) && is_array($cfg['routes'])) {
        foreach ($cfg['routes'] as $route) {
            if (($route['to'] ?? '') === 'default' && isset($route['via'])) { $gw = $route['via']; break; }
        }
    } elseif (isset($cfg['gateway4'])) {
        $gw = $cfg['gateway4'];
    }
    if (isset($cfg['nameservers']['addresses'])) {
        $dns = implode(', ', $cfg['nameservers']['addresses']);
    }

    $live = getInterfaceLiveInfo($iface);

    if ($known) {
        $type = (isset($cfg['dhcp4']) && $cfg['dhcp4']) ? 'dhcp' : 'static';
    } elseif ($live['dhcp'] === true) {
        $type = 'dhcp';
    } elseif ($live['dhcp'] === false) {
        $type = 'static';
    } else {
        $type = 'static';
    }

    if ($addr === '' && $live['ip'] !== '—') {
        $addr = $live['ip'];
        if ($mask === '' && $live['mask'] !== '—') $mask = $live['mask'];
    }
    if ($gw === '' && $live['gateway'] !== '—') $gw = $live['gateway'];
    if ($gw === '' && $fallbackGateway !== '' && $fallbackGateway !== '-') $gw = $fallbackGateway;
    if ($dns === '' && !empty($live['dns'])) $dns = implode(', ', $live['dns']);
    if ($mask === '') $mask = '24';

    $file = netplanFileFor($netplanDir, $iface);

    return [
        'type'    => $type,
        'known'   => $known,
        'address' => $addr,
        'mask'    => $mask,
        'gateway' => $gw,
        'dns'     => $dns,
        'file'    => $file,
        'foreign' => ($file !== '' && $file !== $ownFile) || !$known,
    ];
}

function ifaceExists(string $iface): bool {
    return $iface !== '' && is_dir('/sys/class/net/' . preg_replace('/[^a-z0-9_.-]/i', '', $iface));
}

function writeYamlFile(string $filePath, array $data): bool {
    $yaml = yaml_emit($data, YAML_UTF8_ENCODING);
    $yaml = preg_replace('/^---\n/', '', $yaml);
    $yaml = preg_replace('/\n\.\.\.\n?$/', '', $yaml);
    return file_put_contents($filePath, $yaml) !== false;
}

function getInterfaceLiveInfo(string $iface): array {
    $info = [
        'status' => 'down', 'ip' => '—', 'mask' => '—', 'gateway' => '—',
        'dns' => [], 'mac' => '—', 'speed' => '—',
        'rx_bytes' => 0, 'tx_bytes' => 0, 'dhcp' => null,
    ];
    if (empty($iface)) return $info;

    $safeIface  = escapeshellarg($iface);
    $cleanIface = preg_replace('/[^a-z0-9_.-]/i', '', $iface);

    $out = shell_exec("ip -o -4 addr show $safeIface 2>/dev/null");
    if ($out && preg_match('/inet ([\d.]+)\/(\d+)/', $out, $m)) {
        $info['ip']   = $m[1];
        $info['mask'] = $m[2];
        $info['dhcp'] = (bool)preg_match('/\bdynamic\b/', $out);
    }

    $link = shell_exec("ip link show $safeIface 2>/dev/null");
    if ($link && preg_match('/state (\w+)/', $link, $m)) $info['status'] = strtolower($m[1]);
    if ($link && preg_match('/link\/ether ([\da-f:]+)/i', $link, $m)) $info['mac'] = $m[1];

    $speedFile = "/sys/class/net/{$cleanIface}/speed";
    $speed = @file_get_contents($speedFile);
    if ($speed !== false && is_numeric(trim($speed)) && (int)trim($speed) > 0) {
        $info['speed'] = trim($speed) . ' Mbps';
    }

    $route = shell_exec("ip route show default 2>/dev/null");
    if ($route && preg_match('/default via ([\d.]+) dev ' . preg_quote($iface, '/') . '/', $route, $m)) {
        $info['gateway'] = $m[1];
    }

    $resolv = @file_get_contents('/etc/resolv.conf');
    if ($resolv) {
        preg_match_all('/^nameserver\s+([\d.]+)/m', $resolv, $m);
        $info['dns'] = $m[1] ?? [];
    }

    $info['rx_bytes'] = (int)trim(@file_get_contents("/sys/class/net/{$cleanIface}/statistics/rx_bytes") ?: '0');
    $info['tx_bytes'] = (int)trim(@file_get_contents("/sys/class/net/{$cleanIface}/statistics/tx_bytes") ?: '0');
    return $info;
}

function formatBytes(int $bytes): string {
    if ($bytes >= 1073741824) return round($bytes / 1073741824, 2) . ' GB';
    if ($bytes >= 1048576)    return round($bytes / 1048576, 2) . ' MB';
    if ($bytes >= 1024)       return round($bytes / 1024, 2) . ' KB';
    return $bytes . ' B';
}

define('VP_ROUTING_BIN', '/usr/local/sbin/vpn-panel-routing');

function vp_routing(string $args): string {
    $r = vp_routingRun($args);
    return $r['out'];
}

function vp_routingRun(string $args): array {
    if (!is_executable(VP_ROUTING_BIN)) {
        return ['rc' => 127, 'out' => ''];
    }
    $lines = [];
    $rc = 1;
    exec('sudo ' . VP_ROUTING_BIN . ' ' . $args . ' 2>&1', $lines, $rc);
    return ['rc' => $rc, 'out' => implode("\n", $lines)];
}

function vp_wanList(): array {
    static $cache = null;
    if ($cache !== null) return $cache;
    $rows = [];
    foreach (preg_split('/\r?\n/', vp_routing('status')) as $line) {
        if (trim($line) === '') continue;
        $p = explode("\t", $line);
        if (count($p) < 6) continue;
        $flags = explode(',', $p[5]);
        $rows[] = [
            'iface'    => $p[0],
            'priority' => (int)$p[1],
            'table'    => $p[2],
            'address'  => $p[3],
            'gateway'  => $p[4],
            'state'    => $flags[0],
            'active'   => in_array('active', $flags, true),
        ];
    }
    $cache = $rows;
    return $cache;
}

function vp_freeIfaces(): array {
    $rows = [];
    foreach (preg_split('/\r?\n/', vp_routing('free')) as $line) {
        if (trim($line) === '') continue;
        $p = explode("\t", $line);
        if (count($p) < 3) continue;
        $rows[] = ['iface' => $p[0], 'address' => $p[1], 'link' => $p[2]];
    }
    return $rows;
}

$flashMessage = '';
$flashType    = '';

if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['wan_action'])) {
    $wanAction = $_POST['wan_action'];
    $wanIface  = trim($_POST['wan_iface'] ?? '');

    if (!preg_match('/^[a-zA-Z0-9_:.-]{1,20}$/', $wanIface)) {
        $flashMessage = 'Недопустимое имя интерфейса';
        $flashType    = 'error';
    } elseif (!is_executable(VP_ROUTING_BIN)) {
        $flashMessage = 'Управление каналами недоступно: vpn-panel-routing не установлен';
        $flashType    = 'error';
    } else {
        $safe = escapeshellarg($wanIface);
        $verbs = [
            'add'      => ['add-wan',    "Канал {$wanIface} добавлен"],
            'remove'   => ['remove-wan', "Канал {$wanIface} удалён"],
            'activate' => ['set-active', "Активный канал: {$wanIface}"],
            'primary'  => ['set-primary', "Основной канал: {$wanIface}"],
        ];

        if ($wanAction === 'move') {
            $dir = ($_POST['wan_dir'] ?? '') === 'up' ? 'up' : 'down';
            $verbs['move'] = ['move-wan ' . $safe . ' ' . escapeshellarg($dir), 'Порядок каналов изменён'];
        }
        if (!isset($verbs[$wanAction])) {
            $flashMessage = 'Неизвестное действие';
            $flashType    = 'error';
        } else {
            [$sub, $okText] = $verbs[$wanAction];
            $res  = vp_routingRun($wanAction === 'move' ? $sub : $sub . ' ' . $safe);
            $note = trim($res['out']);
            if ($res['rc'] === 0) {
                $flashMessage = $note !== '' ? $note : $okText;
                $flashType    = 'success';
            } else {
                $flashMessage = $note !== '' ? $note : "Не удалось выполнить действие над каналом {$wanIface}";
                $flashType    = 'error';
            }
        }
    }
}


if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['apply_settings'])) {
    $data = readYamlFile($yamlFilePath);

    if ($data === null && file_exists($yamlFilePath) && filesize($yamlFilePath) === 0) {
        $data = ['network' => ['version' => 2, 'renderer' => 'networkd', 'ethernets' => []]];
    }

    if ($data === null) {
        if (!file_exists($yamlFilePath)) {
            $why = 'файла нет';
        } elseif (!is_readable($yamlFilePath)) {
            $why = 'нет прав на чтение (ожидается 660 root:www-data)';
        } elseif (!is_writable($yamlFilePath)) {
            $why = 'файл только для чтения';
        } else {
            $why = 'не разбирается как YAML';
        }
        $flashMessage = 'Не прочитать ' . basename($yamlFilePath) . ': ' . $why;
        $flashType    = 'error';
    } else {
        $newType         = $_POST['connection_type']  ?? '';
        $inputInterface  = trim($_POST['input_interface']  ?? '');
        $outputInterface = trim($_POST['output_interface'] ?? '');

        if (!in_array($newType, ['dhcp', 'static'], true)) {
            $flashMessage = 'Недопустимый тип подключения'; $flashType = 'error';
        } elseif (!preg_match('/^[a-zA-Z0-9_:.-]{1,20}$/', $inputInterface) ||
                  !preg_match('/^[a-zA-Z0-9_:.-]{1,20}$/', $outputInterface) ||
                  $inputInterface === $outputInterface) {
            $flashMessage = 'Недопустимые интерфейсы'; $flashType = 'error';
        } elseif (!ifaceExists($inputInterface)) {
            $flashMessage = "Интерфейс {$inputInterface} не найден в системе"; $flashType = 'error';
        } else {
            if (!isset($data['network']))              $data['network'] = [];
            if (!isset($data['network']['version']))   $data['network']['version'] = 2;
            if (!isset($data['network']['renderer']))  $data['network']['renderer'] = 'networkd';
            if (!isset($data['network']['ethernets'])) $data['network']['ethernets'] = [];
            unset($data['network']['ethernets'][$inputInterface]);

            if ($newType === 'static') {
                $address    = trim($_POST['address']);
                $subnetMask = (int)trim($_POST['subnet_mask']);
                $gateway    = trim($_POST['gateway']);
                $dns        = array_filter(array_map('trim', explode(',', $_POST['dns'])));

                $isValidIp   = filter_var($address, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4);
                $isValidGw   = filter_var($gateway, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4);
                $isValidMask = $subnetMask >= 1 && $subnetMask <= 32;
                $dnsValid    = true;
                foreach ($dns as $d) {
                    if (!filter_var($d, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) { $dnsValid = false; break; }
                }

                if (empty($address) || empty($gateway))   { $flashMessage = 'Все поля для статической конфигурации обязательны'; $flashType = 'error'; }
                elseif (!$isValidIp)                       { $flashMessage = "Некорректный IP-адрес: $address";                   $flashType = 'error'; }
                elseif (!$isValidGw)                       { $flashMessage = "Некорректный шлюз: $gateway";                       $flashType = 'error'; }
                elseif (!$isValidMask)                     { $flashMessage = "Некорректная маска подсети (1-32): $subnetMask";    $flashType = 'error'; }
                elseif (!$dnsValid)                        { $flashMessage = 'Некорректный DNS-адрес';                             $flashType = 'error'; }
                else {
                    $data['network']['ethernets'][$inputInterface] = [
                        'dhcp4'       => false,
                        'addresses'   => ["$address/$subnetMask"],
                        'routes'      => [['to' => 'default', 'via' => $gateway]],
                        'nameservers' => ['addresses' => $dns ?: ['8.8.8.8', '8.8.4.4']],
                    ];
                }
            } else {
                $data['network']['ethernets'][$inputInterface] = ['dhcp4' => true];
            }

            if (empty($flashMessage)) {
                if (!isset($data['network']['ethernets'][$outputInterface])) {
                    $data['network']['ethernets'][$outputInterface] = [
                        'dhcp4'       => false,
                        'addresses'   => [vp_panelConf('LAN_IP', '10.32.0.1') . '/' . vp_panelConf('LAN_PREFIX', '20')],
                        'nameservers' => ['addresses' => [vp_panelConf('LAN_IP', '10.32.0.1')]],
                        'optional'    => true,
                    ];
                }

                if (writeYamlFile($yamlFilePath, $data)) {
                    exec('sudo netplan apply 2>&1', $applyOutput, $applyReturn);
                    if ($applyReturn === 0) {
                        sleep(2);
                        $flashMessage = 'Настройки сети успешно применены';
                        $flashType    = 'success';
                    } else {
                        $flashMessage = 'Ошибка применения: ' . implode(' ', $applyOutput);
                        $flashType    = 'error';
                    }
                } else {
                    $flashMessage = 'Ошибка записи файла конфигурации';
                    $flashType    = 'error';
                }
            }
        }
    }
}

$data = readYamlFile($yamlFilePath);
$allEthernets = readAllNetplanEthernets($netplanDir);

$inputInterface  = '';
$outputInterface = '';
$inputConfig     = [];
$outputConfig    = [];

$confWan = vp_panelConf('WAN', '');
$confLan = vp_panelConf('LAN', '');

if ($confWan !== '' && ifaceExists($confWan)) {
    $inputInterface = $confWan;
    $inputConfig    = $allEthernets[$confWan] ?? [];
}
if ($confLan !== '' && ifaceExists($confLan)) {
    $outputInterface = $confLan;
    $outputConfig    = $allEthernets[$confLan] ?? [];
}

if (empty($inputInterface) || empty($outputInterface)) {
    foreach ($allEthernets as $iface => $config) {
        if ($iface === $inputInterface || $iface === $outputInterface) continue;
        if (!empty($config['optional']) && $config['optional'] === true) {
            if (empty($outputInterface)) { $outputInterface = $iface; $outputConfig = $config; }
        } elseif (empty($inputInterface)) {
            $inputInterface = $iface;
            $inputConfig    = $config;
        }
    }
}

$wanConfigFile = $inputInterface !== '' ? netplanFileFor($netplanDir, $inputInterface) : '';
$wanManagedElsewhere = $wanConfigFile !== '' && $wanConfigFile !== $yamlFilePath;

$inputType = (isset($inputConfig['dhcp4']) && $inputConfig['dhcp4']) ? 'dhcp' : 'static';
$inputAddress = '';
$inputSubnetMask = '';
$inputGateway = '';
$inputDNS = '';

if ($inputType === 'static' && !empty($inputConfig)) {
    if (isset($inputConfig['addresses'][0])) {
        $parts = explode('/', $inputConfig['addresses'][0]);
        $inputAddress    = $parts[0];
        $inputSubnetMask = $parts[1] ?? '24';
    }
    if (isset($inputConfig['routes'])) {
        foreach ($inputConfig['routes'] as $route) {
            if (isset($route['to']) && $route['to'] === 'default' && isset($route['via'])) {
                $inputGateway = $route['via'];
                break;
            }
        }
    } elseif (isset($inputConfig['gateway4'])) {
        $inputGateway = $inputConfig['gateway4'];
    }
    $inputDNS = isset($inputConfig['nameservers']['addresses'])
        ? implode(', ', $inputConfig['nameservers']['addresses'])
        : '';
}

$outputAddress    = '';
$outputSubnetMask = '';
if (isset($outputConfig['addresses'][0])) {
    $parts = explode('/', $outputConfig['addresses'][0]);
    $outputAddress    = $parts[0];
    $outputSubnetMask = $parts[1] ?? '20';
}

$wanLive = getInterfaceLiveInfo($inputInterface);

if ($inputAddress === '' && $wanLive['ip'] !== '—') {
    $inputAddress = $wanLive['ip'];
    if ($inputSubnetMask === '' && $wanLive['mask'] !== '—') $inputSubnetMask = $wanLive['mask'];
}
if ($inputGateway === '' && $wanLive['gateway'] !== '—') $inputGateway = $wanLive['gateway'];
if ($inputDNS === '' && !empty($wanLive['dns']))          $inputDNS     = implode(', ', $wanLive['dns']);
?>

<link rel="stylesheet" href="assets/css/pages/netsettings.css?v=<?php echo $netsettingsAssetsVer; ?>">

<?php if ($flashMessage): ?>
<script>
window.__flashMessage = {
    text: <?php echo json_encode($flashMessage, JSON_UNESCAPED_UNICODE); ?>,
    type: <?php echo json_encode($flashType); ?>
};
</script>
<?php endif; ?>

<div class="net-page-header">
    <h1>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75">
            <path stroke-linecap="round" stroke-linejoin="round" d="M21 12a9 9 0 01-9 9m9-9a9 9 0 00-9-9m9 9H3m9 9a9 9 0 01-9-9m9 9c1.657 0 3-4.03 3-9s-1.343-9-3-9m0 18c-1.657 0-3-4.03-3-9s1.343-9 3-9"/>
        </svg>
        Настройки сети
    </h1>
</div>

<div class="card card--accent-cyan" style="margin-bottom: var(--space-5);">
    <div class="card-header">
        <div class="card-title">
            <span class="icon-badge icon-badge--cyan">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M8.111 16.404a5.5 5.5 0 017.778 0M12 20h.01m-7.08-7.071c3.904-3.905 10.236-3.905 14.141 0M1.394 9.393c5.857-5.857 15.355-5.857 21.213 0"/></svg>
            </span>
            Текущее состояние
        </div>
        <?php $okStatus = ($wanLive['status'] === 'up'); ?>
        <span class="status-pill <?php echo $okStatus ? 'status-pill--ok' : 'status-pill--err'; ?>">
            <span class="status-dot <?php echo $okStatus ? 'status-dot--ok status-dot--pulse' : 'status-dot--err'; ?>"></span>
            <?php echo $okStatus ? 'Подключено' : 'Не подключено'; ?>
        </span>
    </div>

    <div class="net-stats-grid">
        <div class="net-stat">
            <div class="net-stat-icon net-stat-icon--cyan">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M5 12h14M5 12a2 2 0 100 4 2 2 0 000-4zm14 0a2 2 0 110 4 2 2 0 010-4zm-7-9v18"/></svg>
            </div>
            <span class="net-stat-label">Интерфейс</span>
            <span class="net-stat-value mono"><?php echo htmlspecialchars($inputInterface); ?></span>
        </div>

        <div class="net-stat">
            <div class="net-stat-icon net-stat-icon--emerald">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M3.055 11H5a2 2 0 012 2v1a2 2 0 002 2 2 2 0 012 2v2.945M8 3.935V5.5A2.5 2.5 0 0010.5 8h.5a2 2 0 012 2 2 2 0 002 2 2 2 0 012-2h1.064M15 20.488V18a2 2 0 012-2h3.064M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
            </div>
            <span class="net-stat-label">IP-адрес</span>
            <span class="net-stat-value mono"><?php echo htmlspecialchars($wanLive['ip']); ?><?php echo $wanLive['mask'] !== '—' ? '<span class="net-stat-suffix">/' . htmlspecialchars($wanLive['mask']) . '</span>' : ''; ?></span>
        </div>

        <div class="net-stat">
            <div class="net-stat-icon net-stat-icon--violet">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6"/></svg>
            </div>
            <span class="net-stat-label">Шлюз</span>
            <span class="net-stat-value mono"><?php echo htmlspecialchars($wanLive['gateway']); ?></span>
        </div>

        <div class="net-stat">
            <div class="net-stat-icon net-stat-icon--amber">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M3.055 11H5a2 2 0 012 2v1a2 2 0 002 2 2 2 0 012 2v2.945M8 3.935V5.5A2.5 2.5 0 0010.5 8h.5a2 2 0 012 2 2 2 0 002 2 2 2 0 012-2h1.064M15 20.488V18a2 2 0 012-2h3.064M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
            </div>
            <span class="net-stat-label">DNS</span>
            <span class="net-stat-value mono"><?php echo !empty($wanLive['dns']) ? htmlspecialchars(implode(', ', $wanLive['dns'])) : '—'; ?></span>
        </div>

        <div class="net-stat">
            <div class="net-stat-icon net-stat-icon--slate">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"/></svg>
            </div>
            <span class="net-stat-label">MAC-адрес</span>
            <span class="net-stat-value mono"><?php echo htmlspecialchars($wanLive['mac']); ?></span>
        </div>
    </div>

    <div class="net-metrics-grid">
        <div class="net-metric">
            <div class="net-metric-head">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M13 10V3L4 14h7v7l9-11h-7z"/></svg>
                <span>Скорость</span>
            </div>
            <span class="net-metric-value"><?php echo htmlspecialchars($wanLive['speed']); ?></span>
        </div>

        <div class="net-metric net-metric--rx">
            <div class="net-metric-head">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M19 14l-7 7m0 0l-7-7m7 7V3"/></svg>
                <span>Получено</span>
            </div>
            <span class="net-metric-value"><?php echo formatBytes($wanLive['rx_bytes']); ?></span>
        </div>

        <div class="net-metric net-metric--tx">
            <div class="net-metric-head">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M5 10l7-7m0 0l7 7m-7-7v18"/></svg>
                <span>Отправлено</span>
            </div>
            <span class="net-metric-value"><?php echo formatBytes($wanLive['tx_bytes']); ?></span>
        </div>
    </div>

    <div class="net-mode-note">
        <span class="text-xs text-muted">
            Режим: <span class="text-secondary"><?php echo $inputType === 'dhcp' ? 'DHCP (автоматически)' : 'Статический IP'; ?></span>
        </span>
    </div>
</div>

<?php
$wanRows  = vp_wanList();
$wanFree  = vp_freeIfaces();
$wanState = [
    'up'      => ['pill' => 'ok',   'text' => 'канал живой'],
    'down'    => ['pill' => 'err',  'text' => 'нет связи'],
    'no-ip'   => ['pill' => 'warn', 'text' => 'нет адреса'],
    'missing' => ['pill' => 'err',  'text' => 'карта отсутствует'],
];
?>

<?php if (!empty($wanRows)): ?>
<div class="card card--accent-emerald" style="margin-bottom: var(--space-5);">
    <div class="card-header">
        <div class="card-title">
            <span class="icon-badge icon-badge--emerald">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M8 7h12m0 0l-4-4m4 4l-4 4M16 17H4m0 0l4 4m-4-4l4-4"/></svg>
            </span>
            Каналы в интернет
        </div>
        <span class="badge badge--slate"><?php echo count($wanRows); ?> шт.</span>
    </div>

    <div class="wan-list">
        <?php foreach ($wanRows as $row):
            $view = $wanState[$row['state']] ?? ['pill' => 'warn', 'text' => $row['state']];
            $isPrimary = $row['priority'] === 1;
            $isUp      = $row['state'] === 'up';
            if ($row['active']) {
                $roleText = 'Интернет идёт через этот канал';
            } elseif ($isUp) {
                $roleText = 'В запасе — готов принять трафик';
            } else {
                $roleText = 'Не готов принять трафик';
            }
        ?>
        <div class="wan-item<?php echo $row['active'] ? ' is-active' : ''; ?>">

            <div class="wan-item-order">
                <span class="wan-item-num"><?php echo (int)$row['priority']; ?></span>
                <?php if (count($wanRows) > 1): ?>
                <div class="net-prio-arrows">
                    <form method="post">
                        <input type="hidden" name="wan_action" value="move">
                        <input type="hidden" name="wan_dir" value="up">
                        <?php echo vp_csrfField(); ?>
                        <input type="hidden" name="wan_iface" value="<?php echo htmlspecialchars($row['iface']); ?>">
                        <button type="submit" class="btn btn--ghost net-prio-btn" title="Выше по приоритету"
                                <?php echo $isPrimary ? 'disabled' : ''; ?>><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path stroke-linecap="round" stroke-linejoin="round" d="M5 15l7-7 7 7"/></svg></button>
                    </form>
                    <form method="post">
                        <input type="hidden" name="wan_action" value="move">
                        <input type="hidden" name="wan_dir" value="down">
                        <?php echo vp_csrfField(); ?>
                        <input type="hidden" name="wan_iface" value="<?php echo htmlspecialchars($row['iface']); ?>">
                        <button type="submit" class="btn btn--ghost net-prio-btn" title="Ниже по приоритету"
                                <?php echo $row['priority'] === count($wanRows) ? 'disabled' : ''; ?>><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path stroke-linecap="round" stroke-linejoin="round" d="M19 9l-7 7-7-7"/></svg></button>
                    </form>
                </div>
                <?php endif; ?>
            </div>

            <div class="wan-item-main">
                <div class="wan-item-head">
                    <span class="wan-item-name mono"><?php echo htmlspecialchars($row['iface']); ?></span>
                    <?php if ($isPrimary): ?>
                        <span class="badge badge--blue">основной</span>
                    <?php else: ?>
                        <span class="badge badge--slate">резервный</span>
                    <?php endif; ?>
                    <span class="status-pill status-pill--<?php echo $view['pill']; ?>"><?php echo htmlspecialchars($view['text']); ?></span>
                </div>

                <div class="wan-item-role<?php echo $row['active'] ? ' is-active' : ''; ?>">
                    <?php echo htmlspecialchars($roleText); ?>
                </div>

                <div class="wan-item-meta">
                    <span>адрес <b class="mono"><?php echo htmlspecialchars($row['address']); ?></b></span>
                    <span>шлюз <b class="mono"><?php echo htmlspecialchars($row['gateway']); ?></b></span>
                </div>
            </div>

            <div class="wan-item-actions">
                <?php if (!$row['active'] && $isUp): ?>
                <form method="post" class="wan-inline-form"
                      data-confirm="Пустить весь интернет через <?php echo htmlspecialchars($row['iface']); ?>?"
                      data-confirm-ok="Подключить" data-confirm-danger="0">
                    <input type="hidden" name="wan_action" value="activate">
                    <?php echo vp_csrfField(); ?>
                    <input type="hidden" name="wan_iface" value="<?php echo htmlspecialchars($row['iface']); ?>">
                    <button type="submit" class="btn btn--secondary btn--sm">Подключить интернет отсюда</button>
                </form>
                <?php endif; ?>

                <?php if (count($wanRows) > 1): ?>
                <form method="post" class="wan-inline-form"
                      data-confirm="Убрать канал <?php echo htmlspecialchars($row['iface']); ?> из списка?">
                    <input type="hidden" name="wan_action" value="remove">
                    <?php echo vp_csrfField(); ?>
                    <input type="hidden" name="wan_iface" value="<?php echo htmlspecialchars($row['iface']); ?>">
                    <button type="submit" class="btn btn--ghost btn--icon-sm" title="Убрать канал"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M14.74 9l-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 01-2.244 2.077H8.084a2.25 2.25 0 01-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 00-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 013.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 00-3.32 0c-1.18.037-2.09 1.022-2.09 2.201v.916m7.5 0a48.667 48.667 0 00-7.5 0"/></svg></button>
                </form>
                <?php endif; ?>
            </div>
        </div>
        <?php endforeach; ?>
    </div>

    <div class="net-legend">
        <span><span class="badge badge--blue">основной</span> — первый по приоритету, сюда сервер возвращается сам</span>
        <span><span class="badge badge--slate">резервный</span> — вступает, когда канал выше пропал</span>
    </div>

    <?php if (!empty($wanFree)): ?>
    <form method="post" class="toolbar" style="margin-top: var(--space-5); margin-bottom:0;">
        <input type="hidden" name="wan_action" value="add">
                                <?php echo vp_csrfField(); ?>
        <span class="text-muted text-sm">Добавить провайдера на свободную карту:</span>
        <select name="wan_iface" class="select" style="max-width:280px">
            <?php foreach ($wanFree as $free): ?>
            <option value="<?php echo htmlspecialchars($free['iface']); ?>">
                <?php echo htmlspecialchars($free['iface']); ?>
                — <?php echo htmlspecialchars($free['address'] !== '-' ? $free['address'] : 'без адреса'); ?>
                (<?php echo htmlspecialchars($free['link']); ?>)
            </option>
            <?php endforeach; ?>
        </select>
        <button type="submit" class="btn btn--primary btn--sm">Добавить канал</button>
    </form>
    <?php else: ?>
    <div class="text-muted text-sm" style="margin-top: var(--space-4);">
        Свободных сетевых карт нет — все заняты под каналы или локальную сеть.
    </div>
    <?php endif; ?>
</div>
<?php endif; ?>

<script>
(function () {
    document.querySelectorAll('form[data-confirm]').forEach(function (form) {
        form.addEventListener('submit', function (e) {
            if (form.dataset.confirmed === '1') return;
            e.preventDefault();
            var ask = window.VPNPanel && window.VPNPanel.confirm;
            if (!ask) { form.dataset.confirmed = '1'; form.submit(); return; }
            ask({
                title:       'Подтвердите действие',
                message:     form.dataset.confirm,
                confirmText: form.dataset.confirmOk || 'Убрать',
                cancelText:  'Отмена',
                danger:      form.dataset.confirmDanger !== '0',
            }).then(function (ok) {
                if (!ok) return;
                form.dataset.confirmed = '1';
                form.submit();
            });
        });
    });
})();
</script>

<?php foreach ($wanRows as $chan):
    $ci   = $chan['iface'];
    $cid  = preg_replace('/[^a-zA-Z0-9_]/', '_', $ci);
    $data = wanFormData($ci, $chan['gateway'], $allEthernets, $netplanDir, $yamlFilePath);
?>
<form method="post" class="net-form">
    <?php echo vp_csrfField(); ?>
    <input type="hidden" name="input_interface"  value="<?php echo htmlspecialchars($ci); ?>">
    <input type="hidden" name="output_interface" value="<?php echo htmlspecialchars($outputInterface); ?>">

    <div class="card card--accent-blue">
        <div class="card-header">
            <div class="card-title">
                <span class="icon-badge icon-badge--violet">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M21 12a9 9 0 01-9 9m9-9a9 9 0 00-9-9m9 9H3m9 9a9 9 0 01-9-9m9 9c1.657 0 3-4.03 3-9s-1.343-9-3-9m0 18c-1.657 0-3-4.03-3-9s1.343-9 3-9"/></svg>
                </span>
                Канал <?php echo (int)$chan['priority']; ?> — настройки
                <?php if ($chan['active']): ?>
                    <span class="badge badge--emerald">активный</span>
                <?php endif; ?>
            </div>
            <span class="net-iface-pill"><?php echo htmlspecialchars($ci); ?></span>
        </div>

        <?php if ($data['foreign']): ?>
        <div class="net-note">
            <?php if ($data['file'] !== ''): ?>
                Управляется файлом <span class="mono"><?php echo htmlspecialchars(basename($data['file'])); ?></span>.
                Применение настроек передаст управление панели.
            <?php else: ?>
                Интерфейс не описан ни в одном файле netplan — адрес получен помимо него.
                Применение настроек добавит его в конфигурацию панели.
            <?php endif; ?>
        </div>
        <?php endif; ?>

        <div class="net-form-fields">
            <div class="net-row">
                <label for="ctype_<?php echo $cid; ?>" class="net-row-label">Тип подключения</label>
                <select name="connection_type" id="ctype_<?php echo $cid; ?>" class="select"
                        data-fields="sfields_<?php echo $cid; ?>">
                    <option value="dhcp"   <?php echo $data['type'] === 'dhcp'   ? 'selected' : ''; ?>>DHCP (автоматически)</option>
                    <option value="static" <?php echo $data['type'] === 'static' ? 'selected' : ''; ?>>Статический IP</option>
                </select>
            </div>

            <div id="sfields_<?php echo $cid; ?>" class="net-static-fields"
                 style="display: <?php echo $data['type'] === 'static' ? 'flex' : 'none'; ?>;">
                <div class="net-row">
                    <label for="addr_<?php echo $cid; ?>" class="net-row-label">IP-адрес</label>
                    <input type="text" id="addr_<?php echo $cid; ?>" name="address" class="input mono"
                           value="<?php echo htmlspecialchars($data['address']); ?>" placeholder="192.168.1.100">
                </div>
                <div class="net-row">
                    <label for="mask_<?php echo $cid; ?>" class="net-row-label">Маска подсети</label>
                    <input type="number" min="1" max="32" id="mask_<?php echo $cid; ?>" name="subnet_mask" class="input mono"
                           value="<?php echo htmlspecialchars($data['mask']); ?>" placeholder="24">
                </div>
                <div class="net-row">
                    <label for="gw_<?php echo $cid; ?>" class="net-row-label">Шлюз</label>
                    <input type="text" id="gw_<?php echo $cid; ?>" name="gateway" class="input mono"
                           value="<?php echo htmlspecialchars($data['gateway']); ?>" placeholder="192.168.1.1">
                </div>
                <div class="net-row">
                    <label for="dns_<?php echo $cid; ?>" class="net-row-label">DNS (через запятую)</label>
                    <input type="text" id="dns_<?php echo $cid; ?>" name="dns" class="input mono"
                           value="<?php echo htmlspecialchars($data['dns']); ?>" placeholder="8.8.8.8, 8.8.4.4">
                </div>
            </div>
        </div>

        <div class="net-submit-row">
            <button type="submit" name="apply_settings" value="1" class="btn btn--primary">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" width="16" height="16">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/>
                </svg>
                Применить к <?php echo htmlspecialchars($ci); ?>
            </button>
        </div>
    </div>
</form>
<?php endforeach; ?>

<div class="card card--accent-violet">
    <div class="card-header">
        <div class="card-title">
            <span class="icon-badge icon-badge--emerald">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M9 17v-2m3 2v-4m3 4v-6m2 10H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"/></svg>
            </span>
            Локальная сеть (LAN)
        </div>
        <span class="net-iface-pill"><?php echo htmlspecialchars($outputInterface); ?></span>
    </div>

    <div class="net-form-fields">
        <div class="net-row">
            <span class="net-row-label">IP-адрес шлюза</span>
            <span class="net-readonly-value"><?php echo htmlspecialchars($outputAddress ?: vp_panelConf('LAN_IP', '10.32.0.1')); ?></span>
        </div>
        <div class="net-row">
            <span class="net-row-label">Маска подсети</span>
            <span class="net-readonly-value">/<?php echo htmlspecialchars($outputSubnetMask ?: vp_panelConf('LAN_PREFIX', '20')); ?> (<?php echo htmlspecialchars(vp_panelConf('LAN_MASK', '255.255.240.0')); ?>)</span>
        </div>
        <div class="net-row">
            <span class="net-row-label">Диапазон DHCP</span>
            <span class="net-readonly-value"><?php echo htmlspecialchars(vp_panelConf('DHCP_FROM', '10.32.0.2')); ?> — <?php echo htmlspecialchars(vp_panelConf('DHCP_TO', '10.32.15.254')); ?></span>
        </div>
    </div>
</div>

<script>

function toggleStaticFields(select) {
    const fields = document.getElementById(select.dataset.fields);
    if (!fields) return;
    const on = select.value === 'static';
    fields.style.display = on ? 'flex' : 'none';
    fields.querySelectorAll('input').forEach(i => { i.required = on; });
}
document.addEventListener('DOMContentLoaded', () => {
    document.querySelectorAll('select[data-fields]').forEach(sel => {
        sel.addEventListener('change', () => toggleStaticFields(sel));
        toggleStaticFields(sel);
    });
});
</script>
