<?php

require_once __DIR__ . '/../includes/guard.php';
require_once __DIR__ . '/../includes/vpn_helpers.php';

if (!isset($_SESSION["authenticated"]) || $_SESSION["authenticated"] !== true) {
    header("Location: login.php");
    exit();
}

$speedAssetsVer = '1.3.0';
$speedBinary    = is_file('/usr/local/bin/speedtest') && is_executable('/usr/local/bin/speedtest');
$speedChannels  = vp_speedChannels();
?>

<link rel="stylesheet" href="assets/css/pages/speed.css?v=<?php echo $speedAssetsVer; ?>">

<div class="speed-page-header">
    <h1>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75">
            <path stroke-linecap="round" stroke-linejoin="round" d="M13 10V3L4 14h7v7l9-11h-7z"/>
        </svg>
        Скорость
    </h1>
    <p class="text-sm text-muted">Замер через официальный клиент Speedtest by Ookla. Можно померить каждый канал отдельно.</p>
</div>

<?php if (!$speedBinary): ?>
<div class="card card--accent-amber">
    <div class="empty-state">
        <div class="empty-state-title">Speedtest CLI не установлен</div>
        <div class="empty-state-text">
            Он ставится сам — при установке панели и при каждом обновлении. Если вы это видите,
            значит загрузка не удалась: скорее всего сервер не достучался до
            <span class="mono">install.speedtest.net</span>.
            <pre class="speed-hint mono">sudo vpn-panel-deploy deploy</pre>
            повторит попытку. Если доступа к сайту Ookla нет совсем — положите бинарник в
            <span class="mono">panel/bin/speedtest</span> в репозитории, и он поедет вместе с выпуском.
        </div>
    </div>
</div>
<?php else: ?>

<div class="card card--accent-cyan">
    <div class="card-header">
        <div class="card-title">
            <span class="icon-badge icon-badge--cyan">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M3 12a9 9 0 1018 0 9 9 0 00-18 0z"/><path stroke-linecap="round" stroke-linejoin="round" d="M12 12l4-4"/></svg>
            </span>
            Замер канала
        </div>
        <span id="speed-state" class="badge badge--slate">готов</span>
    </div>

    <div class="speed-controls">
        <label for="speed-iface" class="speed-label">Через какой канал мерить</label>
        <select id="speed-iface" class="select">
            <option value="">Текущий маршрут по умолчанию</option>
            <?php foreach ($speedChannels as $chan): ?>
            <option value="<?php echo htmlspecialchars($chan['iface']); ?>">
                <?php
                    $label = $chan['iface'];
                    if ($chan['tunnel'])   $label .= ' — через VPN-туннель';
                    if ($chan['active'])   $label .= ' — активный';
                    if ($chan['state'] !== 'up') $label .= ' (' . $chan['state'] . ')';
                    echo htmlspecialchars($label);
                ?>
            </option>
            <?php endforeach; ?>
        </select>
        <button id="speed-run" type="button" class="btn btn--primary">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" width="16" height="16">
                <path stroke-linecap="round" stroke-linejoin="round" d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z"/>
                <path stroke-linecap="round" stroke-linejoin="round" d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
            </svg>
            Запустить замер
        </button>
    </div>

    <div id="speed-progress" class="speed-progress" hidden>
        <div class="speed-progress-bar"><span></span></div>
        <div id="speed-progress-text" class="speed-progress-text">Идёт замер…</div>
    </div>

    <div id="speed-error" class="speed-error" hidden></div>

    <div id="speed-result" class="speed-result" hidden>
        <div class="speed-metric speed-metric--down">
            <div class="speed-metric-head">Приём</div>
            <div class="speed-metric-value"><span id="speed-download">—</span><span class="speed-metric-unit">Мбит/с</span></div>
        </div>
        <div class="speed-metric speed-metric--up">
            <div class="speed-metric-head">Отдача</div>
            <div class="speed-metric-value"><span id="speed-upload">—</span><span class="speed-metric-unit">Мбит/с</span></div>
        </div>
        <div class="speed-metric speed-metric--ping">
            <div class="speed-metric-head">Задержка</div>
            <div class="speed-metric-value"><span id="speed-ping">—</span><span class="speed-metric-unit">мс</span></div>
        </div>
    </div>

    <div id="speed-meta" class="speed-meta" hidden></div>
</div>

<div class="card card--accent-violet">
    <div class="card-header">
        <div class="card-title">
            <span class="icon-badge icon-badge--violet">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
            </span>
            История замеров
        </div>
        <div class="speed-history-actions">
            <span id="speed-history-count" class="badge badge--slate">0</span>
            <button id="speed-history-clear" type="button" class="btn btn--ghost btn--sm" hidden>Очистить</button>
        </div>
    </div>

    <div id="speed-history-empty" class="empty-state">
        <div class="empty-state-text">Замеров ещё не было</div>
    </div>

    <div id="speed-history-wrap" class="table-wrap" hidden>
        <table class="table">
            <thead>
                <tr>
                    <th>Когда</th>
                    <th>Канал</th>
                    <th>Приём</th>
                    <th>Отдача</th>
                    <th>Задержка</th>
                    <th>Сервер</th>
                    <th style="width:44px"></th>
                </tr>
            </thead>
            <tbody id="speed-history-body"></tbody>
        </table>
    </div>
</div>

<script src="assets/js/pages/speed.js?v=<?php echo $speedAssetsVer; ?>"></script>
<?php endif; ?>
