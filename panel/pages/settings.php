<?php

require_once __DIR__ . '/../includes/guard.php';

if (!isset($_SESSION["authenticated"]) || $_SESSION["authenticated"] !== true) {
    header("Location: login.php");
    exit();
}

$settingGroups = [
    'vpn' => [
        'title' => 'Работа VPN',
        'icon'  => 'shield',
        'color' => 'emerald',
        'items' => [
            'vpnchecker' => [
                'name' => 'Включить мониторинг VPN',
                'description' => 'Сервер сам следит за работой VPN и реагирует на проблемы. Без этого VPN работает «как есть»: упал — лежит, пока вручную не перезапустите.',
                'parent' => null,
                'level'  => 0,
                'icon'   => 'eye',
                'color'  => 'emerald',
            ],
            'autoupvpn' => [
                'name' => 'Автоматически восстанавливать VPN при сбоях',
                'description' => 'Если VPN перестал работать — сервер сам попробует его починить. Сначала аккуратно (без перезапуска), а если не помогло — перезапустит. Без включения этого пункта — сервер только запишет в журнал, что VPN упал, но ничего делать не будет.',
                'parent' => 'vpnchecker',
                'level'  => 1,
                'icon'   => 'wrench',
                'color'  => 'cyan',
            ],
            'failover' => [
                'name' => 'Резервирование VPN-конфигов',
                'description' => 'Если у вас загружено несколько VPN-конфигов на странице «VPN» — сервер автоматически переключится на резервный, когда основной упал и не подымается. Основной/резервный настраиваются на странице «VPN».',
                'parent' => 'autoupvpn',
                'level'  => 2,
                'icon'   => 'swap',
                'color'  => 'violet',
            ],
            'failover_first' => [
                'name' => 'Сразу переключаться на резерв (без перезапуска текущего)',
                'description' => 'При сбое не тратить время на оживление основного — сразу прыгать на резервный. Быстрее (3 сек вместо 15 сек), но активный конфиг не получит шанса исправиться сам. Без включения этого пункта: сначала идет перезапуск текущего конфига, и только если не помогло — на резерв.',
                'parent' => 'failover',
                'level'  => 3,
                'icon'   => 'bolt',
                'color'  => 'amber',
            ],
        ],
    ],
];

$allKeys = [];
foreach ($settingGroups as $group) {
    foreach ($group['items'] as $key => $_) $allKeys[] = $key;
}

$settingsFile = '/var/www/settings';

function readSimpleSettings(string $filePath): array {
    if (!file_exists($filePath)) return [];
    $settings = [];
    $lines = file($filePath, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    foreach ($lines as $line) {
        if (strpos($line, '=') !== false) {
            [$key, $value] = explode('=', $line, 2);
            $settings[trim($key)] = (trim($value) === 'true');
        }
    }
    return $settings;
}

function writeSimpleSettings(string $filePath, array $settings): bool {
    $content = '';
    foreach ($settings as $key => $value) {
        $content .= $key . '=' . ($value ? 'true' : 'false') . "\n";
    }
    $bytes = @file_put_contents($filePath, $content, LOCK_EX);
    if ($bytes === false) {

        error_log("VPN Panel settings.php: failed to write $filePath (check permissions: chmod 666 + ownership)");
        return false;
    }
    return true;
}

function renderToggleIcon(string $iconKey): string {
    switch ($iconKey) {
        case 'eye':
            return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M2.036 12.322a1.012 1.012 0 010-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178z"/><path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/></svg>';
        case 'wrench':
            return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M11.42 15.17L17.25 21A2.652 2.652 0 0021 17.25l-5.877-5.877M11.42 15.17l2.496-3.03c.317-.384.74-.626 1.208-.766m-2.704 3.796l-4.655 5.653a2.548 2.548 0 11-3.586-3.586l6.837-5.63m5.108-.233c.55-.164 1.163-.188 1.743-.14a4.5 4.5 0 004.486-6.336l-3.276 3.277a3.004 3.004 0 01-2.25-2.25l3.276-3.276a4.5 4.5 0 00-6.336 4.486c.091 1.076-.071 2.264-.904 2.95l-.102.085m-1.745 1.437L5.909 7.5H4.5L2.25 3.75l1.5-1.5L7.5 4.5v1.409l4.26 4.26"/></svg>';
        case 'swap':
            return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M7.5 21L3 16.5m0 0L7.5 12M3 16.5h13.5m0-13.5L21 7.5m0 0L16.5 12M21 7.5H7.5"/></svg>';
        case 'bolt':
            return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M3.75 13.5l10.5-11.25L12 10.5h8.25L9.75 21.75 12 13.5H3.75z"/></svg>';
    }
    return '';
}

function colorVar(string $color): string {

    $allowed = ['emerald', 'cyan', 'violet', 'amber'];
    return in_array($color, $allowed, true) ? "var(--$color)" : 'var(--border-subtle)';
}

$flashMessage = '';
$flashType    = '';

if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['save_settings'])) {
    $newSettings = [];
    foreach ($allKeys as $key) {
        $newSettings[$key] = isset($_POST[$key]);
    }

    if (writeSimpleSettings($settingsFile, $newSettings)) {
        $flashMessage = 'Настройки успешно сохранены';
        $flashType    = 'success';
    } else {
        $flashMessage = 'Не удалось сохранить настройки. Проверьте права на /var/www/settings (нужно chmod 666).';
        $flashType    = 'error';
    }
}

