#!/bin/bash

if [ "${NO_COLOR:-0}" = "1" ]; then
    RED=''; GREEN=''; YELLOW=''; CYAN=''; WHITE=''; GRAY=''; NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    WHITE='\033[1;37m'
    GRAY='\033[0;90m'
    NC='\033[0m'
fi

PASSED=0
WARNED=0
FAILED=0
WARNINGS=()
FAILURES=()

QUIET=0
WEB_DIR_DIAG="/var/www/html"

VP_CONF_FILE="/etc/vpn-panel.conf"
LAN_IP="10.10.1.1"
LAN_NET="10.10.1.0/20"
if [ -f "$VP_CONF_FILE" ]; then
    v=$(grep "^LAN_IP=" "$VP_CONF_FILE" 2>/dev/null | cut -d= -f2);  [ -n "$v" ] && LAN_IP="$v"
    v=$(grep "^LAN_NET=" "$VP_CONF_FILE" 2>/dev/null | cut -d= -f2); [ -n "$v" ] && LAN_NET="$v"
fi
[ "${1:-}" = "--quiet" ] && QUIET=1

pass() {
    PASSED=$((PASSED + 1))
    [ "$QUIET" -eq 0 ] && echo -e "  ${GREEN}[✓]${NC} $1"
}

warn() {
    WARNED=$((WARNED + 1))
    WARNINGS+=("$1")
    echo -e "  ${YELLOW}[!]${NC} $1"
}

fail() {
    FAILED=$((FAILED + 1))
    FAILURES+=("$1")
    echo -e "  ${RED}[✗]${NC} $1"
}

info() {
    [ "$QUIET" -eq 0 ] && echo -e "  ${GRAY}[i]${NC} $1"
}

section() {
    [ "$QUIET" -eq 0 ] && {
        echo ""
        echo -e "${CYAN}━━━ $1 ━━━${NC}"
    }
}

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Запустите от root: sudo bash $0${NC}"
    exit 1
fi

[ "$QUIET" -eq 0 ] && {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       VPN Server v5 — Диагностика            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo -e "${GRAY}  Запущено: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${GRAY}  Hostname: $(hostname)${NC}"
}

section "1. Базовая система"

