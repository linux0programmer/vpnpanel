<?php

require_once __DIR__ . '/includes/guard.php';
require_once __DIR__ . '/includes/vpn_helpers.php';

if (!isset($_SESSION["authenticated"]) || $_SESSION["authenticated"] !== true) {
    header("Location: login.php");
    exit();
}

define('SESSION_TIMEOUT', 8 * 3600);
if (isset($_SESSION['login_time']) && (time() - $_SESSION['login_time']) > SESSION_TIMEOUT) {
    session_unset(); session_destroy();
    header('Location: login.php?reason=timeout'); exit();
}
$inactiveTimeout = 30 * 60;
if (isset($_SESSION['last_activity']) && (time() - $_SESSION['last_activity']) > $inactiveTimeout) {
    session_unset(); session_destroy();
    header('Location: login.php?reason=timeout'); exit();
}
$_SESSION['last_activity'] = time();

if (isset($_SESSION['ip']) && !empty($_SESSION['ip'])) {
    $currentIp = $_SERVER['REMOTE_ADDR'] ?? '';
    if ($currentIp !== $_SESSION['ip']) {
        session_unset(); session_destroy();
        header('Location: login.php'); exit();
    }
}

if (isset($_POST['menu'])) {
    $_GET['menu'] = $_POST['menu'];
}
$menu_item = $_GET['menu'] ?? 'stats';

$menu_pages = [
    'stats'       => 'pages/stats.php',
    'vpn'         => 'pages/vpn-manager.php',
    'ping'        => 'pages/pinger.php',
    'speed'       => 'pages/speed.php',
    'console'     => 'pages/console.php',
    'netsettings' => 'pages/netsettings.php',
    'settings'    => 'pages/settings.php',
    'about'       => 'pages/about.php',
];
if (!array_key_exists($menu_item, $menu_pages)) {
    $menu_item = 'stats';
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    vp_requireCsrf(false);

    $renderFile  = $menu_pages[$menu_item];
    $handlerPath = __DIR__ . '/' . preg_replace('/\.php$/', '.handler.php', $renderFile);
    if (file_exists($handlerPath)) {
        include_once $handlerPath;

    }
}

function menuActive(string $current, string $item): string {
    return $current === $item ? 'menu-item is-active' : 'menu-item';
}

$cssVer = '5.6.8';
?><!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><?php echo htmlspecialchars(vp_panelConf('PANEL_TITLE', 'Панель')); ?></title>
    <meta name="robots" content="noindex, nofollow">
    <meta name="referrer" content="no-referrer">

    <link rel="stylesheet" href="assets/css/tokens.css?v=<?php echo $cssVer; ?>">
    <link rel="stylesheet" href="assets/css/base.css?v=<?php echo $cssVer; ?>">
    <link rel="stylesheet" href="assets/css/components.css?v=<?php echo $cssVer; ?>">
    <link rel="stylesheet" href="assets/css/layout.css?v=<?php echo $cssVer; ?>">
</head>
<body data-page="<?php echo htmlspecialchars($menu_item); ?>">

