<?php

if (!isset($_SESSION["authenticated"]) || $_SESSION["authenticated"] !== true) {
    header("Location: login.php");
    exit();
}

require_once __DIR__ . '/../includes/vpn_helpers.php';

$configs     = vp_loadConfigs();
$vpnState    = vp_readState();
$isConnected = vp_checkVPNStatus();
$activeId    = $vpnState['ACTIVE_ID'] ?? '';
$currentState = $vpnState['STATE'] ?? 'stopped';
$activatedByFailover = ($vpnState['ACTIVATED_BY'] ?? '') === 'failover';
$activeConfig = ($activeId && isset($configs[$activeId])) ? $configs[$activeId] : null;

$heroClass = 'overview-hero';
if ($currentState === 'stopped')      $heroClass .= ' overview-hero--stopped';
elseif ($isConnected)                 $heroClass .= ' overview-hero--connected';
else                                  $heroClass .= ' overview-hero--disconnected';

$interfaceRoles = ['tun0' => 'vpn', 'wg0' => 'vpn'];
$netplanFile = null;
if (is_dir('/etc/netplan/')) {
    $files = array_merge(
        glob('/etc/netplan/*.yaml') ?: [],
        glob('/etc/netplan/*.yml')  ?: []
    );
    foreach ($files as $f) {
        if (strpos($f, 'vpn-panel') !== false) { $netplanFile = $f; break; }
    }
    if (!$netplanFile && !empty($files)) $netplanFile = $files[0];
}
if ($netplanFile && function_exists('yaml_parse_file')) {
    $np = @yaml_parse_file($netplanFile);
    if (isset($np['network']['ethernets'])) {
        foreach ($np['network']['ethernets'] as $ifName => $cfg) {
            $interfaceRoles[$ifName] = (!empty($cfg['optional']) && $cfg['optional'] === true) ? 'lan' : 'wan';
        }
    }
}

$statsAssetsVer = '5.6.0';
?>

<link rel="stylesheet" href="assets/css/pages/stats.css?v=<?php echo $statsAssetsVer; ?>">

<div id="vpn-state-data"
     data-active-id="<?php echo htmlspecialchars($activeId); ?>"
     data-state="<?php echo htmlspecialchars($currentState); ?>"
     hidden></div>

<script type="application/json" id="stats-iface-roles"><?php echo json_encode($interfaceRoles, JSON_UNESCAPED_UNICODE); ?></script>

