<?php

if (!defined('VP_CONFIG_PATH'))     define('VP_CONFIG_PATH', '/var/www/vpn-configs');
if (!defined('VP_METADATA_FILE'))   define('VP_METADATA_FILE', VP_CONFIG_PATH . '/configs.json');
if (!defined('VP_STATE_FILE'))      define('VP_STATE_FILE', '/var/www/vpn-state');
if (!defined('VP_ACTIVE_OVPN'))     define('VP_ACTIVE_OVPN', '/etc/openvpn/tun0.conf');
if (!defined('VP_ACTIVE_WG'))       define('VP_ACTIVE_WG', '/etc/wireguard/tun0.conf');
if (!defined('VP_EVENTS_FILE'))     define('VP_EVENTS_FILE', '/var/log/vpn-panel/events.log');
if (!defined('VP_MAX_CONFIGS'))     define('VP_MAX_CONFIGS', 30);
if (!defined('VP_MAX_CONFIG_NAME')) define('VP_MAX_CONFIG_NAME', 64);
if (!defined('VP_PANEL_CONF'))      define('VP_PANEL_CONF', '/etc/vpn-panel.conf');

function vp_panelConf(string $key, string $default = ''): string {
    static $conf = null;
    if ($conf === null) {
        $conf = [];
        $raw = @file_get_contents(VP_PANEL_CONF);
        if ($raw !== false) {
            foreach (preg_split('/\r?\n/', $raw) as $line) {
                if (strpos($line, '=') === false) continue;
                [$k, $v] = explode('=', $line, 2);
                $conf[trim($k)] = trim($v);
            }
        }
    }
    return (isset($conf[$key]) && $conf[$key] !== '') ? $conf[$key] : $default;
}

function vp_loadConfigs(string $metadataFile = VP_METADATA_FILE): array {
    if (!file_exists($metadataFile)) return [];
    $lockFile = $metadataFile . '.lock';
    $fp = fopen($lockFile, 'c');
    $content = '';
    if ($fp && flock($fp, LOCK_SH)) {
        $content = file_get_contents($metadataFile);
        flock($fp, LOCK_UN);
        fclose($fp);
    } else {
        if ($fp) fclose($fp);
        $content = file_get_contents($metadataFile);
    }
    $configs = json_decode($content, true) ?: [];
    return vp_dedupConfigs($configs);
}

function vp_dedupConfigs(array $configs): array {
    if (empty($configs)) return [];
    $byFilename = [];
    $orphans    = [];
    foreach ($configs as $id => $cfg) {
        $filename = $cfg['filename'] ?? '';
        if (empty($filename)) { $orphans[$id] = $cfg; continue; }

        if (!isset($byFilename[$filename])) {
            $byFilename[$filename] = [$id => $cfg];
        } else {
            $byFilename[$filename][$id] = $cfg;
        }
    }

    $clean = [];
    foreach ($byFilename as $filename => $candidates) {
        if (count($candidates) === 1) {

            foreach ($candidates as $id => $cfg) $clean[$id] = $cfg;
            continue;
        }

        uasort($candidates, function($a, $b) {
            $ta = $a['created_at'] ?? '';
            $tb = $b['created_at'] ?? '';
            return strcmp($ta, $tb);
        });

        $first = array_key_first($candidates);
        $clean[$first] = $candidates[$first];
    }
    return $clean;
}

function vp_saveConfigs(array $configs, string $metadataFile = VP_METADATA_FILE): void {
    $configs = vp_dedupConfigs($configs);
    $lockFile = $metadataFile . '.lock';
    $tmpFile  = $metadataFile . '.tmp';
    $json = json_encode($configs, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE);

    $fp = fopen($lockFile, 'c');
    if ($fp && flock($fp, LOCK_EX)) {
        if (file_put_contents($tmpFile, $json) !== false) {
            rename($tmpFile, $metadataFile);
        }
        flock($fp, LOCK_UN);
        fclose($fp);
    } else {
        if ($fp) fclose($fp);
        if (file_put_contents($tmpFile, $json) !== false) {
            rename($tmpFile, $metadataFile);
        }
    }
}

