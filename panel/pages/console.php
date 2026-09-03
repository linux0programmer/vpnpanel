<?php

if (!isset($_SESSION["authenticated"]) || $_SESSION["authenticated"] !== true) {
    header("Location: login.php");
    exit();
}

$hostname   = gethostname() ?: 'server';
$shellReady = file_exists('/var/www/shell-token');

$consoleAssetsVer = '5.5.5';
?>

<link rel="stylesheet" href="assets/css/pages/console.css?v=<?php echo $consoleAssetsVer; ?>">

<div class="console-card">

    <div class="console-bar">
        <div class="traffic-lights">
            <span class="traffic-light traffic-light--r"></span>
            <span class="traffic-light traffic-light--y"></span>
            <span class="traffic-light traffic-light--g"></span>
        </div>
        <span class="console-title">root@<?php echo htmlspecialchars($hostname); ?></span>
        <?php if ($shellReady): ?>
            <div class="console-bar-actions">
                <button type="button" class="btn btn--ghost btn--sm" onclick="reloadShell()">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" width="14" height="14">
                        <path stroke-linecap="round" stroke-linejoin="round" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
                    </svg>
                    Перезагрузить
                </button>
                <a class="btn btn--ghost btn--sm" href="/shell/" target="_blank" rel="noopener">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" width="14" height="14">
                        <path stroke-linecap="round" stroke-linejoin="round" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"/>
                    </svg>
                    Новое окно
                </a>
            </div>
        <?php endif; ?>
    </div>

    <?php if ($shellReady): ?>
        <div class="console-frame-wrap">
            <iframe id="shell-frame" class="console-frame" src="/shell/" title="Shell"></iframe>
        </div>
        <div id="diag-notice" class="console-diag" style="display:none"></div>
    <?php else: ?>
        <div class="console-diag">
            <span class="warn">⚠ Веб-терминал не настроен</span>
            shell-token отсутствует: <code>/var/www/shell-token</code><br><br>
            Выполните обновление:
            <span class="cmd">cd /var/www/html && sudo bash update.sh</span>
        </div>
    <?php endif; ?>

</div>

<?php if ($shellReady): ?>
<script>

(function() {
    const iframe = document.getElementById('shell-frame');
    const diag   = document.getElementById('diag-notice');

    window.reloadShell = function() {
        iframe.src = iframe.src;
    };

    function showDiag(html) {

        iframe.parentElement.style.display = 'none';
        diag.style.display = 'block';
        diag.innerHTML = html;
    }

    fetch('/shell/', { method: 'HEAD', cache: 'no-store' })
        .then(r => {
            if (r.status >= 500 && r.status < 600) {
                showDiag(
                    '<span class="warn">⚠ shellinabox не отвечает (HTTP ' + r.status + ')</span>' +
                    'Apache получил отказ от 127.0.0.1:4200.<br><br>' +
                    'Перезапустите:<span class="cmd">sudo systemctl restart shellinabox</span>' +
                    'Или запустите обновление:<span class="cmd">cd /var/www/html && sudo bash update.sh</span>'
                );
            } else if (r.status === 404) {
                showDiag(
                    '<span class="warn">⚠ Apache не проксирует /shell/ (404)</span>' +
                    '<span class="cmd">sudo a2enconf vpn-panel-shell && sudo systemctl reload apache2</span>'
                );
            }
        })
        .catch(() => {  });

    iframe.addEventListener('load', function() {
        try {
            const iw = iframe.contentWindow;
            if (!iw) return;
            iw.onbeforeunload = null;
            const origAdd = iw.addEventListener.bind(iw);
            iw.addEventListener = function(type, listener, options) {
                if (type === 'beforeunload') return;
                return origAdd(type, listener, options);
            };
            try {
                Object.defineProperty(iw, 'onbeforeunload', {
                    get: () => null,
                    set: () => {},
                    configurable: true,
                });
            } catch(e) {}
        } catch(e) {
            console.warn('Cannot patch iframe:', e);
        }
    });

    function stripBeforeUnload() {
        try {
            const iw = iframe.contentWindow;
            if (iw) iw.onbeforeunload = null;
        } catch(e) {}
        window.onbeforeunload = null;
    }

    document.addEventListener('click', function(e) {
        const link = e.target.closest('a[href]');
        if (link && link.href && !link.target) stripBeforeUnload();
    }, true);

    document.addEventListener('submit', stripBeforeUnload, true);

    window.addEventListener('beforeunload', function(e) {
        e.stopImmediatePropagation();
        delete e.returnValue;
    }, { capture: true });
})();
</script>
<?php endif; ?>
