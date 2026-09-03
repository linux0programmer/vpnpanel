
(function() {
    'use strict';

    let openSelect = null;

    function buildCustomSelect(nativeSelect) {

        if (nativeSelect.dataset.customBuilt === '1') return;
        if (nativeSelect.disabled) return;

        nativeSelect.dataset.customBuilt = '1';

        const wrap = document.createElement('div');
        wrap.className = 'vp-select';
        wrap.setAttribute('tabindex', '0');
        wrap.setAttribute('role', 'combobox');
        wrap.setAttribute('aria-haspopup', 'listbox');
        wrap.setAttribute('aria-expanded', 'false');

        const trigger = document.createElement('div');
        trigger.className = 'vp-select-trigger';

        const labelSpan = document.createElement('span');
        labelSpan.className = 'vp-select-label';
        trigger.appendChild(labelSpan);

        const arrow = document.createElement('span');
        arrow.className = 'vp-select-arrow';
        arrow.innerHTML = '<svg viewBox="0 0 12 8" width="14" height="10"><path fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" d="M1 1l5 5 5-5"/></svg>';
        trigger.appendChild(arrow);

        wrap.appendChild(trigger);

        const menu = document.createElement('ul');
        menu.className = 'vp-select-menu';
        menu.setAttribute('role', 'listbox');
        wrap.appendChild(menu);

        function rebuildOptions() {
            menu.innerHTML = '';
            Array.from(nativeSelect.options).forEach((opt, idx) => {
                const item = document.createElement('li');
                item.className = 'vp-select-option';
                item.setAttribute('role', 'option');
                item.setAttribute('data-value', opt.value);
                item.setAttribute('data-index', idx);
                item.textContent = opt.textContent;
                if (opt.selected) {
                    item.classList.add('is-selected');
                    labelSpan.textContent = opt.textContent;
                }
                if (opt.disabled) item.classList.add('is-disabled');
                menu.appendChild(item);
            });

            if (!labelSpan.textContent && nativeSelect.options.length) {
                labelSpan.textContent = nativeSelect.options[0].textContent;
            }
        }
        rebuildOptions();

        nativeSelect.parentNode.insertBefore(wrap, nativeSelect);
        nativeSelect.classList.add('vp-select-native');

        function open() {
            if (wrap.classList.contains('is-open')) return;

            if (openSelect && openSelect !== wrap) {
                openSelect.classList.remove('is-open');
                openSelect.setAttribute('aria-expanded', 'false');
            }
            wrap.classList.add('is-open');
            wrap.setAttribute('aria-expanded', 'true');
            openSelect = wrap;

            const selected = menu.querySelector('.vp-select-option.is-selected');
            if (selected) selected.scrollIntoView({ block: 'nearest' });
        }

        function close() {
            wrap.classList.remove('is-open');
            wrap.setAttribute('aria-expanded', 'false');
            if (openSelect === wrap) openSelect = null;
        }

        function toggle() {
            wrap.classList.contains('is-open') ? close() : open();
        }

        function selectByIndex(idx) {
            if (idx < 0 || idx >= nativeSelect.options.length) return;
            const opt = nativeSelect.options[idx];
            if (opt.disabled) return;
            nativeSelect.selectedIndex = idx;
            labelSpan.textContent = opt.textContent;

            menu.querySelectorAll('.vp-select-option').forEach(li => li.classList.remove('is-selected'));
            const li = menu.querySelector(`.vp-select-option[data-index="${idx}"]`);
            if (li) li.classList.add('is-selected');

            nativeSelect.dispatchEvent(new Event('change', { bubbles: true }));

            if (typeof nativeSelect.onchange === 'function') {
                try { nativeSelect.onchange(); } catch (e) { console.error('select onchange:', e); }
            }
        }

        trigger.addEventListener('mousedown', (e) => {
            e.preventDefault();
            toggle();
            wrap.focus();
        });

        menu.addEventListener('click', (e) => {
            const li = e.target.closest('.vp-select-option');
            if (!li || li.classList.contains('is-disabled')) return;
            const idx = parseInt(li.dataset.index, 10);
            selectByIndex(idx);
            close();
            wrap.focus();
        });

        let hoverIdx = -1;
        function setHover(idx) {
            menu.querySelectorAll('.vp-select-option').forEach(li => li.classList.remove('is-hover'));
            const li = menu.querySelector(`.vp-select-option[data-index="${idx}"]`);
            if (li) {
                li.classList.add('is-hover');
                li.scrollIntoView({ block: 'nearest' });
                hoverIdx = idx;
            }
        }

        wrap.addEventListener('keydown', (e) => {
            const isOpen = wrap.classList.contains('is-open');
            const total = nativeSelect.options.length;
            const current = nativeSelect.selectedIndex;

            switch (e.key) {
                case 'Enter':
                case ' ':
                    e.preventDefault();
                    if (!isOpen) {
                        open();
                        hoverIdx = current;
                        setHover(current);
                    } else {
                        if (hoverIdx >= 0) selectByIndex(hoverIdx);
                        close();
                    }
                    break;
                case 'Escape':
                    if (isOpen) { e.preventDefault(); close(); }
                    break;
                case 'ArrowDown':
                    e.preventDefault();
                    if (!isOpen) { open(); hoverIdx = current; setHover(current); }
                    else { setHover(Math.min(total - 1, hoverIdx + 1)); }
                    break;
                case 'ArrowUp':
                    e.preventDefault();
                    if (!isOpen) { open(); hoverIdx = current; setHover(current); }
                    else { setHover(Math.max(0, hoverIdx - 1)); }
                    break;
                case 'Home':
                    if (isOpen) { e.preventDefault(); setHover(0); }
                    break;
                case 'End':
                    if (isOpen) { e.preventDefault(); setHover(total - 1); }
                    break;
                case 'Tab':
                    close();
                    break;
            }
        });

        nativeSelect.addEventListener('change', () => {
            const idx = nativeSelect.selectedIndex;
            if (idx >= 0) {
                labelSpan.textContent = nativeSelect.options[idx].textContent;
                menu.querySelectorAll('.vp-select-option').forEach(li => li.classList.remove('is-selected'));
                const li = menu.querySelector(`.vp-select-option[data-index="${idx}"]`);
                if (li) li.classList.add('is-selected');
            }
        });

        return { rebuildOptions, open, close, wrap };
    }

    document.addEventListener('click', (e) => {
        if (!openSelect) return;
        if (!openSelect.contains(e.target)) {
            openSelect.classList.remove('is-open');
            openSelect.setAttribute('aria-expanded', 'false');
            openSelect = null;
        }
    });

    function initAll(root = document) {
        root.querySelectorAll('select.select:not([data-custom-built])').forEach(buildCustomSelect);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', () => initAll());
    } else {
        initAll();
    }

    window.VPNPanel = window.VPNPanel || {};
    window.VPNPanel.customSelect = {
        refresh: (root) => initAll(root || document),
    };
})();
