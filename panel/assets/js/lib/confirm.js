
(function() {
    'use strict';

    let activeBackdrop = null;
    let activeResolve = null;
    let lastFocused = null;
    let prevBodyOverflow = '';
    let prevBodyPaddingRight = '';

    function escapeHtml(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, c => (
            { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
        ));
    }

    function close(result) {
        if (!activeBackdrop) return;
        const backdrop = activeBackdrop;
        const resolve = activeResolve;
        activeBackdrop = null;
        activeResolve = null;

        document.removeEventListener('keydown', handleKey, true);

        backdrop.classList.remove('is-open');

        setTimeout(() => {
            backdrop.remove();

            document.body.style.overflow = prevBodyOverflow;
            document.body.style.paddingRight = prevBodyPaddingRight;
            if (lastFocused && typeof lastFocused.focus === 'function') {
                try { lastFocused.focus(); } catch (e) {}
            }
            lastFocused = null;
        }, 220);

        if (resolve) resolve(result);
    }

    function handleKey(e) {
        if (!activeBackdrop) return;
        if (e.key === 'Escape') {
            e.preventDefault();
            e.stopPropagation();
            close(false);
            return;
        }
        if (e.key === 'Enter') {
            const cancel = activeBackdrop.querySelector('[data-vp-confirm-cancel]');
            if (document.activeElement !== cancel) {
                e.preventDefault();
                e.stopPropagation();
                close(true);
            }
            return;
        }
        if (e.key === 'Tab') {
            const focusables = activeBackdrop.querySelectorAll('button');
            if (!focusables.length) return;
            const first = focusables[0];
            const last  = focusables[focusables.length - 1];
            if (e.shiftKey && document.activeElement === first) {
                e.preventDefault();
                last.focus();
            } else if (!e.shiftKey && document.activeElement === last) {
                e.preventDefault();
                first.focus();
            }
        }
    }

    function open(opts) {
        if (activeBackdrop) close(false);

        const o = opts || {};
        const title       = o.title       || 'Подтвердите действие';
        const message     = o.message     || '';
        const confirmText = o.confirmText || 'OK';
        const cancelText  = o.cancelText  || 'Отмена';
        const danger      = !!o.danger;

        lastFocused = document.activeElement;

        const backdrop = document.createElement('div');
        backdrop.className = 'modal-backdrop';
        backdrop.setAttribute('role', 'dialog');
        backdrop.setAttribute('aria-modal', 'true');
        backdrop.setAttribute('aria-labelledby', 'vp-confirm-title');
        backdrop.innerHTML = `
            <div class="modal" role="document">
                <div class="modal-header">
                    <h3 id="vp-confirm-title" class="modal-title">${escapeHtml(title)}</h3>
                </div>
                ${message ? `<div class="modal-body">${escapeHtml(message)}</div>` : ''}
                <div class="modal-footer">
                    <button type="button" class="btn btn--ghost" data-vp-confirm-cancel>${escapeHtml(cancelText)}</button>
                    <button type="button" class="btn ${danger ? 'btn--danger' : 'btn--primary'}" data-vp-confirm-ok>${escapeHtml(confirmText)}</button>
                </div>
            </div>
        `;

        backdrop.addEventListener('click', (e) => {

            if (e.target === backdrop) {
                close(false);
                return;
            }
            if (e.target.closest('[data-vp-confirm-cancel]')) {
                close(false);
                return;
            }
            if (e.target.closest('[data-vp-confirm-ok]')) {
                close(true);
                return;
            }
        });

        document.body.appendChild(backdrop);

        const scrollbarWidth = window.innerWidth - document.documentElement.clientWidth;
        prevBodyOverflow = document.body.style.overflow;
        prevBodyPaddingRight = document.body.style.paddingRight;
        document.body.style.overflow = 'hidden';
        if (scrollbarWidth > 0) {
            document.body.style.paddingRight = scrollbarWidth + 'px';
        }

        activeBackdrop = backdrop;
        document.addEventListener('keydown', handleKey, true);

        requestAnimationFrame(() => {
            backdrop.classList.add('is-open');
            const okBtn = backdrop.querySelector('[data-vp-confirm-ok]');
            if (okBtn) okBtn.focus();
        });

        return new Promise((resolve) => {
            activeResolve = resolve;
        });
    }

    window.VPNPanel = window.VPNPanel || {};
    window.VPNPanel.confirm = open;
})();
