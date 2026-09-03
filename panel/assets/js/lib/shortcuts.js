
(function() {
    'use strict';

    let seqPending = null;
    let seqTimer = null;
    const SEQ_TIMEOUT = 1000;

    function resetSeq() {
        seqPending = null;
        if (seqTimer) { clearTimeout(seqTimer); seqTimer = null; }
    }

    function startSeq(prefix) {
        seqPending = prefix;
        if (seqTimer) clearTimeout(seqTimer);
        seqTimer = setTimeout(resetSeq, SEQ_TIMEOUT);
    }

    const GO_TARGETS = {
        'o': { url: 'cabinet.php?menu=stats',       label: 'Обзор' },
        'd': { url: 'cabinet.php?menu=stats',       label: 'Обзор' },
        's': { url: 'cabinet.php?menu=stats',       label: 'Обзор' },
        'v': { url: 'cabinet.php?menu=vpn',         label: 'VPN Manager' },
        'p': { url: 'cabinet.php?menu=ping',        label: 'Пинг' },
        'c': { url: 'cabinet.php?menu=console',     label: 'Консоль' },
        'n': { url: 'cabinet.php?menu=netsettings', label: 'Сеть' },
        't': { url: 'cabinet.php?menu=settings',    label: 'Настройки' },
        'a': { url: 'cabinet.php?menu=about',       label: 'О продукте' },
    };

    function isTyping(event) {
        const t = event.target;
        if (!t) return false;
        const tag = t.tagName;
        if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return true;
        if (t.isContentEditable) return true;
        return false;
    }

    let helpModal = null;

    function buildHelpModal() {
        if (helpModal) return helpModal;
        const backdrop = document.createElement('div');
        backdrop.className = 'modal-backdrop';
        backdrop.innerHTML = `
            <div class="modal" role="dialog" aria-labelledby="shortcuts-title">
                <div class="modal-header">
                    <h3 class="modal-title" id="shortcuts-title">Горячие клавиши</h3>
                    <button type="button" class="modal-close" aria-label="Закрыть">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="18" height="18">
                            <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12"/>
                        </svg>
                    </button>
                </div>
                <div class="modal-body">
                    <div class="shortcut-group">
                        <div class="shortcut-group-title">Навигация</div>
                        <div class="shortcut-row"><span><kbd class="kbd">g</kbd> <kbd class="kbd">o</kbd></span><span>Обзор (стартовая)</span></div>
                        <div class="shortcut-row"><span><kbd class="kbd">g</kbd> <kbd class="kbd">v</kbd></span><span>VPN Manager</span></div>
                        <div class="shortcut-row"><span><kbd class="kbd">g</kbd> <kbd class="kbd">p</kbd></span><span>Пинг</span></div>
                        <div class="shortcut-row"><span><kbd class="kbd">g</kbd> <kbd class="kbd">c</kbd></span><span>Консоль</span></div>
                        <div class="shortcut-row"><span><kbd class="kbd">g</kbd> <kbd class="kbd">n</kbd></span><span>Настройки сети</span></div>
                        <div class="shortcut-row"><span><kbd class="kbd">g</kbd> <kbd class="kbd">t</kbd></span><span>Настройки</span></div>
                        <div class="shortcut-row"><span><kbd class="kbd">g</kbd> <kbd class="kbd">a</kbd></span><span>О продукте</span></div>
                    </div>
                    <div class="shortcut-group">
                        <div class="shortcut-group-title">Действия</div>
                        <div class="shortcut-row"><span><kbd class="kbd">r</kbd></span><span>Перезагрузить страницу</span></div>
                        <div class="shortcut-row"><span><kbd class="kbd">/</kbd></span><span>Фокус на поиск (если есть)</span></div>
                        <div class="shortcut-row"><span><kbd class="kbd">?</kbd></span><span>Показать эту справку</span></div>
                        <div class="shortcut-row"><span><kbd class="kbd">Esc</kbd></span><span>Закрыть модалку / меню</span></div>
                    </div>
                </div>
            </div>
        `;
        document.body.appendChild(backdrop);

        backdrop.addEventListener('click', (e) => {
            if (e.target === backdrop || e.target.closest('.modal-close')) {
                closeHelp();
            }
        });

        helpModal = backdrop;
        return backdrop;
    }

    function openHelp() {
        const m = buildHelpModal();
        m.classList.add('is-open');
    }

    function closeHelp() {
        if (helpModal) helpModal.classList.remove('is-open');
    }

    function isHelpOpen() {
        return helpModal && helpModal.classList.contains('is-open');
    }

    function handleKey(e) {

        if (e.key === 'Escape') {
            if (isHelpOpen()) {
                e.preventDefault();
                closeHelp();
                return;
            }

            const openMenus = document.querySelectorAll('.action-menu.is-open');
            if (openMenus.length) {
                e.preventDefault();
                openMenus.forEach(m => m.classList.remove('is-open'));
                return;
            }
            return;
        }

        if (isTyping(e)) return;

        if (e.ctrlKey || e.metaKey || e.altKey) return;

        const key = e.key.toLowerCase();

        if (seqPending === 'g') {
            if (GO_TARGETS[key]) {
                e.preventDefault();
                const target = GO_TARGETS[key];
                resetSeq();
                window.location.href = target.url;
                return;
            }

            resetSeq();
        }

        if (key === '?' || (e.key === '/' && e.shiftKey)) {

            e.preventDefault();
            openHelp();
            return;
        }

        if (key === 'g') {
            e.preventDefault();
            startSeq('g');
            return;
        }

        if (key === 'r') {
            e.preventDefault();
            location.reload();
            return;
        }

        if (key === '/') {

            const search = document.getElementById('config-search-input')
                        || document.querySelector('input[type="search"]')
                        || document.querySelector('input[name="search"]');
            if (search) {
                e.preventDefault();
                search.focus();
                search.select();
            }
            return;
        }
    }

    document.addEventListener('keydown', handleKey);

    window.VPNPanelShortcuts = {
        openHelp,
        closeHelp,
    };
})();