$settings = readSimpleSettings($settingsFile);
foreach ($allKeys as $key) {
    if (!isset($settings[$key])) $settings[$key] = false;
}
?>

<?php if ($flashMessage): ?>
<script>
window.__flashMessage = {
    text: <?php echo json_encode($flashMessage, JSON_UNESCAPED_UNICODE); ?>,
    type: <?php echo json_encode($flashType); ?>
};
</script>
<?php endif; ?>

<style>

    .settings-layout {
        display: grid;
        grid-template-columns: minmax(0, 2fr) minmax(0, 1fr);
        gap: var(--space-6);
        align-items: start;
    }
    @media (max-width: 1023px) {
        .settings-layout { grid-template-columns: 1fr; }
    }

    .settings-sidebar {
        position: sticky;
        top: var(--space-4);
    }
    @media (max-width: 1023px) {
        .settings-sidebar { position: static; }
    }

    .settings-section-title {
        display: flex;
        align-items: center;
        gap: var(--space-3);
        font-size: var(--text-xl);
        font-weight: 600;
        margin: 0 0 var(--space-5) 0;
        color: var(--text-primary);
    }

    .settings-toggles {
        display: flex;
        flex-direction: column;
        gap: var(--space-4);
    }

    .settings-toggle {
        display: flex;
        align-items: flex-start;
        gap: var(--space-4);
        padding: var(--space-4) var(--space-5);
        background: var(--surface-2);
        border: 1px solid var(--border-subtle);
        border-left: 3px solid var(--accent, var(--border-subtle));
        border-radius: var(--radius-lg);
        position: relative;
        transition: opacity var(--dur-base) var(--ease),
                    max-height var(--dur-base) var(--ease),
                    margin var(--dur-base) var(--ease),
                    padding var(--dur-base) var(--ease),
                    border-width var(--dur-base) var(--ease);
        overflow: visible;
    }

    .settings-toggle[data-level="1"] { margin-left: var(--space-7); }
    .settings-toggle[data-level="2"] { margin-left: calc(var(--space-7) * 2); }
    .settings-toggle[data-level="3"] { margin-left: calc(var(--space-7) * 3); }

    .settings-toggle[data-level="1"]::before,
    .settings-toggle[data-level="2"]::before,
    .settings-toggle[data-level="3"]::before {
        content: '';
        position: absolute;
        left: calc(-1 * var(--space-7));
        top: calc(-1 * var(--space-4));
        height: calc(var(--space-4) + var(--space-6));
        width: var(--space-6);
        border-left: 2px solid var(--border-subtle);
        border-bottom: 2px solid var(--border-subtle);
        border-bottom-left-radius: 8px;
        pointer-events: none;
    }

    .settings-toggle.is-hidden {
        max-height: 0 !important;
        opacity: 0;
        margin-top: 0 !important;
        margin-bottom: 0 !important;
        padding-top: 0 !important;
        padding-bottom: 0 !important;
        border-width: 0 !important;
        overflow: hidden !important;
    }
    .settings-toggle.is-hidden::before { display: none; }

    .settings-toggle .switch { flex-shrink: 0; margin-top: 2px; }

    .settings-toggle-text { flex: 1; min-width: 0; }
    .settings-toggle-text label {
        display: block;
        color: var(--text-primary);
        font-weight: 600;
        margin-bottom: var(--space-1);
        cursor: pointer;
        line-height: var(--leading-snug);
    }
    .settings-toggle-text p {
        margin: 0;
        line-height: var(--leading-snug);
    }

    .server-action {
        display: flex;
        flex-direction: column;
        gap: var(--space-3);
        padding: var(--space-4);
        background: var(--surface-2);
        border: 1px solid var(--border-subtle);
        border-radius: var(--radius-lg);
    }
    .server-action-title {
        color: var(--text-primary);
        font-weight: 600;
        margin-bottom: var(--space-1);
    }
    .server-action p {
        margin: 0;
        line-height: var(--leading-snug);
    }
    .server-action .btn { width: 100%; justify-content: center; }
