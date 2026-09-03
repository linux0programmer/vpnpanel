
(function() {
    'use strict';

    let bar = null;
    let activeCount = 0;

    function getBar() {
        if (bar && document.body.contains(bar)) return bar;
        bar = document.createElement('div');
        bar.className = 'progress-bar';
        bar.innerHTML = '<div class="progress-bar-fill"></div>';
        document.body.appendChild(bar);
        return bar;
    }

    function start() {
        activeCount++;
        const b = getBar();

        b.classList.remove('is-done');

        void b.offsetWidth;
        b.classList.add('is-active');
    }

    function done() {
        activeCount = Math.max(0, activeCount - 1);
        if (activeCount > 0) return;
        const b = getBar();
        b.classList.remove('is-active');
        b.classList.add('is-done');

        setTimeout(() => {
            if (activeCount === 0) b.classList.remove('is-done');
        }, 400);
    }

    window.Progress = { start, done };
})();