function vp_readState(string $stateFile = VP_STATE_FILE): array {
    $state = [
        'STATE'        => 'stopped',
        'ACTIVE_ID'    => '',
        'PRIMARY_ID'   => '',
        'ACTIVATED_BY' => '',
    ];
    if (!file_exists($stateFile)) return $state;
    $allowed = ['STATE', 'ACTIVE_ID', 'PRIMARY_ID', 'ACTIVATED_BY'];
    $lines = @file($stateFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
    foreach ($lines as $line) {
        if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && in_array($m[1], $allowed, true)) {
            $state[$m[1]] = $m[2];
        }
    }
    return $state;
}

function vp_saveState(string $state, string $activeId, string $primaryId, string $activatedBy, string $stateFile = VP_STATE_FILE): void {
    $content = "STATE=$state\nACTIVE_ID=$activeId\nPRIMARY_ID=$primaryId\nACTIVATED_BY=$activatedBy\n";
    file_put_contents($stateFile, $content, LOCK_EX);
}

function vp_isValidConfigId(string $id): bool {
    return (bool) preg_match('/^vpn_[a-f0-9]{16}$/', $id);
}

function vp_safeSubstr(string $str, int $start, int $length): string {
    if (function_exists('mb_substr')) {
        return mb_substr($str, $start, $length);
    }
    return substr($str, $start, $length);
}

function vp_detectConfigType(string $filePath): string {
    if (!file_exists($filePath)) return 'unknown';
    $content = file_get_contents($filePath);

    if (preg_match('/\[Interface\]/i', $content) && preg_match('/PrivateKey\s*=/i', $content)) {
        return 'wireguard';
    }
    if (preg_match('/^(client|remote|proto|dev|cipher)/mi', $content)) {
        return 'openvpn';
    }
    return 'unknown';
}

function vp_extractConfigInfo(string $filePath, string $type): array {
    $info = ['server' => 'Неизвестно', 'port' => '', 'protocol' => ''];
    if (!file_exists($filePath)) return $info;
    $content = file_get_contents($filePath);

    if ($type === 'openvpn') {
        if (preg_match('/^\s*remote\s+([^\s]+)\s*(\d+)?/mi', $content, $m)) {
            $info['server'] = $m[1];
            $info['port']   = $m[2] ?? '1194';
        }
        if (preg_match('/^\s*proto\s+(\w+)/mi', $content, $m)) {
            $info['protocol'] = strtoupper($m[1]);
        }
    } elseif ($type === 'wireguard') {
        if (preg_match('/^\s*Endpoint\s*=\s*([^:]+):(\d+)/mi', $content, $m)) {
            $info['server'] = $m[1];
            $info['port']   = $m[2];
        }
        $info['protocol'] = 'UDP';
    }
    return $info;
}

function vp_generateConfigId(): string {
    return 'vpn_' . bin2hex(random_bytes(8));
}

function vp_getActiveConfig(): ?array {
    $wgActive   = (trim(shell_exec("systemctl is-active wg-quick@tun0 2>/dev/null")) === 'active');
    $ovpnActive = (trim(shell_exec("systemctl is-active openvpn@tun0 2>/dev/null")) === 'active');

    if ($wgActive && file_exists(VP_ACTIVE_WG)) {
        return ['type' => 'wireguard', 'file' => VP_ACTIVE_WG];
    }
    if ($ovpnActive && file_exists(VP_ACTIVE_OVPN)) {
        return ['type' => 'openvpn', 'file' => VP_ACTIVE_OVPN];
    }

    if (file_exists(VP_ACTIVE_WG))   return ['type' => 'wireguard', 'file' => VP_ACTIVE_WG];
    if (file_exists(VP_ACTIVE_OVPN)) return ['type' => 'openvpn', 'file' => VP_ACTIVE_OVPN];
    return null;
}

function vp_checkVPNStatus(): bool {
    $output = shell_exec("ip link show tun0 2>&1");
    return (strpos($output, 'does not exist') === false
         && strpos($output, 'Device not found') === false
         && strpos($output, ',UP') !== false);
}

