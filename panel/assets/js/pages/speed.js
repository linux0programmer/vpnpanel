(function () {
    'use strict';

    const API = 'api/speedtest.php';
    const POLL_MS = 2000;

    const el = {
        state:        document.getElementById('speed-state'),
        iface:        document.getElementById('speed-iface'),
        run:          document.getElementById('speed-run'),
        progress:     document.getElementById('speed-progress'),
        progressText: document.getElementById('speed-progress-text'),
        error:        document.getElementById('speed-error'),
        result:       document.getElementById('speed-result'),
        download:     document.getElementById('speed-download'),
        upload:       document.getElementById('speed-upload'),
        ping:         document.getElementById('speed-ping'),
        meta:         document.getElementById('speed-meta'),
        historyWrap:  document.getElementById('speed-history-wrap'),
        historyBody:  document.getElementById('speed-history-body'),
        historyEmpty: document.getElementById('speed-history-empty'),
        historyCount: document.getElementById('speed-history-count'),
    };

    if (!el.run) return;

    let polling = null;

    async function api(action, params) {
        const query = new URLSearchParams(Object.assign({ action: action }, params || {}));
        try {
            const res = await fetch(API + '?' + query.toString(), {
                headers: { 'X-Requested-With': 'XMLHttpRequest' },
            });
            return await res.json();
        } catch (err) {
            return { ok: false, error: 'Ошибка соединения: ' + err.message };
        }
    }

    function setState(text, tone) {
        el.state.textContent = text;
        el.state.className = 'badge badge--' + (tone || 'slate');
    }

    function showError(message) {
        el.error.textContent = message;
        el.error.hidden = false;
    }

    function clearError() {
        el.error.hidden = true;
        el.error.textContent = '';
    }

    function busy(on) {
        el.run.disabled = on;
        el.iface.disabled = on;
        el.progress.hidden = !on;
    }

    function renderResult(row) {
        if (!row) return;
        el.download.textContent = row.download.toFixed(1);
        el.upload.textContent   = row.upload.toFixed(1);
        el.ping.textContent     = row.ping.toFixed(1);
        el.result.hidden = false;

        const bits = [];
        if (row.iface)  bits.push('канал <b class="mono">' + row.iface + '</b>');
        if (row.server) bits.push('сервер ' + row.server);
        if (row.isp)    bits.push('провайдер ' + row.isp);
        if (row.jitter) bits.push('джиттер ' + row.jitter.toFixed(1) + ' мс');
        if (row.loss)   bits.push('потери ' + row.loss.toFixed(1) + '%');
        el.meta.innerHTML = bits.join(' · ');
        el.meta.hidden = bits.length === 0;
    }

    function renderHistory(rows) {
        el.historyCount.textContent = String(rows.length);
        if (!rows.length) {
            el.historyWrap.hidden = true;
            el.historyEmpty.hidden = false;
            return;
        }
        el.historyEmpty.hidden = true;
        el.historyWrap.hidden = false;
        el.historyBody.innerHTML = rows.map(function (r) {
            return '<tr>'
                + '<td class="mono">' + r.time + '</td>'
                + '<td class="mono">' + (r.iface || '—') + '</td>'
                + '<td class="mono">' + r.download.toFixed(1) + '</td>'
                + '<td class="mono">' + r.upload.toFixed(1) + '</td>'
                + '<td class="mono">' + r.ping.toFixed(1) + '</td>'
                + '<td>' + (r.server || '—') + '</td>'
                + '</tr>';
        }).join('');
    }

    async function loadChannels() {
        const data = await api('channels');
        if (!data.ok) return;
        (data.channels || []).forEach(function (c) {
            const opt = document.createElement('option');
            opt.value = c.iface;
            const label = c.iface === 'tun0' ? 'tun0 — через VPN-туннель' : c.iface;
            opt.textContent = label + (c.active ? ' — активный' : '')
                + (c.state !== 'up' ? ' (' + c.state + ')' : '');
            el.iface.appendChild(opt);
        });
        const known = Array.prototype.map.call(el.iface.options, function (o) { return o.value; });
        if (data.tunnel && known.indexOf('tun0') === -1) {
            const opt = document.createElement('option');
            opt.value = 'tun0';
            opt.textContent = 'tun0 — через VPN-туннель';
            el.iface.appendChild(opt);
        }
    }

    async function loadHistory(showLast) {
        const data = await api('history');
        if (!data.ok) return;
        renderHistory(data.history || []);
        if (showLast && data.last) renderResult(data.last);
    }

    function stopPolling() {
        if (polling) { clearInterval(polling); polling = null; }
    }

    async function poll() {
        const data = await api('status');

        if (data.state === 'running') {
            el.progressText.textContent = 'Идёт замер… ' + (data.elapsed || 0) + ' с';
            return;
        }

        stopPolling();
        busy(false);

        if (data.state === 'done') {
            setState('готов', 'emerald');
            renderResult(data.result);
            loadHistory(false);
            window.Toast && Toast.success('Замер завершён');
            return;
        }

        if (data.state === 'idle') {
            setState('готов', 'slate');
            return;
        }

        setState('ошибка', 'rose');
        showError(data.error || 'Замер не удался');
        window.Toast && Toast.error('Замер не удался');
    }

    async function start() {
        clearError();
        busy(true);
        setState('идёт замер', 'cyan');
        el.progressText.textContent = 'Идёт замер…';

        const data = await api('start', { iface: el.iface.value });
        if (!data.ok) {
            busy(false);
            setState('ошибка', 'rose');
            showError(data.error || 'Не удалось запустить замер');
            return;
        }
        polling = setInterval(poll, POLL_MS);
    }

    el.run.addEventListener('click', start);

    loadChannels();
    loadHistory(true);
    api('status').then(function (data) {
        if (data.state === 'running') {
            busy(true);
            setState('идёт замер', 'cyan');
            polling = setInterval(poll, POLL_MS);
        }
    });
})();