<div class="<?php echo $heroClass; ?>">

    <?php if ($activeConfig): ?>

        <div class="overview-protocol overview-protocol--<?php echo $activeConfig['type'] === 'wireguard' ? 'wg' : 'ovpn'; ?>">
            <?php if ($activeConfig['type'] === 'wireguard'): ?>

                <svg class="overview-protocol-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>
                    <polyline points="13 8 9 14 12 14 11 18 15 12 12 12 13 8"/>
                </svg>
            <?php else: ?>

                <svg class="overview-protocol-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>
                    <polyline points="9 12 11 14 15 10"/>
                </svg>
            <?php endif; ?>
            <span class="overview-protocol-name"><?php echo $activeConfig['type'] === 'wireguard' ? 'WireGuard' : 'OpenVPN'; ?></span>
        </div>

        <div class="overview-config-line">
            <span class="overview-config-name" title="<?php echo htmlspecialchars($activeConfig['name']); ?>">
                <?php echo htmlspecialchars($activeConfig['name']); ?>
            </span>
            <?php if (!empty($activeConfig['server'])): ?>
                <span class="overview-config-server">(<?php echo htmlspecialchars($activeConfig['server']); ?><?php if (!empty($activeConfig['port'])): ?>:<?php echo htmlspecialchars($activeConfig['port']); ?><?php endif; ?>)</span>
            <?php endif; ?>
        </div>
    <?php else: ?>

        <div class="overview-config-line">
            <span class="overview-config-name">— конфиг не выбран —</span>
            <span class="overview-config-server">Откройте раздел VPN для загрузки</span>
        </div>
    <?php endif; ?>

    <div class="overview-status">
        <span class="overview-status-dot"></span>
        <span>
            <?php
            if ($currentState === 'stopped')         echo 'Остановлен';
            elseif ($isConnected)                     echo 'Подключено';
            elseif ($currentState === 'recovering')   echo 'Восстановление';
            elseif ($currentState === 'restarting')   echo 'Перезапуск';
            else                                      echo 'Нет связи';
            ?>
        </span>
    </div>

    <?php if ($activatedByFailover): ?>
    <div class="overview-badges">
        <span class="badge badge--amber">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path stroke-linecap="round" stroke-linejoin="round" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
            </svg>
            Резерв активирован автоматически
        </span>
    </div>
    <?php endif; ?>

    <div class="overview-actions">
        <?php if ($activeId && $currentState !== 'stopped'): ?>
            <button type="button" class="btn btn--warning" data-action="restart">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" width="18" height="18">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
                </svg>
                Перезапустить VPN
            </button>
            <button type="button" class="btn btn--danger" data-action="stop">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" width="18" height="18">
                    <rect x="6" y="6" width="12" height="12" rx="2"/>
                </svg>
                Остановить
            </button>
        <?php elseif ($activeId): ?>
            <button type="button" class="btn btn--success"
                    data-action="activate"
                    data-config-id="<?php echo htmlspecialchars($activeId); ?>"
                    data-config-name="<?php echo htmlspecialchars($activeConfig['name'] ?? '', ENT_QUOTES); ?>">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="18" height="18">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M13 10V3L4 14h7v7l9-11h-7z"/>
                </svg>
                Подключиться
            </button>
        <?php else: ?>
            <a href="cabinet.php?menu=vpn" class="btn btn--primary">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" width="18" height="18">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M12 4v16m8-8H4"/>
                </svg>
                Добавить конфиг VPN
            </a>
        <?php endif; ?>

        <a href="cabinet.php?menu=vpn" class="btn btn--ghost">
            Все конфиги
        </a>
    </div>
</div>

<div class="server-info-card">
    <div class="overview-info-item">
        <span class="overview-info-icon overview-info-icon--cyan">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <polyline points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/>
            </svg>
        </span>
        <div class="overview-info-text">
            <div class="overview-info-label">Задержка</div>
            <div class="overview-info-value mono" id="overview-ping">—</div>
        </div>
    </div>

    <div class="overview-info-item">
        <span class="overview-info-icon overview-info-icon--emerald">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <circle cx="12" cy="12" r="10"/>
                <polyline points="12 6 12 12 16 14"/>
            </svg>
        </span>
        <div class="overview-info-text">
            <div class="overview-info-label">Время работы</div>
            <div class="overview-info-value mono" id="overview-uptime">—</div>
        </div>
    </div>

    <div class="overview-info-item">
        <span class="overview-info-icon overview-info-icon--amber">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/>
                <line x1="12" y1="9" x2="12" y2="13"/>
                <line x1="12" y1="17" x2="12.01" y2="17"/>
            </svg>
        </span>
        <div class="overview-info-text">
            <div class="overview-info-label">Последняя проблема</div>
            <div class="overview-info-value" id="overview-lastproblem">—</div>
            <div class="overview-info-sub" id="overview-lastproblem-time">—</div>
        </div>
    </div>

    <div class="overview-info-item">
        <span class="overview-info-icon overview-info-icon--violet">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <rect x="3" y="4" width="18" height="18" rx="2" ry="2"/>
                <line x1="16" y1="2" x2="16" y2="6"/>
                <line x1="8" y1="2" x2="8" y2="6"/>
                <line x1="3" y1="10" x2="21" y2="10"/>
            </svg>
        </span>
        <div class="overview-info-text">
            <div class="overview-info-label">Часы сервера</div>
            <div class="overview-info-value mono" id="overview-clock">—:—:—</div>
        </div>
    </div>
</div>

