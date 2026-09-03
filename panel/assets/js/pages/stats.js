
(function() {
    'use strict';

    const LIVE_UPD_MS      = 2000;
    const LIVE_UPD_MS_LITE = 5000;
    const SLOW_UPD_MS      = 5000;

    const CHART_POINTS     = 60;

    let hist = {};
    try {
        const s = sessionStorage.getItem('vp_hist');
        if (s) hist = JSON.parse(s);
    } catch (e) {}

    function saveHist() {
        try { sessionStorage.setItem('vp_hist', JSON.stringify(hist)); } catch (e) {}
    }

    function txt(id, v) {
        const el = document.getElementById(id);
        if (el && el.textContent !== v) el.textContent = v;
    }

    function el(id) { return document.getElementById(id); }

    function escapeHtml(s) {
        return String(s || '').replace(/[&<>"']/g, c => (
            { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
        ));
    }

    function fmtSpeed(bytesPerSec) {

        if (!bytesPerSec || bytesPerSec < 1) return '0 бит/с';
        const bps = bytesPerSec * 8;
        if (bps < 1000)        return bps.toFixed(0) + ' бит/с';
        if (bps < 1_000_000)   return (bps / 1000).toFixed(1) + ' Кбит/с';
        if (bps < 1_000_000_000) return (bps / 1_000_000).toFixed(2) + ' Мбит/с';
        return (bps / 1_000_000_000).toFixed(2) + ' Гбит/с';
    }

    function isReducedMotion() {
        return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    }

    let IFACE_ROLES = {};

    function loadIfaceRoles() {
        const node = document.getElementById('stats-iface-roles');
        if (!node) return;
        try { IFACE_ROLES = JSON.parse(node.textContent) || {}; } catch (e) {}
    }

    function ifaceRole(iface) {
        if (IFACE_ROLES[iface]) return IFACE_ROLES[iface];
        if (iface === 'tun0' || iface === 'wg0') return 'vpn';
        return 'unknown';
    }

    function ifaceName(iface) {
        const role = ifaceRole(iface);
        if (role === 'vpn')     return 'VPN-туннель';
        if (role === 'wan')     return 'Интернет-провайдер';
        if (role === 'lan')     return 'Локальная сеть';
        return iface;
    }

    function ifaceIconSvg(role) {

        const icons = {
            vpn: '<svg class="iface-name-icon iface-name-icon--vpn" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"/></svg>',
            wan: '<svg class="iface-name-icon iface-name-icon--wan" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><circle cx="12" cy="12" r="10"/><path stroke-linecap="round" d="M2 12h20M12 2a15 15 0 010 20M12 2a15 15 0 000 20"/></svg>',
            lan: '<svg class="iface-name-icon iface-name-icon--lan" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6"/></svg>',
            unknown: '<svg class="iface-name-icon iface-name-icon--other" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01"/></svg>',
        };
        return icons[role] || icons.unknown;
    }

    function ifaceOrd(iface) {
        const r = ifaceRole(iface);
        return r === 'vpn' ? 0 : r === 'wan' ? 1 : r === 'lan' ? 2 : 3;
    }
    function sortIfaces(a, b) { return ifaceOrd(a) - ifaceOrd(b); }

    const RING_CIRC = 213.6;

    function updateRing(id, pct) {
        const circle = el(id);
        if (!circle) return;
        circle.style.strokeDashoffset = RING_CIRC - (pct / 100) * RING_CIRC;
        const col = pct < 50 ? '#10B981'
                  : pct < 70 ? '#F59E0B'
                  : pct < 90 ? '#F97316'
                  :            '#F43F5E';
        circle.style.stroke = col;
    }

    const smoothMax = {};

    function drawChart(canvasId, rxArr, txArr) {
        const cv = el(canvasId);
        if (!cv || !cv.offsetWidth) return;

        const dpr = window.devicePixelRatio || 1;
        const w = cv.offsetWidth;
        const h = cv.offsetHeight;

        if (cv.width !== w * dpr || cv.height !== h * dpr) {
            cv.width = w * dpr;
            cv.height = h * dpr;
        }

        const ctx = cv.getContext('2d');
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.clearRect(0, 0, w, h);

        const rawMax = Math.max(1024, ...rxArr, ...txArr);
        if (!smoothMax[canvasId]) smoothMax[canvasId] = rawMax;

        if (rawMax > smoothMax[canvasId]) smoothMax[canvasId] += (rawMax - smoothMax[canvasId]) * 0.4;
        else                              smoothMax[canvasId] += (rawMax - smoothMax[canvasId]) * 0.06;
        const maxV = smoothMax[canvasId];

        ctx.strokeStyle = 'rgba(100, 116, 139, 0.1)';
        ctx.lineWidth = 0.5;
        for (let y = h / 4; y < h; y += h / 4) {
            ctx.beginPath();
            ctx.moveTo(0, y);
            ctx.lineTo(w, y);
            ctx.stroke();
        }

        const step = w / (CHART_POINTS - 1);

        function drawCurve(data, color, fillAlpha) {
            const n = data.length;
            if (n < 2) return;
            const offset = Math.max(0, n - CHART_POINTS);
            const pts = [];
            for (let i = offset; i < n; i++) {
                const x = (i - offset) * step;
                const y = h - (data[i] / maxV) * (h - 8) - 4;
                pts.push({ x, y });
            }

            ctx.beginPath();
            ctx.strokeStyle = color;
            ctx.lineWidth = 1.5;
            ctx.lineJoin = 'round';
            ctx.moveTo(pts[0].x, pts[0].y);
            for (let i = 0; i < pts.length - 1; i++) {
                const cp = (pts[i].x + pts[i + 1].x) / 2;
                ctx.bezierCurveTo(cp, pts[i].y, cp, pts[i + 1].y, pts[i + 1].x, pts[i + 1].y);
            }
            ctx.stroke();

            ctx.lineTo(pts[pts.length - 1].x, h);
            ctx.lineTo(pts[0].x, h);
            ctx.closePath();
            ctx.fillStyle = color;
            ctx.globalAlpha = fillAlpha;
            ctx.fill();
            ctx.globalAlpha = 1;
        }

        drawCurve(rxArr, '#10B981', 0.08);
        drawCurve(txArr, '#06B6D4', 0.06);

        ctx.fillStyle = 'rgba(148, 163, 184, 0.4)';
        ctx.font = '9px system-ui, sans-serif';
        ctx.textAlign = 'right';
        ctx.fillText(fmtSpeed(maxV), w - 4, 11);
    }

    let speedBuilt = false;
    let trafficBuilt = false;
    let knownSpeedIfaces = [];
    let knownTrafficIfaces = [];

    function buildSpeedSection(ifaces) {
        const c = el('speedSection');
        if (!c) return;
        c.innerHTML = '';
        if (!ifaces.length) {
            c.innerHTML = '<div class="text-sm text-muted">Сбор данных...</div>';
            return;
        }
        for (const iface of ifaces) {
            const cvId = 'cv_' + iface.replace(/\W/g, '');
            const div = document.createElement('div');
            div.className = 'iface-card';
            div.innerHTML = `
                <div class="iface-name">
                    ${ifaceIconSvg(ifaceRole(iface))}
                    ${escapeHtml(ifaceName(iface))}
                </div>
                <div class="speed-numbers">
                    <div class="speed-num">
                        <div class="speed-num-value speed-num-value--rx mono" id="rxs_${iface}">—</div>
                        <div class="speed-num-label">↓ Скачивание</div>
                    </div>
                    <div class="speed-num">
                        <div class="speed-num-value speed-num-value--tx mono" id="txs_${iface}">—</div>
                        <div class="speed-num-label">↑ Отдача</div>
                    </div>
                </div>
                <canvas id="${cvId}" class="speed-canvas"></canvas>
                <div class="speed-legend">
                    <span class="speed-legend-rx">● скачивание</span>
                    <span class="speed-legend-tx">● отдача</span>
                </div>
            `;
            c.appendChild(div);
        }
    }

    function buildTrafficSection(ifaces) {
        const c = el('trafficSection');
        if (!c) return;
        c.innerHTML = '';
        if (!ifaces.length) {
            c.innerHTML = '<div class="text-sm text-muted">Нет данных</div>';
            return;
        }
        for (const iface of ifaces) {
            const div = document.createElement('div');
            div.className = 'iface-card';
            div.innerHTML = `
                <div class="traffic-head">
                    <span class="iface-name">
                        ${ifaceIconSvg(ifaceRole(iface))}
                        ${escapeHtml(ifaceName(iface))}
                    </span>
                    <span class="traffic-total mono" id="tt_${iface}">—</span>
                </div>
                <div class="traffic-rows">
                    <div class="traffic-row">
                        <span class="traffic-row-label traffic-row-label--rx">↓ Входящий</span>
                        <div class="traffic-bar"><div class="traffic-bar-fill traffic-bar-fill--rx" id="rxb_${iface}" style="width:50%"></div></div>
                        <span class="traffic-row-value" id="rxt_${iface}">—</span>
                    </div>
                    <div class="traffic-row">
                        <span class="traffic-row-label traffic-row-label--tx">↑ Исходящий</span>
                        <div class="traffic-bar"><div class="traffic-bar-fill traffic-bar-fill--tx" id="txb_${iface}" style="width:50%"></div></div>
                        <span class="traffic-row-value" id="txt_${iface}">—</span>
                    </div>
                </div>
            `;
            c.appendChild(div);
        }
    }

    async function pollLive() {
        let data;
        try {
            const r = await fetch('api/stats_api.php?action=live&_=' + Date.now(), { cache: 'no-store' });
            data = await r.json();
        } catch (e) {
            return;
        }

        txt('cpuText', data.cpu.percent.toFixed(1) + '%');
        updateRing('cpuRing', data.cpu.percent);
        const nc = data.cpu.cores;
        txt('cpuCores', nc + (nc === 1 ? ' ядро' : nc < 5 ? ' ядра' : ' ядер'));

        txt('ramText', data.memory.percent.toFixed(1) + '%');
        updateRing('ramRing', data.memory.percent);
        txt('ramUsed',  data.memory.used_gb  + ' ГБ');
        txt('ramTotal', data.memory.total_gb + ' ГБ');

        txt('diskText', data.disk.percent.toFixed(1) + '%');
        updateRing('diskRing', data.disk.percent);
        txt('diskUsed', data.disk.used_gb + ' ГБ');
        txt('diskFree', data.disk.free_gb + ' ГБ');

        const t = data.server_time.datetime;
        txt('currentTime', t.split(' ')[1] || t);
        txt('serverTime',  t);
        txt('timezone',    data.server_time.timezone);

        const card = el('vpnStatusCard');
        if (card) {
            if (data.vpn.status.active) {
                txt('vpnStatus', 'Подключён');
                txt('vpnConfig', data.vpn.config.type + ': ' + data.vpn.config.name);
                card.classList.add('is-connected');
                card.classList.remove('is-disconnected');
                const dot = el('vpnIndicator');
                if (dot) dot.className = 'status-dot status-dot--ok status-dot--pulse';
            } else {
                txt('vpnStatus', 'Нет подключения');
                txt('vpnConfig', data.vpn.config.name);
                card.classList.add('is-disconnected');
                card.classList.remove('is-connected');
                const dot = el('vpnIndicator');
                if (dot) dot.className = 'status-dot status-dot--err';
            }
        }

        const tIfaces = Object.keys(data.network || {}).sort(sortIfaces);
        if (!trafficBuilt || tIfaces.join(',') !== knownTrafficIfaces.join(',')) {
            knownTrafficIfaces = tIfaces;
            buildTrafficSection(tIfaces);
            trafficBuilt = true;
        }
        for (const iface of tIfaces) {
            const s = data.network[iface];
            const tot = s.rx_bytes + s.tx_bytes;
            txt('tt_'  + iface, s.total_human);
            txt('rxt_' + iface, s.rx_human);
            txt('txt_' + iface, s.tx_human);
            const rxB = el('rxb_' + iface);
            const txB = el('txb_' + iface);
            if (rxB) rxB.style.width = (tot > 0 ? (s.rx_bytes / tot * 100) + '%' : '50%');
            if (txB) txB.style.width = (tot > 0 ? (s.tx_bytes / tot * 100) + '%' : '50%');
        }

        const bw = data.bandwidth || {};
        const sIfaces = Object.keys(bw).sort(sortIfaces);

        for (const iface of sIfaces) {
            if (!hist[iface]) hist[iface] = { rx: [], tx: [] };
            hist[iface].rx.push(bw[iface].rx_speed || 0);
            hist[iface].tx.push(bw[iface].tx_speed || 0);
            while (hist[iface].rx.length > CHART_POINTS) {
                hist[iface].rx.shift();
                hist[iface].tx.shift();
            }
        }
        saveHist();

        if (!speedBuilt || sIfaces.join(',') !== knownSpeedIfaces.join(',')) {
            knownSpeedIfaces = sIfaces;
            buildSpeedSection(sIfaces);
            speedBuilt = true;
        }

        for (const iface of sIfaces) {
            txt('rxs_' + iface, fmtSpeed(bw[iface].rx_speed));
            txt('txs_' + iface, fmtSpeed(bw[iface].tx_speed));
        }

        for (const iface of sIfaces) {
            if (hist[iface]) {
                drawChart('cv_' + iface.replace(/\W/g, ''), hist[iface].rx, hist[iface].tx);
            }
        }
    }

    let lastModified = null;
    let eventsOffset = 0;
    const EVENTS_PAGE = 20;
    let hasMoreEvents = false;

    async function pollSlow(reset = false) {
        if (reset) {
            eventsOffset = 0;
        }

        const url = `api/stats_api.php?action=slow&events_offset=${eventsOffset}&events_limit=${EVENTS_PAGE}`;
        const headers = {};

        if (lastModified && eventsOffset === 0) {
            headers['If-Modified-Since'] = lastModified;
        }

        let data;
        try {
            const r = await fetch(url, { headers, cache: 'no-store' });
            if (r.status === 304) {

                return;
            }
            const lm = r.headers.get('Last-Modified');
            if (lm) lastModified = lm;
            data = await r.json();
        } catch (e) {
            return;
        }

        if (data.uptime) {
            txt('uptime', data.uptime.human);
        }

        if (data.last_disconnection) {
            if (data.last_disconnection.timestamp) {
                txt('lastDisconnect',     data.last_disconnection.ago_human);
                txt('lastDisconnectTime', data.last_disconnection.timestamp);
            } else {
                txt('lastDisconnect',     'Нет');
                txt('lastDisconnectTime', 'Проблем не было');
            }
        }

        renderHistoryEvents(data.events || [], data.events_has_more, reset);
        hasMoreEvents = !!data.events_has_more;

        renderConfigStats(data.config_stats || {});
    }

    function renderHistoryEvents(events, hasMore, reset) {
        const list = el('configHistory');
        if (!list) return;

        if (reset) list.innerHTML = '';

        if (eventsOffset === 0 && !events.length) {
            list.innerHTML = '<div class="empty-state-text">Нет событий</div>';
            return;
        }

        const oldBtn = document.getElementById('history-load-more-wrap');
        if (oldBtn) oldBtn.remove();

        const fragment = document.createDocumentFragment();
        for (const e of events) {
            const timeShort = (e.time || '').slice(5, 16);
            const textCls = 'history-text history-text--' + (e.badge_color || 'slate');
            const badge = e.badge
                ? `<span class="badge badge--${mapBadgeColor(e.badge_color)}">${escapeHtml(e.badge)}</span>`
                : '';

            const div = document.createElement('div');
            div.className = 'history-item';
            div.innerHTML = `
                <span class="history-icon">${escapeHtml(e.icon || '•')}</span>
                <div class="history-body">
                    <div class="${textCls}">${escapeHtml(e.text)}</div>
                </div>
                <div class="history-meta">
                    ${badge}
                    <span class="history-time">${escapeHtml(timeShort)}</span>
                </div>
            `;
            fragment.appendChild(div);
        }

        list.appendChild(fragment);
        eventsOffset += events.length;

        if (hasMore) {
            const wrap = document.createElement('div');
            wrap.id = 'history-load-more-wrap';
            wrap.className = 'history-load-more';
            wrap.innerHTML = `
                <button type="button" class="btn btn--ghost btn--sm" id="history-load-more-btn">
                    Показать ещё 20
                </button>
            `;
            list.appendChild(wrap);
            const btn = wrap.querySelector('#history-load-more-btn');
            btn.addEventListener('click', () => {
                btn.disabled = true;
                btn.textContent = 'Загрузка...';
                pollSlow(false);
            });
        }
    }

    function mapBadgeColor(color) {
        const map = {
            green:  'emerald',
            yellow: 'amber',
            orange: 'orange',
            red:    'rose',
            blue:   'cyan',
            purple: 'violet',
            slate:  'slate',
        };
        return map[color] || 'slate';
    }

    function renderConfigStats(stats) {
        const c = el('configStats');
        if (!c) return;
        if (!stats || !Object.keys(stats).length) {
            c.innerHTML = '<div class="empty-state-text">Нет данных</div>';
            return;
        }

        let total = 0;
        for (const s of Object.values(stats)) total += s.total_seconds || 0;

        let html = '';
        for (const [name, s] of Object.entries(stats)) {
            const pct = total > 0 ? ((s.total_seconds || 0) / total * 100) : 0;
            const hours   = Math.floor((s.total_seconds || 0) / 3600);
            const minutes = Math.floor(((s.total_seconds || 0) % 3600) / 60);
            html += `
                <div class="config-stat-item">
                    <div class="config-stat-head">
                        <span class="config-stat-name">${escapeHtml(name)}</span>
                        <span class="config-stat-time">${hours}ч ${minutes}м</span>
                    </div>
                    <div class="config-stat-bar">
                        <div class="config-stat-bar-fill" style="width:${pct.toFixed(1)}%"></div>
                    </div>
                </div>
            `;
        }
        c.innerHTML = html;
    }

    let liveTimer = null;
    let slowTimer = null;

    function startPolling() {
        const liveMs = isReducedMotion() ? LIVE_UPD_MS_LITE : LIVE_UPD_MS;
        pollLive();
        pollSlow(true);
        liveTimer = setInterval(pollLive, liveMs);
        slowTimer = setInterval(() => pollSlow(true), SLOW_UPD_MS);
    }

    function stopPolling() {
        if (liveTimer) { clearInterval(liveTimer); liveTimer = null; }
        if (slowTimer) { clearInterval(slowTimer); slowTimer = null; }
    }

    function handleVisibility() {
        if (document.hidden) {
            stopPolling();
        } else if (!liveTimer) {
            startPolling();
        }
    }

    function init() {
        loadIfaceRoles();
        startPolling();
        setupClearEventsButton();
        document.addEventListener('visibilitychange', handleVisibility);
    }

    function setupClearEventsButton() {
        const btn = document.getElementById('events-clear-btn');
        if (!btn) return;

        btn.addEventListener('click', async () => {

            const ok = window.VPNPanel && window.VPNPanel.confirm
                ? await VPNPanel.confirm({
                    title:       'Очистить журнал событий?',
                    message:     'Все записи будут удалены. Это действие нельзя отменить.',
                    confirmText: 'Очистить',
                    cancelText:  'Отмена',
                    danger:      true,
                })
                : confirm('Очистить весь журнал событий?\nЭто действие нельзя отменить.');

            if (!ok) return;

            btn.disabled = true;
            const orig = btn.innerHTML;
            btn.innerHTML = 'Очищаем...';
            try {
                const r = await fetch('api/stats_api.php?action=clear_events', {
                    method: 'POST',
                    headers: { 'X-Requested-With': 'XMLHttpRequest' },
                    cache: 'no-store'
                });
                const data = await r.json();
                if (data.ok) {
                    if (window.Toast) Toast.success(data.message || 'Журнал очищен');

                    lastModified = null;
                    pollSlow(true);
                } else {
                    if (window.Toast) Toast.error(data.error || 'Ошибка очистки');
                }
            } catch (e) {
                if (window.Toast) Toast.error('Ошибка связи: ' + e.message);
            } finally {
                btn.disabled = false;
                btn.innerHTML = orig;
            }
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
