
(function() {
    'use strict';

    let container = null;

    function getContainer() {
        if (container && document.body.contains(container)) return container;
        container = document.createElement('div');
        container.className = 'toast-container';
        document.body.appendChild(container);
        return container;
    }

    const ICONS = {
        success: '<svg fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/></svg>',
        error:   '<svg fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>',
        warning: '<svg fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/></svg>',
        info:    '<svg fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>'
    };
    const CLOSE_ICON = '<svg fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>';

    function escapeHtml(str) {
        const div = document.createElement('div');
        div.textContent = String(str ?? '');
        return div.innerHTML;
    }

    function show(type, titleOrText, text) {
        const c = getContainer();

        let title, body, action, customDuration;
        if (titleOrText && typeof titleOrText === 'object') {
            title = titleOrText.title || null;
            body = titleOrText.body || titleOrText.text || '';
            action = titleOrText.action || null;
            customDuration = titleOrText.duration;
        } else if (text === undefined) {
            title = null;
            body = titleOrText;
        } else {
            title = titleOrText;
            body = text;
        }

        const toast = document.createElement('div');
        toast.className = 'toast toast--' + type;

        let actionHtml = '';
        if (action && action.text) {
            const safeText = escapeHtml(action.text);
            const safeHref = escapeHtml(action.href || '#');
            const safeTarget = escapeHtml(action.target || '_blank');
            actionHtml = `<a class="toast-action" href="${safeHref}" target="${safeTarget}" rel="noopener noreferrer">${safeText}</a>`;
        }

        toast.innerHTML = `
            <div class="toast-icon">${ICONS[type] || ICONS.info}</div>
            <div class="toast-body">
                ${title ? '<div class="toast-title">' + escapeHtml(title) + '</div>' : ''}
                <div>${escapeHtml(body)}</div>
                ${actionHtml}
            </div>
            <button type="button" class="toast-close" aria-label="Закрыть">
                ${CLOSE_ICON}
            </button>
        `;

        c.appendChild(toast);

        const defaultTimeout = action ? 9000 : (type === 'error' ? 6000 : 4000);
        const timeout = (typeof customDuration === 'number') ? customDuration : defaultTimeout;
        const timer = setTimeout(() => dismiss(toast), timeout);

        toast.querySelector('.toast-close').addEventListener('click', () => {
            clearTimeout(timer);
            dismiss(toast);
        });

        return toast;
    }

    function dismiss(toast) {
        if (!toast || !toast.parentNode) return;
        toast.classList.add('is-leaving');
        setTimeout(() => {
            if (toast.parentNode) toast.parentNode.removeChild(toast);
        }, 200);
    }

    window.Toast = {
        success: (t, b) => show('success', t, b),
        error:   (t, b) => show('error', t, b),
        warning: (t, b) => show('warning', t, b),
        info:    (t, b) => show('info', t, b),

        show:    (options) => show(options.type || 'info', options),
        dismiss
    };
})();