<div class="hidden-stats-sink" aria-hidden="true">
    <span id="uptime">—</span>
    <span id="lastDisconnect">—</span>
    <span id="lastDisconnectTime">—</span>
    <span id="currentTime">—</span>
    <span id="timezone">—</span>
    <span id="vpnStatus">—</span>
    <span id="vpnConfig">—</span>
    <span id="vpnIndicator"></span>
    <span id="vpnStatusCard"></span>
</div>

<div class="stats-grid stats-grid--3">

    <div class="resource-card">
        <div class="resource-card-header">
            <div class="resource-card-info">
                <div class="resource-card-label">Процессор (CPU)</div>
                <div class="resource-card-value" id="cpuText">0.0%</div>
            </div>
            <div class="progress-ring">
                <svg viewBox="0 0 80 80">
                    <circle class="progress-ring__track" r="34" cx="40" cy="40"/>
                    <circle id="cpuRing" class="progress-ring__fill" r="34" cx="40" cy="40"/>
                </svg>
                <div class="progress-ring__icon">
                    <svg viewBox="0 0 24 24" fill="none" stroke="var(--blue)" stroke-width="1.75">
                        <path stroke-linecap="round" stroke-linejoin="round" d="M9 3v2m6-2v2M9 19v2m6-2v2M5 9H3m2 6H3m18-6h-2m2 6h-2M7 19h10a2 2 0 002-2V7a2 2 0 00-2-2H7a2 2 0 00-2 2v10a2 2 0 002 2zM9 9h6v6H9V9z"/>
                    </svg>
                </div>
            </div>
        </div>
        <div class="resource-card-stats">
            <div class="resource-stat-row">
                <span class="resource-stat-label">Ядра</span>
                <span class="resource-stat-value" id="cpuCores">—</span>
            </div>
        </div>
    </div>

    <div class="resource-card">
        <div class="resource-card-header">
            <div class="resource-card-info">
                <div class="resource-card-label">Оперативная память</div>
                <div class="resource-card-value" id="ramText">0.0%</div>
            </div>
            <div class="progress-ring">
                <svg viewBox="0 0 80 80">
                    <circle class="progress-ring__track" r="34" cx="40" cy="40"/>
                    <circle id="ramRing" class="progress-ring__fill" r="34" cx="40" cy="40"/>
                </svg>
                <div class="progress-ring__icon">
                    <svg viewBox="0 0 24 24" fill="none" stroke="var(--cyan)" stroke-width="1.75">
                        <path stroke-linecap="round" stroke-linejoin="round" d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"/>
                    </svg>
                </div>
            </div>
        </div>
        <div class="resource-card-stats">
            <div class="resource-stat-row">
                <span class="resource-stat-label">Занято</span>
                <span class="resource-stat-value" id="ramUsed">—</span>
            </div>
            <div class="resource-stat-row">
                <span class="resource-stat-label">Всего</span>
                <span class="resource-stat-value" id="ramTotal">—</span>
            </div>
        </div>
    </div>

    <div class="resource-card">
        <div class="resource-card-header">
            <div class="resource-card-info">
                <div class="resource-card-label">Накопитель</div>
                <div class="resource-card-value" id="diskText">0.0%</div>
            </div>
            <div class="progress-ring">
                <svg viewBox="0 0 80 80">
                    <circle class="progress-ring__track" r="34" cx="40" cy="40"/>
                    <circle id="diskRing" class="progress-ring__fill" r="34" cx="40" cy="40"/>
                </svg>
                <div class="progress-ring__icon">
                    <svg viewBox="0 0 24 24" fill="none" stroke="var(--emerald)" stroke-width="1.75">
                        <path stroke-linecap="round" stroke-linejoin="round" d="M4 7v10c0 2.21 3.582 4 8 4s8-1.79 8-4V7M4 7c0 2.21 3.582 4 8 4s8-1.79 8-4M4 7c0-2.21 3.582-4 8-4s8 1.79 8 4"/>
                    </svg>
                </div>
            </div>
        </div>
        <div class="resource-card-stats">
            <div class="resource-stat-row">
                <span class="resource-stat-label">Занято</span>
                <span class="resource-stat-value" id="diskUsed">—</span>
            </div>
            <div class="resource-stat-row">
                <span class="resource-stat-label">Свободно</span>
                <span class="resource-stat-value" id="diskFree">—</span>
            </div>
        </div>
    </div>