if [ -f /etc/os-release ]; then
    os_name=$(grep -E "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
    os_version=$(grep -E "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
    if [ "${os_name,,}" = "ubuntu" ] && { [[ "$os_version" == "22.04"* ]] || [[ "$os_version" == "24.04"* ]]; }; then
        pass "ОС: Ubuntu $os_version (поддерживается)"
    else
        warn "ОС: $os_name $os_version (проверено на Ubuntu 22.04 и 24.04)"
    fi
else
    fail "Не удалось определить ОС (/etc/os-release отсутствует)"
fi

uptime_str=$(uptime -p 2>/dev/null | sed 's/up //')
[ -n "$uptime_str" ] && info "Uptime: $uptime_str"

if [ -f /var/www/version ]; then
    vp_version=$(cat /var/www/version 2>/dev/null)
    expected_version=$(grep -m1 "^SCRIPT_VERSION=" /var/www/html/update.sh 2>/dev/null | cut -d= -f2)
[ -z "$expected_version" ] && expected_version="$vp_version"
if [ "$vp_version" = "$expected_version" ]; then
        pass "Версия VPN Panel: v$vp_version"
    else
        warn "Версия VPN Panel: v$vp_version (код ожидает v$expected_version)"
    fi
else
    fail "/var/www/version отсутствует"
fi

if command -v df >/dev/null 2>&1; then
    disk_used=$(df / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
    if [ -n "$disk_used" ]; then
        if [ "$disk_used" -lt 80 ]; then
            pass "Дисковое пространство /: ${disk_used}% использовано"
        elif [ "$disk_used" -lt 90 ]; then
            warn "Дисковое пространство /: ${disk_used}% использовано (>80%)"
        else
            fail "Дисковое пространство /: ${disk_used}% использовано (>90%)"
        fi
    fi
fi

if [ -f /proc/meminfo ]; then
    mem_total=$(grep "^MemTotal:" /proc/meminfo | awk '{print $2}')
    mem_avail=$(grep "^MemAvailable:" /proc/meminfo | awk '{print $2}')
    if [ -n "$mem_total" ] && [ -n "$mem_avail" ]; then
        mem_used_pct=$(( 100 - (mem_avail * 100 / mem_total) ))
        info "RAM: ${mem_used_pct}% использовано ($((mem_avail/1024)) MB свободно из $((mem_total/1024)) MB)"
    fi
fi

section "2. Сетевые интерфейсы"

ACTUAL_LAN=$(ip -4 addr show 2>/dev/null | grep -F "$LAN_IP/" | awk '{print $NF}' | head -1)
ACTUAL_WAN=$(ip route show default 2>/dev/null | grep -v "dev tun\|dev wg" | grep -oP 'dev \K[^ ]+' | head -1)

if [ -n "$ACTUAL_LAN" ]; then
    if ip link show "$ACTUAL_LAN" 2>/dev/null | grep -q "state UP"; then
        pass "LAN интерфейс: $ACTUAL_LAN (UP, IP $LAN_IP)"
    else
        fail "LAN интерфейс $ACTUAL_LAN не в состоянии UP"
    fi
else
    fail "LAN интерфейс не найден (нет интерфейса с IP $LAN_IP)"
fi

if [ -n "$ACTUAL_WAN" ]; then
    wan_ip=$(ip -4 addr show "$ACTUAL_WAN" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    if ip link show "$ACTUAL_WAN" 2>/dev/null | grep -q "state UP"; then
        pass "WAN интерфейс: $ACTUAL_WAN (UP, IP ${wan_ip:-нет})"
    else
        fail "WAN интерфейс $ACTUAL_WAN не в состоянии UP"
    fi
else
    fail "WAN интерфейс не найден (нет default route через physical interface)"
fi

if ip link show tun0 >/dev/null 2>&1; then
    tun_ip=$(ip -4 addr show tun0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    if [ -n "$tun_ip" ]; then
        pass "VPN tun0: активен (IP $tun_ip)"
    else
        info "VPN tun0: интерфейс есть, но без IP (VPN не активирован)"
    fi
else
    info "VPN tun0: отсутствует (конфиг не загружен/не активирован — норма для свежей установки)"
fi

def_route_dev=$(ip route show default 2>/dev/null | grep -oP 'dev \K[^ ]+' | head -1)
if [ "$def_route_dev" = "tun0" ]; then
    info "Default route: через tun0 (full tunnel)"
elif [ "$def_route_dev" = "$ACTUAL_WAN" ]; then
    info "Default route: через $ACTUAL_WAN (split tunnel или VPN не активен)"
fi

section "3. /etc/vpn-panel.conf"

if [ ! -f /etc/vpn-panel.conf ]; then
    fail "/etc/vpn-panel.conf отсутствует"
else
    conf_version=$(grep "^VERSION=" /etc/vpn-panel.conf 2>/dev/null | cut -d= -f2)
    conf_wan=$(grep "^WAN=" /etc/vpn-panel.conf 2>/dev/null | cut -d= -f2)
    conf_lan=$(grep "^LAN=" /etc/vpn-panel.conf 2>/dev/null | cut -d= -f2)

    [ -n "$conf_version" ] && info "Версия в файле: $conf_version"

    if [ -z "$conf_wan" ] || [ "$conf_wan" = "unknown" ]; then
        fail "WAN= пустой или 'unknown' в vpn-panel.conf"
    elif ! ip link show "$conf_wan" >/dev/null 2>&1; then
        fail "WAN=$conf_wan — интерфейс НЕ существует в системе!"
    elif [ "$conf_wan" != "$ACTUAL_WAN" ]; then
        warn "WAN=$conf_wan в файле, но default route через $ACTUAL_WAN (возможно VPN активен — это норма)"
    else
        pass "WAN=$conf_wan соответствует реальному состоянию системы"
    fi

    if [ -z "$conf_lan" ] || [ "$conf_lan" = "unknown" ]; then
        fail "LAN= пустой или 'unknown' в vpn-panel.conf"
    elif ! ip link show "$conf_lan" >/dev/null 2>&1; then
        fail "LAN=$conf_lan — интерфейс НЕ существует в системе!"
    elif [ "$conf_lan" != "$ACTUAL_LAN" ]; then
        warn "LAN=$conf_lan в файле, но IP $LAN_IP на $ACTUAL_LAN"
    else
        pass "LAN=$conf_lan соответствует реальному состоянию системы"
    fi
fi

section "4. Netplan (поиск конфликтов)"

backup_dirs=$(find /etc/netplan -mindepth 1 -type d 2>/dev/null)
if [ -n "$backup_dirs" ]; then
    while IFS= read -r dir; do
        warn "Найдена подпапка в /etc/netplan/: $dir (может сломать парсинг netplan на старых версиях update.sh)"
    done <<< "$backup_dirs"
else
    pass "Подпапок в /etc/netplan/ нет"
fi

if [ -f /etc/netplan/50-cloud-init.yaml ]; then
    if grep -q "eth0" /etc/netplan/50-cloud-init.yaml 2>/dev/null; then
        warn "/etc/netplan/50-cloud-init.yaml содержит eth0 (cloud-init артефакт)"
    else
        info "/etc/netplan/50-cloud-init.yaml присутствует (без eth0)"
    fi
fi

yaml_count=$(find /etc/netplan -maxdepth 1 -name "*.yaml" 2>/dev/null | wc -l)
if [ -f /etc/netplan/99-vpn-panel.yaml ]; then
    pass "netplan панели: /etc/netplan/99-vpn-panel.yaml (применяется последним)"
    [ "$yaml_count" -gt 1 ] && info "Рядом ещё $((yaml_count - 1)) сторонних .yaml — это допустимо, конфликты проверяются в секции 10"
elif [ "$yaml_count" -eq 0 ]; then
    fail "В /etc/netplan/ нет ни одного .yaml файла"
else
    warn "Нет /etc/netplan/99-vpn-panel.yaml — панель не управляет сетью (найдено файлов: $yaml_count)"
fi

section "5. iptables — Kill Switch (FORWARD chain)"

fwd_policy=$(iptables -L FORWARD -n 2>/dev/null | head -1 | grep -oP '(?<=policy )\w+')
if [ "$fwd_policy" = "DROP" ]; then
    pass "FORWARD policy: DROP"
else
    fail "FORWARD policy: $fwd_policy (ожидается DROP — без этого Kill Switch не работает)"
fi

if iptables -t nat -C POSTROUTING -o tun0 -s "$LAN_NET" -j MASQUERADE 2>/dev/null; then
    pass "NAT MASQUERADE -o tun0 для $LAN_NET: присутствует"
else
    fail "NAT MASQUERADE -o tun0 для $LAN_NET: ОТСУТСТВУЕТ"
fi

if [ -n "$ACTUAL_LAN" ]; then
    if iptables -C FORWARD -i "$ACTUAL_LAN" -o tun0 -j ACCEPT 2>/dev/null; then
        pass "FORWARD: $ACTUAL_LAN → tun0 ACCEPT (LAN до VPN)"
    else
        fail "FORWARD: $ACTUAL_LAN → tun0 ACCEPT — ОТСУТСТВУЕТ"
    fi

    if iptables -C FORWARD -i tun0 -o "$ACTUAL_LAN" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
        pass "FORWARD: tun0 → $ACTUAL_LAN RELATED,ESTABLISHED (обратный трафик)"
    else
        warn "FORWARD: tun0 → $ACTUAL_LAN RELATED,ESTABLISHED — ОТСУТСТВУЕТ"
    fi

    if [ -n "$ACTUAL_WAN" ]; then
        if iptables -C FORWARD -i "$ACTUAL_LAN" -o "$ACTUAL_WAN" -j REJECT --reject-with icmp-net-unreachable 2>/dev/null; then
            pass "FORWARD: $ACTUAL_LAN → $ACTUAL_WAN REJECT (Kill Switch активен)"
        else
            fail "FORWARD: $ACTUAL_LAN → $ACTUAL_WAN REJECT — ОТСУТСТВУЕТ (Kill Switch не блокирует LAN→WAN)"
        fi
    fi
fi

if [ -f /etc/iptables/rules.v4 ]; then
    if grep -q "FORWARD.*REJECT.*icmp-net-unreachable" /etc/iptables/rules.v4 2>/dev/null; then
        pass "/etc/iptables/rules.v4 содержит Kill Switch REJECT правило"
    else
        warn "/etc/iptables/rules.v4 НЕ содержит Kill Switch REJECT — после reboot правила пропадут"
    fi

    if grep -q "POSTROUTING.*tun0.*MASQUERADE" /etc/iptables/rules.v4 2>/dev/null; then
        pass "/etc/iptables/rules.v4 содержит NAT MASQUERADE"
    else
        warn "/etc/iptables/rules.v4 НЕ содержит NAT MASQUERADE"
    fi
else
    fail "/etc/iptables/rules.v4 отсутствует (правила не сохранены для reboot)"
fi

section "6. iptables — INPUT chain"

iptables -C INPUT -i lo -j ACCEPT 2>/dev/null && pass "INPUT lo ACCEPT" || fail "INPUT lo ACCEPT — отсутствует"

iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null && \
    pass "INPUT ESTABLISHED,RELATED ACCEPT" || \
    fail "INPUT ESTABLISHED,RELATED ACCEPT — отсутствует"

iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null && \
    pass "INPUT TCP 80 (HTTP) ACCEPT" || \
    fail "INPUT TCP 80 (HTTP) ACCEPT — отсутствует (панель недоступна)"

iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null && \
    pass "INPUT TCP 22 (SSH) ACCEPT" || \
    fail "INPUT TCP 22 (SSH) ACCEPT — отсутствует"

if iptables -L INPUT -n 2>/dev/null | grep "recent" | grep "name: HTTP" | grep -q "hit_count: 60"; then
    pass "HTTP rate limit (60/мин) настроен"
else
    warn "HTTP rate limit не настроен (защита от flood отсутствует)"
fi

if iptables -L INPUT -n 2>/dev/null | grep "recent" | grep "name: SSH" | grep -q "hit_count: 10"; then
    pass "SSH rate limit (10/мин) настроен"
else
    warn "SSH rate limit не настроен (защита от brute-force отсутствует)"
fi

if [ -n "$ACTUAL_LAN" ]; then
    if iptables -C INPUT -i "$ACTUAL_LAN" -p tcp --dport 22 -j ACCEPT 2>/dev/null && \
       iptables -C INPUT -i "$ACTUAL_LAN" -p tcp --dport 80 -j ACCEPT 2>/dev/null; then
        pass "LAN whitelist для SSH/HTTP (перед rate-limit, любой объём connections разрешён)"
    else
        warn "LAN whitelist для SSH/HTTP отсутствует (LAN-клиенты могут попасть в rate-limit)"
    fi
fi

if [ -n "$ACTUAL_LAN" ]; then
    iptables -C INPUT -i "$ACTUAL_LAN" -p udp --dport 53 -j ACCEPT 2>/dev/null && \
        pass "INPUT $ACTUAL_LAN UDP 53 (DNS)" || \
        warn "INPUT $ACTUAL_LAN UDP 53 (DNS) — отсутствует"

    iptables -C INPUT -i "$ACTUAL_LAN" -p udp --dport 67 -j ACCEPT 2>/dev/null && \
        pass "INPUT $ACTUAL_LAN UDP 67 (DHCP)" || \
        warn "INPUT $ACTUAL_LAN UDP 67 (DHCP) — отсутствует"
fi

section "7. Systemd сервисы VPN Panel"

for svc in apache2 dnsmasq ssh vpn-healthcheck shellinabox; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        pass "$svc: активен"
    elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        fail "$svc: enabled, но НЕ активен"
    else
        if [ "$svc" = "shellinabox" ]; then
            warn "$svc: не активен (опциональный — только если нужен веб-терминал)"
        else
            fail "$svc: не активен и не enabled"
        fi
    fi
done

if systemctl list-unit-files 2>/dev/null | grep -q "wg-quick@tun0"; then
    if systemctl is-active --quiet wg-quick@tun0 2>/dev/null; then
        info "wg-quick@tun0: активен (WireGuard VPN)"
    fi
fi
if systemctl list-unit-files 2>/dev/null | grep -q "openvpn@tun0"; then
    if systemctl is-active --quiet openvpn@tun0 2>/dev/null; then
        info "openvpn@tun0: активен (OpenVPN)"
    fi
fi

if [ -f /etc/systemd/system/vpn-healthcheck.service ]; then
    if grep -q "Type=simple" /etc/systemd/system/vpn-healthcheck.service; then
        pass "vpn-healthcheck.service: Type=simple (v5 daemon mode)"
    else
        fail "vpn-healthcheck.service: НЕ Type=simple (старый v3/v4 oneshot формат)"
    fi

    if grep -q "ExecStart=/var/www/html/vpn-healthcheck.sh" /etc/systemd/system/vpn-healthcheck.service; then
        pass "vpn-healthcheck: ExecStart ссылается на /var/www/html/vpn-healthcheck.sh"
    elif grep -q "ExecStart=/usr/local/bin/vpn-healthcheck.sh" /etc/systemd/system/vpn-healthcheck.service; then
        warn "vpn-healthcheck: старая схема /usr/local/bin/ — должна была быть миграция к /var/www/html/"
    fi
fi

section "8. HC daemon — анализ лога"

VPN_LOG="/var/log/vpn-panel/vpn.log"
if [ ! -f "$VPN_LOG" ]; then
    fail "$VPN_LOG отсутствует"
else
    log_size=$(stat -c%s "$VPN_LOG" 2>/dev/null)
    info "Размер vpn.log: $((log_size / 1024)) KB"

    ten_min_ago=$(date -d "10 minutes ago" '+%Y-%m-%d %H:%M' 2>/dev/null)
    if [ -n "$ten_min_ago" ]; then
        recent_restores=$(awk -v cutoff="$ten_min_ago" '
            {
                ts = substr($0, 2, 16)
                if (ts >= cutoff && /Восстановление iptables Kill Switch/) count++
            }
            END { print count + 0 }
        ' "$VPN_LOG" 2>/dev/null)

        if [ "$recent_restores" -eq 0 ]; then
            pass "За последние 10 мин: ни одного 'Восстановление iptables' (loop'а нет)"
        elif [ "$recent_restores" -le 2 ]; then
            warn "За последние 10 мин: $recent_restores раз 'Восстановление iptables' (возможно одиночное восстановление)"
        else
            fail "За последние 10 мин: $recent_restores раз 'Восстановление iptables' — LOOP АКТИВЕН"
        fi
    fi

    last_status=$(tail -50 "$VPN_LOG" 2>/dev/null | grep -E "VPN стабилен|Нет связи|Восстановление" | tail -1)
    [ -n "$last_status" ] && info "Последняя запись: $last_status"

    if [ -n "$ten_min_ago" ]; then
        recent_crits=$(awk -v cutoff="$ten_min_ago" '
            {
                ts = substr($0, 2, 16)
                if (ts >= cutoff && /\[CRIT\]/) count++
            }
            END { print count + 0 }
        ' "$VPN_LOG" 2>/dev/null)

        if [ "$recent_crits" -eq 0 ]; then
            pass "За последние 10 мин: ни одного [CRIT] сообщения"
        else
            fail "За последние 10 мин: $recent_crits [CRIT] сообщений в vpn.log"
        fi
    fi
fi

EVENTS_LOG="/var/log/vpn-panel/events.log"
if [ -f "$EVENTS_LOG" ]; then
    events_count=$(wc -l < "$EVENTS_LOG" 2>/dev/null || echo 0)
    info "events.log: $events_count событий"

    if [ "$events_count" -gt 0 ]; then
        last_events=$(tail -3 "$EVENTS_LOG" 2>/dev/null | wc -l)
        [ "$last_events" -gt 0 ] && info "Последние события (3 из $events_count):"
        tail -3 "$EVENTS_LOG" 2>/dev/null | while IFS= read -r line; do
            [ "$QUIET" -eq 0 ] && echo -e "    ${GRAY}$line${NC}"
        done
    fi
else
    info "events.log отсутствует (HC daemon ещё не записал событий — норма для свежей установки)"
fi

section "9. Веб-панель"

WEB_DIR="/var/www/html"
if [ ! -d "$WEB_DIR" ]; then
    fail "$WEB_DIR отсутствует"
else
    for f in cabinet.php index.php login.php update.sh vpn-healthcheck.sh; do
        if [ -f "$WEB_DIR/$f" ]; then
            pass "$WEB_DIR/$f присутствует"
        else
            fail "$WEB_DIR/$f ОТСУТСТВУЕТ"
        fi
    done

    for d in api pages includes assets; do
        if [ -d "$WEB_DIR/$d" ]; then
            pass "$WEB_DIR/$d/ присутствует"
        else
            fail "$WEB_DIR/$d/ ОТСУТСТВУЕТ (v5 структура нарушена)"
        fi
    done

    for old in about.php openvpn.php ping.php settings.php status_check.php wireguard.php; do
        if [ -f "$WEB_DIR/$old" ]; then
            warn "Остаток v4: $WEB_DIR/$old присутствует (должен был быть удалён)"
        fi
    done
fi

if command -v curl >/dev/null 2>&1; then
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://$LAN_IP/" 2>/dev/null)
    if [ "$http_code" = "200" ] || [ "$http_code" = "302" ]; then
        pass "Веб-панель http://$LAN_IP/ отвечает HTTP $http_code"
    else
        fail "Веб-панель http://$LAN_IP/ отвечает HTTP $http_code (ожидается 200/302)"
    fi
fi

section "10. Файлы и права"

for f in /var/www/version /var/www/settings /var/www/vpn-state; do
    if [ -f "$f" ]; then
        perms=$(stat -c '%a' "$f" 2>/dev/null)
        if [ "$f" = "/var/www/version" ]; then
            pass "$f: $perms"
        elif [ "$perms" = "666" ]; then
            pass "$f: $perms (PHP имеет write)"
        else
            warn "$f: $perms (ожидается 666 для www-data write)"
        fi
    else
        if [ "$f" = "/var/www/vpn-state" ]; then
            info "$f отсутствует (создаётся при первой активации VPN — норма для свежей установки)"
        else
            warn "$f отсутствует"
        fi
    fi
done

if [ -d /var/www/vpn-configs ]; then
    perms=$(stat -c '%a' /var/www/vpn-configs 2>/dev/null)
    owner=$(stat -c '%U:%G' /var/www/vpn-configs 2>/dev/null)
    if [ "$perms" = "770" ] && [ "$owner" = "root:www-data" ]; then
        pass "/var/www/vpn-configs: $perms $owner"
    else
        warn "/var/www/vpn-configs: $perms $owner (ожидается 770 root:www-data)"
    fi

    if [ -f /var/www/vpn-configs/configs.json ]; then
        configs_count=$(php -r '$c=@json_decode(file_get_contents($argv[1]),true); echo is_array($c)?count($c):0;' -- /var/www/vpn-configs/configs.json 2>/dev/null)
        if [ "${configs_count:-0}" -gt 0 ]; then
            info "VPN конфигов в configs.json: $configs_count"
        else
            info "VPN конфигов в configs.json: 0 (загрузите конфиг через VPN Manager)"
        fi
    else
        info "configs.json отсутствует (создаётся при загрузке первого конфига через VPN Manager)"
    fi
else
    fail "/var/www/vpn-configs/ ОТСУТСТВУЕТ (должна создаваться Installer'ом — проверьте установку)"
fi

if [ -f /var/www/html/vpn-healthcheck.sh ]; then
    perms=$(stat -c '%a' /var/www/html/vpn-healthcheck.sh 2>/dev/null)
    owner=$(stat -c '%U:%G' /var/www/html/vpn-healthcheck.sh 2>/dev/null)
    if [ "$perms" = "755" ] && [ "$owner" = "root:root" ]; then
        pass "vpn-healthcheck.sh: $perms $owner (security ok)"
    else
        warn "vpn-healthcheck.sh: $perms $owner (ожидается 755 root:root)"
    fi
fi

if [ -f /etc/sudoers.d/vpn-panel-www-data ]; then
    perms=$(stat -c '%a' /etc/sudoers.d/vpn-panel-www-data 2>/dev/null)
    if [ "$perms" = "440" ]; then
        pass "/etc/sudoers.d/vpn-panel-www-data: 440"
    else
        warn "/etc/sudoers.d/vpn-panel-www-data: $perms (ожидается 440)"
    fi

    if grep -q "systemctl reboot" /etc/sudoers.d/vpn-panel-www-data 2>/dev/null; then
        pass "Sudoers: reboot/poweroff правила присутствуют"
    else
        warn "Sudoers: reboot/poweroff правила ОТСУТСТВУЮТ (кнопки в Настройках не работают)"
    fi

    if visudo -c -f /etc/sudoers.d/vpn-panel-www-data >/dev/null 2>&1; then
        pass "Sudoers: синтаксис валиден (visudo -c)"
    else
        fail "Sudoers: ОШИБКА СИНТАКСИСА! Это может заблокировать весь sudo"
    fi
else
    fail "/etc/sudoers.d/vpn-panel-www-data ОТСУТСТВУЕТ"
fi

PANEL_NETPLAN="/etc/netplan/99-vpn-panel.yaml"
[ -f "$PANEL_NETPLAN" ] || PANEL_NETPLAN="/etc/netplan/01-network-manager-all.yaml"

if [ -f "$PANEL_NETPLAN" ]; then
    perms=$(stat -c '%a' "$PANEL_NETPLAN" 2>/dev/null)
    owner=$(stat -c '%U:%G' "$PANEL_NETPLAN" 2>/dev/null)
    if [ "$perms" = "660" ] && [ "$owner" = "root:www-data" ]; then
        pass "$PANEL_NETPLAN: $perms $owner"
    else
        warn "$PANEL_NETPLAN: $perms $owner (ожидается 660 root:www-data — без этого netsettings.php не пишет)"
    fi
else
    fail "netplan-файл панели не найден (/etc/netplan/99-vpn-panel.yaml)"
fi

foreign=0
for np in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    [ -f "$np" ] || continue
    [ "$np" = "$PANEL_NETPLAN" ] && continue
    foreign=$((foreign + 1))
    np_wan="${conf_wan:-$ACTUAL_WAN}"
    np_lan="${conf_lan:-$ACTUAL_LAN}"
    if [ -z "$np_wan" ] && [ -z "$np_lan" ]; then
        info "$np: сторонний конфиг (интерфейсы панели неизвестны — пропускаю проверку конфликта)"
        continue
    fi
    if grep -qE "^[[:space:]]*(${np_wan:-__none__}|${np_lan:-__none__}):" "$np" 2>/dev/null; then
        fail "$np описывает интерфейс панели ($np_wan/$np_lan) — конфликт приоритетов netplan"
    else
        info "$np: сторонний конфиг, интерфейсы панели не затрагивает"
    fi
done
[ "$foreign" -eq 0 ] && info "Сторонних netplan-файлов нет"

for np in /etc/netplan/*.disabled-by-vpn-panel; do
    [ -e "$np" ] || continue
    info "$(basename "$np"): отключён установщиком (восстановится при полном удалении)"
done

section "11. PHP расширения"

if command -v php >/dev/null 2>&1; then
    php_version=$(php -v 2>/dev/null | head -1 | awk '{print $2}')
    info "PHP: $php_version"

    for ext in yaml mbstring; do
        if php -m 2>/dev/null | grep -qi "^${ext}$"; then
            pass "php-$ext установлен"
        else
            fail "php-$ext НЕ установлен (необходимо для v5)"
        fi
    done
else
    fail "PHP не установлен"
fi

section "12. Apache модули"

if command -v apache2ctl >/dev/null 2>&1; then
    enabled_modules=$(apache2ctl -M 2>/dev/null)
    for mod in headers expires rewrite deflate proxy proxy_http; do
        if echo "$enabled_modules" | grep -qE "^\s*${mod}_module"; then
            pass "Apache модуль: $mod"
        else
            warn "Apache модуль: $mod не enabled"
        fi
    done

    if grep -q "AllowOverride All" /etc/apache2/apache2.conf 2>/dev/null; then
        pass "Apache: AllowOverride All (.htaccess работает)"
    else
        warn "Apache: AllowOverride None — .htaccess не работает"
    fi
fi

section "13. Cron автообновление"

if [ -x /usr/local/sbin/vpn-panel-deploy ]; then
    pass "/usr/local/sbin/vpn-panel-deploy на месте"
else
    fail "/usr/local/sbin/vpn-panel-deploy ОТСУТСТВУЕТ (обновления не работают)"
fi

for legacy in /usr/local/bin/vpn-panel-update.sh /usr/local/bin/run-update.sh; do
    [ -f "$legacy" ] && warn "$legacy присутствует (легаси — должен был быть удалён)"
done

if [ -d "$WEB_DIR_DIAG/.git" ]; then
    warn "$WEB_DIR_DIAG/.git присутствует — остаток старой схемы, код теперь разворачивается из /opt/vpn-panel/src"
fi

if crontab -l 2>/dev/null | grep -qF "vpn-panel-deploy"; then
    cron_line=$(crontab -l 2>/dev/null | grep "vpn-panel-deploy")
    pass "Crontab: настроен на vpn-panel-deploy"
    info "Cron: $cron_line"
elif crontab -l 2>/dev/null | grep -qE "(vpn-panel-update|run-update)"; then
    fail "Crontab: старый лаунчер вместо vpn-panel-deploy — запустите update.sh"
else
    fail "Crontab: автообновление не настроено"
fi

deploy_channel=$(grep "^CHANNEL=" /etc/vpn-panel.conf 2>/dev/null | cut -d= -f2)
deploy_repo=$(grep "^REPO_URL=" /etc/vpn-panel.conf 2>/dev/null | cut -d= -f2-)
if [ -n "$deploy_repo" ]; then
    info "Канал: ${deploy_channel:-stable}, репозиторий: $deploy_repo"
else
    warn "REPO_URL не задан в /etc/vpn-panel.conf — деплой не будет знать откуда тянуть код"
fi

if [ -d /opt/vpn-panel/src/.git ]; then
    pass "Исходники: /opt/vpn-panel/src"
    snap_count=$(ls -1d /opt/vpn-panel/releases/*/ 2>/dev/null | wc -l)
    info "Снимков для отката: $snap_count"
else
    info "/opt/vpn-panel/src ещё не создан — появится при первом запуске vpn-panel-deploy"
fi

section "14. Сторонние systemd сервисы"

suspicious=$(systemctl list-unit-files --state=enabled --no-pager 2>/dev/null | \
    grep -iE "metric|monitor|psutil|home" | \
    grep -vE "^(vpn-healthcheck|lvm2-monitor|mdmonitor|smartmontools|packagekit)" | \
    awk '{print $1}')

if [ -z "$suspicious" ]; then
    pass "Сторонние monitoring/metrics сервисы не найдены"
else
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            warn "Сторонний сервис: $svc (АКТИВЕН — не из нашего кода)"
        else
            warn "Сторонний сервис: $svc (enabled, не активен)"
        fi
    done <<< "$suspicious"
fi

harmless_failed_pattern="NetworkManager-wait-online|fwupd-refresh|ifupdown-pre|systemd-modules-load"
failed_all=$(systemctl --failed --no-pager --no-legend 2>/dev/null)

if [ -z "$failed_all" ]; then
    failed_count_all=0
    failed_count_real=0
else
    failed_count_all=$(echo "$failed_all" | grep -c .)
    failed_count_all=$(echo "${failed_count_all:-0}" | head -1 | tr -d ' \n')
    failed_real=$(echo "$failed_all" | grep -vE "$harmless_failed_pattern")
    if [ -z "$failed_real" ]; then
        failed_count_real=0
    else
        failed_count_real=$(echo "$failed_real" | grep -c .)
        failed_count_real=$(echo "${failed_count_real:-0}" | head -1 | tr -d ' \n')
    fi
fi

if [ "$failed_count_all" -eq 0 ] 2>/dev/null; then
    pass "Failed services: 0"
elif [ "$failed_count_real" -eq 0 ] 2>/dev/null; then
    pass "Failed services: $failed_count_all (все known-harmless: NetworkManager-wait-online/fwupd-refresh и т.п.)"
else
    harmless_count=$((failed_count_all - failed_count_real))
    warn "Failed services: $failed_count_real (+ $harmless_count known-harmless)"
    echo "$failed_real" | head -5 | while IFS= read -r line; do
        [ -n "$line" ] && info "  $line"
    done
fi

section "15. VPN подключение"

configs_loaded=0
if [ -f /var/www/vpn-configs/configs.json ]; then
    configs_loaded=$(php -r '$c=@json_decode(file_get_contents($argv[1]),true); echo is_array($c)?count($c):0;' -- /var/www/vpn-configs/configs.json 2>/dev/null)
    configs_loaded=${configs_loaded:-0}
fi

if [ "$configs_loaded" = "0" ]; then
    info "VPN конфиги не загружены — пропускаем VPN-проверки"
    info "Для активации: откройте веб-панель → VPN Manager → загрузите .conf файл"
else
    info "Найдено конфигов в панели: $configs_loaded"

    if ip link show tun0 >/dev/null 2>&1 && ip -4 addr show tun0 2>/dev/null | grep -q "inet "; then
        if ping -c 1 -W 3 -I tun0 8.8.8.8 >/dev/null 2>&1; then
            pass "Ping 8.8.8.8 через tun0: успех"
        else
            warn "Ping 8.8.8.8 через tun0: не прошёл"
        fi
    else
        info "tun0 не активен — конфиг загружен но не активирован (это нормально, активируйте через панель)"
    fi

    if [ -f /etc/wireguard/tun0.conf ]; then
        pass "WireGuard конфиг /etc/wireguard/tun0.conf присутствует"
    elif [ -f /etc/openvpn/tun0.conf ]; then
        pass "OpenVPN конфиг /etc/openvpn/tun0.conf присутствует"
    else
        info "Активный конфиг (/etc/wireguard/tun0.conf или /etc/openvpn/tun0.conf) отсутствует — нажмите 'Активировать' в VPN Manager"
    fi
fi

section "16. /var/www/settings"

if [ -f /var/www/settings ]; then
    for key in vpnchecker autoupvpn failover failover_first; do
        if grep -q "^${key}=" /var/www/settings; then
            value=$(grep "^${key}=" /var/www/settings | cut -d= -f2)
            pass "settings: $key=$value"
        else
            warn "settings: ключ '$key' отсутствует"
        fi
    done

    if grep -q "^try_primary_first=" /var/www/settings; then
        warn "settings: легаси ключ 'try_primary_first' присутствует (должен был быть удалён в v5)"
    fi
else
    fail "/var/www/settings ОТСУТСТВУЕТ"
fi

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                  Р Е З У Л Ь Т А Т                ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}[✓] Пройдено:${NC}    $PASSED"
echo -e "  ${YELLOW}[!] Предупреждений:${NC} $WARNED"
echo -e "  ${RED}[✗] Провалено:${NC}   $FAILED"
echo ""

if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}━━━ КРИТИЧНЫЕ ПРОБЛЕМЫ ━━━${NC}"
    for f in "${FAILURES[@]}"; do
        echo -e "  ${RED}✗${NC} $f"
    done
    echo ""
fi

if [ "$WARNED" -gt 0 ]; then
    echo -e "${YELLOW}━━━ ПРЕДУПРЕЖДЕНИЯ ━━━${NC}"
    for w in "${WARNINGS[@]}"; do
        echo -e "  ${YELLOW}!${NC} $w"
    done
    echo ""
fi

if [ "$FAILED" -eq 0 ] && [ "$WARNED" -eq 0 ]; then
    echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          ✓  В С Ё   В   П О Р Я Д К Е            ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
    exit 0
elif [ "$FAILED" -eq 0 ]; then
    echo -e "${YELLOW}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║   ⚠  Есть предупреждения, но система работает    ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════╝${NC}"
    exit 1
else
    echo -e "${RED}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║   ✗  Есть критичные проблемы — нужно вмешательство ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════╝${NC}"
    exit 2
fi
