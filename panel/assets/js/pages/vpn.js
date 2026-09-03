
(function() {
    'use strict';

    const API = 'api/vpn_action.php';

    async function apiCall(action, payload = {}) {
        Progress.start();
        try {
            const res = await fetch(API, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
                body: JSON.stringify({ action, ...payload }),
            });
            const data = await res.json();
            return data;
        } catch (err) {
            return { ok: false, error: 'Ошибка соединения: ' + err.message };
        } finally {
            Progress.done();
        }
    }

    async function doActivate(configId, configName) {
        window.showVpnLoading && showVpnLoading('Подключение VPN...');
        const result = await apiCall('activate', { config_id: configId });
        window.hideVpnLoading && hideVpnLoading();

        if (result.ok) {
            Toast.success(result.message || 'Конфиг активирован');

            setTimeout(() => location.reload(), 500);
        } else {
            Toast.error(result.error || 'Ошибка активации');

            setTimeout(() => location.reload(), 1000);
        }
    }

    async function doDelete(configId, configName) {

        const ok = window.VPNPanel && window.VPNPanel.confirm
            ? await VPNPanel.confirm({
                title:       'Удалить конфиг?',
                message:     `Конфигурация «${configName}» будет удалена безвозвратно.`,
                confirmText: 'Удалить',
                cancelText:  'Отмена',
                danger:      true,
            })
            : confirm(`Удалить конфигурацию "${configName}"?`);
        if (!ok) return;

        const item = document.querySelector(`[data-config-id="${configId}"]`);
        const result = await apiCall('delete', { config_id: configId });

        if (result.ok) {
            Toast.success(result.message || 'Конфиг удалён');
            if (item) {

                item.style.transition = 'opacity 200ms, transform 200ms';
                item.style.opacity = '0';
                item.style.transform = 'translateX(-20px)';
                setTimeout(() => {
                    item.remove();
                    updateConfigCount();
                    showEmptyStateIfNoConfigs();
                }, 220);
            }
        } else {
            Toast.error(result.error || 'Ошибка удаления');
        }
    }

    function startInlineRename(nameEl) {
        if (nameEl.classList.contains('is-editing')) return;
        const original = nameEl.textContent.trim();
        nameEl.dataset.original = original;
        nameEl.contentEditable = 'true';
        nameEl.classList.add('is-editing');

        nameEl.focus();
        const range = document.createRange();
        range.selectNodeContents(nameEl);
        const sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
    }

    function cancelInlineRename(nameEl) {
        nameEl.textContent = nameEl.dataset.original || '';
        finishInlineRename(nameEl);
    }

    function finishInlineRename(nameEl) {
        nameEl.contentEditable = 'false';
        nameEl.classList.remove('is-editing');
        nameEl.blur();
    }

    async function commitInlineRename(nameEl) {
        const configItem = nameEl.closest('.config-item');
        const configId   = configItem?.dataset.configId;
        const newName    = nameEl.textContent.trim();
        const original   = nameEl.dataset.original || '';

        if (!configId || newName === original) {
            cancelInlineRename(nameEl);
            return;
        }
        if (!newName) {
            Toast.warning('Название не может быть пустым');
            cancelInlineRename(nameEl);
            return;
        }
        if (newName.length > 64) {
            Toast.warning('Максимум 64 символа');
            nameEl.textContent = newName.substring(0, 64);
        }

        finishInlineRename(nameEl);
        const result = await apiCall('rename', { config_id: configId, new_name: nameEl.textContent.trim() });
        if (result.ok) {
            Toast.success('Переименовано');
        } else {
            Toast.error(result.error || 'Ошибка');
            nameEl.textContent = original;
        }
    }

    async function doToggleRole(configId) {
        const result = await apiCall('toggle_role', { config_id: configId });
        if (result.ok) {
            Toast.success(result.message);

            setTimeout(() => location.reload(), 400);
        } else {
            Toast.error(result.error || 'Ошибка');
        }
    }

    async function doMove(configId, direction) {
        const list = document.getElementById('config-items');
        const item = document.querySelector(`[data-config-id="${configId}"]`);
        if (!list || !item) return;

        if (direction === 'up' && !item.previousElementSibling) return;
        if (direction === 'down' && !item.nextElementSibling) return;

        const result = await apiCall('move', { config_id: configId, direction });
        if (!result.ok) {
            Toast.error(result.error || 'Ошибка перемещения');
            return;
        }

        if (direction === 'up') {
            list.insertBefore(item, item.previousElementSibling);
        } else {
            list.insertBefore(item.nextElementSibling, item);
        }

        list.querySelectorAll('.config-item').forEach((el, idx) => {
            const pill = el.querySelector('.config-priority');
            if (pill) pill.textContent = idx + 1;
        });
    }

    async function doStop() {
        const ok = window.VPNPanel && window.VPNPanel.confirm
            ? await VPNPanel.confirm({
                title:       'Остановить VPN?',
                message:     'Соединение будет разорвано и весь VPN-трафик пойдёт напрямую.',
                confirmText: 'Остановить',
                cancelText:  'Отмена',
                danger:      true,
            })
            : confirm('Остановить VPN?');
        if (!ok) return;
        window.showVpnLoading && showVpnLoading('Остановка VPN...');
        const result = await apiCall('stop');
        window.hideVpnLoading && hideVpnLoading();
        if (result.ok) {
            Toast.success(result.message || 'VPN остановлен');
            setTimeout(() => location.reload(), 400);
        } else {
            Toast.error(result.error || 'Ошибка');
        }
    }

    async function doRestart() {
        window.showVpnLoading && showVpnLoading('Перезапуск VPN...');
        const result = await apiCall('restart');
        window.hideVpnLoading && hideVpnLoading();
        if (result.ok) {
            Toast.success(result.message || 'VPN перезапущен');
            setTimeout(() => location.reload(), 400);
        } else {
            Toast.error(result.error || 'Ошибка');
            setTimeout(() => location.reload(), 1000);
        }
    }

    let draggedItem = null;

    function findDropTarget(clientY, items) {
        if (!items.length) return null;

        const firstRect = items[0].getBoundingClientRect();
        if (clientY < firstRect.top) return { target: items[0], pos: 'before' };

        const lastRect = items[items.length - 1].getBoundingClientRect();
        if (clientY > lastRect.bottom) return { target: items[items.length - 1], pos: 'after' };

        let closest = null;
        let closestDist = Infinity;
        for (const item of items) {
            const rect = item.getBoundingClientRect();
            const midY = rect.top + rect.height / 2;
            const dist = Math.abs(clientY - midY);
            if (dist < closestDist) { closestDist = dist; closest = item; }
        }
        if (!closest) return null;

        const list = closest.parentElement;
        const allItems = Array.from(list.querySelectorAll('.config-item'));
        const draggedIdx = allItems.indexOf(draggedItem);
        const closestIdx = allItems.indexOf(closest);
        const draggingDown = draggedIdx >= 0 && draggedIdx < closestIdx;

        const rect = closest.getBoundingClientRect();

        const thresholdRatio = draggingDown ? 0.2 : 0.8;
        const thresholdY = rect.top + rect.height * thresholdRatio;

        return {
            target: closest,
            pos: clientY < thresholdY ? 'before' : 'after',
        };
    }

    function clearDropIndicators(list) {
        list.querySelectorAll('.is-drop-before, .is-drop-after')
            .forEach(el => el.classList.remove('is-drop-before', 'is-drop-after'));
    }

    function setupDragDrop() {
        const list = document.getElementById('config-items');
        if (!list) return;

        list.querySelectorAll('.config-item').forEach(item => {
            item.setAttribute('draggable', 'true');

            item.addEventListener('dragstart', (e) => {
                if (document.body.classList.contains('is-bulk-mode')) {
                    e.preventDefault();
                    return;
                }
                draggedItem = item;
                item.classList.add('is-dragging');
                e.dataTransfer.effectAllowed = 'move';
                e.dataTransfer.setData('text/plain', item.dataset.configId || '');
            });

            item.addEventListener('dragend', () => {
                item.classList.remove('is-dragging');
                clearDropIndicators(list);
                draggedItem = null;
            });
        });

        list.addEventListener('dragover', (e) => {
            if (!draggedItem) return;
            e.preventDefault();
            e.dataTransfer.dropEffect = 'move';

            const items = Array.from(list.querySelectorAll('.config-item:not(.is-dragging)'));
            const result = findDropTarget(e.clientY, items);

            clearDropIndicators(list);
            if (result) {
                result.target.classList.add(result.pos === 'before' ? 'is-drop-before' : 'is-drop-after');
            }
        });

        list.addEventListener('drop', async (e) => {
            if (!draggedItem) return;
            e.preventDefault();
            e.stopPropagation();

            const items = Array.from(list.querySelectorAll('.config-item:not(.is-dragging)'));
            const result = findDropTarget(e.clientY, items);
            clearDropIndicators(list);
            if (!result) return;

            const oldOrder = Array.from(list.querySelectorAll('.config-item'))
                .map(el => el.dataset.configId).join(',');

            if (result.pos === 'before') {
                list.insertBefore(draggedItem, result.target);
            } else {
                list.insertBefore(draggedItem, result.target.nextSibling);
            }

            const newOrder = Array.from(list.querySelectorAll('.config-item'))
                .map(el => el.dataset.configId).join(',');

            if (oldOrder !== newOrder) {
                await persistReorder();
            }
        });

        list.addEventListener('dragleave', (e) => {
            if (!list.contains(e.relatedTarget)) clearDropIndicators(list);
        });
    }

    async function persistReorder() {
        const list = document.getElementById('config-items');
        if (!list) return;
        const order = Array.from(list.querySelectorAll('.config-item'))
            .map(el => el.dataset.configId)
            .filter(Boolean);
        const result = await apiCall('reorder', { order });
        if (result.ok) {
            Toast.success('Порядок сохранён');

            list.querySelectorAll('.config-item').forEach((el, idx) => {
                const pill = el.querySelector('.config-priority');
                if (pill) pill.textContent = idx + 1;
            });
        } else {
            Toast.error(result.error || 'Ошибка сохранения порядка');
            setTimeout(() => location.reload(), 800);
        }
    }

    function setupSearch() {
        const input = document.getElementById('config-search-input');
        if (!input) return;
        input.addEventListener('input', () => {
            const q = input.value.toLowerCase().trim();
            const items = document.querySelectorAll('.config-item');
            items.forEach(item => {
                if (!q) {
                    item.style.display = '';
                    return;
                }
                const name   = (item.querySelector('.config-name')?.textContent || '').toLowerCase();
                const server = (item.querySelector('.config-meta-server')?.textContent || '').toLowerCase();
                const type   = (item.dataset.configType || '').toLowerCase();
                const match = name.includes(q) || server.includes(q) || type.includes(q);
                item.style.display = match ? '' : 'none';
            });
        });
    }

    function toggleBulkMode() {
        document.body.classList.toggle('is-bulk-mode');
        if (!document.body.classList.contains('is-bulk-mode')) {

            document.querySelectorAll('.bulk-check').forEach(cb => cb.checked = false);
            document.querySelectorAll('.config-item.is-selected').forEach(el => el.classList.remove('is-selected'));
            updateBulkToolbar();
        }
    }

    function setupBulkSelection() {
        document.addEventListener('change', (e) => {
            if (!e.target.classList.contains('bulk-check')) return;
            const item = e.target.closest('.config-item');
            if (item) item.classList.toggle('is-selected', e.target.checked);
            updateBulkToolbar();
        });
    }

    function updateBulkToolbar() {
        const selected = document.querySelectorAll('.bulk-check:checked');
        const countEl = document.getElementById('bulk-count');
        if (countEl) countEl.textContent = selected.length;
    }

    function getSelectedIds() {
        return Array.from(document.querySelectorAll('.bulk-check:checked'))
            .map(cb => cb.closest('.config-item')?.dataset.configId)
            .filter(Boolean);
    }

    async function doBulkDelete() {
        const ids = getSelectedIds();
        if (!ids.length) { Toast.warning('Нет выделенных'); return; }
        const ok = window.VPNPanel && window.VPNPanel.confirm
            ? await VPNPanel.confirm({
                title:       `Удалить ${ids.length} конфигураций?`,
                message:     'Выбранные конфиги будут удалены. Действие нельзя отменить.',
                confirmText: 'Удалить все',
                cancelText:  'Отмена',
                danger:      true,
            })
            : confirm(`Удалить ${ids.length} конфигураций?`);
        if (!ok) return;

        const result = await apiCall('bulk_delete', { ids });
        if (result.ok) {
            Toast.success(result.message);
            setTimeout(() => location.reload(), 400);
        } else {
            Toast.error(result.error || 'Ошибка');
        }
    }

    function setupActionMenus() {
        document.addEventListener('click', (e) => {

            const btn = e.target.closest('.action-menu-btn');
            if (btn) {
                e.stopPropagation();
                const menu = btn.closest('.action-menu');

                document.querySelectorAll('.action-menu.is-open').forEach(m => {
                    if (m !== menu) m.classList.remove('is-open');
                });
                menu.classList.toggle('is-open');
                return;
            }

            if (!e.target.closest('.action-menu-dropdown')) {
                document.querySelectorAll('.action-menu.is-open').forEach(m => m.classList.remove('is-open'));
            }
        });

        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') {
                document.querySelectorAll('.action-menu.is-open').forEach(m => m.classList.remove('is-open'));
            }
        });
    }

    function setupUploadZone() {
        const zone  = document.getElementById('upload-zone');
        const input = document.getElementById('config-file-input');
        const label = document.getElementById('upload-zone-text');
        if (!zone || !input || !label) return;

        input.addEventListener('change', () => {
            const name = input.files[0]?.name || '';
            label.textContent = name || '.ovpn или .conf';
        });

        ['dragenter', 'dragover'].forEach(ev => {
            zone.addEventListener(ev, (e) => {
                e.preventDefault();
                zone.classList.add('is-dragover');
            });
        });
        ['dragleave', 'drop'].forEach(ev => {
            zone.addEventListener(ev, (e) => {
                e.preventDefault();
                zone.classList.remove('is-dragover');
            });
        });
        zone.addEventListener('drop', (e) => {
            const file = e.dataTransfer.files[0];
            if (!file) return;
            input.files = e.dataTransfer.files;
            label.textContent = file.name;
        });

        const form = zone.closest('form');
        if (form) {
            form.addEventListener('submit', (e) => {
                if (form.__submitting) {
                    e.preventDefault();
                    return;
                }
                form.__submitting = true;

                setTimeout(() => { form.__submitting = false; }, 30000);
            });
        }
    }

    let knownActiveId = '';
    let knownState    = 'stopped';

    function subscribeToPing() {
        const pingEl   = document.getElementById('ping-display');
        const statusEl = document.getElementById('connection-status');
        if (!pingEl || !window.VPNPanel || !window.VPNPanel.ping) return;

        window.VPNPanel.ping.subscribe(({ status, ms }) => {
            if (status === 'ok') {
                pingEl.textContent = ms + ' мс';
                pingEl.className = 'status-value mono text-emerald';
                if (statusEl) {
                    statusEl.className = 'status-pill status-pill--ok';
                    statusEl.innerHTML = '<span class="status-dot status-dot--ok status-dot--pulse"></span>Подключено';
                }
            } else if (status === 'slow') {
                pingEl.textContent = ms + ' мс';
                pingEl.className = 'status-value mono text-amber';
                if (statusEl) {
                    statusEl.className = 'status-pill status-pill--ok';
                    statusEl.innerHTML = '<span class="status-dot status-dot--warn"></span>Подключено';
                }
            } else if (status === 'bad') {
                pingEl.textContent = ms !== null ? (ms + ' мс') : '—';
                pingEl.className = 'status-value mono text-rose';
                if (statusEl) {
                    statusEl.className = 'status-pill status-pill--err';
                    statusEl.innerHTML = '<span class="status-dot status-dot--err"></span>Отключено';
                }
            } else {
                pingEl.textContent = '—';
                pingEl.className = 'status-value mono text-muted';
            }
        });
    }

    async function checkStateChange() {
        const result = await apiCall('status');
        if (!result.ok || !result.data) return;
        const { state, active_id } = result.data;

        const wasRunning      = (knownActiveId !== '' && knownState === 'running');
        const isStillRunning  = (active_id !== ''   && state === 'running');
        const activeIdChanged = (active_id !== knownActiveId && active_id !== '');

        if (wasRunning && isStillRunning && activeIdChanged) {

            const newItem = document.querySelector(`[data-config-id="${active_id}"] .config-name`);
            const newName = newItem ? newItem.textContent.trim() : '';
            if (window.VPNPanel && VPNPanel.markFailoverPending) {
                VPNPanel.markFailoverPending({ to: newName, toId: active_id });
            }
        }

        if (active_id !== knownActiveId || state !== knownState) {

            location.reload();
        }
    }

    function startPolling() {
        const initial = document.getElementById('vpn-state-data');
        if (initial) {
            knownActiveId = initial.dataset.activeId || '';
            knownState    = initial.dataset.state || 'stopped';
        }
        subscribeToPing();

        setInterval(checkStateChange, 10000);
    }

    function updateConfigCount() {
        const countEl = document.getElementById('config-count');
        if (!countEl) return;
        const n = document.querySelectorAll('.config-item').length;
        countEl.textContent = n + ' шт.';
    }

    function showEmptyStateIfNoConfigs() {
        const list = document.getElementById('config-items');
        const empty = document.getElementById('config-empty-state');
        if (!list || !empty) return;
        if (list.querySelectorAll('.config-item').length === 0) {
            list.style.display = 'none';
            empty.style.display = '';
        }
    }

    function setupEventDelegation() {
        document.addEventListener('click', (e) => {
            const el = e.target.closest('[data-action]');
            if (!el) return;
            const action = el.dataset.action;
            const configId   = el.dataset.configId   || '';
            const configName = el.dataset.configName || '';

            switch (action) {
                case 'activate':     e.preventDefault(); doActivate(configId, configName); break;
                case 'delete':       e.preventDefault(); doDelete(configId, configName); break;
                case 'toggle-role':  e.preventDefault(); doToggleRole(configId); break;
                case 'stop':         e.preventDefault(); doStop(); break;
                case 'restart':      e.preventDefault(); doRestart(); break;
                case 'bulk-toggle':  e.preventDefault(); toggleBulkMode(); break;
                case 'bulk-delete':  e.preventDefault(); doBulkDelete(); break;
                case 'move-up':      e.preventDefault(); doMove(configId, 'up'); break;
                case 'move-down':    e.preventDefault(); doMove(configId, 'down'); break;
                case 'rename':
                    e.preventDefault();
                    const configItem = document.querySelector(`[data-config-id="${configId}"]`);
                    const nameEl = configItem?.querySelector('.config-name');
                    if (nameEl) startInlineRename(nameEl);

                    document.querySelectorAll('.action-menu.is-open').forEach(m => m.classList.remove('is-open'));
                    break;
            }
        });

        document.addEventListener('dblclick', (e) => {
            const nameEl = e.target.closest('.config-name');
            if (nameEl) startInlineRename(nameEl);
        });

        document.addEventListener('keydown', (e) => {
            const nameEl = e.target.closest('.config-name.is-editing');
            if (!nameEl) return;
            if (e.key === 'Enter')  { e.preventDefault(); commitInlineRename(nameEl); }
            if (e.key === 'Escape') { e.preventDefault(); cancelInlineRename(nameEl); }
        });

        document.addEventListener('focusout', (e) => {
            const nameEl = e.target.closest('.config-name.is-editing');
            if (nameEl) {

                setTimeout(() => {
                    if (nameEl.classList.contains('is-editing')) commitInlineRename(nameEl);
                }, 100);
            }
        }, true);
    }

    function init() {
        setupDragDrop();
        setupSearch();
        setupBulkSelection();
        setupActionMenus();
        setupUploadZone();
        setupEventDelegation();
        startPolling();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