</div>

<div class="section-card section-card--blue">
    <h3 class="section-title">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" style="color:var(--blue)">
            <path stroke-linecap="round" stroke-linejoin="round" d="M13 10V3L4 14h7v7l9-11h-7z"/>
        </svg>
        Скорость интернета
        <span class="section-title-hint">в реальном времени</span>
    </h3>
    <div id="speedSection" class="speed-grid">
        <div class="text-sm text-muted">Сбор данных...</div>
    </div>
</div>

<div class="section-card section-card--cyan">
    <h3 class="section-title">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" style="color:var(--cyan)">
            <path stroke-linecap="round" stroke-linejoin="round" d="M7 16V4m0 0L3 8m4-4l4 4m6 0v12m0 0l4-4m-4 4l-4-4"/>
        </svg>
        Использовано трафика
        <span class="section-title-hint">с момента включения</span>
    </h3>
    <div id="trafficSection" class="traffic-grid">
        <div class="text-sm text-muted">Загрузка...</div>
    </div>
</div>

<div class="stats-grid stats-grid--2">

    <div class="section-card section-card--amber" style="margin-bottom:0;">
        <div class="section-header">
            <h3 class="section-title" style="margin-bottom:0;">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" style="color:var(--amber)">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9"/>
                </svg>
                События
            </h3>
            <button type="button" class="btn btn--ghost btn--sm" id="events-clear-btn" title="Очистить журнал событий">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" width="16" height="16">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
                </svg>
                Очистить
            </button>
        </div>
        <div id="configHistory" class="history-list">
            <div class="history-item">
                <span class="skeleton" style="width:20px;height:20px;border-radius:50%"></span>
                <div class="history-body" style="flex:1">
                    <div class="skeleton skeleton--text" style="width:85%"></div>
                </div>
                <div class="history-meta">
                    <span class="skeleton" style="width:60px;height:18px"></span>
                </div>
            </div>
            <div class="history-item">
                <span class="skeleton" style="width:20px;height:20px;border-radius:50%"></span>
                <div class="history-body" style="flex:1">
                    <div class="skeleton skeleton--text" style="width:70%"></div>
                </div>
                <div class="history-meta">
                    <span class="skeleton" style="width:60px;height:18px"></span>
                </div>
            </div>
            <div class="history-item">
                <span class="skeleton" style="width:20px;height:20px;border-radius:50%"></span>
                <div class="history-body" style="flex:1">
                    <div class="skeleton skeleton--text" style="width:60%"></div>
                </div>
                <div class="history-meta">
                    <span class="skeleton" style="width:60px;height:18px"></span>
                </div>
            </div>
        </div>
    </div>

    <div class="section-card section-card--emerald" style="margin-bottom:0;">
        <h3 class="section-title">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" style="color:var(--emerald)">
                <path stroke-linecap="round" stroke-linejoin="round" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"/>
                <circle cx="12" cy="12" r="3"/>
            </svg>
            Время работы на конфигах
        </h3>
        <div id="configStats" class="config-stats-list">
            <div class="config-stat-item">
                <div class="config-stat-head">
                    <span class="skeleton skeleton--text" style="width:140px"></span>
                    <span class="skeleton skeleton--text" style="width:60px"></span>
                </div>
                <div class="skeleton" style="height:8px;border-radius:var(--radius-full)"></div>
            </div>
            <div class="config-stat-item">
                <div class="config-stat-head">
                    <span class="skeleton skeleton--text" style="width:100px"></span>
                    <span class="skeleton skeleton--text" style="width:60px"></span>
                </div>
                <div class="skeleton" style="height:8px;border-radius:var(--radius-full)"></div>
            </div>
        </div>
    </div>
</div>

<script>

