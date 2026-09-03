<?php

require_once __DIR__ . '/includes/guard.php';

$purpose     = $_SERVER['HTTP_SEC_PURPOSE'] ?? ($_SERVER['HTTP_PURPOSE'] ?? '');
$mozPrefetch = $_SERVER['HTTP_X_MOZ']       ?? '';

if (stripos($purpose, 'prefetch') !== false
    || stripos($purpose, 'prerender') !== false
    || stripos($mozPrefetch, 'prefetch') !== false) {

    http_response_code(204);
    header('Cache-Control: no-store');
    exit;
}

session_unset();
session_destroy();

if (ini_get('session.use_cookies')) {
    $params = session_get_cookie_params();
    setcookie(
        session_name(), '', time() - 42000,
        $params['path'], $params['domain'],
        $params['secure'], $params['httponly']
    );
}

header('Location: login.php');
exit();
?>
