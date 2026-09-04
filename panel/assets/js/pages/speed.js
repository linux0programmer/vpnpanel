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
        historyClear: document.getElementById('speed-history-clear'),
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

    const TRASH = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75">'
        + '<path stroke-linecap="round" stroke-linejoin="round" d="M14.74 9l-.346 9m-4.788 0L9.26 9m9.968-3.21'
        + 'c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 01-2.244 2.077H8.084a2.25 2.25 0 '
        + '01-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 00-3.478-.397m-12 .562c.34-.059.68-.114 '
        + '1.022-.165m0 0a48.11 48.11 0 013.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 '
        + '00-3.32 0c-1.18.037-2.09 1.022-2.09 2.201v.916m7.5 0a48.667 48.667 0 00-7.5 0"/></svg>';

    function renderHistory(rows) {
        el.historyCount.textContent = String(rows.length);
        el.historyClear.hidden = rows.length === 0;
        if (!rows.length) {
            el.historyWrap.hidden = true;
            el.historyEmpty.hidden = false;
            return;
        }
        el.historyEmpty.hidden = true;
        el.historyWrap.hidden = false;
        el.historyBody.innerHTML = rows.map(function (r) {
            const key = r.id || r.time;
            return '<tr>'
                + '<td class="mono">' + r.time + '</td>'
                + '<td class="mono">' + (r.iface || '—') + '</td>'
                + '<td class="mono">' + r.download.toFixed(1) + '</td>'
                + '<td class="mono">' + r.upload.toFixed(1) + '</td>'
                + '<td class="mono">' + r.ping.toFixed(1) + '</td>'
                + '<td>' + (r.server || '—') + '</td>'
                + '<td><button type="button" class="btn btn--ghost speed-forget" '
                + 'data-id="' + key + '" title="Удалить замер">' + TRASH + '</button></td>'
                + '</tr>';
        }).join('');
    }

    async function forget(id) {
        const data = await api('forget', { id: id });
        if (!data.ok) {
            window.Toast && Toast.error(data.error || 'Не удалось удалить замер');
            return;
        }
        renderHistory(data.history || []);
        if (!data.last) {
            el.result.hidden = true;
            el.meta.hidden = true;
        } else {
            renderResult(data.last);
        }
    }

    async function forgetAll() {
        const ask = window.VPNPanel && window.VPNPanel.confirm;
        if (ask) {
            const ok = await ask({
                title:       'Подтвердите действие',
                message:     'Удалить всю историю замеров?',
                confirmText: 'Очистить',
                cancelText:  'Отмена',
                danger:      true,
            });
            if (!ok) return;
        }
        const data = await api('forget-all');
        if (!data.ok) {
            window.Toast && Toast.error(data.error || 'Не удалось очистить историю');
            return;
        }
        renderHistory([]);
        el.result.hidden = true;
        el.meta.hidden = true;
        window.Toast && Toast.success('История очищена');
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

    el.historyClear.addEventListener('click', forgetAll);

    el.historyBody.addEventListener('click', function (e) {
        const btn = e.target.closest('.speed-forget');
        if (btn) forget(btn.dataset.id);
    });

    loadHistory(true);
    api('status').then(function (data) {
        if (data.state === 'running') {
            busy(true);
            setState('идёт замер', 'cyan');
            polling = setInterval(poll, POLL_MS);
        }
    });
})();