function vp_logEvent(string $type, string ...$fields): void {
    $ts = date('Y-m-d H:i:s');
    $sanitize = fn($v) => str_replace(['|', "\n", "\r"], ['/', ' ', ' '], (string)$v);
    $parts = array_map($sanitize, $fields);
    $line = $ts . '|' . $type;
    if (!empty($parts)) $line .= '|' . implode('|', $parts);
    $line .= "\n";
    @file_put_contents(VP_EVENTS_FILE, $line, FILE_APPEND | LOCK_EX);

    $size = @filesize(VP_EVENTS_FILE);
    if ($size !== false && $size > 262144) {
        $lines = @file(VP_EVENTS_FILE, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
        if (count($lines) > 500) {
            $keep = array_slice($lines, -500);
            @file_put_contents(VP_EVENTS_FILE, implode("\n", $keep) . "\n", LOCK_EX);
        }
    }
}

function vp_stopAllServices(): void {
    shell_exec('sudo systemctl stop openvpn@tun0 2>/dev/null');
    shell_exec('sudo systemctl stop wg-quick@tun0 2>/dev/null');
}

function vp_disableAllServices(): void {
    shell_exec('sudo systemctl disable wg-quick@tun0 2>/dev/null');
    shell_exec('sudo systemctl disable openvpn@tun0 2>/dev/null');
}

function vp_cleanActiveConfigFiles(): void {
    shell_exec('rm -f ' . escapeshellarg(VP_ACTIVE_OVPN) . ' ' . escapeshellarg(VP_ACTIVE_WG) . ' 2>/dev/null');
}

function vp_activateServiceFromFile(string $sourceFile, string $type): bool {
    if ($type === 'wireguard') {
        if (!copy($sourceFile, VP_ACTIVE_WG)) return false;
        chmod(VP_ACTIVE_WG, 0600);
        shell_exec('sudo systemctl disable openvpn@tun0 2>/dev/null');
        shell_exec('sudo systemctl enable wg-quick@tun0 2>/dev/null');
        shell_exec('sudo systemctl start wg-quick@tun0');
        return true;
    } else {
        if (!copy($sourceFile, VP_ACTIVE_OVPN)) return false;
        chmod(VP_ACTIVE_OVPN, 0600);
        shell_exec('sudo systemctl disable wg-quick@tun0 2>/dev/null');
        shell_exec('sudo systemctl enable openvpn@tun0 2>/dev/null');
        shell_exec('sudo systemctl start openvpn@tun0');
        return true;
    }
}

function vp_pollVpnUp(int $timeoutSec = 15): bool {
    for ($i = 0; $i < $timeoutSec; $i++) {
        sleep(1);
        if (vp_checkVPNStatus()) return true;
    }
    return false;
}

function vp_ifaceCidr(string $iface): string {
    $out = @shell_exec('ip -4 -o addr show ' . escapeshellarg($iface) . ' scope global 2>/dev/null');
    if ($out && preg_match('/inet ([\d.]+\/\d+)/', $out, $m)) return $m[1];
    return '-';
}

function vp_defaultRouteIface(): string {
    $out = @shell_exec('ip route show default 2>/dev/null');
    if ($out && preg_match('/dev (\S+)/', $out, $m)) return $m[1];
    return '';
}

function vp_speedChannels(): array {
    $lan    = vp_panelConf('LAN', '');
    $active = vp_defaultRouteIface();
    $list   = [];

    $entries = @scandir('/sys/class/net');
    if (!is_array($entries)) return $list;
    sort($entries);

    foreach ($entries as $iface) {
        if ($iface === '.' || $iface === '..' || $iface === 'lo') continue;
        if ($iface === $lan) continue;
        if (preg_match('/^(docker|veth|br-|virbr|dummy)/', $iface)) continue;

        $cidr    = vp_ifaceCidr($iface);
        $operRaw = @file_get_contents('/sys/class/net/' . $iface . '/operstate');
        $oper    = is_string($operRaw) ? trim($operRaw) : '';
        $tunnel  = (bool)preg_match('/^(tun|wg)/', $iface);

        $list[] = [
            'iface'   => $iface,
            'address' => $cidr,
            'state'   => $cidr === '-' ? 'no-ip' : (($oper === 'up' || $oper === 'unknown') ? 'up' : 'down'),
            'active'  => $iface === $active,
            'tunnel'  => $tunnel,
        ];
    }
    return $list;
}
