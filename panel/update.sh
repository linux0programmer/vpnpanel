#!/bin/bash

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
    echo "Миграции и проверка конфигурации"
    echo "Запущено: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "PID: $UPDATE_PID"
    if [ "${AUTO_RUN:-0}" = "1" ]; then
        echo "Запуск: автоматический, из vpn-panel-deploy"
    else
        echo "Запуск: вручную"
    fi
    echo "============================================"
} >> "$LOG_FILE"

VP_HAS_TTY=0
if [ -e /dev/tty ] && { : >/dev/tty; } 2>/dev/null; then
    VP_HAS_TTY=1
fi

if [ "$VP_HAS_TTY" = "1" ]; then
    exec 7>/dev/tty
    exec 8>/dev/tty
    exec 3> >(stdbuf -oL tee >(stdbuf -oL sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE") >&7)
    exec 4> >(stdbuf -oL tee >(stdbuf -oL sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE") >&8)
else
    exec 3> >(stdbuf -oL sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE")
    exec 4> >(stdbuf -oL sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE")
fi

exec 1>>"$LOG_FILE" 2>&1

trap '' PIPE
trap 'exec 3>&- 4>&- 2>/dev/null; sleep 0.2' EXIT

log_info() { echo -e "${GREEN}[✓]${NC} $1" >&3; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1" >&3; }
log_step() { echo -e "${CYAN}[*]${NC} $1" >&3; }

VP_CONF_FILE="/etc/vpn-panel.conf"
LAN_IP="10.32.0.1"
LAN_NET="10.32.0.0/20"
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
    echo -e "${CYAN}║      Миграции и проверка конфигурации     ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""
} >&3

log_info "Код разворачивает vpn-panel-deploy — этот скрипт только применяет миграции"

release_number() {
    local n="${1#v}"
    case "$n" in
        ''|*[!0-9]*) printf '0' ;;
        *)           printf '%s' "$n" ;;
    esac
}

CURRENT_RELEASE=0
if [ -f "$VERSION_FILE" ] && [ -s "$VERSION_FILE" ]; then
    CURRENT_RELEASE=$(release_number "$(cat "$VERSION_FILE")")
fi

DEPLOYED_RELEASE="${VP_RELEASE:-}"
if [ -z "$DEPLOYED_RELEASE" ] && [ -f /var/lib/vpn-panel/deployed ]; then
    DEPLOYED_RELEASE=$(awk '{print $1}' /var/lib/vpn-panel/deployed 2>/dev/null)
fi
TARGET_RELEASE=$(release_number "$DEPLOYED_RELEASE")
[ "$TARGET_RELEASE" = "0" ] && TARGET_RELEASE="$CURRENT_RELEASE"

echo "" >&3
if [ "$TARGET_RELEASE" -gt "$CURRENT_RELEASE" ] 2>/dev/null; then
    log_step "Выпуск: v$CURRENT_RELEASE → v$TARGET_RELEASE"
else
    log_step "Выпуск: v$CURRENT_RELEASE"
fi
echo "" >&3

mkdir -p /var/log/vpn-panel
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

if [ -f "$PANEL_NETPLAN" ]; then
    np_perms=$(stat -c '%a' "$PANEL_NETPLAN" 2>/dev/null)
    np_owner=$(stat -c '%U:%G' "$PANEL_NETPLAN" 2>/dev/null)
    if [ "$np_perms" != "660" ] || [ "$np_owner" != "root:www-data" ]; then
        chown root:www-data "$PANEL_NETPLAN" 2>/dev/null || true
        chmod 660 "$PANEL_NETPLAN" 2>/dev/null && \
            log_info "Исправлены права $PANEL_NETPLAN: $np_owner $np_perms → root:www-data 660"
    fi
fi

if [ -f /var/www/settings ]; then
    settings_added=""
    for pair in "vpnchecker=true" "autoupvpn=true" "failover=true" "failover_first=false" \
                "wan_failover=true" "wan_return=true"; do
        key=${pair%%=*}
        if ! grep -q "^$key=" /var/www/settings 2>/dev/null; then
            echo "$pair" >> /var/www/settings
            settings_added="${settings_added:+$settings_added }$key"
        fi
    done
    if [ -n "$settings_added" ]; then
        chmod 666 /var/www/settings 2>/dev/null || true
        log_info "В /var/www/settings добавлены недостающие ключи: $settings_added"
    fi
fi

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
        [ "$ks_bad" -eq 0 ] && ! iptables -C FORWARD -i "$ks_lan" ! -o tun0 -j REJECT --reject-with icmp-net-unreachable 2>/dev/null && ks_bad=1

        if [ "$ks_bad" = "1" ]; then
            log_warn "Kill Switch правила відсутні або неповні — налаштовую (LAN=$ks_lan, WAN=$ks_wan)"
            iptables -P FORWARD DROP
            iptables -F FORWARD
            iptables -A FORWARD -i "$ks_lan" -o tun0 -j ACCEPT
            iptables -A FORWARD -i tun0 -o "$ks_lan" -m state --state RELATED,ESTABLISHED -j ACCEPT
            iptables -A FORWARD -i "$ks_lan" -o "$ks_lan" -j ACCEPT
            iptables -A FORWARD -i "$ks_lan" ! -o tun0 -j REJECT --reject-with icmp-net-unreachable
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
SUDOERS_REQUIRED="
/bin/systemctl reboot
/bin/systemctl poweroff
/usr/local/sbin/vpn-panel-routing status
/usr/local/sbin/vpn-panel-routing free
/usr/local/sbin/vpn-panel-routing netplan-dump
/usr/local/sbin/vpn-panel-routing netplan-owner *
/usr/local/sbin/vpn-panel-routing apply
/usr/local/sbin/vpn-panel-routing set-active *
/usr/local/sbin/vpn-panel-routing set-primary *
/usr/local/sbin/vpn-panel-routing move-wan *
/usr/local/sbin/vpn-panel-routing add-wan *
/usr/local/sbin/vpn-panel-routing remove-wan *
/usr/sbin/netplan apply
"

if [ -f "$SUDOERS_FILE" ]; then
    sudoers_added=""
    cp -a "$SUDOERS_FILE" "${SUDOERS_FILE}.bak" 2>/dev/null || true

    printf '%s\n' "$SUDOERS_REQUIRED" | while IFS= read -r cmd; do
        [ -z "$cmd" ] && continue
        grep -qF "NOPASSWD: $cmd" "$SUDOERS_FILE" && continue
        echo "www-data ALL=(ALL) NOPASSWD: $cmd" >> "$SUDOERS_FILE"
        echo "$cmd" >> /tmp/vp-sudoers-added.$$
    done

    if [ -f "/tmp/vp-sudoers-added.$$" ]; then
        sudoers_added=$(tr '\n' ' ' < "/tmp/vp-sudoers-added.$$")
        rm -f "/tmp/vp-sudoers-added.$$"
    fi

    if [ -n "$sudoers_added" ]; then
        if visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
            chmod 440 "$SUDOERS_FILE"
            rm -f "${SUDOERS_FILE}.bak"
            log_info "Sudoers: добавлены недостающие права — $sudoers_added"
        else
            if [ -f "${SUDOERS_FILE}.bak" ]; then
                mv -f "${SUDOERS_FILE}.bak" "$SUDOERS_FILE"
                log_warn "Sudoers: правка не прошла visudo, файл возвращён из копии"
            else
                log_warn "Sudoers: правка не прошла visudo, а копии нет — проверьте $SUDOERS_FILE"
            fi
            MIGRATION_FAILED=1
        fi
    else
        rm -f "${SUDOERS_FILE}.bak"
    fi
fi

[ "$MIGRATION_FAILED" = "1" ] && log_warn "Миграции завершились с ошибками — номер выпуска не поднят"

{
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        Конфигурация проверена            ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
} >&3

if [ "$MIGRATION_FAILED" = "1" ]; then
    exit 1
fi
exit 0