(function() {
    'use strict';

    function init() {

        const pingEl = document.getElementById('overview-ping');
        if (pingEl && window.VPNPanel && window.VPNPanel.ping) {
            window.VPNPanel.ping.subscribe(({ status, ms }) => {
                if (status === 'ok') {
                    pingEl.textContent = ms + ' мс';
                    pingEl.className = 'overview-info-value mono overview-info-value--ping-ok';
                } else if (status === 'slow') {
                    pingEl.textContent = ms + ' мс';
                    pingEl.className = 'overview-info-value mono overview-info-value--ping-slow';
                } else if (status === 'bad') {
                    pingEl.textContent = ms !== null ? (ms + ' мс') : '—';
                    pingEl.className = 'overview-info-value mono overview-info-value--ping-bad';
                } else {
                    pingEl.textContent = '—';
                    pingEl.className = 'overview-info-value mono';
                }
            });
        }

        function mirror(sourceId, targetId) {
            const source = document.getElementById(sourceId);
            const target = document.getElementById(targetId);
            if (!source || !target) return;
            const update = () => {
                const txt = source.textContent.trim();
                if (txt && !source.querySelector('.skeleton')) {
                    target.textContent = txt;
                }
            };
            update();
            new MutationObserver(update).observe(source, {
                childList: true, subtree: true, characterData: true
            });
        }

        mirror('uptime',             'overview-uptime');
        mirror('lastDisconnect',     'overview-lastproblem');
        mirror('lastDisconnectTime', 'overview-lastproblem-time');
        mirror('currentTime',        'overview-clock');
        mirror('timezone',           'overview-tz');
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        setTimeout(init, 0);
    }

    const API_VPN = 'api/vpn_action.php';
    async function vpnApi(action, payload = {}) {
        if (window.Progress) Progress.start();
        try {
            const r = await fetch(API_VPN, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
                body: JSON.stringify({ action, ...payload }),
            });
            return await r.json();
        } catch (e) {
            return { ok: false, error: 'Ошибка связи: ' + e.message };
        } finally {
            if (window.Progress) Progress.done();
        }
    }

    document.addEventListener('click', async function(e) {
        const btn = e.target.closest('.overview-hero [data-action]');
        if (!btn) return;
        const action = btn.dataset.action;

        if (action === 'activate') {
            e.preventDefault();
            const configId = btn.dataset.configId;
            if (!configId) return;
            window.showVpnLoading && showVpnLoading('Подключение VPN...');
            const r = await vpnApi('activate', { config_id: configId });
            window.hideVpnLoading && hideVpnLoading();
            if (r.ok) { Toast.success(r.message || 'Подключено'); setTimeout(() => location.reload(), 500); }
            else     { Toast.error(r.error || 'Ошибка'); setTimeout(() => location.reload(), 1000); }
        }
        else if (action === 'stop') {
            e.preventDefault();

            const ok = window.VPNPanel && window.VPNPanel.confirm
                ? await VPNPanel.confirm({
                    title:       'Остановить VPN?',
                    message:     'Соединение будет разорвано. Kill switch остановит весь интернет-трафик в локальной сети.',
                    confirmText: 'Остановить',
                    cancelText:  'Отмена',
                    danger:      true,
                })
                : confirm('Остановить VPN?');
            if (!ok) return;
            window.showVpnLoading && showVpnLoading('Остановка VPN...');
            const r = await vpnApi('stop');
            window.hideVpnLoading && hideVpnLoading();
            if (r.ok) { Toast.success(r.message || 'VPN остановлен'); setTimeout(() => location.reload(), 500); }
            else     { Toast.error(r.error || 'Ошибка'); }
        }
        else if (action === 'restart') {
            e.preventDefault();
            window.showVpnLoading && showVpnLoading('Перезапуск VPN...');
            const r = await vpnApi('restart');
            window.hideVpnLoading && hideVpnLoading();
            if (r.ok) { Toast.success(r.message || 'VPN перезапущен'); setTimeout(() => location.reload(), 500); }
            else     { Toast.error(r.error || 'Ошибка'); setTimeout(() => location.reload(), 1000); }
        }
    });
})();
</script>

<script src="assets/js/pages/stats.js?v=<?php echo $statsAssetsVer; ?>"></script>