</style>

<div style="margin-bottom: var(--space-6);">
    <h1 style="display: flex; align-items: center; gap: var(--space-3);">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" style="width:30px;height:30px;color:var(--blue);">
            <path stroke-linecap="round" stroke-linejoin="round" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"/>
            <circle cx="12" cy="12" r="3"/>
        </svg>
        Настройки сервера
    </h1>
</div>

<div class="settings-layout">

    <div>
        <form method="post" id="settings-form" style="display: flex; flex-direction: column; gap: var(--space-5);">
            <?php echo vp_csrfField(); ?>

            <?php foreach ($settingGroups as $groupKey => $group): ?>
            <div class="card card--accent-emerald">
                <h2 class="settings-section-title">
                    <span class="icon-badge icon-badge--<?php echo $group['color']; ?>">
                        <?php if ($group['icon'] === 'shield'): ?>
                            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path stroke-linecap="round" stroke-linejoin="round" d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z"/></svg>
                        <?php endif; ?>
                    </span>
                    <?php echo htmlspecialchars($group['title']); ?>
                </h2>

                <div class="settings-toggles">
                    <?php foreach ($group['items'] as $key => $meta): ?>
                    <div class="settings-toggle"
                         data-toggle-key="<?php echo htmlspecialchars($key); ?>"
                         data-parent="<?php echo htmlspecialchars($meta['parent'] ?? ''); ?>"
                         data-level="<?php echo (int)$meta['level']; ?>"
                         style="--accent: <?php echo colorVar($meta['color']); ?>; max-height: 280px;">
                        <span class="icon-badge icon-badge--<?php echo htmlspecialchars($meta['color']); ?>">
                            <?php echo renderToggleIcon($meta['icon']); ?>
                        </span>
                        <div class="settings-toggle-text">
                            <label for="setting-<?php echo htmlspecialchars($key); ?>">
                                <?php echo htmlspecialchars($meta['name']); ?>
                            </label>
                            <p class="text-sm text-muted">
                                <?php echo htmlspecialchars($meta['description']); ?>
                            </p>
                        </div>
                        <label class="switch">
                            <input type="checkbox"
                                   id="setting-<?php echo htmlspecialchars($key); ?>"
                                   name="<?php echo htmlspecialchars($key); ?>"
                                   data-toggle-input="<?php echo htmlspecialchars($key); ?>"
                                   <?php echo $settings[$key] ? 'checked' : ''; ?>>
                            <span class="switch-slider"></span>
                        </label>
                    </div>
                    <?php endforeach; ?>
                </div>
            </div>
            <?php endforeach; ?>

            <div style="display: flex; gap: var(--space-3); justify-content: flex-end;">
                <button type="submit" name="save_settings" value="1" class="btn btn--primary">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" width="16" height="16">
                        <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/>
                    </svg>
                    Сохранить настройки
                </button>
            </div>
        </form>
    </div>

    <aside class="settings-sidebar">
        <div class="card card--accent-rose">
            <h2 class="settings-section-title">
                <span class="icon-badge icon-badge--rose">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75">
                        <path stroke-linecap="round" stroke-linejoin="round" d="M5 12V7a2 2 0 012-2h10a2 2 0 012 2v5M5 12h14M5 12v5a2 2 0 002 2h10a2 2 0 002-2v-5M9 16h.01M13 16h2"/>
                    </svg>
                </span>
                Управление сервером
            </h2>
            <p class="text-sm text-muted" style="margin: 0 0 var(--space-5) 0; line-height: var(--leading-snug);">
                Перезагрузка и выключение всего сервера. На время операции VPN, веб-панель и локальная сеть будут недоступны.
            </p>

            <div style="display: flex; flex-direction: column; gap: var(--space-3);">

                <div class="server-action">
                    <div>
                        <div class="server-action-title">Перезапустить сервер</div>
                        <p class="text-sm text-muted">
                            Полная перезагрузка ОС. Сервер будет недоступен 30–60 секунд, после чего VPN автоматически восстановится.
                        </p>
                    </div>
                    <button type="button" class="btn btn--warning" id="system-reboot-btn">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" width="16" height="16">
                            <path stroke-linecap="round" stroke-linejoin="round" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
                        </svg>
                        Перезапустить
                    </button>
                </div>

                <div class="server-action">
                    <div>
                        <div class="server-action-title">Выключить сервер</div>
                        <p class="text-sm text-muted">
                            Полное выключение питания. Чтобы включить заново — потребуется физический доступ к серверу.
                        </p>
                    </div>
                    <button type="button" class="btn btn--danger" id="system-poweroff-btn">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" width="16" height="16">
                            <path stroke-linecap="round" stroke-linejoin="round" d="M18.36 6.64a9 9 0 11-12.73 0M12 2v10"/>
                        </svg>
                        Выключить
                    </button>
                </div>

            </div>
        </div>
    </aside>

