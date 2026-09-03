
(function() {
    'use strict';

    const PING_INTERVAL_MS = 5000;

    const ping = (function() {
        const subscribers = new Set();
        let timer = null;
        let lastResult = { status: 'off', ms: null };
        let inflight = false;

        function classify(msOrNull) {
            if (msOrNull === null) return 'off';
            if (msOrNull < 0)      return 'bad';
            if (msOrNull < 100)    return 'ok';
            if (msOrNull < 200)    return 'slow';
            return 'bad';
        }

        function broadcast(result) {
            lastResult = result;
            subscribers.forEach(cb => {
                try { cb(result); } catch (e) { console.error('ping subscriber:', e); }
            });
        }

        function doFetch() {
            if (inflight) return;
            inflight = true;

            fetch('api/ping.php?host=8.8.8.8&interface=tun0', { cache: 'no-store' })
                .then(r => r.text())
                .then(data => {
                    if (data.includes('NO PING')) {
                        broadcast({ status: 'bad', ms: null });
                    } else {
                        const ms = Math.round(parseFloat(data));
                        broadcast({ status: classify(ms), ms });
                    }
                })
                .catch(() => {
                    broadcast({ status: 'off', ms: null });
                })
                .finally(() => {
                    inflight = false;
                });
        }

        function startPolling() {
            if (timer) return;
            doFetch();
            timer = setInterval(doFetch, PING_INTERVAL_MS);
        }

        function stopPolling() {
            if (timer) { clearInterval(timer); timer = null; }
        }

        function updatePollingState() {

            if (subscribers.size > 0 && !document.hidden) {
                startPolling();
            } else {
                stopPolling();
            }
        }

        function subscribe(cb) {
            subscribers.add(cb);

            try { cb(lastResult); } catch (e) {}
            updatePollingState();
            return function unsubscribe() {
                subscribers.delete(cb);
                updatePollingState();
            };
        }

        document.addEventListener('visibilitychange', updatePollingState);

        return {
            subscribe,
            refresh: doFetch,
            _stats: () => ({ subscribers: subscribers.size, polling: !!timer, last: lastResult }),
        };
    })();

    const SIDEBAR_STATUS = {
        ok:   { cls: 'is-ok',   dot: 'status-dot--ok',   title: 'VPN подключён' },
        slow: { cls: 'is-warn', dot: 'status-dot--warn', title: 'VPN нестабилен' },
        bad:  { cls: 'is-err',  dot: 'status-dot--err',  title: 'VPN недоступен' },
    };

    function renderSidebarStatus(status, ms) {
        const box = document.getElementById('sidebar-status');
        if (!box) return;
        const view = SIDEBAR_STATUS[status] || { cls: '', dot: 'status-dot--off', title: 'Проверка связи' };
        box.className = 'sidebar-status' + (view.cls ? ' ' + view.cls : '');
        const dot = document.getElementById('sidebar-status-dot');
        if (dot) dot.className = 'status-dot ' + view.dot + (status === 'ok' ? ' is-live' : '');
        const title = document.getElementById('sidebar-status-title');
        if (title) title.textContent = view.title;
        const sub = document.getElementById('sidebar-status-sub');
        if (sub) sub.textContent = ms !== null && ms !== undefined ? 'задержка ' + ms + ' мс' : 'задержка —';
    }

    function setupSidebarPing() {
        const dot  = document.getElementById('sidebar-vpn-dot');
        const ping_el = document.getElementById('sidebar-ping-display');
        if (!dot || !ping_el) return;

        ping.subscribe(({ status, ms }) => {
            renderSidebarStatus(status, ms);

            dot.className = 'status-dot';
            ping_el.className = 'menu-ping';

            if (status === 'ok') {
                ping_el.textContent = ms + 'ms';
                ping_el.classList.add('ping--good');
                dot.classList.add('status-dot--ok', 'status-dot--pulse');
            } else if (status === 'slow') {
                ping_el.textContent = ms + 'ms';
                ping_el.classList.add('ping--slow');
                dot.classList.add('status-dot--warn');
            } else if (status === 'bad') {
                ping_el.textContent = ms !== null ? ms + 'ms' : '—';
                ping_el.classList.add('ping--bad');
                dot.classList.add('status-dot--err');
            } else {

                ping_el.textContent = '—';
                dot.classList.add('status-dot--off');
            }
        });
    }

    let overlay = null;

    function getOverlay() {
        if (overlay && document.body.contains(overlay)) return overlay;
        overlay = document.createElement('div');
        overlay.className = 'loading-overlay';
        overlay.innerHTML = `
            <div class="loading-spinner"></div>
            <div class="loading-text" id="vpn-loading-text">Подключение...</div>
            <div class="text-sm text-muted">Пожалуйста, подождите</div>
        `;
        document.body.appendChild(overlay);
        return overlay;
    }

    window.showVpnLoading = function(text) {
        const o = getOverlay();
        const t = o.querySelector('#vpn-loading-text');
        if (t) t.textContent = text || 'Подключение...';
        o.classList.add('is-open');
    };

    window.hideVpnLoading = function() {
        const o = overlay;
        if (o) o.classList.remove('is-open');
    };

    window.Notice = function(text, type) {
        if (!window.Toast) return;
        if (type === 'error')        Toast.error(text);
        else if (type === 'warning') Toast.warning(text);
        else                         Toast.success(text);
    };

    function showFlashIfAny() {
        if (!window.__flashMessage || !window.Toast) return;
        const { text, type } = window.__flashMessage;
        if (type === 'error')        Toast.error(text);
        else if (type === 'warning') Toast.warning(text);
        else                         Toast.success(text);
        window.__flashMessage = null;
    }

    function bindFormLoaders() {
        document.querySelectorAll('form[data-vpn-action]').forEach(form => {
            if (form.__vpnBound) return;
            form.__vpnBound = true;
            form.addEventListener('submit', () => {
                const action = form.getAttribute('data-vpn-action');
                const labels = {
                    'activate': 'Подключение VPN...',
                    'restart':  'Перезапуск VPN...',
                    'stop':     'Остановка VPN...',
                    'delete':   'Удаление...',
                    'upload':   'Загрузка конфига...',
                };
                showVpnLoading(labels[action] || 'Пожалуйста, подождите...');
            });
        });
    }

    const FAILOVER_KEY = 'vp_failover_pending';

    function markFailoverPending(opts) {
        try {
            sessionStorage.setItem(FAILOVER_KEY, JSON.stringify(opts || {}));
        } catch (e) {}
    }

    function showFailoverToastIfPending() {
        if (!window.Toast) return;
        let data;
        try {
            const raw = sessionStorage.getItem(FAILOVER_KEY);
            if (!raw) return;
            sessionStorage.removeItem(FAILOVER_KEY);
            data = JSON.parse(raw);
        } catch (e) { return; }

        const newName = data && data.to ? String(data.to).slice(0, 64) : '';
        const body = newName
            ? 'Основной VPN упал. Подключён резервный: ' + newName + '.'
            : 'Основной VPN упал. Подключён резервный конфиг.';

        Toast.show({
            type: 'warning',
            title: 'Сработало резервирование',
            body: body,
            duration: 12000,
        });
    }

    function init() {
        setupSidebarPing();
        showFlashIfAny();
        showFailoverToastIfPending();
        bindFormLoaders();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

    window.VPNPanel = window.VPNPanel || {};
    Object.assign(window.VPNPanel, {
        ping,

        refreshPing: () => ping.refresh(),
        bindFormLoaders,

        markFailoverPending,
    });
})();
