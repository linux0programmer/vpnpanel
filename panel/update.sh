#!/bin/bash

SCRIPT_VERSION=6
MIGRATION_FAILED=0
VERSION_FILE="/var/www/version"
SETTINGS_FILE="/var/www/settings"
WEB_DIR="/var/www/html"
VPN_CONFIGS_DIR="/var/www/vpn-configs"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG_FILE="/var/log/vpn-panel/update.log"
mkdir -p /var/log/vpn-panel 2>/dev/null
touch "$LOG_FILE" 2>/dev/null
chmod 644 "$LOG_FILE" 2>/dev/null

UPDATE_PID=$BASHPID
{
    echo ""
    echo "============================================"
    echo "VPN Panel Update v$SCRIPT_VERSION"
    echo "Запущено: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "PID: $UPDATE_PID"
    if [ "${SKIP_GIT:-0}" = "1" ]; then
        echo "Викликано: з Installer.sh або cron-launcher (SKIP_GIT=1)"
    else
        echo "Викликано: вручну"
    fi
    echo "============================================"
} >> "$LOG_FILE"

if [ -e /dev/tty ] && [ -w /dev/tty ]; then
    exec 7>/dev/tty
    exec 8>/dev/tty
    exec 3> >(stdbuf -oL tee >(stdbuf -oL sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE") >&7)
    exec 4> >(stdbuf -oL tee >(stdbuf -oL sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE") >&8)
else
    exec 3> >(stdbuf -oL sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE")
    exec 4> >(stdbuf -oL sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE")
fi

exec 1>>"$LOG_FILE" 2>&1

trap 'exec 3>&- 4>&- 2>/dev/null; sleep 0.2' EXIT

log_info() { echo -e "${GREEN}[✓]${NC} $1" >&3; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1" >&3; }
log_step() { echo -e "${CYAN}[*]${NC} $1" >&3; }

VP_CONF_FILE="/etc/vpn-panel.conf"
LAN_IP="10.10.1.1"
LAN_NET="10.10.1.0/20"
LAN_PREFIX="20"
PANEL_NETPLAN="/etc/netplan/99-vpn-panel.yaml"

load_lan_params() {
    [ -f "$VP_CONF_FILE" ] || return 0
    local v
    v=$(grep "^LAN_IP=" "$VP_CONF_FILE" 2>/dev/null | cut -d= -f2);     [ -n "$v" ] && LAN_IP="$v"
    v=$(grep "^LAN_NET=" "$VP_CONF_FILE" 2>/dev/null | cut -d= -f2);    [ -n "$v" ] && LAN_NET="$v"
    v=$(grep "^LAN_PREFIX=" "$VP_CONF_FILE" 2>/dev/null | cut -d= -f2); [ -n "$v" ] && LAN_PREFIX="$v"
    return 0
}
load_lan_params

detect_interfaces() {
    DETECTED_LAN=$(ip -4 addr show 2>/dev/null | grep -F "$LAN_IP/" | awk '{print $NF}')
    DETECTED_WAN=$(ip route show default 2>/dev/null | grep -v "dev tun\|dev wg" | grep -oP 'dev \K[^ ]+' | head -1)
}

{
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       VPN Server Update v$SCRIPT_VERSION           ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""
} >&3

log_info "Код разворачивает vpn-panel-deploy — этот скрипт только применяет миграции"

CURRENT_VERSION=0
if [ -f "$VERSION_FILE" ] && [ -s "$VERSION_FILE" ]; then
    CURRENT_VERSION=$(cat "$VERSION_FILE")
fi
case "$CURRENT_VERSION" in
    ''|*[!0-9]*)
        log_warn "В $VERSION_FILE мусор ('$CURRENT_VERSION') — считаю версию нулевой"
        CURRENT_VERSION=0 ;;
esac

echo "" >&3
log_step "Текущая версия: $CURRENT_VERSION"
log_step "Целевая версия: $SCRIPT_VERSION"
echo "" >&3

if [ "$CURRENT_VERSION" -ge "$SCRIPT_VERSION" ]; then
    log_info "Система уже обновлена до v$CURRENT_VERSION — выполняю проверки конфигурации"
else
    log_warn "Применяю обновление..."
fi
echo "" >&3

if [ "$CURRENT_VERSION" -lt 1 ]; then
    log_step "Миграция v1: Базовая настройка..."

    if ! php -m 2>/dev/null | grep -q yaml; then
        apt-get install -y -qq php-yaml 2>/dev/null || true
    fi

    for np in "$PANEL_NETPLAN" /etc/netplan/01-network-manager-all.yaml; do
        [ -f "$np" ] || continue
        chown root:www-data "$np" 2>/dev/null || true
        chmod 660 "$np" 2>/dev/null || true
    done

    SUDOERS_FILE="/etc/sudoers.d/vpn-panel-www-data"
    if [ ! -f "$SUDOERS_FILE" ]; then
        cat > "$SUDOERS_FILE" << 'EOF'
www-data ALL=(ALL) NOPASSWD: /bin/systemctl stop openvpn*, /bin/systemctl start openvpn*, /bin/systemctl restart openvpn*
www-data ALL=(ALL) NOPASSWD: /bin/systemctl stop wg-quick*, /bin/systemctl start wg-quick*, /bin/systemctl restart wg-quick*
www-data ALL=(ALL) NOPASSWD: /bin/systemctl enable wg-quick*, /bin/systemctl disable wg-quick*
www-data ALL=(ALL) NOPASSWD: /usr/sbin/netplan apply
EOF
        chmod 440 "$SUDOERS_FILE"
    fi

    if ! iptables -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
        iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi

    log_info "Миграция v1 завершена"
fi

if [ "$CURRENT_VERSION" -lt 2 ]; then
    log_step "Миграция v2: Система обновлений..."

    mkdir -p /var/log/vpn-panel

    if [ -x /usr/local/sbin/vpn-panel-deploy ]; then
        (crontab -l 2>/dev/null | grep -vE "(run-update|vpn-panel-update|update\.sh)"; \
         echo "0 * * * * /usr/local/sbin/vpn-panel-deploy auto >> /var/log/vpn-panel/update.log 2>&1") | crontab -
    fi

    log_info "Миграция v2 завершена"
fi

if [ "$CURRENT_VERSION" -lt 3 ]; then
    log_step "Миграция v3: VPN Health Check..."

    if [ ! -f "$SETTINGS_FILE" ]; then
        echo -e "vpnchecker=true\nautoupvpn=true" > "$SETTINGS_FILE"
    fi
    chmod 666 "$SETTINGS_FILE"

    HC_V3_SKIP=false
    if [ -f /etc/systemd/system/vpn-healthcheck.service ]; then
        grep -q "Type=simple" /etc/systemd/system/vpn-healthcheck.service 2>/dev/null && HC_V3_SKIP=true
    fi

    if [ "$HC_V3_SKIP" = true ]; then
        log_info "Healthcheck daemon уже установлен, пропускаем"
    else
    cat > /usr/local/bin/vpn-healthcheck.sh << 'SCRIPT'
#!/bin/bash
INTERFACE="tun0"
SETTINGS="/var/www/settings"

[ -f "$SETTINGS" ] && ! grep -q "^vpnchecker=true$" "$SETTINGS" && exit 0

if ! ip link show "$INTERFACE" > /dev/null 2>&1; then
    if [ -f "$SETTINGS" ] && grep -q "^autoupvpn=true$" "$SETTINGS"; then
        [ -f "/etc/wireguard/${INTERFACE}.conf" ] && systemctl restart "wg-quick@${INTERFACE}"
        [ -f "/etc/openvpn/${INTERFACE}.conf" ] && systemctl restart "openvpn@${INTERFACE}"
    fi
    exit 1
fi
exit 0
SCRIPT
    chmod +x /usr/local/bin/vpn-healthcheck.sh

    cat > /etc/systemd/system/vpn-healthcheck.service << 'EOF'
[Unit]
Description=VPN Health Check
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn-healthcheck.sh
EOF

    cat > /etc/systemd/system/vpn-healthcheck.timer << 'EOF'
[Unit]
Description=VPN Health Check Timer
[Timer]
OnBootSec=1min
OnUnitActiveSec=30s
[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now vpn-healthcheck.timer 2>/dev/null || true
    fi

    log_info "Миграция v3 завершена"
fi

if [ "$CURRENT_VERSION" -lt 4 ]; then
    log_step "Миграция v4: Минорные фиксы"
    log_info "Миграция v4 завершена"
fi

if [ "$CURRENT_VERSION" -lt 5 ]; then
    log_step "Миграция v5: VPN Manager + Kill Switch + улучшенный мониторинг..."

    sed -i '/www-data ALL=(ALL) NOPASSWD: ALL/d' /etc/sudoers 2>/dev/null || true
    sed -i '/www-data.*NOPASSWD.*systemctl.*openvpn/d' /etc/sudoers 2>/dev/null || true
    sed -i '/www-data.*NOPASSWD.*systemctl.*wg-quick/d' /etc/sudoers 2>/dev/null || true
    sed -i '/www-data.*NOPASSWD.*\/usr\/bin\/id/d' /etc/sudoers 2>/dev/null || true
    sed -i '/www-data.*NOPASSWD.*netplan/d' /etc/sudoers 2>/dev/null || true

    cat > /etc/sudoers.d/vpn-panel-www-data << 'EOF'
# VPN Panel Web Panel Permissions v5 (updated)
# OpenVPN
www-data ALL=(ALL) NOPASSWD: /bin/systemctl stop openvpn@tun0
www-data ALL=(ALL) NOPASSWD: /bin/systemctl start openvpn@tun0
www-data ALL=(ALL) NOPASSWD: /bin/systemctl restart openvpn@tun0
www-data ALL=(ALL) NOPASSWD: /bin/systemctl enable openvpn@tun0
www-data ALL=(ALL) NOPASSWD: /bin/systemctl disable openvpn@tun0
# WireGuard
www-data ALL=(ALL) NOPASSWD: /bin/systemctl stop wg-quick@tun0
www-data ALL=(ALL) NOPASSWD: /bin/systemctl start wg-quick@tun0
www-data ALL=(ALL) NOPASSWD: /bin/systemctl restart wg-quick@tun0
www-data ALL=(ALL) NOPASSWD: /bin/systemctl enable wg-quick@tun0
www-data ALL=(ALL) NOPASSWD: /bin/systemctl disable wg-quick@tun0
# Сеть
www-data ALL=(ALL) NOPASSWD: /usr/local/sbin/vpn-panel-routing status
www-data ALL=(ALL) NOPASSWD: /usr/local/sbin/vpn-panel-routing free
www-data ALL=(ALL) NOPASSWD: /usr/local/sbin/vpn-panel-routing apply
www-data ALL=(ALL) NOPASSWD: /usr/local/sbin/vpn-panel-routing set-active *
www-data ALL=(ALL) NOPASSWD: /usr/local/sbin/vpn-panel-routing add-wan *
www-data ALL=(ALL) NOPASSWD: /usr/local/sbin/vpn-panel-routing remove-wan *
www-data ALL=(ALL) NOPASSWD: /usr/sbin/netplan apply
# Проверка пароля root
EOF
    chmod 440 /etc/sudoers.d/vpn-panel-www-data
    visudo -c -f /etc/sudoers.d/vpn-panel-www-data 2>/dev/null || log_warn "Ошибка в sudoers!"
    log_info "Sudoers обновлён (/bin/bash удалён)"

    mkdir -p "$VPN_CONFIGS_DIR"
    chown root:www-data "$VPN_CONFIGS_DIR"
    chmod 770 "$VPN_CONFIGS_DIR"
    log_info "Директория VPN конфигов создана (770 root:www-data)"

    if [ ! -f /var/www/vpn-state ]; then
        touch /var/www/vpn-state
        chmod 666 /var/www/vpn-state
        log_info "State файл создан"
    fi

    CONFIGS_JSON="$VPN_CONFIGS_DIR/configs.json"
    if [ ! -f "$CONFIGS_JSON" ] || [ ! -s "$CONFIGS_JSON" ] || [ "$(cat "$CONFIGS_JSON" 2>/dev/null)" = "{}" ]; then
        for tun_conf in /etc/wireguard/tun0.conf /etc/openvpn/tun0.conf; do
            [ -f "$tun_conf" ] || continue
            CONF_ID="vpn_$(md5sum "$tun_conf" | cut -c1-16)"
            CONF_EXT="conf"
            cp "$tun_conf" "$VPN_CONFIGS_DIR/${CONF_ID}.${CONF_EXT}"
            chown www-data:www-data "$VPN_CONFIGS_DIR/${CONF_ID}.${CONF_EXT}"

            CONF_TYPE="openvpn"
            CONF_SERVER="unknown"
            if grep -qi "\[Interface\]" "$tun_conf" && grep -qi "PrivateKey" "$tun_conf"; then
                CONF_TYPE="wireguard"
                CONF_SERVER=$(grep -oP 'Endpoint\s*=\s*\K[^:]+' "$tun_conf" 2>/dev/null | head -1)
            else
                CONF_SERVER=$(grep -oP '^\s*remote\s+\K\S+' "$tun_conf" 2>/dev/null | head -1)
            fi
            [ -z "$CONF_SERVER" ] && CONF_SERVER="unknown"

            cat > "$CONFIGS_JSON" << MIGEOF
{
    "${CONF_ID}": {
        "id": "${CONF_ID}",
        "name": "${CONF_SERVER}",
        "filename": "${CONF_ID}.${CONF_EXT}",
        "original_filename": "tun0.conf",
        "type": "${CONF_TYPE}",
        "server": "${CONF_SERVER}",
        "port": "",
        "protocol": "",
        "priority": 1,
        "role": "primary",
        "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
        "last_used": "$(date '+%Y-%m-%d %H:%M:%S')"
    }
}
MIGEOF
            chown www-data:www-data "$CONFIGS_JSON"

            cat > /var/www/vpn-state << STEOF
STATE=running
ACTIVE_ID=${CONF_ID}
PRIMARY_ID=${CONF_ID}
ACTIVATED_BY=migration
STEOF
            chmod 666 /var/www/vpn-state

            log_info "Мигрирован VPN конфиг: $CONF_SERVER ($CONF_TYPE)"
            break
        done
    fi

    if [ ! -f "$SETTINGS_FILE" ]; then
        echo -e "vpnchecker=true\nautoupvpn=true\nfailover=true\nfailover_first=false" > "$SETTINGS_FILE"
        chmod 666 "$SETTINGS_FILE"
        log_info "Settings створено з дефолтними значеннями"
    else
        grep -q "^vpnchecker=" "$SETTINGS_FILE" || echo "vpnchecker=true" >> "$SETTINGS_FILE"
        grep -q "^autoupvpn=" "$SETTINGS_FILE" || echo "autoupvpn=true" >> "$SETTINGS_FILE"
        grep -q "^failover=" "$SETTINGS_FILE" || echo "failover=true" >> "$SETTINGS_FILE"
        grep -q "^failover_first=" "$SETTINGS_FILE" || echo "failover_first=false" >> "$SETTINGS_FILE"
        sed -i '/^try_primary_first=/d' "$SETTINGS_FILE"
    fi

    detect_interfaces
    LAN_IF="$DETECTED_LAN"
    WAN_IF="$DETECTED_WAN"

    if [ -n "$LAN_IF" ] && [ -n "$WAN_IF" ] && [ "$LAN_IF" != "$WAN_IF" ]; then
        if ! iptables -C FORWARD -i "$LAN_IF" -o "$WAN_IF" -j REJECT 2>/dev/null; then
            log_step "Настройка Kill Switch (LAN=$LAN_IF, WAN=$WAN_IF)..."

            iptables-save -t nat > /tmp/iptables-nat-backup.txt 2>/dev/null || true

            iptables -P FORWARD DROP

            iptables -F FORWARD

            iptables -A FORWARD -i "$LAN_IF" -o tun0 -j ACCEPT
            iptables -A FORWARD -i tun0 -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
            iptables -A FORWARD -i "$LAN_IF" -o "$LAN_IF" -j ACCEPT
            iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -j REJECT --reject-with icmp-net-unreachable
            iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

            iptables-restore -T nat < /tmp/iptables-nat-backup.txt 2>/dev/null || true
            rm -f /tmp/iptables-nat-backup.txt

            if ! iptables -t nat -C POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null; then
                iptables -t nat -A POSTROUTING -o tun0 -s "$LAN_NET" -j MASQUERADE
            fi

            iptables-save > /etc/iptables/rules.v4
            log_info "Kill Switch активирован"
        else
            log_info "Kill Switch уже настроен"
        fi
    else
        log_warn "Не вдалося визначити інтерфейси для Kill Switch (LAN='$LAN_IF', WAN='$WAN_IF')"
    fi

    if ! iptables -C INPUT -p tcp --dport 80 -m state --state NEW -m recent --set --name HTTP 2>/dev/null; then
        log_step "Налаштування INPUT chain (rate limit HTTP/SSH + LAN whitelist + LAN сервіси)..."

        INPUT_LAN_IF="${LAN_IF:-}"
        [ -z "$INPUT_LAN_IF" ] && INPUT_LAN_IF=$(ip -4 addr show 2>/dev/null | grep -F "$LAN_IP/" | awk '{print $NF}' | head -1)

        iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -A INPUT -i lo -j ACCEPT
        iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
            iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

        if [ -n "$INPUT_LAN_IF" ]; then
            iptables -A INPUT -i "$INPUT_LAN_IF" -p tcp --dport 22 -j ACCEPT
            iptables -A INPUT -i "$INPUT_LAN_IF" -p tcp --dport 80 -j ACCEPT
        fi

        iptables -A INPUT -p tcp --dport 80 -m state --state NEW -m recent --set --name HTTP
        iptables -A INPUT -p tcp --dport 80 -m state --state NEW -m recent --update --seconds 60 --hitcount 60 --name HTTP -j DROP
        iptables -A INPUT -p tcp --dport 80 -j ACCEPT
        iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH
        iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 10 --name SSH -j DROP
        iptables -A INPUT -p tcp --dport 22 -j ACCEPT
        if [ -n "$INPUT_LAN_IF" ]; then
            iptables -A INPUT -i "$INPUT_LAN_IF" -p udp --dport 53 -j ACCEPT
            iptables -A INPUT -i "$INPUT_LAN_IF" -p tcp --dport 53 -j ACCEPT
            iptables -A INPUT -i "$INPUT_LAN_IF" -p udp --dport 67 -j ACCEPT
            log_info "INPUT chain налаштовано (LAN whitelist + rate limit HTTP/SSH для WAN, DNS/DHCP для LAN=$INPUT_LAN_IF)"
        else
            log_warn "INPUT chain налаштовано (rate limit HTTP/SSH), але LAN інтерфейс не визначено — LAN whitelist і DNS/DHCP не додано"
        fi

        iptables-save > /etc/iptables/rules.v4
    fi

    mkdir -p /var/log/vpn-panel
    touch /var/log/vpn-panel/vpn.log
    chmod 644 /var/log/vpn-panel/vpn.log

    systemctl stop vpn-healthcheck.timer vpn-healthcheck.service 2>/dev/null || true
    systemctl disable vpn-healthcheck.timer vpn-healthcheck.service 2>/dev/null || true
    rm -f /etc/systemd/system/vpn-healthcheck.timer

    cat > /etc/systemd/system/vpn-healthcheck.service << EOF
[Unit]
Description=VPN Health Check Daemon
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$WEB_DIR/vpn-healthcheck.sh
Restart=always
RestartSec=5
StandardOutput=null
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF

    if [ -f "$WEB_DIR/vpn-healthcheck.sh" ]; then
        chown root:root "$WEB_DIR/vpn-healthcheck.sh"
        chmod 755 "$WEB_DIR/vpn-healthcheck.sh"
        log_info "HC daemon настроен ($WEB_DIR/vpn-healthcheck.sh)"
    else
        log_warn "HC скрипт не найден в $WEB_DIR — HC не установлен (проверьте деплой)"
    fi

    rm -f /usr/local/bin/vpn-healthcheck.sh

    systemctl daemon-reload
    systemctl enable --now vpn-healthcheck.service 2>/dev/null || true
    log_info "Мониторинг VPN обновлён (daemon)"

    sed -i 's/^AUTOSTART=.*/AUTOSTART="none"/' /etc/default/openvpn 2>/dev/null || true
    log_info "AUTOSTART=none выставлен"

    chown -R www-data:www-data "$WEB_DIR" 2>/dev/null || true
    chmod -R 755 "$WEB_DIR" 2>/dev/null || true
    chown root:www-data /etc/openvpn /etc/wireguard 2>/dev/null || true
    chmod 770 /etc/openvpn/ 2>/dev/null || true
    chmod 770 /etc/wireguard/ 2>/dev/null || true
    chmod g+s /etc/openvpn /etc/wireguard 2>/dev/null || true
    find /etc/wireguard /etc/openvpn -type f -exec chmod 660 {} \; 2>/dev/null || true

    a2enmod headers expires rewrite deflate 2>/dev/null || true
    if grep -q 'AllowOverride None' /etc/apache2/apache2.conf 2>/dev/null; then
        sed -i 's|AllowOverride None|AllowOverride All|g' /etc/apache2/apache2.conf
        log_info "AllowOverride All выставлен"
    fi
    sed -i 's/ServerTokens OS/ServerTokens Prod/' /etc/apache2/conf-enabled/security.conf 2>/dev/null || true
    sed -i 's/ServerSignature On/ServerSignature Off/' /etc/apache2/conf-enabled/security.conf 2>/dev/null || true
    for np in "$PANEL_NETPLAN" /etc/netplan/01-network-manager-all.yaml; do
        [ -f "$np" ] || continue
        chown root:www-data "$np" 2>/dev/null || true
        chmod 660 "$np" 2>/dev/null || true
    done
    systemctl restart apache2 2>/dev/null || true
    log_info "Apache модули включены, apache2 перезапущен"

    rm -f "$WEB_DIR/setup-shellinabox.sh"

    if [ ! -f /var/www/shell-token ]; then
        log_step "Установка shellinabox..."
        apt-get install -y -qq shellinabox 2>/dev/null || log_warn "apt-get install shellinabox не удался"
        if dpkg -l shellinabox 2>/dev/null | grep -q "^ii"; then
            cat > /etc/default/shellinabox << 'EOF'
# VPN Panel — shellinabox конфиг
SHELLINABOX_DAEMON_START=1
SHELLINABOX_PORT=4200
SHELLINABOX_ARGS="--no-beep --disable-ssl --localhost-only --user-css MineDark:+/etc/shellinabox/mine-theme.css"
EOF
            a2enmod proxy proxy_http 2>/dev/null || true
            cat > /etc/apache2/conf-available/vpn-panel-shell.conf << 'APACHEEOF'
# VPN Panel — shellinabox HTTP proxy
<IfModule mod_proxy.c>
    ProxyRequests Off
    ProxyPass        /shell/ http://127.0.0.1:4200/
    ProxyPassReverse /shell/ http://127.0.0.1:4200/
</IfModule>
APACHEEOF
            a2enconf vpn-panel-shell 2>/dev/null || true
            echo "enabled" > /var/www/shell-token
            chmod 644 /var/www/shell-token
            systemctl enable shellinabox 2>/dev/null
            systemctl restart shellinabox
            systemctl reload apache2 2>/dev/null || systemctl restart apache2 2>/dev/null
            systemctl is-active --quiet shellinabox && log_info "shellinabox установлен" || log_warn "shellinabox не запустился"
        else
            log_warn "shellinabox не установлен"
        fi
    else
        log_info "shellinabox уже установлен"
    fi

    need_recreate_vpn_panel_conf=0
    if [ ! -f /etc/vpn-panel.conf ]; then
        need_recreate_vpn_panel_conf=1
    else
        existing_wan=$(grep "^WAN=" /etc/vpn-panel.conf 2>/dev/null | cut -d= -f2)
        existing_lan=$(grep "^LAN=" /etc/vpn-panel.conf 2>/dev/null | cut -d= -f2)
        if [ -z "$existing_wan" ] || ! ip link show "$existing_wan" >/dev/null 2>&1; then
            log_warn "/etc/vpn-panel.conf містить хибний WAN='$existing_wan' (інтерфейс не існує) — перестворюю"
            need_recreate_vpn_panel_conf=1
        elif [ -z "$existing_lan" ] || ! ip link show "$existing_lan" >/dev/null 2>&1; then
            log_warn "/etc/vpn-panel.conf містить хибний LAN='$existing_lan' (інтерфейс не існує) — перестворюю"
            need_recreate_vpn_panel_conf=1
        fi
    fi

    if [ "$need_recreate_vpn_panel_conf" = "1" ]; then
        detect_interfaces
        keep_wan_list=$(grep "^WAN_LIST=" /etc/vpn-panel.conf 2>/dev/null | cut -d= -f2-)
        keep_lan_mask=$(grep "^LAN_MASK=" /etc/vpn-panel.conf 2>/dev/null | cut -d= -f2)
        keep_dhcp_from=$(grep "^DHCP_FROM=" /etc/vpn-panel.conf 2>/dev/null | cut -d= -f2)
        keep_dhcp_to=$(grep "^DHCP_TO=" /etc/vpn-panel.conf 2>/dev/null | cut -d= -f2)
        cat > /etc/vpn-panel.conf << EOF
VERSION=$SCRIPT_VERSION
DATE=$(date '+%Y-%m-%d %H:%M:%S')
WAN=${DETECTED_WAN:-unknown}
WAN_LIST=${keep_wan_list:-${DETECTED_WAN:-unknown}}
LAN=${DETECTED_LAN:-unknown}
LAN_IP=$LAN_IP
LAN_NET=$LAN_NET
LAN_PREFIX=$LAN_PREFIX
LAN_MASK=${keep_lan_mask:-255.255.240.0}
DHCP_FROM=${keep_dhcp_from:-10.10.1.2}
DHCP_TO=${keep_dhcp_to:-10.10.15.254}
EOF
        log_info "/etc/vpn-panel.conf створено/оновлено (WAN=${DETECTED_WAN:-unknown}, LAN=${DETECTED_LAN:-unknown})"
    fi

    if grep -qE "^net\.netfilter\.nf_conntrack_max[[:space:]]*=[[:space:]]*262144" /etc/sysctl.conf; then
        sed -i 's|^net\.netfilter\.nf_conntrack_max[[:space:]]*=.*|net.netfilter.nf_conntrack_max=524288|' /etc/sysctl.conf
        log_info "Conntrack max оновлено 262144 → 524288 (для 400+ LAN пристроїв)"
    elif ! grep -q "^net.netfilter.nf_conntrack_max" /etc/sysctl.conf; then
        echo "net.netfilter.nf_conntrack_max=524288" >> /etc/sysctl.conf
    fi
    grep -q "^net.netfilter.nf_conntrack_udp_timeout=" /etc/sysctl.conf || echo "net.netfilter.nf_conntrack_udp_timeout=30" >> /etc/sysctl.conf
    grep -q "^net.netfilter.nf_conntrack_udp_timeout_stream" /etc/sysctl.conf || echo "net.netfilter.nf_conntrack_udp_timeout_stream=120" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    log_info "Conntrack sysctl настроєні (max=524288, UDP timeout=30/120)"

    if [ ! -f /etc/modprobe.d/no-sip-alg.conf ]; then
        modprobe -r nf_conntrack_sip 2>/dev/null || true
        modprobe -r nf_nat_sip 2>/dev/null || true
        cat > /etc/modprobe.d/no-sip-alg.conf << 'EOF'
# VPN Panel — отключение SIP ALG для корректной работы VOIP за NAT
blacklist nf_conntrack_sip
blacklist nf_nat_sip
EOF
        log_info "SIP ALG отключён (модули nf_conntrack_sip + nf_nat_sip в blacklist)"
    fi

    if [ -f /etc/dnsmasq.conf ] && grep -qF ",12h" /etc/dnsmasq.conf; then
        sed -i 's/,12h/,72h/' /etc/dnsmasq.conf
        if systemctl is-active --quiet dnsmasq 2>/dev/null; then
            systemctl restart dnsmasq 2>/dev/null && log_info "DHCP lease обновлён 12h → 72h (dnsmasq перезапущен)" \
                || log_warn "DHCP lease обновлён, но dnsmasq не перезапустился"
        else
            log_info "DHCP lease обновлён 12h → 72h (dnsmasq неактивен, рестарт не нужен)"
        fi
    fi

    if [ -f /etc/dnsmasq.conf ]; then
        dnsmasq_changed=0

        grep -qF "dhcp-authoritative" /etc/dnsmasq.conf || { echo "dhcp-authoritative" >> /etc/dnsmasq.conf; dnsmasq_changed=1; }
        grep -qF "domain=vpn-panel.lan" /etc/dnsmasq.conf || { echo "domain=vpn-panel.lan" >> /etc/dnsmasq.conf; dnsmasq_changed=1; }
        grep -qF "bind-interfaces" /etc/dnsmasq.conf || { echo "bind-interfaces" >> /etc/dnsmasq.conf; dnsmasq_changed=1; }
        grep -qF "server=1.1.1.1" /etc/dnsmasq.conf || { echo "server=1.1.1.1" >> /etc/dnsmasq.conf; dnsmasq_changed=1; }
        grep -qF "server=8.8.8.8" /etc/dnsmasq.conf || { echo "server=8.8.8.8" >> /etc/dnsmasq.conf; dnsmasq_changed=1; }

        for setting in "cache-size=50000" "dns-forward-max=8192" "dhcp-lease-max=2000" "min-cache-ttl=60" "neg-ttl=60"; do
            key="${setting%%=*}"
            if grep -qE "^${key}=" /etc/dnsmasq.conf; then
                current=$(grep -E "^${key}=" /etc/dnsmasq.conf | head -1)
                if [ "$current" != "$setting" ]; then
                    sed -i "s|^${key}=.*|${setting}|" /etc/dnsmasq.conf
                    dnsmasq_changed=1
                fi
            else
                echo "${setting}" >> /etc/dnsmasq.conf
                dnsmasq_changed=1
            fi
        done

        if [ "$dnsmasq_changed" = "1" ]; then
            if systemctl is-active --quiet dnsmasq 2>/dev/null; then
                systemctl restart dnsmasq 2>/dev/null && log_info "dnsmasq.conf оновлено (ліміти 400+ пристроїв) + перезапущено" \
                    || log_warn "dnsmasq.conf оновлено, але dnsmasq не перезапустився"
            else
                log_info "dnsmasq.conf оновлено (ліміти 400+ пристроїв, dnsmasq неактивний)"
            fi
        fi
    fi

    if [ -f /etc/ssh/sshd_config ]; then
        sshd_changed=0
        if grep -qE "^#?PermitRootLogin[[:space:]]+(prohibit-password|no)" /etc/ssh/sshd_config; then
            sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
            sed -i 's/^PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
            sed -i 's/^PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config
            sshd_changed=1
        fi
        if [ "$sshd_changed" = "1" ]; then
            systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
            log_info "SSH PermitRootLogin yes (виставлено)"
        fi
    fi

    if [ -f /etc/security/faillock.conf ]; then
        [ ! -f /etc/security/faillock.conf.vpn-panel-backup ] && \
            cp /etc/security/faillock.conf /etc/security/faillock.conf.vpn-panel-backup
        faillock_changed=0
        for setting in "deny=30" "unlock_time=60" "fail_interval=900"; do
            key="${setting%%=*}"
            current=$(grep -E "^[#[:space:]]*${key}[[:space:]]*=" /etc/security/faillock.conf | head -1 | tr -d ' ')
            expected=$(echo "$setting" | tr -d ' ')
            if [ "$current" != "$expected" ]; then
                if grep -qE "^[#[:space:]]*${key}[[:space:]]*=" /etc/security/faillock.conf; then
                    sed -i "s|^[#[:space:]]*${key}[[:space:]]*=.*|${setting}|" /etc/security/faillock.conf
                else
                    echo "${setting}" >> /etc/security/faillock.conf
                fi
                faillock_changed=1
            fi
        done
        [ "$faillock_changed" = "1" ] && log_info "/etc/security/faillock.conf: deny=30, unlock_time=60, fail_interval=900"
    fi
    pam_disabled=0
    for pam_file in /etc/pam.d/common-auth /etc/pam.d/common-account /etc/pam.d/sshd; do
        [ -f "$pam_file" ] || continue
        if grep -qE "^[[:space:]]*[^#].*pam_faillock\.so" "$pam_file"; then
            sed -i 's|^\([[:space:]]*[^#].*pam_faillock\.so.*\)|# VPN Panel disabled: \1|' "$pam_file"
            pam_disabled=1
        fi
    done
    [ "$pam_disabled" = "1" ] && log_info "PAM faillock закоментовано у /etc/pam.d/* (LAN-friendly)"

    log_info "Миграция v5 завершена"
fi

if [ "$CURRENT_VERSION" -lt 6 ]; then
    log_step "Миграция v6: код больше не хранится в веб-корне..."

    if [ -d "$WEB_DIR/.git" ]; then
        log_warn "В $WEB_DIR остался git-репозиторий от старой схемы обновлений."
        log_warn "Он больше не используется: код разворачивает vpn-panel-deploy из /opt/vpn-panel/src."
    fi

    log_info "Миграция v6 завершена"
fi

mkdir -p /var/log/vpn-panel
if [ -f /var/log/vpn-panel/vpn_history.json ] && [ ! -s /var/log/vpn-panel/events.log ]; then
    log_step "Миграция vpn_history.json → events.log..."
    php -r '
        $json = @file_get_contents("/var/log/vpn-panel/vpn_history.json");
        $d = $json ? json_decode($json, true) : null;
        if (!is_array($d)) exit;
        $out = [];
        foreach (($d["disconnections"] ?? []) as $ev) {
            $t = $ev["time"] ?? ""; $r = $ev["reason"] ?? "";
            if ($t && $r) $out[] = [strtotime($t), "$t|disconnect|$r"];
        }
        foreach (($d["config_changes"] ?? []) as $ev) {
            $t = $ev["time"] ?? ""; $c = $ev["config"] ?? ""; $by = $ev["type"] ?? "auto";
            if (!$t || !$c) continue;
            // Старый формат: config был либо ID, либо "failover to ID", либо "primary restored"
            if (preg_match("/^failover to (\S+)/", $c, $m)) { $out[] = [strtotime($t), "$t|config_change|".$m[1]."|failover"]; }
            elseif (preg_match("/^(vpn_[a-f0-9]+)/", $c, $m)) { $out[] = [strtotime($t), "$t|config_change|".$m[1]."|manual"]; }
            // primary restored и прочее — пропускаем (нет ID для маппинга)
        }
        usort($out, fn($a, $b) => $a[0] - $b[0]);
        $lines = array_column($out, 1);
        file_put_contents("/var/log/vpn-panel/events.log", implode("\n", $lines) . (empty($lines) ? "" : "\n"));
    ' 2>/dev/null
    mv /var/log/vpn-panel/vpn_history.json /var/log/vpn-panel/vpn_history.json.migrated 2>/dev/null
    chmod 666 /var/log/vpn-panel/events.log
    log_info "Миграция завершена ($(wc -l < /var/log/vpn-panel/events.log 2>/dev/null || echo 0) событий)"
fi
touch /var/log/vpn-panel/events.log
chmod 666 /var/log/vpn-panel/events.log

if [ -d "$VPN_CONFIGS_DIR" ]; then
    perms=$(stat -c '%a' "$VPN_CONFIGS_DIR" 2>/dev/null)
    if [ "$perms" != "770" ]; then
        chown root:www-data "$VPN_CONFIGS_DIR"
        chmod 770 "$VPN_CONFIGS_DIR"
        log_info "Исправлены права $VPN_CONFIGS_DIR: $perms → 770"
    fi
fi

if [ -f /var/log/vpn-panel/events.log ]; then
    chmod 666 /var/log/vpn-panel/events.log 2>/dev/null || true
fi

for f in /var/www/vpn-state /var/www/settings; do
    if [ -f "$f" ]; then
        perms=$(stat -c '%a' "$f" 2>/dev/null)
        if [ "$perms" != "666" ]; then
            chmod 666 "$f" 2>/dev/null && log_info "Исправлены права $f: $perms → 666"
        fi
    fi
done

vpn_panel_conf_recreate=0
if [ ! -f /etc/vpn-panel.conf ]; then
    vpn_panel_conf_recreate=1
else
    existing_wan=$(grep "^WAN=" /etc/vpn-panel.conf 2>/dev/null | cut -d= -f2)
    existing_lan=$(grep "^LAN=" /etc/vpn-panel.conf 2>/dev/null | cut -d= -f2)
    if [ -z "$existing_wan" ] || [ "$existing_wan" = "unknown" ] || ! ip link show "$existing_wan" >/dev/null 2>&1; then
        log_warn "/etc/vpn-panel.conf містить хибний WAN='$existing_wan' (інтерфейс не існує в системі) — перестворюю"
        vpn_panel_conf_recreate=1
    elif [ -z "$existing_lan" ] || [ "$existing_lan" = "unknown" ] || ! ip link show "$existing_lan" >/dev/null 2>&1; then
        log_warn "/etc/vpn-panel.conf містить хибний LAN='$existing_lan' (інтерфейс не існує в системі) — перестворюю"
        vpn_panel_conf_recreate=1
    fi
fi

conf_put() {
    local key="$1" value="$2" file="/etc/vpn-panel.conf"
    [ -f "$file" ] || : > "$file"
    if grep -q "^$key=" "$file"; then
        local tmp
        tmp=$(mktemp "${file}.XXXXXX") || return 1
        grep -v "^$key=" "$file" > "$tmp"
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
        cat "$tmp" > "$file"
        rm -f "$tmp"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

if [ "$vpn_panel_conf_recreate" = "1" ]; then
    detect_interfaces
    if [ -n "$DETECTED_WAN" ]; then
        conf_put WAN "$DETECTED_WAN"
    else
        log_warn "WAN не визначено — старе значення в /etc/vpn-panel.conf залишено без змін"
    fi
    if [ -n "$DETECTED_LAN" ]; then
        conf_put LAN "$DETECTED_LAN"
    else
        log_warn "LAN не визначено — старе значення в /etc/vpn-panel.conf залишено без змін"
    fi
    conf_put VERSION "$SCRIPT_VERSION"
    conf_put DATE "$(date '+%Y-%m-%d %H:%M:%S')"
    log_info "/etc/vpn-panel.conf оновлено (WAN=${DETECTED_WAN:-unknown}, LAN=${DETECTED_LAN:-unknown})"
    if systemctl is-active --quiet vpn-healthcheck.service 2>/dev/null; then
        systemctl restart vpn-healthcheck.service 2>/dev/null && log_info "HC daemon перезапущено для перечитання vpn-panel.conf"
    fi
fi

if [ -f /etc/vpn-panel.conf ]; then
    ks_lan=$(grep "^LAN=" /etc/vpn-panel.conf 2>/dev/null | cut -d= -f2)
    ks_wan=$(grep "^WAN=" /etc/vpn-panel.conf 2>/dev/null | cut -d= -f2)
    if [ -n "$ks_lan" ] && [ -n "$ks_wan" ] && [ "$ks_lan" != "unknown" ] && [ "$ks_wan" != "unknown" ]; then
        ks_bad=0
        ks_policy=$(iptables -L FORWARD -n 2>/dev/null | head -1 | grep -oP '(?<=policy )\w+')
        [ "$ks_policy" != "DROP" ] && ks_bad=1
        [ "$ks_bad" -eq 0 ] && ! iptables -t nat -C POSTROUTING -o tun0 -s "$LAN_NET" -j MASQUERADE 2>/dev/null && ks_bad=1
        [ "$ks_bad" -eq 0 ] && ! iptables -C FORWARD -i "$ks_lan" -o tun0 -j ACCEPT 2>/dev/null && ks_bad=1

        if [ "$ks_bad" = "1" ]; then
            log_warn "Kill Switch правила відсутні або неповні — налаштовую (LAN=$ks_lan, WAN=$ks_wan)"
            iptables -P FORWARD DROP
            iptables -F FORWARD
            iptables -A FORWARD -i "$ks_lan" -o tun0 -j ACCEPT
            iptables -A FORWARD -i tun0 -o "$ks_lan" -m state --state RELATED,ESTABLISHED -j ACCEPT
            iptables -A FORWARD -i "$ks_lan" -o "$ks_lan" -j ACCEPT
            iptables -A FORWARD -i "$ks_lan" -o "$ks_wan" -j REJECT --reject-with icmp-net-unreachable
            iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
            iptables -t nat -C POSTROUTING -o tun0 -s "$LAN_NET" -j MASQUERADE 2>/dev/null || \
                iptables -t nat -A POSTROUTING -o tun0 -s "$LAN_NET" -j MASQUERADE
            iptables-save > /etc/iptables/rules.v4
            log_info "Kill Switch налаштовано і збережено в rules.v4"
        fi
    fi
fi

for ext in mbstring yaml; do
    if ! php -m 2>/dev/null | grep -qi "^${ext}$"; then
        log_step "Установка php-${ext}..."
        apt-get install -y -qq "php-${ext}" 2>/dev/null && {
            log_info "php-${ext} установлен"
            php_ext_installed=1
        } || log_warn "не удалось установить php-${ext}"
    fi
done
if [ "${php_ext_installed:-0}" = "1" ]; then
    systemctl restart apache2 2>/dev/null && log_info "apache2 перезапущен для подключения PHP расширений" || true
fi

if dpkg -l shellinabox 2>/dev/null | grep -q "^ii"; then
    mkdir -p /etc/shellinabox
    theme_changed=0

    if [ -f "$WEB_DIR/assets/css/shellinabox-theme.css" ]; then
        if ! cmp -s "$WEB_DIR/assets/css/shellinabox-theme.css" /etc/shellinabox/mine-theme.css 2>/dev/null; then
            cp "$WEB_DIR/assets/css/shellinabox-theme.css" /etc/shellinabox/mine-theme.css
            chmod 644 /etc/shellinabox/mine-theme.css
            theme_changed=1
            log_info "shellinabox theme обновлена из $WEB_DIR/assets/css/shellinabox-theme.css"
        fi
    fi

    if ! grep -q 'user-css' /etc/default/shellinabox 2>/dev/null; then
        cat > /etc/default/shellinabox << 'EOF'
# VPN Panel — shellinabox конфиг
SHELLINABOX_DAEMON_START=1
SHELLINABOX_PORT=4200
SHELLINABOX_ARGS="--no-beep --disable-ssl --localhost-only --user-css MineDark:+/etc/shellinabox/mine-theme.css"
EOF
        theme_changed=1
        log_info "SHELLINABOX_ARGS обновлён (добавлен --user-css)"
    fi

    if [ "$theme_changed" -eq 1 ]; then
        systemctl restart shellinabox 2>/dev/null && log_info "shellinabox перезапущен" || log_warn "не удалось перезапустить shellinabox"
    fi
fi

if [ -f /etc/systemd/system/vpn-healthcheck.service ]; then
    if grep -q '/usr/local/bin/vpn-healthcheck.sh' /etc/systemd/system/vpn-healthcheck.service 2>/dev/null; then
        log_step "Миграция HC service: /usr/local/bin/ → $WEB_DIR/"
        cat > /etc/systemd/system/vpn-healthcheck.service << EOF
[Unit]
Description=VPN Health Check Daemon
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$WEB_DIR/vpn-healthcheck.sh
Restart=always
RestartSec=5
StandardOutput=null
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        log_info "HC service обновлён (ExecStart → $WEB_DIR/vpn-healthcheck.sh)"
        hc_service_changed=1
    fi
fi

if [ -f "$WEB_DIR/vpn-healthcheck.sh" ]; then
    owner=$(stat -c '%U:%G' "$WEB_DIR/vpn-healthcheck.sh" 2>/dev/null)
    perms=$(stat -c '%a' "$WEB_DIR/vpn-healthcheck.sh" 2>/dev/null)
    if [ "$owner" != "root:root" ] || [ "$perms" != "755" ]; then
        chown root:root "$WEB_DIR/vpn-healthcheck.sh"
        chmod 755 "$WEB_DIR/vpn-healthcheck.sh"
        log_info "HC скрипт: права исправлены ($owner $perms → root:root 755)"
    fi
fi

if [ -f /usr/local/bin/vpn-healthcheck.sh ]; then
    rm -f /usr/local/bin/vpn-healthcheck.sh
    log_info "Удалена устаревшая копия /usr/local/bin/vpn-healthcheck.sh"
fi

HC_MD5_FILE="/var/lib/vpn-panel/hc.md5"
mkdir -p /var/lib/vpn-panel
if [ -f "$WEB_DIR/vpn-healthcheck.sh" ]; then
    current_md5=$(md5sum "$WEB_DIR/vpn-healthcheck.sh" 2>/dev/null | cut -d' ' -f1)
    saved_md5=$(cat "$HC_MD5_FILE" 2>/dev/null || echo "")
    if [ "$current_md5" != "$saved_md5" ] || [ "${hc_service_changed:-0}" = "1" ]; then
        echo "$current_md5" > "$HC_MD5_FILE"
        if systemctl is-active --quiet vpn-healthcheck.service 2>/dev/null; then
            systemctl restart vpn-healthcheck.service 2>/dev/null && \
                log_info "HC daemon перезапущен (скрипт обновлён)" || \
                log_warn "HC daemon не удалось перезапустить"
        fi
    fi
fi

ROUTING_SRC="$WEB_DIR/vpn-panel-routing.sh"
ROUTING_BIN="/usr/local/sbin/vpn-panel-routing"

if [ -f "$ROUTING_SRC" ]; then
    chown root:root "$ROUTING_SRC"
    chmod 755 "$ROUTING_SRC"
    ln -sf "$ROUTING_SRC" "$ROUTING_BIN"

    if [ ! -f /etc/systemd/system/vpn-panel-routing.service ]; then
        cat > /etc/systemd/system/vpn-panel-routing.service << 'ROUTING_UNIT_EOF'
[Unit]
Description=VPN Panel policy routing for WAN links
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/vpn-panel-routing apply
[Install]
WantedBy=multi-user.target
ROUTING_UNIT_EOF
        systemctl daemon-reload
        systemctl enable vpn-panel-routing.service >/dev/null 2>&1 || true
        log_info "Установлен vpn-panel-routing (маршрутизация каналов)"
    fi

    if [ -f /etc/vpn-panel.conf ] && ! grep -q "^WAN_LIST=" /etc/vpn-panel.conf; then
        existing_wan=$(grep "^WAN=" /etc/vpn-panel.conf 2>/dev/null | cut -d= -f2)
        printf 'WAN_LIST=%s\n' "${existing_wan:-${DETECTED_WAN:-unknown}}" >> /etc/vpn-panel.conf
        log_info "WAN_LIST добавлен в /etc/vpn-panel.conf (${existing_wan:-unknown})"
    fi

    "$ROUTING_BIN" apply >/dev/null 2>&1 || true
else
    log_warn "vpn-panel-routing.sh отсутствует в $WEB_DIR — многоканальность недоступна"
fi

DEPLOY_SRC="$WEB_DIR/vpn-panel-deploy.sh"
DEPLOY_BIN="/usr/local/sbin/vpn-panel-deploy"

if [ -f "$DEPLOY_SRC" ]; then
    chown root:root "$DEPLOY_SRC"
    chmod 755 "$DEPLOY_SRC"
    ln -sf "$DEPLOY_SRC" "$DEPLOY_BIN"

    if [ -f /etc/vpn-panel.conf ] && ! grep -q "^CHANNEL=" /etc/vpn-panel.conf; then
        printf 'CHANNEL=stable\n' >> /etc/vpn-panel.conf
        log_info "CHANNEL=stable добавлен в /etc/vpn-panel.conf"
    fi
    if [ -f /etc/vpn-panel.conf ] && ! grep -q "^REPO_URL=" /etc/vpn-panel.conf; then
        old_remote=$(git -C "$WEB_DIR" remote get-url origin 2>/dev/null)
        [ -n "$old_remote" ] && printf 'REPO_URL=%s\n' "$old_remote" >> /etc/vpn-panel.conf &&             log_info "REPO_URL взят из старой рабочей копии: $old_remote"
    fi

    if crontab -l 2>/dev/null | grep -qE "(vpn-panel-update|run-update)"; then
        (crontab -l 2>/dev/null | grep -vE "(run-update|vpn-panel-update|vpn-panel-deploy)";          echo "0 * * * * $DEPLOY_BIN auto >> /var/log/vpn-panel/update.log 2>&1") | crontab -
        log_info "Cron переведён на vpn-panel-deploy (git больше не выполняется в веб-корне)"
    elif ! crontab -l 2>/dev/null | grep -q "vpn-panel-deploy"; then
        (crontab -l 2>/dev/null;          echo "0 * * * * $DEPLOY_BIN auto >> /var/log/vpn-panel/update.log 2>&1") | crontab -
        log_info "Cron автообновления добавлен (vpn-panel-deploy)"
    fi

    rm -f /usr/local/bin/vpn-panel-update.sh /usr/local/bin/run-update.sh
else
    log_warn "vpn-panel-deploy.sh отсутствует в $WEB_DIR — автообновление не переведено"
fi


SUDOERS_FILE="/etc/sudoers.d/vpn-panel-www-data"
if [ -f "$SUDOERS_FILE" ]; then
    sudoers_changed=0

    if ! grep -qF "/bin/systemctl reboot" "$SUDOERS_FILE"; then
        echo "www-data ALL=(ALL) NOPASSWD: /bin/systemctl reboot" >> "$SUDOERS_FILE"
        sudoers_changed=1
    fi

    if ! grep -qF "/bin/systemctl poweroff" "$SUDOERS_FILE"; then
        echo "www-data ALL=(ALL) NOPASSWD: /bin/systemctl poweroff" >> "$SUDOERS_FILE"
        sudoers_changed=1
    fi

    if [ "$sudoers_changed" = "1" ]; then
        if visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
            log_info "Sudoers: добавлены reboot/poweroff (для страницы Настройки → Управление сервером)"
        else
            log_warn "Sudoers: ошибка валидации после добавления reboot/poweroff! Проверьте $SUDOERS_FILE"
        fi
    fi
fi

if [ "$MIGRATION_FAILED" = "1" ]; then
    log_warn "Миграции завершились с ошибками — версия не поднята"
else
    echo "$SCRIPT_VERSION" > "$VERSION_FILE"
fi

{
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║    Обновление завершено: v$CURRENT_VERSION → v$SCRIPT_VERSION         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}Что нового в v6:${NC}"
    echo "    • Код разворачивает vpn-panel-deploy из /opt/vpn-panel/src — git в веб-корне не нужен"
    echo "    • Обновление идёт по тегам (канал stable), а не по ветке main"
    echo "    • Перед обновлением снимок, после — diagnostic.sh и откат при провале"
    echo ""
} >&3

if [ "$MIGRATION_FAILED" = "1" ]; then
    exit 1
fi
exit 0
