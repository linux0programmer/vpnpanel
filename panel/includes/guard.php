<?php

if (session_status() === PHP_SESSION_NONE) {
    session_set_cookie_params([
        'httponly' => true,
        'samesite' => 'Strict',
        'path'     => '/',
    ]);
    session_start();
}

if (!defined('VP_SESSION_TIMEOUT'))   define('VP_SESSION_TIMEOUT', 8 * 3600);
if (!defined('VP_IDLE_TIMEOUT'))      define('VP_IDLE_TIMEOUT', 30 * 60);

function vp_sessionValid(): bool {
    if (!isset($_SESSION['authenticated']) || $_SESSION['authenticated'] !== true) {
        return false;
    }
    if (isset($_SESSION['login_time']) && (time() - $_SESSION['login_time']) > VP_SESSION_TIMEOUT) {
        return false;
    }
    if (isset($_SESSION['last_activity']) && (time() - $_SESSION['last_activity']) > VP_IDLE_TIMEOUT) {
        return false;
    }
    if (!empty($_SESSION['ip']) && ($_SERVER['REMOTE_ADDR'] ?? '') !== $_SESSION['ip']) {
        return false;
    }
    return true;
}

function vp_dropSession(): void {
    $_SESSION = [];
    session_unset();
    session_destroy();
}

function vp_requireSession(bool $json = false): void {
    if (vp_sessionValid()) {
        $_SESSION['last_activity'] = time();
        return;
    }
    vp_dropSession();
    if ($json) {
        http_response_code(401);
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode(['success' => false, 'error' => 'Сессия истекла'], JSON_UNESCAPED_UNICODE);
    } else {
        header('Location: login.php?reason=timeout');
    }
    exit();
}

function vp_csrfToken(): string {
    if (empty($_SESSION['csrf'])) {
        $_SESSION['csrf'] = bin2hex(random_bytes(32));
    }
    return $_SESSION['csrf'];
}

function vp_csrfField(): string {
    return '<input type="hidden" name="csrf" value="' . htmlspecialchars(vp_csrfToken(), ENT_QUOTES) . '">';
}

function vp_isAjax(): bool {
    return strcasecmp($_SERVER['HTTP_X_REQUESTED_WITH'] ?? '', 'XMLHttpRequest') === 0;
}

function vp_csrfValid(): bool {
    if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
        return true;
    }
    $sent = $_POST['csrf'] ?? '';
    if ($sent !== '' && !empty($_SESSION['csrf']) && hash_equals($_SESSION['csrf'], (string)$sent)) {
        return true;
    }
    return vp_isAjax();
}

function vp_requireCsrf(bool $json = false): void {
    if (vp_csrfValid()) {
        return;
    }
    if ($json) {
        http_response_code(403);
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode(['success' => false, 'error' => 'Запрос отклонён: не пройдена проверка происхождения'], JSON_UNESCAPED_UNICODE);
    } else {
        http_response_code(403);
        echo 'Запрос отклонён: не пройдена проверка происхождения';
    }
    exit();
}
