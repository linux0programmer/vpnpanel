<?php

$deployed_file = '/var/lib/vpn-panel/deployed';
$version_file  = '/var/www/version';
$product_version = 'не определён';

if (file_exists($deployed_file) && is_readable($deployed_file)) {
    $raw = trim((string)file_get_contents($deployed_file));
    if ($raw !== '' && preg_match('/^(v\d+)/', $raw, $m)) {
        $product_version = $m[1];
    }
}

if ($product_version === 'не определён' && file_exists($version_file) && is_readable($version_file)) {
    $raw = trim((string)file_get_contents($version_file));
    if ($raw !== '' && $raw !== '0' && preg_match('/^\d+$/', $raw)) {
        $product_version = 'v' . $raw;
    }
}
?>

<style>

    .about-page {
        display: flex;
        flex-direction: column;
        gap: var(--space-4);
        max-width: 1600px;
        margin: 0 auto;
    }

    .about-hero {
        display: flex;
        align-items: center;
        gap: var(--space-5);
        padding: var(--space-5) var(--space-6);
    }
    .about-hero-logo {
        width: 80px;
        height: 80px;
        object-fit: contain;
        flex-shrink: 0;
    }
    .about-hero-text {
        flex: 1;
        min-width: 0;
    }
    .about-hero-title-row {
        display: flex;
        align-items: center;
        gap: var(--space-3);
        margin-bottom: var(--space-1);
        flex-wrap: wrap;
    }
    .about-hero-title {
        font-size: var(--text-xl);
        font-weight: 800;
        letter-spacing: var(--tracking-tight);
        color: var(--text-primary);
        line-height: 1.1;
    }
    .about-hero-tagline {
        font-size: var(--text-sm);
        color: var(--text-secondary);
        line-height: var(--leading-snug);
    }

    .about-info {
        padding: var(--space-5);
    }
    .about-info-title {
        font-size: var(--text-xs);
        font-weight: 700;
        text-transform: uppercase;
        letter-spacing: 0.08em;
        color: var(--text-muted);
        margin-bottom: var(--space-3);
    }
    .about-info p {
        font-size: var(--text-sm);
        color: var(--text-secondary);
        line-height: var(--leading-relaxed);
        margin-bottom: var(--space-3);
    }
    .about-info p:last-child { margin-bottom: 0; }

    .about-features {
        display: grid;
        grid-template-columns: repeat(3, 1fr);
        gap: var(--space-3);
    }
    @media (max-width: 1023px) {
        .about-features { grid-template-columns: repeat(2, 1fr); }
    }
    @media (max-width: 640px) {
        .about-features { grid-template-columns: 1fr; }
    }

    .about-feature {
        display: flex;
        flex-direction: column;
        gap: var(--space-2);
        padding: var(--space-4);
        background: var(--surface-1);
        border: 1px solid var(--border-subtle);
        border-radius: var(--radius-lg);
        transition: border-color var(--dur-fast) var(--ease),
                    transform var(--dur-fast) var(--ease);
    }
    .about-feature:hover {
        border-color: var(--border-strong);
        transform: translateY(-2px);
    }
    .about-feature-icon {
        width: 36px;
        height: 36px;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        border-radius: var(--radius-md);
        flex-shrink: 0;
    }
    .about-feature-icon--emerald { background: var(--emerald-soft); color: var(--emerald); }
    .about-feature-icon--cyan    { background: var(--cyan-soft);    color: var(--cyan); }
    .about-feature-icon--violet  { background: var(--violet-soft);  color: var(--violet); }
    .about-feature-icon--amber   { background: var(--amber-soft);   color: var(--amber); }
    .about-feature-icon--rose    { background: var(--rose-soft);    color: var(--rose); }
    .about-feature-icon--orange  { background: var(--orange-soft);  color: var(--orange); }

    .about-feature-title {
        font-size: var(--text-sm);
        font-weight: 700;
        color: var(--text-primary);
        letter-spacing: -0.01em;
    }
    .about-feature-desc {
        font-size: var(--text-xs);
        color: var(--text-muted);
        line-height: var(--leading-relaxed);
    }

    .about-cta {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: var(--space-4);
        padding: var(--space-5);

        background: linear-gradient(135deg,
            rgba(244, 63, 94, 0.08) 0%,
            rgba(249, 115, 22, 0.10) 100%);
        border: 1px solid var(--orange-border);
        border-radius: var(--radius-lg);
        flex-wrap: wrap;
    }
    .about-cta-text {
        flex: 1;
        min-width: 240px;
    }
    .about-cta-title {
        font-size: var(--text-md);
        font-weight: 700;
        color: var(--text-primary);
        margin-bottom: 2px;
    }
    .about-cta-subtitle {
        font-size: var(--text-xs);
        color: var(--text-muted);
        line-height: var(--leading-relaxed);
    }
    .about-tg-btn {
        display: inline-flex;
        align-items: center;
        gap: var(--space-2);
        padding: 10px 18px;
        background: linear-gradient(135deg, #F97316, #EC4899);
        color: white !important;
        border-radius: var(--radius-md);
        text-decoration: none;
        font-weight: 700;
        font-size: var(--text-sm);
        flex-shrink: 0;
        transition: transform var(--dur-fast) var(--ease),
                    box-shadow var(--dur-fast) var(--ease);
    }
    .about-tg-btn:hover {
        transform: translateY(-1px);
        box-shadow: 0 6px 20px rgba(249, 115, 22, 0.35);
    }
    .about-tg-btn svg { flex-shrink: 0; }

    .about-footer {
        text-align: center;
        font-size: var(--text-xs);
        color: var(--text-muted);
        padding: var(--space-3) 0;
    }
    .about-footer a {
        color: var(--orange);
        font-weight: 600;
    }
</style>

<div class="about-page">

    <div class="card about-hero">
        <div class="about-hero-text">
            <div class="about-hero-title-row">
                <h1 class="about-hero-title">VPN Server</h1>
                <span class="badge badge--emerald"><?php echo htmlspecialchars($product_version); ?></span>
            </div>
            <p class="about-hero-tagline">
                Один сервер — безопасный интернет для всей локальной сети. Все компьютеры, телефоны и другие устройства
                работают через VPN автоматически — ничего не нужно настраивать на каждом из них.
            </p>
        </div>
    </div>

    <div class="card about-info">
        <div class="about-info-title">Описание</div>
        <p>
            <strong>VPN Server</strong> — это программа с веб-интерфейсом, которая превращает обычный компьютер
            на Ubuntu в «входную дверь в интернет» для всей вашей локальной сети. Все другие устройства —
            компьютеры, телефоны, IP-камеры, принтеры, IP-телефоны — выходят в интернет через этот сервер,
            а он — через защищённый VPN-туннель. В результате ни одно из ваших устройств не раскрывает
            свой настоящий IP-адрес — для внешнего мира они выглядят как посетители из той страны,
            где находится VPN-сервер.
        </p>
        <p>
            Это удобно, когда нужно защитить сразу целую сеть, а не возиться с VPN-клиентами на каждом
            отдельном компьютере или телефоне. Подключили сервер — и все устройства офиса, домашние гаджеты
            или оборудование IP-телефонии сразу работают через VPN. Ничего не нужно устанавливать на телефоны
            гостей, ноутбуки сотрудников или устройства, в которых VPN-клиент вообще нельзя установить.
        </p>
        <p>
            Поддерживаются два самых распространённых VPN-протокола — <strong>WireGuard</strong> (быстрый и современный)
            и <strong>OpenVPN</strong> (проверенный временем). Можно загрузить сразу несколько VPN-конфигов: основной
            и запасные. Если основной VPN-сервер вдруг перестанет отвечать, система сама переключится на резервный —
            пользователи в сети даже не заметят перебоя.
        </p>
    </div>

    <div class="about-features">

        <div class="about-feature">
            <div class="about-feature-icon about-feature-icon--emerald">
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>
                </svg>
            </div>
            <div class="about-feature-title">Kill Switch</div>
            <div class="about-feature-desc">Если VPN-туннель оборвётся, доступ в интернет для всей локальной сети сразу блокируется. Без этого устройства в сети сами перешли бы на обычный интернет и раскрыли ваш настоящий IP-адрес и местоположение.</div>
        </div>

        <div class="about-feature">
            <div class="about-feature-icon about-feature-icon--cyan">
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <path d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
                </svg>
            </div>
            <div class="about-feature-title">Автоматический резерв</div>
            <div class="about-feature-desc">Можно загрузить сразу несколько VPN-конфигов — основной и запасные. Если соединение по основному конфигу пропадёт (упал сервер, сменился IP, заблокировали порт) — система сама переключится на запасной туннель без перерывов.</div>
        </div>

        <div class="about-feature">
            <div class="about-feature-icon about-feature-icon--violet">
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <path d="M3 3v18h18M9 17V9m4 8V5m4 12v-7"/>
                </svg>
            </div>
            <div class="about-feature-title">Мониторинг и статистика</div>
            <div class="about-feature-desc">Показывает в реальном времени нагрузку на сервер (процессор, память, диск), скорость по каждому каналу (VPN, провайдер, локальная сеть) и историю всех важных событий — отключения, переподключения, замены конфигов.</div>
        </div>

        <div class="about-feature">
            <div class="about-feature-icon about-feature-icon--amber">
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <rect x="2" y="3" width="20" height="14" rx="2" ry="2"/>
                    <line x1="8" y1="21" x2="16" y2="21"/>
                    <line x1="12" y1="17" x2="12" y2="21"/>
                    <polyline points="6 8 9 11 6 14"/>
                    <line x1="11" y1="14" x2="14" y2="14"/>
                </svg>
            </div>
            <div class="about-feature-title">Веб-терминал</div>
            <div class="about-feature-desc">Командная строка сервера прямо в браузере — никаких PuTTY или других ssh-клиентов ставить не нужно. Удобно для быстрой проверки или правок с любого устройства — хоть с телефона.</div>
        </div>

        <div class="about-feature">
            <div class="about-feature-icon about-feature-icon--rose">
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72 12.84 12.84 0 00.7 2.81 2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45 12.84 12.84 0 002.81.7A2 2 0 0122 16.92z"/>
                </svg>
            </div>
            <div class="about-feature-title">VOIP-оптимизация</div>
            <div class="about-feature-desc">Если в локальной сети работают IP-телефоны, сервер заранее настроен так, чтобы голосовые звонки проходили без обрывов, фантомных дозвонов и с лучшим качеством — типичных проблем IP-телефонии, когда она работает через общий интернет-шлюз.</div>
        </div>

        <div class="about-feature">
            <div class="about-feature-icon about-feature-icon--orange">
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/>
                </svg>
            </div>
            <div class="about-feature-title">Health Check Daemon</div>
            <div class="about-feature-desc">Фоновая программа-сторож, которая каждые несколько секунд проверяет, жив ли VPN-туннель. Если связь пропала — сама перезапустит соединение или переключится на запасной конфиг. Никого не нужно будить ночью.</div>
        </div>

    </div>

</div>
