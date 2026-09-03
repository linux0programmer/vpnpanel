<?php
require_once __DIR__ . '/../includes/guard.php';
vp_requireSession(true);
vp_requireCsrf(true);
$host = trim($_GET['host'] ?? '');
$interface_param = trim($_GET['interface'] ?? '');

if (empty($host)) {
    die("NO PING");
}

$isIp  = filter_var($host, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4);
$isHostname = preg_match('/^[a-zA-Z0-9]([a-zA-Z0-9\-\.]{0,253}[a-zA-Z0-9])?$/', $host)
              && strlen($host) <= 255;
if (!$isIp && !$isHostname) {
    die("NO PING");
}

if (!empty($interface_param) && !preg_match('/^[a-zA-Z0-9_:@-]{1,20}$/', $interface_param)
    && $interface_param !== 'detect_netplan') {
    die("NO PING");
}

$interface = $interface_param;

if ($interface === 'detect_netplan') {
    $interface = '';
    $yamlFilePath = '/etc/netplan/01-network-manager-all.yaml';
    if (function_exists('yaml_parse_file') && file_exists($yamlFilePath) && is_readable($yamlFilePath)) {
        $data = @yaml_parse_file($yamlFilePath);
        if (isset($data['network']['ethernets'])) {
            foreach ($data['network']['ethernets'] as $if_name => $config) {
                if (!isset($config['optional']) || $config['optional'] !== true) {
                    $interface = $if_name;
                    break;
                }
            }
        }
    }
}

$escaped_host = escapeshellarg($host);
$command = "ping -c 1 -W 1";
if (!empty($interface)) {
    $escaped_interface = escapeshellarg($interface);
    $command .= " -I " . $escaped_interface;
}
$command .= " " . $escaped_host;
exec($command, $output, $result);

if ($result == 0) {
    $found = false;
    foreach ($output as $line) {
        if (strpos($line, "time=") !== false) {
            $time_part = explode("time=", $line)[1];
            $time = trim(explode(" ", $time_part)[0]);
            echo $time;
            $found = true;
            break;
        }
    }
    if (!$found) {
        echo "OK";
    }
} else {
    echo "NO PING";
}
?>