</div>

<script>

(function() {
    'use strict';

    const form = document.getElementById('settings-form');
    if (!form) return;

    function isChecked(key) {
        const el = form.querySelector('[data-toggle-input="' + key + '"]');
        return el && el.checked;
    }

    function applyVisibility() {
        form.querySelectorAll('.settings-toggle').forEach(item => {
            let parent = item.dataset.parent;
            let visible = true;

            while (parent) {
                if (!isChecked(parent)) { visible = false; break; }
                const parentItem = form.querySelector('.settings-toggle[data-toggle-key="' + parent + '"]');
                parent = parentItem ? parentItem.dataset.parent : null;
            }
            item.classList.toggle('is-hidden', !visible);
        });
    }

    form.addEventListener('change', (e) => {
        if (e.target.matches('[data-toggle-input]')) {
            applyVisibility();
        }
    });

    applyVisibility();
})();
</script>

<script>

(function() {
    'use strict';

    const API = 'api/system_action.php';

    async function callSystemAction(action) {
        try {
            const r = await fetch(API, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
                body: JSON.stringify({ action }),
            });
            return await r.json();
        } catch (e) {
            return { ok: false, error: 'Ошибка связи: ' + e.message };
        }
    }

    function showWaitingOverlay(title, expectComeback) {
        const overlay = document.createElement('div');
        overlay.className = 'loading-overlay is-open';
        overlay.style.flexDirection = 'column';
        overlay.innerHTML = `
            <div class="loading-spinner"></div>
            <div class="loading-text">${title}</div>
            <div class="text-sm text-muted" id="sys-wait-sub">Подождите...</div>
        `;
        document.body.appendChild(overlay);

        if (!expectComeback) return;

        const sub = overlay.querySelector('#sys-wait-sub');
        let elapsed = 0;
        const tick = setInterval(async () => {
            elapsed += 3;
            sub.textContent = `Прошло ${elapsed} секунд. Проверяем доступность сервера...`;
            try {
                const r = await fetch('api/ping.php?host=127.0.0.1', { cache: 'no-store' });
                if (r.ok) {
                    clearInterval(tick);
                    sub.textContent = 'Сервер вернулся в строй. Перезагружаем страницу...';
                    setTimeout(() => location.reload(), 1500);
                }
            } catch (e) {

            }
        }, 3000);
    }

    const rebootBtn = document.getElementById('system-reboot-btn');
    if (rebootBtn) {
        rebootBtn.addEventListener('click', async () => {
            const ok = window.VPNPanel && window.VPNPanel.confirm
                ? await VPNPanel.confirm({
                    title:       'Перезапустить сервер?',
                    message:     'Сервер будет недоступен 30–60 секунд. Все активные SSH-сессии и веб-терминал будут разорваны. VPN автоматически восстановится после перезагрузки.',
                    confirmText: 'Перезапустить',
                    cancelText:  'Отмена',
                    danger:      true,
                })
                : confirm('Перезапустить сервер?');
            if (!ok) return;

            const r = await callSystemAction('reboot');
            if (r.ok) {
                if (window.Toast) Toast.warning(r.message);
                showWaitingOverlay('Сервер перезапускается...', true);
            } else {
                if (window.Toast) Toast.error(r.error || 'Ошибка');
            }
        });
    }

    const poweroffBtn = document.getElementById('system-poweroff-btn');
    if (poweroffBtn) {
        poweroffBtn.addEventListener('click', async () => {
            const ok = window.VPNPanel && window.VPNPanel.confirm
                ? await VPNPanel.confirm({
                    title:       'Выключить сервер?',
                    message:     'Сервер будет полностью выключен. Чтобы включить его заново, потребуется физический доступ — нажать кнопку питания на корпусе. Локальная сеть потеряет интернет до повторного включения.',
                    confirmText: 'Выключить',
                    cancelText:  'Отмена',
                    danger:      true,
                })
                : confirm('Выключить сервер?');
            if (!ok) return;

            const r = await callSystemAction('poweroff');
            if (r.ok) {
                if (window.Toast) Toast.warning(r.message);
                showWaitingOverlay('Сервер выключается...', false);
            } else {
                if (window.Toast) Toast.error(r.error || 'Ошибка');
            }
        });
    }
})();
</script>