<div class="app">

    <aside class="sidebar">

        <a href="cabinet.php" class="sidebar-brand" aria-label="VPN">
            <span class="sidebar-mark" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9"><path stroke-linecap="round" stroke-linejoin="round" d="M12 3l7 3v5.5c0 4.2-2.9 7.9-7 9-4.1-1.1-7-4.8-7-9V6l7-3z"/><path stroke-linecap="round" stroke-linejoin="round" d="M9 12l2 2 4-4"/></svg></span>
            <div class="sidebar-brand-text">
                <div class="sidebar-brand-name">VPN</div>
                <div class="sidebar-brand-sub">Server Panel</div>
            </div>
        </a>

        <nav class="sidebar-nav" aria-label="Навигация">

            <a href="cabinet.php?menu=stats" class="<?php echo menuActive($menu_item, 'stats'); ?>" data-accent="blue">
                <svg class="menu-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"/>
                </svg>
                <span class="menu-label">Обзор</span>
            </a>

            <a href="cabinet.php?menu=vpn" class="<?php echo menuActive($menu_item, 'vpn'); ?>" data-accent="emerald">
                <svg class="menu-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z"/>
                </svg>
                <span class="menu-label">VPN</span>
                <span class="menu-meta">
                    <span id="sidebar-vpn-dot" class="status-dot status-dot--off" aria-hidden="true"></span>
                    <span id="sidebar-ping-display" class="menu-ping">—</span>
                </span>
            </a>

            <a href="cabinet.php?menu=ping" class="<?php echo menuActive($menu_item, 'ping'); ?>" data-accent="cyan">
                <svg class="menu-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M13 10V3L4 14h7v7l9-11h-7z"/>
                </svg>
                <span class="menu-label">Пинг</span>
            </a>

            <a href="cabinet.php?menu=speed" class="<?php echo menuActive($menu_item, 'speed'); ?>" data-accent="cyan">
                <svg class="menu-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M3 12a9 9 0 1018 0 9 9 0 00-18 0z"/>
                    <path stroke-linecap="round" stroke-linejoin="round" d="M12 12l4-4"/>
                </svg>
                <span class="menu-label">Скорость</span>
            </a>

            <a href="cabinet.php?menu=console" class="<?php echo menuActive($menu_item, 'console'); ?>" data-accent="purple">
                <svg class="menu-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M8 9l3 3-3 3m5 0h3M5 20h14a2 2 0 002-2V6a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"/>
                </svg>
                <span class="menu-label">Консоль</span>
            </a>

            <a href="cabinet.php?menu=netsettings" class="<?php echo menuActive($menu_item, 'netsettings'); ?>" data-accent="amber">
                <svg class="menu-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M21 12a9 9 0 01-9 9m9-9a9 9 0 00-9-9m9 9H3m9 9a9 9 0 01-9-9m9 9c1.657 0 3-4.03 3-9s-1.343-9-3-9m0 18c-1.657 0-3-4.03-3-9s1.343-9 3-9m-9 9a9 9 0 019-9"/>
                </svg>
                <span class="menu-label">Сеть</span>
            </a>

            <a href="cabinet.php?menu=settings" class="<?php echo menuActive($menu_item, 'settings'); ?>" data-accent="slate">
                <svg class="menu-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"/>
                    <circle cx="12" cy="12" r="3"/>
                </svg>
                <span class="menu-label">Настройки</span>
            </a>

            <a href="cabinet.php?menu=about" class="<?php echo menuActive($menu_item, 'about'); ?>" data-accent="pink">
                <svg class="menu-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75">
                    <circle cx="12" cy="12" r="10"/>
                    <path stroke-linecap="round" stroke-linejoin="round" d="M12 16v-4m0-4h.01"/>
                </svg>
                <span class="menu-label">О продукте</span>
            </a>

            <div class="sidebar-divider"></div>

            <a href="logout.php" class="menu-item menu-item--logout">
                <svg class="menu-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1"/>
                </svg>
                <span class="menu-label">Выход</span>
            </a>
        </nav>

        <div class="sidebar-footer">
            <div class="sidebar-status" id="sidebar-status">
                <span class="status-dot status-dot--off" id="sidebar-status-dot" aria-hidden="true"></span>
                <div class="sidebar-status-text">
                    <div class="sidebar-status-title" id="sidebar-status-title">Проверка связи</div>
                    <div class="sidebar-status-sub" id="sidebar-status-sub">задержка —</div>
                </div>
            </div>
        </div>

    </aside>

    <main class="main">
        <div class="page-content">
            <?php
            $pagePath = __DIR__ . '/' . $menu_pages[$menu_item];
            if (file_exists($pagePath)) {
                include_once $pagePath;
            } else {
                echo '<div class="card"><div class="empty-state">';
                echo '<div class="empty-state-title text-rose">Страница не найдена</div>';
                echo '<div class="empty-state-text">Проверьте параметр ?menu=</div>';
                echo '</div></div>';
            }
            ?>
        </div>
    </main>

</div>

<script src="assets/js/lib/toast.js?v=<?php echo $cssVer; ?>"></script>
<script src="assets/js/lib/progress.js?v=<?php echo $cssVer; ?>"></script>
<script src="assets/js/lib/shortcuts.js?v=<?php echo $cssVer; ?>"></script>
<script src="assets/js/lib/custom-select.js?v=<?php echo $cssVer; ?>"></script>
<script src="assets/js/lib/confirm.js?v=<?php echo $cssVer; ?>"></script>
<script src="assets/js/app.js?v=<?php echo $cssVer; ?>"></script>

</body>
</html>
