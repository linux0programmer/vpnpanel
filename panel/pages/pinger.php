<?php

if (!isset($_SESSION["authenticated"]) || $_SESSION["authenticated"] !== true) {
    header("Location: login.php");
    exit();
}

$pingerAssetsVer = '5.5.2';
?>

<link rel="stylesheet" href="assets/css/pages/pinger.css?v=<?php echo $pingerAssetsVer; ?>">

<div class="pinger-page-header">
    <h1>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75">
            <path stroke-linecap="round" stroke-linejoin="round" d="M13 10V3L4 14h7v7l9-11h-7z"/>
        </svg>
        Диагностика пинга
    </h1>
    <p class="text-sm text-muted">
        Измерение задержки до любого IP или хоста через выбранный интерфейс
    </p>
</div>

<div class="pinger-layout">

    <div class="card card--accent-cyan">
        <div class="pinger-controls">
            <div>
                <label class="label">IP адрес или хост</label>
                <input type="text" id="targetAddress" class="input mono" value="8.8.8.8" placeholder="Например: 8.8.8.8 или google.com">
            </div>
            <div>
                <label class="label">Интерфейс</label>
                <select id="networkInterface" class="select">
                    <option value="">По Умолчанию</option>
                    <option value="detect_netplan">Белый Интернет</option>
                    <option value="tun0">VPN Туннель</option>
                </select>
            </div>
            <div>
                <label class="label">&nbsp;</label>
                <div class="pinger-buttons">
                    <button type="button" id="startButton" class="btn btn--primary">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="14" height="14">
                            <path stroke-linecap="round" stroke-linejoin="round" d="M14.828 14.828a4 4 0 01-5.656 0M9 10h.01M15 10h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
                        </svg>
                        Старт
                    </button>
                    <button type="button" id="stopButton" class="btn btn--danger">Стоп</button>
                </div>
            </div>
        </div>
    </div>

    <div class="card card--accent-blue">
        <div class="pinger-stats-grid" style="margin-bottom: var(--space-3);">
            <div class="pinger-stat">
                <span class="pinger-stat-label">Отправлено</span>
                <span class="pinger-stat-value" id="allCount">0</span>
            </div>
            <div class="pinger-stat">
                <span class="pinger-stat-label">Успешно</span>
                <span class="pinger-stat-value pinger-stat-value--good" id="successCount">0</span>
            </div>
            <div class="pinger-stat">
                <span class="pinger-stat-label">Потеряно</span>
                <span class="pinger-stat-value pinger-stat-value--bad" id="failCount">0</span>
            </div>
            <div class="pinger-stat">
                <span class="pinger-stat-label">Потери</span>
                <span class="pinger-stat-value pinger-stat-value--warn" id="lossPercent">0%</span>
            </div>
        </div>
        <div class="pinger-stats-grid">
            <div class="pinger-stat">
                <span class="pinger-stat-label">Минимум</span>
                <span>
                    <span class="pinger-stat-value pinger-stat-value--info" id="minPing">—</span>
                    <span class="pinger-stat-unit">мс</span>
                </span>
            </div>
            <div class="pinger-stat">
                <span class="pinger-stat-label">Средний</span>
                <span>
                    <span class="pinger-stat-value pinger-stat-value--info" id="avgPing">—</span>
                    <span class="pinger-stat-unit">мс</span>
                </span>
            </div>
            <div class="pinger-stat">
                <span class="pinger-stat-label">Максимум</span>
                <span>
                    <span class="pinger-stat-value pinger-stat-value--info" id="maxPing">—</span>
                    <span class="pinger-stat-unit">мс</span>
                </span>
            </div>
            <div class="pinger-stat">
                <span class="pinger-stat-label">Последний</span>
                <span>
                    <span class="pinger-stat-value" id="lastPing">—</span>
                    <span class="pinger-stat-unit">мс</span>
                </span>
            </div>
        </div>
    </div>

    <div class="card card--accent-violet pinger-log-card">
        <div id="pingLog"></div>
    </div>

</div>

<script>

(function() {
    'use strict';

    let intervalId = null;
    let allCount = 0, successCount = 0, failCount = 0;
    let minPing = Infinity, maxPing = -Infinity, totalPing = 0;

    const $ = (id) => document.getElementById(id);

    function resetStats() {
        allCount = 0; successCount = 0; failCount = 0;
        minPing = Infinity; maxPing = -Infinity; totalPing = 0;
        $('allCount').textContent = '0';
        $('successCount').textContent = '0';
        $('failCount').textContent = '0';
        $('lossPercent').textContent = '0%';
        $('minPing').textContent = '—';
        $('avgPing').textContent = '—';
        $('maxPing').textContent = '—';
        $('lastPing').textContent = '—';
    }

    function appendLog(text, cls) {
        const log = $('pingLog');
        const p = document.createElement('p');
        p.textContent = text;
        if (cls) p.className = cls;
        log.appendChild(p);

        while (log.children.length > 500) log.firstChild.remove();
        log.scrollTop = log.scrollHeight;
    }

    function measurePing(target, iface) {
        fetch('api/ping.php?host=' + encodeURIComponent(target) + '&interface=' + encodeURIComponent(iface), { cache: 'no-store' })
            .then(r => r.text())
            .then(data => {
                const now = new Date().toLocaleTimeString();
                allCount++;
                let ping = NaN;

                if (!data.includes('NO PING')) {
                    successCount++;
                    ping = parseFloat(data);
                    minPing = Math.min(minPing, ping);
                    maxPing = Math.max(maxPing, ping);
                    totalPing += ping;

                    const avg = totalPing / successCount;
                    const isSpike = !isNaN(avg) && ping > (avg + 20);
                    appendLog(`${now}  ·  ping → ${target}  ·  ${ping.toFixed(1)} мс`,
                              isSpike ? 'log-slow' : 'log-ok');
                } else {
                    failCount++;
                    appendLog(`${now}  ·  ping → ${target}  ·  NO PING`, 'log-fail');
                }

                $('allCount').textContent = allCount;
                $('successCount').textContent = successCount;
                $('failCount').textContent = failCount;
                const loss = (allCount === 0) ? 0 : (failCount / allCount * 100);
                $('lossPercent').textContent = loss.toFixed(1) + '%';
                $('minPing').textContent = (minPing === Infinity) ? '—' : minPing.toFixed(1);
                $('maxPing').textContent = (maxPing === -Infinity) ? '—' : maxPing.toFixed(1);
                const avg = totalPing / successCount;
                $('avgPing').textContent = isNaN(avg) ? '—' : avg.toFixed(1);
                $('lastPing').textContent = isNaN(ping) ? '—' : ping.toFixed(1);
            })
            .catch(() => {
                allCount++;
                failCount++;
                appendLog(new Date().toLocaleTimeString() + '  ·  ERROR: ошибка запроса', 'log-fail');
            });
    }

    $('startButton').addEventListener('click', () => {
        const target = $('targetAddress').value.trim();
        const iface  = $('networkInterface').value;
        if (!target) {
            window.Toast && Toast.error('Введите адрес для проверки пинга');
            return;
        }
        if (intervalId) clearInterval(intervalId);
        resetStats();
        $('pingLog').innerHTML = '';
        measurePing(target, iface);
        intervalId = setInterval(() => measurePing(target, iface), 1000);
    });

    $('stopButton').addEventListener('click', () => {
        if (intervalId) { clearInterval(intervalId); intervalId = null; }
    });

    $('targetAddress').addEventListener('keydown', (e) => {
        if (e.key === 'Enter') { e.preventDefault(); $('startButton').click(); }
    });
})();
</script>
