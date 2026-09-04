#!/bin/bash

SCRIPT_VERSION=1
VERSION_FILE="/var/www/version"
SETTINGS_FILE="/var/www/settings"
WEB_DIR="/var/www/html"
VPN_CONFIGS_DIR="/var/www/vpn-configs"
GIT_REPO="https://github.com/linux0programmer/vpnpanel.git"
NETPLAN_FILE="/etc/netplan/99-vpn-panel.yaml"
NETPLAN_LEGACY="/etc/netplan/01-network-manager-all.yaml"

LOCAL_NET="10.32.0.0/20"
LOCAL_IP="10.32.0.1"
LOCAL_PREFIX="20"
LOCAL_MASK="255.255.240.0"
DHCP_RANGE_START="10.32.0.2"
DHCP_RANGE_END="10.32.15.254"

PACKAGES_REQUIRED=(
    "curl" "wget" "dnsmasq" "wireguard" "openvpn"
    "apache2" "php" "php-yaml" "php-mbstring" "libapache2-mod-php" "git" "iptables-persistent"
    "openssh-server"
)

PACKAGES_OPTIONAL=(
    "htop" "net-tools" "mtr" "resolvconf" "shellinabox" "python3-yaml"
)

PACKAGES_TO_INSTALL=("${PACKAGES_REQUIRED[@]}" "${PACKAGES_OPTIONAL[@]}")
PACKAGES_SKIPPED=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

STEP_LOG=()
INPUT_INTERFACE=""
WAN_INTERFACES=""
INSTALL_SOURCE=""
SSH_IFACE=""
PANEL_SRC=""
SRC_DIR="/opt/vpn-panel/src"
RAW_URL="https://raw.githubusercontent.com/linux0programmer/vpnpanel/main/installer/install.sh"
OUTPUT_INTERFACE=""

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

LOG_FILE="/var/log/vpn-panel/install.log"
MAIN_PID=$BASHPID
mkdir -p /var/log/vpn-panel 2>/dev/null
touch "$LOG_FILE" 2>/dev/null
chmod 644 "$LOG_FILE" 2>/dev/null

{
    echo ""
    echo "════════════════════════════════════════════"
    echo "VPN Panel Installer v$SCRIPT_VERSION"
    echo "Запущено: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "PID: $MAIN_PID"
    echo "════════════════════════════════════════════"
} >> "$LOG_FILE"

exec 7>&1
exec 8>&2

exec 3> >(stdbuf -oL tee --output-error=warn >(stdbuf -oL sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE") >&7)
exec 4> >(stdbuf -oL tee --output-error=warn >(stdbuf -oL sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE") >&8)

exec 1>>"$LOG_FILE" 2>&1

trap 'exec 3>&- 4>&- 2>/dev/null; sleep 0.2' EXIT

log_info()  { echo -e "${GREEN}[✓]${NC} $1" >&3; STEP_LOG+=("[✓] $1"); }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1" >&3; STEP_LOG+=("[!] $1"); }
log_error() { echo -e "${RED}[✗]${NC} $1" >&4; STEP_LOG+=("[✗] $1"); }
log_step()  { echo -e "${CYAN}[*]${NC} $1" >&3; }

ask_var() {
    echo -ne "$1" >&3
    if [ -t 0 ]; then
        read -r "$2"
    elif [ -r /dev/tty ] && { : < /dev/tty; } 2>/dev/null; then
        read -r "$2" < /dev/tty
    else
        error_exit "Нет терминала для вопросов установщика. Скачайте файл и запустите его: curl -fsSL $RAW_URL -o install.sh && sudo bash install.sh"
    fi
    echo "" >&3
}

error_exit() {
    log_error "$1"
    {
        echo ""
        echo -e "${YELLOW}═══ История ═══${NC}"
        for step in "${STEP_LOG[@]}"; do echo "  $step"; done
        echo ""
        echo -e "${YELLOW}Полный лог установки:${NC} ${WHITE}$LOG_FILE${NC}"
        echo -e "${YELLOW}Последние 50 строк:${NC} ${WHITE}tail -n 50 $LOG_FILE${NC}"
        echo ""
    } >&3
    exit 1
}

show_banner() {
    clear >&3
    {
        echo ""
        echo -e "  ${WHITE}VPN SERVER INSTALLER${NC}  ${CYAN}v${SCRIPT_VERSION}${NC}"
        echo -e "  ${CYAN}────────────────────────────────────────${NC}"
        echo ""
    } >&3
}

check_root() {
    [ "$EUID" -ne 0 ] && { echo -e "${RED}[✗] Запустите от root: sudo $0${NC}" >&4; exit 1; }
}

check_os() {
    log_step "Проверка ОС..."
    local os_name; os_name=$(grep -E "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
    local os_version; os_version=$(grep -E "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')

    [[ "${os_name,,}" != "ubuntu" ]] && error_exit "Требуется Ubuntu"

    if [[ "$os_version" != "22.04"* ]] && [[ "$os_version" != "24.04"* ]]; then
        {
            echo ""
            echo -e "${YELLOW}[!] Проверено на Ubuntu 22.04 и 24.04. Текущая: $os_version${NC}"
            echo -e "${YELLOW}    Установщик проверит наличие всех пакетов до внесения изменений,${NC}"
            echo -e "${YELLOW}    но поведение netplan, systemd-resolved и iptables на этом релизе не проверялось.${NC}"
            echo ""
        } >&3
        ask_var "Продолжить? [y/N]: " confirm
        [[ "${confirm,,}" != "y" ]] && exit 0
    fi
    log_info "ОС: Ubuntu $os_version"
}

apt_run() {
    local secs="$1"; shift
    local rc=0
    timeout "$secs" apt-get "$@" </dev/null || rc=$?
    if [ "$rc" -eq 124 ]; then
        log_warn "apt-get $1: превышен лимит ${secs}с, команда прервана"
    fi
    return $rc
}

pkg_available() {
    apt-cache policy "$1" 2>/dev/null | grep -qE '^[[:space:]]*Candidate:[[:space:]]*[^([:space:]]'
}

check_packages() {
    log_step "Проверка доступности пакетов в репозиториях..."

    apt_run 300 update -qq || log_warn "apt-get update не отработал — проверка может быть неточной"

    local pkg missing_required=() missing_optional=()
    for pkg in "${PACKAGES_REQUIRED[@]}"; do
        pkg_available "$pkg" || missing_required+=("$pkg")
    done
    for pkg in "${PACKAGES_OPTIONAL[@]}"; do
        pkg_available "$pkg" || missing_optional+=("$pkg")
    done

    if [ ${#missing_required[@]} -gt 0 ]; then
        {
            echo ""
            echo -e "${RED}[✗] В репозиториях этой версии Ubuntu нет обязательных пакетов:${NC}"
            echo -e "    ${WHITE}${missing_required[*]}${NC}"
            echo ""
            echo -e "${WHITE}Что можно сделать:${NC}"
            echo -e "  • включить репозиторий universe: ${CYAN}add-apt-repository universe${NC}"
            echo -e "  • проверить, что зеркало в /etc/apt/sources.list доступно"
            echo -e "  • поставить эти пакеты вручную и запустить установщик заново"
            echo ""
        } >&3
        error_exit "Установка остановлена до внесения изменений в систему"
    fi

    if [ ${#missing_optional[@]} -gt 0 ]; then
        PACKAGES_SKIPPED="${missing_optional[*]}"
        log_warn "Недоступны необязательные пакеты: $PACKAGES_SKIPPED"
        case " $PACKAGES_SKIPPED " in
            *" shellinabox "*)
                log_warn "Веб-терминал в панели будет недоступен — раздел «Консоль» покажет подсказку" ;;
        esac

        local keep=() opt
        for opt in "${PACKAGES_OPTIONAL[@]}"; do
            case " $PACKAGES_SKIPPED " in
                *" $opt "*) continue ;;
            esac
            keep+=("$opt")
        done
        PACKAGES_TO_INSTALL=("${PACKAGES_REQUIRED[@]}" "${keep[@]}")
    fi

    log_info "Пакетов к установке: ${#PACKAGES_TO_INSTALL[@]}"
    return 0
}

check_internet() {
    log_step "Проверка интернета..."
    ping -q -c 1 -W 5 8.8.8.8 >/dev/null 2>&1 || error_exit "Нет интернета (8.8.8.8 недоступен)"
    ping -q -c 1 -W 5 google.com >/dev/null 2>&1 || log_warn "DNS может работать некорректно"
    log_info "Интернет доступен"
}

select_interfaces() {
    log_step "Сканирование интерфейсов..."
    echo "" >&3

    local raw_ifaces
    raw_ifaces=$(ip -o link show | awk -F': ' '$2 !~ /^lo|^tun|^wg|^docker|^br|^veth/ {print $2}')
    if [ -n "$raw_ifaces" ]; then
        for iface in $raw_ifaces; do
            local current_state
            current_state=$(ip link show "$iface" 2>/dev/null | grep -oP '(?<=state )\w+')
            if [ "$current_state" = "DOWN" ]; then
                ip link set "$iface" up 2>/dev/null || true
            fi
        done
        sleep 1
    fi

    local ifaces; ifaces=$(ip -o link show | awk -F': ' '$2 !~ /^lo|^tun|^wg|^docker|^br|^veth/ {print $2}')
    [ -z "$ifaces" ] && error_exit "Нет сетевых интерфейсов"

    local iface_count; iface_count=$(echo "$ifaces" | wc -w)

    echo -e "${WHITE}Интерфейсы:${NC}" >&3
    echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}" >&3

    local n=0
    declare -A map
    for iface in $ifaces; do
        n=$((n + 1))
        local ip; ip=$(ip -o -4 addr show "$iface" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1)
        local state; state=$(ip link show "$iface" | grep -oP '(?<=state )\w+')
        local mac; mac=$(ip -o link show "$iface" 2>/dev/null | grep -oP '(?<=link/ether )[0-9a-f:]{17}')
        [ -z "$ip" ] && ip="нет IP"
        [ -z "$mac" ] && mac="—"
        local sc="${RED}"; [ "$state" = "UP" ] && sc="${GREEN}"
        printf "  ${WHITE}%d)${NC} %-10s │ %-15s │ %-17s │ ${sc}%s${NC}\n" "$n" "$iface" "$ip" "$mac" "$state" >&3
        map[$n]="$iface"
    done
    echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}" >&3
    echo "" >&3

    if [ "$iface_count" -lt 2 ]; then
        {
            echo -e "${YELLOW}[!] Найдена только 1 сетевая карта.${NC}"
            echo -e "${YELLOW}    Для VPN-роутера нужно 2: WAN (интернет) и LAN (локальная сеть).${NC}"
            echo ""
            echo -e "${WHITE}Возможные причины:${NC}"
            echo -e "  • 2-я карта физически не подключена / не подключён USB-Ethernet адаптер"
            echo -e "  • 2-я карта отключена в BIOS или в гипервизоре (VMware/Proxmox/VirtualBox)"
            echo -e "  • Драйвер не загружен — карта не определена ядром"
            echo ""
            echo -e "${WHITE}Что показывает PCI:${NC}"
        } >&3
        if command -v lspci >/dev/null 2>&1; then
            lspci 2>/dev/null | grep -iE "ethernet|network" | sed 's/^/  /' >&3 || echo "  (нет PCI-устройств с типом Ethernet)" >&3
        else
            echo "  (lspci не установлен — не могу показать PCI-устройства)" >&3
        fi
        echo "" >&3
        ask_var "Продолжить с 1 интерфейсом всё равно? [y/N]: " confirm
        if [[ "${confirm,,}" != "y" ]]; then
            error_exit "Установка прервана. Подключите 2-ю сетевую карту и запустите установщик заново."
        fi
        log_warn "Продолжаем с 1 интерфейсом — WAN и LAN будут на одной карте (не рекомендуется)"
    fi

    local _select_iface
    _select_iface() {
        local prompt="$1" varname="$2" forbidden="$3"
        local choice picked
        while true; do
            ask_var "$prompt" choice
            picked=""
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ -n "${map[$choice]}" ]; then
                picked="${map[$choice]}"
            elif [[ "$choice" =~ ^[a-zA-Z][a-zA-Z0-9_.-]*$ ]] && ip link show "$choice" >/dev/null 2>&1; then
                picked="$choice"
            fi
            if [ -z "$picked" ]; then
                echo -e "${YELLOW}Введите номер из списка или точное имя интерфейса (например: eth1)${NC}" >&3
                continue
            fi
            if [ -n "$forbidden" ] && printf '%s\n' $forbidden | grep -qx "$picked"; then
                echo -e "${YELLOW}Эта карта уже занята. Выберите другую.${NC}" >&3
                continue
            fi
            printf -v "$varname" '%s' "$picked"
            return 0
        done
    }

    _select_iface "Номер WAN (основной провайдер): " INPUT_INTERFACE ""
    WAN_INTERFACES="$INPUT_INTERFACE"
    log_info "WAN: $INPUT_INTERFACE"

    if [ "$iface_count" -lt 2 ]; then
        OUTPUT_INTERFACE="$INPUT_INTERFACE"
        log_warn "LAN на той же карте, что и WAN: $OUTPUT_INTERFACE"
    else
        _select_iface "Номер LAN (локальная сеть): " OUTPUT_INTERFACE "$INPUT_INTERFACE"
    fi
    log_info "LAN: $OUTPUT_INTERFACE"

    local taken="$INPUT_INTERFACE $OUTPUT_INTERFACE"
    local more extra
    while [ "$iface_count" -gt $(printf '%s\n' $taken | wc -l) ]; do
        echo "" >&3
        ask_var "Добавить резервного провайдера на свободную карту? [y/N]: " more
        [[ "${more,,}" != "y" ]] && break
        extra=""
        _select_iface "Номер WAN (резервный провайдер): " extra "$taken"
        WAN_INTERFACES="$WAN_INTERFACES $extra"
        taken="$taken $extra"
        log_info "Резервный WAN: $extra (приоритет $(printf '%s\n' $WAN_INTERFACES | wc -l))"
    done

    if [ "$(printf '%s\n' $WAN_INTERFACES | wc -l)" -gt 1 ]; then
        log_info "Каналы в порядке приоритета: $WAN_INTERFACES"
    fi
    echo "" >&3
}

backup_netplan() {
    local dir="/var/backups/vpn-panel/netplan-$(date '+%Y%m%d-%H%M%S')"
    mkdir -p "$dir" 2>/dev/null || return 0
    if cp -a /etc/netplan/. "$dir"/ 2>/dev/null; then
        log_info "Бэкап netplan: $dir"
    else
        rmdir "$dir" 2>/dev/null || true
    fi
}

panel_ifaces_regex() {
    local list out="" i escaped
    if [ "${KEEP_WAN_CONFIG:-0}" = "1" ]; then
        list="$OUTPUT_INTERFACE"
    else
        list="${WAN_INTERFACES:-$INPUT_INTERFACE} $OUTPUT_INTERFACE"
    fi
    for i in $list; do
        [ -z "$i" ] && continue
        escaped=$(printf '%s' "$i" | sed 's/[.[\*^$]/\\&/g')
        out="${out:+$out|}$escaped"
    done
    printf '%s' "$out"
}

netplan_extra_wans() {
    local w
    for w in ${WAN_INTERFACES:-$INPUT_INTERFACE}; do
        [ "$w" = "$INPUT_INTERFACE" ] && continue
        if [ "${KEEP_WAN_CONFIG:-0}" = "1" ] && ip -4 addr show "$w" 2>/dev/null | grep -q "inet "; then
            log_info "Резервный канал $w уже настроен — оставляю как есть" >&2
            continue
        fi
        cat << EOF
    $w:
      dhcp4: true
      dhcp-identifier: mac
      dhcp4-overrides:
        use-dns: false
        route-metric: 200
      optional: true
EOF
    done
}

restore_disabled_netplan() {
    local f
    for f in /etc/netplan/*.disabled-by-vpn-panel; do
        [ -e "$f" ] || continue
        mv "$f" "${f%.disabled-by-vpn-panel}" 2>/dev/null && \
            log_warn "Возвращён netplan-файл: $(basename "${f%.disabled-by-vpn-panel}")"
    done
}

disable_conflicting_netplan() {
    local f base re

    if [ "${KEEP_WAN_CONFIG:-0}" = "1" ]; then
        log_info "Режим «не менять»: сторонние netplan-файлы не трогаю"
        log_info "Наш $NETPLAN_FILE применяется последним, поэтому LAN настроится поверх них"
        return 0
    fi

    re=$(panel_ifaces_regex)
    [ -z "$re" ] && return 0
    for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
        [ -e "$f" ] || continue
        [ "$f" = "$NETPLAN_FILE" ] && continue
        base=$(basename "$f")
        if grep -qE "^[[:space:]]*($re):" "$f" 2>/dev/null; then
            mv "$f" "$f.disabled-by-vpn-panel"
            log_warn "Отключён конфликтующий netplan-файл: $base (переименован в $base.disabled-by-vpn-panel)"
        fi
    done
    if [ -e "$NETPLAN_LEGACY" ]; then
        mv "$NETPLAN_LEGACY" "$NETPLAN_LEGACY.disabled-by-vpn-panel" 2>/dev/null || true
    fi
}

valid_ipv4() {
    local ip="$1" o1 o2 o3 o4
    case "$ip" in
        *[!0-9.]*|"") return 1 ;;
    esac
    IFS=. read -r o1 o2 o3 o4 extra <<< "$ip"
    [ -n "$o4" ] && [ -z "$extra" ] || return 1
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [ -n "$o" ] || return 1
        [ "$o" -ge 0 ] 2>/dev/null && [ "$o" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}

wan_looks_configured() {
    ip -4 addr show "$INPUT_INTERFACE" 2>/dev/null | grep -q "inet " || return 1
    ip route show default 2>/dev/null | grep -q "dev $INPUT_INTERFACE" || return 1
    return 0
}

write_netplan_lan_only() {
    cat > "$NETPLAN_FILE" << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $OUTPUT_INTERFACE:
      dhcp4: false
      addresses: [$LOCAL_IP/$LOCAL_PREFIX]
      nameservers:
        addresses: [$LOCAL_IP]
      optional: true
EOF
    netplan_extra_wans >> "$NETPLAN_FILE"
}

wan_current_mode() {
    local out
    out=$(ip -4 -o addr show "$INPUT_INTERFACE" scope global 2>/dev/null)
    [ -z "$out" ] && { printf 'без адреса'; return; }
    printf '%s' "$out" | grep -q ' dynamic ' && { printf 'DHCP'; return; }
    printf 'статика'
}

wan_current_cidr() {
    ip -4 -o addr show "$INPUT_INTERFACE" scope global 2>/dev/null | awk '{print $4}' | head -1
}

ssh_session_iface() {
    local server_ip
    [ -z "$SSH_CONNECTION" ] && return 1
    server_ip=$(printf '%s' "$SSH_CONNECTION" | awk '{print $3}')
    [ -z "$server_ip" ] && return 1
    ip -o -4 addr show 2>/dev/null | awk -v want="$server_ip" '$4 ~ "^"want"/" {print $2; exit}'
}

write_netplan_static() {
    cat > "$NETPLAN_FILE" << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INPUT_INTERFACE:
      dhcp4: false
      addresses: [$sip/$mask]
      routes:
        - to: default
          via: $gw
      nameservers:
        addresses: [$d1, $d2]
    $OUTPUT_INTERFACE:
      dhcp4: false
      addresses: [$LOCAL_IP/$LOCAL_PREFIX]
      nameservers:
        addresses: [$LOCAL_IP]
      optional: true
EOF
    netplan_extra_wans >> "$NETPLAN_FILE"
}

wan_freeze_current() {
    local cidr dns
    cidr=$(ip -4 -o addr show "$INPUT_INTERFACE" scope global 2>/dev/null | awk '{print $4}' | head -1)
    [ -z "$cidr" ] && return 1
    sip=${cidr%/*}
    mask=${cidr#*/}
    valid_ipv4 "$sip" || return 1
    [ "$mask" -ge 1 ] 2>/dev/null && [ "$mask" -le 32 ] 2>/dev/null || return 1

    gw=$(ip route show default 2>/dev/null | awk -v i="$INPUT_INTERFACE" '$0 ~ ("dev " i) {for (k = 1; k <= NF; k++) if ($k == "via") print $(k + 1)}' | head -1)
    valid_ipv4 "$gw" || return 1

    dns=$(resolvectl dns "$INPUT_INTERFACE" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
    d1=$(printf '%s\n' "$dns" | sed -n 1p)
    d2=$(printf '%s\n' "$dns" | sed -n 2p)
    valid_ipv4 "$d1" || d1="1.1.1.1"
    valid_ipv4 "$d2" || d2="8.8.8.8"
    return 0
}

configure_network() {
    log_step "Настройка сети..."

    SSH_IFACE=$(ssh_session_iface) || SSH_IFACE=""
    if [ -n "$SSH_IFACE" ] && [ "$SSH_IFACE" = "$INPUT_INTERFACE" ]; then
        {
            echo ""
            echo -e "${YELLOW}[!] Вы подключены по SSH через $INPUT_INTERFACE — это и есть WAN,${NC}"
            echo -e "${YELLOW}    который сейчас будет перенастроен. Сессия оборвётся.${NC}"
            echo ""
            echo -e "${WHITE}    Варианты 3 и 4 сохраняют текущий адрес — соединение переживёт установку.${NC}"
            echo -e "${WHITE}    Для вариантов 1 и 2 установщик продолжит работу и без сессии:${NC}"
            echo -e "${WHITE}    вопросов дальше не будет, ход установки — в ${CYAN}$LOG_FILE${NC}"
            echo -e "${WHITE}    После переподключения: ${CYAN}tail -f $LOG_FILE${NC}"
            echo ""
        } >&3
    fi

    {
        echo ""
        local cur_mode cur_cidr
        cur_mode=$(wan_current_mode)
        cur_cidr=$(wan_current_cidr)

        echo -e "  Сейчас на $INPUT_INTERFACE: ${WHITE}${cur_mode}${NC}${cur_cidr:+, адрес ${WHITE}${cur_cidr}${NC}}"
        echo ""
        echo "  1) DHCP на WAN — адрес выдаёт провайдер, может меняться"
        echo "  2) Статический IP на WAN — ввести адрес, маску и шлюз вручную"
        if [ "$cur_mode" = "DHCP" ]; then
            echo -e "  3) Не трогать WAN — останется ${WHITE}DHCP${NC}, адрес продолжит меняться"
            echo -e "  4) Закрепить ${WHITE}${cur_cidr}${NC} статикой — адрес перестанет меняться"
        elif [ "$cur_mode" = "статика" ]; then
            echo -e "  3) Не трогать WAN — останется ${WHITE}статика ${cur_cidr}${NC}, настройками владеет прежний конфиг"
            echo -e "  4) Закрепить ${WHITE}${cur_cidr}${NC} статикой — то же самое, но управляет панель"
        else
            echo "  3) Не трогать WAN — оставить как настроено сейчас"
            echo "  4) Закрепить текущий адрес статикой — адреса нет, вариант не сработает"
        fi
        echo ""
        echo -e "  ${WHITE}Разница 3 и 4:${NC} третий ничего не пишет про WAN и оставляет его"
        echo "  прежнему конфигу; четвёртый переносит текущие адрес, шлюз и DNS"
        echo "  в настройки панели статикой."
        echo ""
    } >&3

    while true; do
        ask_var "Выбор [1/2/3/4]: " choice
        case "$choice" in 1|2|3|4) break ;; esac
    done

    backup_netplan

    KEEP_WAN_CONFIG=0
    if [ "$choice" == "3" ]; then
        if ! wan_looks_configured; then
            {
                echo ""
                echo -e "${YELLOW}[!] На $INPUT_INTERFACE нет IP-адреса или маршрута по умолчанию.${NC}"
                echo -e "${YELLOW}    Оставить настройки как есть не получится — интернета не будет.${NC}"
                echo ""
            } >&3
            ask_var "Настроить WAN через DHCP? [Y/n]: " fallback
            if [[ "${fallback,,}" == "n" ]]; then
                error_exit "Настройте WAN вручную и запустите установщик заново."
            fi
            choice=1
        else
            local cur_ip cur_gw
            cur_ip=$(ip -4 -o addr show "$INPUT_INTERFACE" 2>/dev/null | awk '{print $4}' | head -1)
            cur_gw=$(ip route show default 2>/dev/null | grep "dev $INPUT_INTERFACE" | grep -oP 'via \K[^ ]+' | head -1)
            KEEP_WAN_CONFIG=1
            log_info "Режим: текущие настройки WAN сохранены ($INPUT_INTERFACE $cur_ip, шлюз ${cur_gw:-нет})"
            log_info "Конфиги netplan, описывающие $INPUT_INTERFACE, оставлены как есть"
        fi
    fi

    disable_conflicting_netplan

    if [ "$choice" == "3" ]; then
        write_netplan_lan_only
    elif [ "$choice" == "1" ]; then
        log_info "Режим: DHCP"
        cat > "$NETPLAN_FILE" << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INPUT_INTERFACE:
      dhcp4: true
      dhcp-identifier: mac
      dhcp4-overrides:
        use-dns: false
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
    $OUTPUT_INTERFACE:
      dhcp4: false
      addresses: [$LOCAL_IP/$LOCAL_PREFIX]
      nameservers:
        addresses: [$LOCAL_IP]
      optional: true
EOF
        netplan_extra_wans >> "$NETPLAN_FILE"
    elif [ "$choice" == "4" ]; then
        log_info "Режим: закрепление текущего адреса"
        if ! wan_freeze_current; then
            {
                echo ""
                echo -e "${YELLOW}[!] Не удалось снять текущие настройки $INPUT_INTERFACE.${NC}"
                echo -e "${YELLOW}    Нужны адрес, маска и шлюз по умолчанию через этот интерфейс.${NC}"
                echo ""
            } >&3
            error_exit "Закрепить нечего — выберите вариант 1 или 2"
        fi
        log_info "Закрепляю: $sip/$mask, шлюз $gw, DNS $d1 $d2"
        log_warn "Адрес выдан по DHCP — сделайте резервацию на DHCP-сервере,"
        log_warn "иначе он может достаться другому устройству"
        write_netplan_static
    else
        log_info "Режим: Статический IP"
        while true; do
            ask_var "IP: " sip
            valid_ipv4 "$sip" && break
            echo -e "${YELLOW}Нужен адрес вида 192.168.1.10${NC}" >&3
        done
        while true; do
            ask_var "Маска [24]: " mask; mask=${mask:-24}
            if [ "$mask" -ge 1 ] 2>/dev/null && [ "$mask" -le 32 ] 2>/dev/null; then break; fi
            echo -e "${YELLOW}Маска — число от 1 до 32${NC}" >&3
        done
        while true; do
            ask_var "Шлюз: " gw
            valid_ipv4 "$gw" && break
            echo -e "${YELLOW}Нужен адрес вида 192.168.1.1${NC}" >&3
        done
        while true; do
            ask_var "DNS1 [1.1.1.1]: " d1; d1=${d1:-1.1.1.1}
            valid_ipv4 "$d1" && break
            echo -e "${YELLOW}Нужен адрес вида 1.1.1.1${NC}" >&3
        done
        while true; do
            ask_var "DNS2 [8.8.8.8]: " d2; d2=${d2:-8.8.8.8}
            valid_ipv4 "$d2" && break
            echo -e "${YELLOW}Нужен адрес вида 8.8.8.8${NC}" >&3
        done

        write_netplan_static
    fi

    chmod 600 "$NETPLAN_FILE"

    if [ -n "$SSH_IFACE" ] && [ "$SSH_IFACE" = "$INPUT_INTERFACE" ]; then
        trap '' HUP PIPE
        log_warn "Дальше вопросов нет — установка переживёт обрыв SSH"
    fi

    if ! netplan generate; then
        restore_disabled_netplan
        error_exit "Ошибка netplan generate — отключённые конфиги возвращены на место"
    fi
    if ! netplan apply 2>/dev/null; then
        log_warn "netplan apply завершился с ошибкой — проверьте сеть до перезагрузки"
    fi
    log_info "Сеть настроена"

    echo -ne "    Ожидание сети" >&3
    for i in {1..5}; do sleep 1; echo -n "." >&3; done
    echo "" >&3

    local wan_now
    wan_now=$(ip -o -4 addr show "$INPUT_INTERFACE" 2>/dev/null | awk '{print $4}' | head -1)
    if [ -n "$wan_now" ]; then
        log_info "Адрес $INPUT_INTERFACE: $wan_now"
    else
        log_warn "У $INPUT_INTERFACE пока нет адреса — DHCP может ещё отвечать"
    fi

    configure_dns_early
}

configure_dns_early() {
    log_step "Настройка DNS..."
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    rm -f /etc/resolv.conf
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions timeout:2 attempts:3\n' > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
    sleep 1
    log_info "DNS настроен (защищён от перезаписи)"
}

apache_installed() {
    dpkg-query -W -f='${Status}' apache2 2>/dev/null | grep -q "install ok installed"
}

apache_present() {
    dpkg-query -W -f='${Status}' apache2 2>/dev/null | grep -qE "^install "
}

drop_stale_apache_config() {
    apache_present && return 0
    [ -n "$(php_module_pkg)" ] && return 0
    [ -d /etc/apache2 ] || return 0
    log_warn "Найден /etc/apache2 от прошлой установки, а пакета нет — убираю"
    log_warn "иначе postinst apache2 споткнётся о включённые модули, которых уже нет"
    rm -rf /etc/apache2
}

apache_conffiles_present() {
    [ -f /etc/apache2/mods-available/mpm_event.load ]
}

php_module_pkg() {
    dpkg-query -W -f='${Package} ${Status}\n' 'libapache2-mod-php[0-9]*' 2>/dev/null \
        | awk '$2 == "install" { print $1; exit }'
}

php_module_conffiles_present() {
    local pkg ver
    pkg=$(php_module_pkg)
    [ -n "$pkg" ] || return 0
    ver=${pkg#libapache2-mod-php}
    [ -f "/etc/apache2/mods-available/php${ver}.load" ]
}

restore_pkg_conffiles() {
    local pkg="$1" tmpdir deb rc=1
    log_warn "Возвращаю conffiles пакета $pkg"

    timeout 900 apt-get install -y --reinstall \
        -o Dpkg::Options::="--force-confmiss" \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" "$pkg" </dev/null && rc=0

    if [ "$rc" -ne 0 ]; then
        log_warn "apt не переустанавливает полунастроенный пакет — забираю deb напрямую"
        tmpdir=$(mktemp -d /var/tmp/vpn-panel-deb.XXXXXX) || return 1
        chmod 755 "$tmpdir"
        if ( cd "$tmpdir" && timeout 300 apt-get download "$pkg" </dev/null ); then
            deb=$(find "$tmpdir" -maxdepth 1 -name '*.deb' | head -1)
            if [ -n "$deb" ]; then
                log_info "Распаковываю $(basename "$deb")"
                timeout 300 dpkg -i --force-confmiss "$deb" </dev/null || true
            fi
        else
            log_warn "Не удалось скачать deb пакета $pkg"
        fi
        rm -rf "$tmpdir"
    fi
    return 0
}

restore_apache_conffiles() {
    local php_pkg
    apt_run 300 update -qq || true

    apache_conffiles_present || restore_pkg_conffiles apache2

    php_pkg=$(php_module_pkg)
    if [ -n "$php_pkg" ] && ! php_module_conffiles_present; then
        log_warn "php-модуль установлен, но его conffiles в /etc/apache2 отсутствуют"
        restore_pkg_conffiles "$php_pkg"
    fi

    apache_conffiles_present
}

repair_apache_mpm() {
    apache_installed && return 0

    log_warn "apache2 не настроился — привожу его конфигурацию в порядок"

    mkdir -p "$WEB_DIR"
    mkdir -p /etc/apache2/mods-enabled

    rm -f /etc/apache2/mods-enabled/php*.load /etc/apache2/mods-enabled/php*.conf
    rm -f /etc/apache2/mods-enabled/mpm_*.load /etc/apache2/mods-enabled/mpm_*.conf

    if ! apache_conffiles_present || ! php_module_conffiles_present; then
        restore_apache_conffiles || true
    fi

    if ! apache_conffiles_present; then
        log_warn "mods-available/mpm_event.load так и не появился"
    fi

    if apache_installed; then
        log_info "apache2 настроился при восстановлении conffiles"
        return 0
    fi

    rm -f /etc/apache2/mods-enabled/mpm_*.load /etc/apache2/mods-enabled/mpm_*.conf
    timeout 300 dpkg --configure -a </dev/null || true

    if apache_installed; then
        log_info "apache2 настроен"
        return 0
    fi

    log_warn "Не помогло — apache2 остаётся ненастроенным"
    return 1
}

install_packages() {
    {
        echo ""
        echo -e "${CYAN}══════ УСТАНОВКА СИСТЕМНЫХ ПАКЕТОВ ══════${NC}"
        echo ""
    } >&3

    local waited=0
    while ! apt-get check >/dev/null 2>&1; do
        [ "$waited" -ge 300 ] && error_exit "APT заблокирован более 5 минут. Перезагрузите: reboot"
        [ "$waited" -eq 0 ] && log_warn "APT заблокирован, ожидание..."
        sleep 5; waited=$((waited + 5))
    done
    [ "$waited" -gt 0 ] && log_info "APT освободился (ждали ${waited}с)" || log_info "APT свободен"

    if [ -n "$(ls -A /var/lib/dpkg/updates 2>/dev/null)" ] || [ -n "$(dpkg --audit 2>&1)" ]; then
        log_warn "Пакетная база в неконсистентном состоянии — чиню"
        log_warn "dpkg --audit: $(dpkg --audit 2>&1 | head -3 | tr '\n' ' ')"
        timeout 300 dpkg --configure -a --force-confdef --force-confold </dev/null || true
        timeout 300 apt-get -f install -y </dev/null || true
        if [ -n "$(dpkg --audit 2>&1)" ]; then
            log_warn "После ремонта dpkg всё ещё жалуется — установка может не пройти"
        else
            log_info "Пакетная база приведена в порядок"
        fi
    fi

    log_step "Обновление списка пакетов..."
    local i
    for i in 1 2 3; do
        apt_run 300 update -qq && break
        [ "$i" -eq 3 ] && error_exit "Не удалось обновить список пакетов"
        rm -rf /var/lib/apt/lists/partial/* 2>/dev/null
        rm -f /var/lib/apt/lists/lock 2>/dev/null
        sleep 3
    done
    log_info "Список пакетов обновлён"

    log_step "Обновление системы..."
    apt_run 1800 upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"
    log_info "Система обновлена"

    log_step "Установка ${#PACKAGES_TO_INSTALL[@]} пакетов..."
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
    echo "postfix postfix/main_mailer_type string 'No configuration'" | debconf-set-selections

    chattr -i /etc/resolv.conf 2>/dev/null || true
    local apt_opts=(-y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")

    mkdir -p "$WEB_DIR"

    drop_stale_apache_config
    log_step "Ставлю apache2 отдельно, до php..."
    apt_run 900 install "${apt_opts[@]}" apache2 || log_warn "apache2 отдельным заходом не встал — пробую вместе со всеми"
    apache_installed || repair_apache_mpm || true

    log_step "Ставлю остальные пакеты..."
    if ! apt_run 1800 install "${apt_opts[@]}" "${PACKAGES_TO_INSTALL[@]}"; then
        log_warn "Первая попытка не удалась, пробуем восстановиться..."
        timeout 300 dpkg --configure -a --force-confdef --force-confold </dev/null || true
        apt_run 600 -f install -y || true
        apache_installed || repair_apache_mpm || true
        apt-get clean
        apt_run 300 update -qq || true
        apt_run 1800 install "${apt_opts[@]}" "${PACKAGES_TO_INSTALL[@]}" || true
    fi

    apache_installed || repair_apache_mpm || true
    chattr +i /etc/resolv.conf 2>/dev/null || true

    local missing=()
    for pkg in "${PACKAGES_TO_INSTALL[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" || missing+=("$pkg")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        local why
        why=$(timeout 300 apt-get install -y "${missing[@]}" </dev/null 2>&1 | grep -vE '^(Reading|Building|Selecting|Preparing|Unpacking|Setting up|Processing) ' | tail -20)
        {
            echo ""
            echo -e "${RED}[✗] Не удалось поставить: ${missing[*]}${NC}"
            echo ""
            echo -e "${WHITE}Что ответил apt:${NC}"
            printf '%s\n' "$why" | sed 's/^/    /'
            echo ""
            echo -e "${WHITE}Дальше вручную:${NC}"
            echo -e "    ${CYAN}dpkg --configure -a${NC}"
            echo -e "    ${CYAN}apt-get -f install -y${NC}"
            echo -e "    ${CYAN}apt-get install -y ${missing[*]}${NC}"
            echo ""
        } >&3
        error_exit "Не установлены: ${missing[*]}"
    fi
    log_info "Все ${#PACKAGES_TO_INSTALL[@]} пакетов установлены"
}

configure_dhcp() {
    log_step "Настройка DHCP..."

    [ -f /etc/dnsmasq.conf ] && cp /etc/dnsmasq.conf /etc/dnsmasq.conf.original.backup

    cat > /etc/dnsmasq.conf << EOF
# VPN Panel DHCP v$SCRIPT_VERSION
dhcp-authoritative
domain=vpn-panel.lan
interface=$OUTPUT_INTERFACE
bind-dynamic
listen-address=127.0.0.1,$LOCAL_IP
dhcp-range=$DHCP_RANGE_START,$DHCP_RANGE_END,$LOCAL_MASK,72h
server=1.1.1.1
server=8.8.8.8
# Ліміти для 400+ LAN пристроїв (default dns-forward-max=150, dhcp-lease-max=1000 — замало).
# При 400 пристроях × 10 паралельних DNS = 4000 baseline → 8192 з запасом.
# dhcp-lease-max=2000 — буфер для гостьових пристроїв і колізій.
# cache-size=50000 — більший DNS-кеш для 400 пристроїв.
dns-forward-max=8192
dhcp-lease-max=2000
cache-size=50000
min-cache-ttl=60
neg-ttl=60
EOF

    local waited=0
    while ! ip addr show "$OUTPUT_INTERFACE" 2>/dev/null | grep -q "$LOCAL_IP"; do
        if [ "$waited" -ge 15 ]; then
            log_warn "Інтерфейс $OUTPUT_INTERFACE не отримав IP $LOCAL_IP за 15с — пробуємо підняти вручну..."
            ip link set "$OUTPUT_INTERFACE" up 2>/dev/null || true
            ip addr add "$LOCAL_IP/$LOCAL_PREFIX" dev "$OUTPUT_INTERFACE" 2>/dev/null || true
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    systemctl restart dnsmasq || { systemctl status dnsmasq --no-pager; error_exit "Ошибка dnsmasq"; }
    systemctl enable dnsmasq
    log_info "DHCP настроен ($DHCP_RANGE_START - $DHCP_RANGE_END)"
}

configure_resolvconf() {
    log_step "Настройка resolvconf..."
    chattr -i /etc/resolv.conf 2>/dev/null || true
    dpkg --configure resolvconf 2>/dev/null || true
    mkdir -p /etc/resolvconf/resolv.conf.d
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolvconf/resolv.conf.d/base
    printf '# VPN Panel DNS\nnameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolvconf/resolv.conf.d/head
    resolvconf -u 2>/dev/null || true
    chattr +i /etc/resolv.conf 2>/dev/null || true
    log_info "resolvconf настроен"
}

configure_firewall() {
    log_step "Настройка файрвола + Kill Switch..."

    sed -i '/^#.*net.ipv4.ip_forward/s/^#//' /etc/sysctl.conf
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    grep -q "^net.netfilter.nf_conntrack_max" /etc/sysctl.conf || echo "net.netfilter.nf_conntrack_max=524288" >> /etc/sysctl.conf
    grep -q "^net.netfilter.nf_conntrack_udp_timeout=" /etc/sysctl.conf || echo "net.netfilter.nf_conntrack_udp_timeout=30" >> /etc/sysctl.conf
    grep -q "^net.netfilter.nf_conntrack_udp_timeout_stream" /etc/sysctl.conf || echo "net.netfilter.nf_conntrack_udp_timeout_stream=120" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1

    modprobe -r nf_conntrack_sip 2>/dev/null || true
    modprobe -r nf_nat_sip 2>/dev/null || true
    cat > /etc/modprobe.d/no-sip-alg.conf << 'EOF'
# VPN Panel — отключение SIP ALG для корректной работы VOIP за NAT
blacklist nf_conntrack_sip
blacklist nf_nat_sip
EOF

    iptables -F
    iptables -t nat -F
    iptables -X 2>/dev/null || true

    iptables -P FORWARD DROP

    iptables -A FORWARD -i "$OUTPUT_INTERFACE" -o tun0 -j ACCEPT
    iptables -A FORWARD -i tun0 -o "$OUTPUT_INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i "$OUTPUT_INTERFACE" -o "$OUTPUT_INTERFACE" -j ACCEPT

    local wan_if
    for wan_if in ${WAN_INTERFACES:-$INPUT_INTERFACE}; do
        iptables -A FORWARD -i "$OUTPUT_INTERFACE" -o "$wan_if" -j REJECT --reject-with icmp-net-unreachable
    done

    iptables -t nat -A POSTROUTING -o tun0 -s "$LOCAL_NET" -j MASQUERADE

    iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    iptables -A INPUT -i "$OUTPUT_INTERFACE" -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -i "$OUTPUT_INTERFACE" -p tcp --dport 80 -j ACCEPT

    iptables -A INPUT -p tcp --dport 80 -m state --state NEW -m recent --set --name HTTP
    iptables -A INPUT -p tcp --dport 80 -m state --state NEW -m recent --update --seconds 60 --hitcount 60 --name HTTP -j DROP
    iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 10 --name SSH -j DROP
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -i "$OUTPUT_INTERFACE" -p udp --dport 53 -j ACCEPT
    iptables -A INPUT -i "$OUTPUT_INTERFACE" -p tcp --dport 53 -j ACCEPT
    iptables -A INPUT -i "$OUTPUT_INTERFACE" -p udp --dport 67 -j ACCEPT

    iptables-save > /etc/iptables/rules.v4
    log_info "Kill Switch активен (LAN→WAN заблоковано, LAN→VPN дозволено, rate limit HTTP/SSH)"
}

configure_pam() {
    log_step "Налаштування PAM faillock (м'які ліміти для LAN)..."

    if [ -f /etc/security/faillock.conf ]; then
        [ ! -f /etc/security/faillock.conf.vpn-panel-backup ] && \
            cp /etc/security/faillock.conf /etc/security/faillock.conf.vpn-panel-backup

        for setting in "deny=30" "unlock_time=60" "fail_interval=900"; do
            key="${setting%%=*}"
            if grep -qE "^[#[:space:]]*${key}[[:space:]]*=" /etc/security/faillock.conf; then
                sed -i "s|^[#[:space:]]*${key}[[:space:]]*=.*|${setting}|" /etc/security/faillock.conf
            else
                echo "${setting}" >> /etc/security/faillock.conf
            fi
        done
        log_info "/etc/security/faillock.conf: deny=30, unlock_time=60, fail_interval=900"
    fi

    pam_disabled=0
    for pam_file in /etc/pam.d/common-auth /etc/pam.d/common-account /etc/pam.d/sshd; do
        [ -f "$pam_file" ] || continue
        if grep -qE "^[[:space:]]*[^#].*pam_faillock\.so" "$pam_file"; then
            sed -i 's|^\([[:space:]]*[^#].*pam_faillock\.so.*\)|# VPN Panel disabled: \1|' "$pam_file"
            log_info "Закоментовано pam_faillock у $pam_file"
            pam_disabled=1
        fi
    done

    [ "$pam_disabled" = "0" ] && log_info "pam_faillock не активний у PAM (тільки faillock.conf оновлено)"
}

configure_ssh() {
    log_step "Настройка SSH..."
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
    systemctl restart sshd
    log_info "SSH настроен"
}

configure_vpn() {
    log_step "Настройка VPN..."

    sed -i 's/^AUTOSTART=.*/AUTOSTART="none"/' /etc/default/openvpn 2>/dev/null || true

    chown -R root:www-data /etc/wireguard /etc/openvpn
    chmod 770 /etc/wireguard /etc/openvpn
    chmod g+s /etc/wireguard /etc/openvpn
    find /etc/wireguard /etc/openvpn -type f -exec chmod 660 {} \; 2>/dev/null

    mkdir -p "$VPN_CONFIGS_DIR"
    chown root:www-data "$VPN_CONFIGS_DIR"
    chmod 770 "$VPN_CONFIGS_DIR"

    log_info "VPN настроен (WireGuard + OpenVPN)"
}

panel_source_local() {
    local self here candidate
    self="${BASH_SOURCE[0]}"
    [ -f "$self" ] || return 1
    here=$(cd "$(dirname "$self")" 2>/dev/null && pwd) || return 1
    for candidate in "$here/../panel" "$here/panel"; do
        [ -f "$candidate/cabinet.php" ] && { (cd "$candidate" && pwd); return 0; }
    done
    return 1
}

fetch_sources() {
    log_step "Получение кода панели..."

    local local_src=""
    local_src=$(panel_source_local) || local_src=""

    if [ -n "$local_src" ]; then
        PANEL_SRC="$local_src"
        INSTALL_SOURCE="local"
        log_info "Код панели лежит рядом с установщиком: $PANEL_SRC"
        return 0
    fi

    if printf '%s' "$GIT_REPO" | grep -q "OWNER/REPO"; then
        {
            echo ""
            echo -e "${RED}[✗] Не задан репозиторий панели.${NC}"
            echo -e "    В install.sh переменная GIT_REPO всё ещё содержит заглушку OWNER/REPO."
            echo ""
            echo -e "${WHITE}Варианты:${NC}"
            echo -e "  • скопировать на сервер весь каталог проекта и запустить"
            echo -e "    ${CYAN}sudo bash installer/install.sh${NC} — панель возьмётся из соседней папки panel/"
            echo -e "  • либо прописать реальный адрес в GIT_REPO и запустить снова"
            echo ""
        } >&3
        error_exit "Установка остановлена: неоткуда взять код панели"
    fi

    if ! command -v git >/dev/null 2>&1; then
        log_info "git ещё не установлен — ставлю его первым"
        apt_run 300 install -y -qq git >/dev/null 2>&1 || \
            error_exit "Не удалось поставить git — скачать код панели нечем"
    fi

    mkdir -p "$(dirname "$SRC_DIR")"
    [ -d "$SRC_DIR" ] && rm -rf "$SRC_DIR"
    log_info "Клонирую $GIT_REPO -> $SRC_DIR"
    git clone --quiet "$GIT_REPO" "$SRC_DIR" || error_exit "Ошибка git clone $GIT_REPO"

    PANEL_SRC="$SRC_DIR"
    [ -f "$SRC_DIR/panel/cabinet.php" ] && PANEL_SRC="$SRC_DIR/panel"
    [ -f "$PANEL_SRC/cabinet.php" ] || error_exit "В репозитории нет кода панели (cabinet.php)"
    INSTALL_SOURCE="git"
    log_info "Код получен до того, как менялись сетевые настройки"
    return 0
}

install_web_panel() {
    log_step "Установка веб-панели..."

    [ -n "$PANEL_SRC" ] || error_exit "Код панели не получен — шаг fetch_sources не отработал"
    [ -f "$PANEL_SRC/cabinet.php" ] || error_exit "В $PANEL_SRC нет cabinet.php"

    [ -d "$WEB_DIR" ] && rm -rf "$WEB_DIR"
    mkdir -p "$WEB_DIR"
    log_info "Разворачиваю панель из $PANEL_SRC"
    cp -a "$PANEL_SRC/." "$WEB_DIR"/ || error_exit "Не удалось скопировать панель из $PANEL_SRC"

    rm -rf "$WEB_DIR/.git" "$WEB_DIR/.github"

    chown -R www-data:www-data "$WEB_DIR"
    chmod -R 755 "$WEB_DIR"

    cat > /etc/sudoers.d/vpn-panel-www-data << 'EOF'
# VPN Panel Web Panel — мінімальні права для www-data
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
# Мережа
www-data ALL=(ALL) NOPASSWD: /usr/local/sbin/vpn-panel-routing status
www-data ALL=(ALL) NOPASSWD: /usr/local/sbin/vpn-panel-routing free
www-data ALL=(ALL) NOPASSWD: /usr/local/sbin/vpn-panel-routing apply
www-data ALL=(ALL) NOPASSWD: /usr/local/sbin/vpn-panel-routing set-active *
www-data ALL=(ALL) NOPASSWD: /usr/local/sbin/vpn-panel-routing set-primary *
www-data ALL=(ALL) NOPASSWD: /usr/local/sbin/vpn-panel-routing move-wan *
www-data ALL=(ALL) NOPASSWD: /usr/local/sbin/vpn-panel-routing add-wan *
www-data ALL=(ALL) NOPASSWD: /usr/local/sbin/vpn-panel-routing remove-wan *
www-data ALL=(ALL) NOPASSWD: /usr/sbin/netplan apply
# Управління сервером (settings.php → секція "Управление сервером")
www-data ALL=(ALL) NOPASSWD: /bin/systemctl reboot
www-data ALL=(ALL) NOPASSWD: /bin/systemctl poweroff
# Перевірка пароля root (login.php)
EOF
    chmod 440 /etc/sudoers.d/vpn-panel-www-data
    visudo -c -f /etc/sudoers.d/vpn-panel-www-data || log_warn "Помилка в sudoers!"

    chown root:www-data "$NETPLAN_FILE" 2>/dev/null || true
    chmod 660 "$NETPLAN_FILE" 2>/dev/null || true

    a2enmod headers expires rewrite deflate 2>/dev/null || true
    if ! grep -q 'AllowOverride All' /etc/apache2/apache2.conf 2>/dev/null; then
        sed -i 's|AllowOverride None|AllowOverride All|g' /etc/apache2/apache2.conf 2>/dev/null || true
    fi
    sed -i 's/ServerTokens OS/ServerTokens Prod/' /etc/apache2/conf-enabled/security.conf 2>/dev/null || true
    sed -i 's/ServerSignature On/ServerSignature Off/' /etc/apache2/conf-enabled/security.conf 2>/dev/null || true

    systemctl enable apache2
    systemctl start apache2 || log_warn "Ошибка запуска apache2"

    mkdir -p /var/log/vpn-panel
    chmod 755 /var/log/vpn-panel
    touch /var/log/vpn-panel/events.log
    chmod 666 /var/log/vpn-panel/events.log
    touch /var/log/vpn-panel/vpn.log
    chmod 644 /var/log/vpn-panel/vpn.log

    log_info "Веб-панель установлена из репозитория"
}

configure_settings() {
    log_step "Создание настроек..."
    mkdir -p /var/www
    echo -e "vpnchecker=true\nautoupvpn=true\nfailover=true\nfailover_first=false\nwan_failover=true\nwan_return=true" > "$SETTINGS_FILE"
    chmod 666 "$SETTINGS_FILE"
    echo -e "STATE=stopped\nACTIVE_ID=\nPRIMARY_ID=\nACTIVATED_BY=" > /var/www/vpn-state
    chmod 666 /var/www/vpn-state
    log_info "Настройки созданы"
}

configure_routing() {
    log_step "Настройка маршрутизации каналов..."

    if [ ! -f "$WEB_DIR/vpn-panel-routing.sh" ]; then
        log_warn "vpn-panel-routing.sh не найден в $WEB_DIR — многоканальность недоступна"
        return 0
    fi

    chown root:root "$WEB_DIR/vpn-panel-routing.sh"
    chmod 755 "$WEB_DIR/vpn-panel-routing.sh"
    ln -sf "$WEB_DIR/vpn-panel-routing.sh" /usr/local/sbin/vpn-panel-routing

    cat > /etc/systemd/system/vpn-panel-routing.service << EOF
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
EOF

    systemctl daemon-reload
    systemctl enable vpn-panel-routing.service >/dev/null 2>&1 || true

    local wan_count
    wan_count=$(printf '%s\n' ${WAN_INTERFACES:-$INPUT_INTERFACE} | wc -l)
    if [ "$wan_count" -le 1 ]; then
        log_info "Канал один — policy routing не требуется, правила применены на будущее"
    else
        log_info "Каналов: $wan_count — таблицы 101..$((100 + wan_count))"
    fi
    return 0
}

configure_vpn_monitor() {
    log_step "Установка мониторинга VPN..."

    mkdir -p /var/log/vpn-panel

    if [ ! -f "$WEB_DIR/vpn-healthcheck.sh" ]; then
        log_warn "vpn-healthcheck.sh не найден в $WEB_DIR — monitor не установлен"
        return 0
    fi

    chown root:root "$WEB_DIR/vpn-healthcheck.sh"
    chmod 755 "$WEB_DIR/vpn-healthcheck.sh"

    systemctl stop vpn-healthcheck.timer vpn-healthcheck.service 2>/dev/null || true
    systemctl disable vpn-healthcheck.timer vpn-healthcheck.service 2>/dev/null || true
    rm -f /etc/systemd/system/vpn-healthcheck.service /etc/systemd/system/vpn-healthcheck.timer

    rm -f /usr/local/bin/vpn-healthcheck.sh

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

    mkdir -p /var/lib/vpn-panel
    md5sum "$WEB_DIR/vpn-healthcheck.sh" 2>/dev/null | cut -d' ' -f1 > /var/lib/vpn-panel/hc.md5

    systemctl daemon-reload
    systemctl enable --now vpn-healthcheck.service
    log_info "Мониторинг VPN установлен (daemon, ExecStart=$WEB_DIR/vpn-healthcheck.sh)"
}

configure_shellinabox() {
    log_step "Налаштування shellinabox (веб-термінал)..."

    if ! dpkg -l shellinabox 2>/dev/null | grep -q "^ii"; then
        apt_run 300 install -y -qq shellinabox || {
            log_warn "shellinabox не встановлено — термінал недоступний"
            return 0
        }
    fi

    mkdir -p /etc/shellinabox
    if [ -f "$WEB_DIR/assets/css/shellinabox-theme.css" ]; then
        cp "$WEB_DIR/assets/css/shellinabox-theme.css" /etc/shellinabox/mine-theme.css
        chmod 644 /etc/shellinabox/mine-theme.css
    else
        log_warn "shellinabox-theme.css відсутній в репо — термінал буде зі стандартною темою shellinabox"
    fi

    cat > /etc/default/shellinabox << 'EOF'
# VPN Panel — shellinabox конфіг
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

    if systemctl is-active --quiet shellinabox; then
        log_info "shellinabox запущено (127.0.0.1:4200)"
    else
        log_warn "shellinabox не запустився"
    fi
}

configure_auto_update() {
    log_step "Настройка автообновления..."

    if [ -f "$WEB_DIR/vpn-panel-deploy.sh" ]; then
        chown root:root "$WEB_DIR/vpn-panel-deploy.sh"
        chmod 755 "$WEB_DIR/vpn-panel-deploy.sh"
        ln -sf "$WEB_DIR/vpn-panel-deploy.sh" /usr/local/sbin/vpn-panel-deploy
    else
        log_warn "vpn-panel-deploy.sh не найден — автообновление не настроено"
        return 0
    fi

    rm -f /usr/local/bin/vpn-panel-update.sh /usr/local/bin/run-update.sh

    if printf '%s' "$GIT_REPO" | grep -q "OWNER/REPO"; then
        log_warn "Репозиторий не настроен — cron автообновления не добавлен"
        log_warn "После настройки REPO_URL: sudo vpn-panel-deploy check"
        return 0
    fi

    (crontab -l 2>/dev/null | grep -vE "(run-update|vpn-panel-update|vpn-panel-deploy)";      echo "0 * * * * /usr/local/sbin/vpn-panel-deploy auto >> /var/log/vpn-panel/update.log 2>&1") | crontab -

    log_info "Автообновление: ежечасно + случайная задержка до 10 мин, релиз берётся из release.conf"
}

finalize() {
    log_step "Финализация..."

    CONF_REPO_URL=""
    if printf '%s' "$GIT_REPO" | grep -q "OWNER/REPO"; then
        log_warn "GIT_REPO не настроен — автообновление выключено до тех пор,"
        log_warn "пока в /etc/vpn-panel.conf не появится REPO_URL"
    else
        CONF_REPO_URL="$GIT_REPO"
    fi

    echo "$SCRIPT_VERSION" > "$VERSION_FILE"

    cat > /etc/vpn-panel.conf << EOF
VERSION=$SCRIPT_VERSION
REPO_URL=$CONF_REPO_URL
CHANNEL=stable
DATE=$(date '+%Y-%m-%d %H:%M:%S')
WAN=$INPUT_INTERFACE
WAN_LIST=${WAN_INTERFACES:-$INPUT_INTERFACE}
LAN=$OUTPUT_INTERFACE
LAN_IP=$LOCAL_IP
LAN_NET=$LOCAL_NET
LAN_PREFIX=$LOCAL_PREFIX
LAN_MASK=$LOCAL_MASK
DHCP_FROM=$DHCP_RANGE_START
DHCP_TO=$DHCP_RANGE_END
PANEL_TITLE=
EOF

    if [ -x /usr/local/sbin/vpn-panel-routing ]; then
        /usr/local/sbin/vpn-panel-routing apply >/dev/null 2>&1             && log_info "Правила маршрутизации применены"             || log_warn "Не удалось применить правила маршрутизации (проверьте vpn-panel-routing status)"
    fi

    log_info "Версия $SCRIPT_VERSION сохранена"
}

verify_services() {
    {
        echo ""
        echo -e "${CYAN}══════ ПРОВЕРКА СЕРВИСОВ ══════${NC}"
        echo ""
    } >&3

    local svc
    for svc in apache2 dnsmasq ssh vpn-healthcheck.service shellinabox; do
        echo -n "    ${svc}: " >&3
        if systemctl is-active --quiet "$svc"; then
            echo -e "${GREEN}● активен${NC}" >&3
        else
            echo -e "${YELLOW}○ не активен${NC} — пробую старт..." >&3
            systemctl start "$svc" 2>/dev/null
        fi
    done

    echo "" >&3
    echo "    Интерфейсы:" >&3
    local pair iface role addr
    for pair in "$INPUT_INTERFACE:WAN" "$OUTPUT_INTERFACE:LAN"; do
        iface="${pair%%:*}"; role="${pair##*:}"
        echo -n "      $iface ($role): " >&3
        if ip link show "$iface" 2>/dev/null | grep -q "state UP"; then
            addr=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
            echo -e "${GREEN}● UP${NC} ($addr)" >&3
        else
            echo -e "${RED}○ DOWN${NC}" >&3
        fi
    done

    echo "" >&3
    echo -n "    Веб-панель (http://$LOCAL_IP/): " >&3
    if curl -s -o /dev/null -w "%{http_code}" "http://$LOCAL_IP/" 2>/dev/null | grep -q "200\|302"; then
        echo -e "${GREEN}● доступна${NC}" >&3
    else
        echo -e "${YELLOW}○ проверьте вручную${NC}" >&3
    fi
    echo "" >&3
}

full_install() {
    echo "" >&3
    echo -e "${GREEN}═══ УСТАНОВКА VPN PANEL v${SCRIPT_VERSION} ═══${NC}" >&3
    echo "" >&3

    local steps=(
        "check_os"
        "check_internet"
        "check_packages"
        "fetch_sources"
        "select_interfaces"
        "configure_network"
        "check_internet"
        "install_packages"
        "configure_resolvconf"
        "configure_dhcp"
        "configure_firewall"
        "configure_pam"
        "configure_ssh"
        "configure_vpn"
        "install_web_panel"
        "configure_settings"
        "configure_routing"
        "configure_vpn_monitor"
        "configure_shellinabox"
        "configure_auto_update"
        "finalize"
    )

    local total=${#steps[@]}
    for i in "${!steps[@]}"; do
        local n=$((i + 1))
        {
            echo ""
            echo -e "${WHITE}[${n}/${total}] ${steps[$i]}${NC}"
            echo "────────────────────────────────────────"
        } >&3
        ${steps[$i]}
    done

    verify_services

    {
        echo ""
    echo -e "${GREEN}╔═════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         УСТАНОВКА ЗАВЕРШЕНА!                        ║${NC}"
    echo -e "${GREEN}╚═════════════════════════════════════════════════════╝${NC}"
    echo ""
        echo -e "  ${WHITE}Панель:${NC}  http://$LOCAL_IP/"
        echo -e "  ${WHITE}Логин:${NC}   пароль root"
        echo -e "  ${WHITE}Сеть:${NC}    $LOCAL_NET"
        echo -e "  ${WHITE}Логи:${NC}    /var/log/vpn-panel/"
        echo -e "  ${WHITE}Лог установки:${NC} $LOG_FILE"
        echo ""
        echo -e "  ${YELLOW}Рекомендуется:${NC} ${WHITE}reboot${NC}"
        echo ""
    } >&3
}

do_remove() {
    local mode="${1:-full}"

    if [ "$mode" = "full" ]; then
        {
            echo ""
            echo -e "${RED}═══ ПОЛНОЕ УДАЛЕНИЕ ═══${NC}"
            echo ""
            echo -e "${YELLOW}Будет удалено:${NC} веб-панель, VPN-конфиги, DHCP, DNS, Firewall, пакеты, логи"
            echo -e "${RED}ЭТО НЕОБРАТИМО!${NC}"
            echo ""
        } >&3
        ask_var "Введите 'DELETE ALL': " confirm
        [ "$confirm" != "DELETE ALL" ] && { echo "Отменено" >&3; return; }
        log_step "Остановка служб..."
    else
        log_step "Удаление старой установки..."
    fi

    systemctl stop vpn-healthcheck.service openvpn@tun0 wg-quick@tun0 dnsmasq apache2 shellinabox 2>/dev/null || true
    systemctl disable vpn-healthcheck.service shellinabox 2>/dev/null || true
    [ "$mode" = "full" ] && { systemctl disable dnsmasq apache2 2>/dev/null || true; }
    chattr -i /etc/resolv.conf 2>/dev/null || true

    rm -rf "$WEB_DIR" "$VPN_CONFIGS_DIR"
    mkdir -p "$WEB_DIR"
    if [ -d /var/log/vpn-panel ]; then
        find /var/log/vpn-panel -mindepth 1 ! -name 'install.log' -exec rm -rf {} + 2>/dev/null || true
    fi
    rm -f "$VERSION_FILE" "$SETTINGS_FILE" /etc/vpn-panel.conf
    rm -f /etc/sudoers.d/vpn-panel-www-data
    rm -f /usr/local/bin/vpn-healthcheck.sh /usr/local/bin/run-update.sh /usr/local/bin/vpn-panel-update.sh
    systemctl stop vpn-panel-routing.service 2>/dev/null || true
    systemctl disable vpn-panel-routing.service 2>/dev/null || true
    rm -f /etc/systemd/system/vpn-panel-routing.service
    systemctl daemon-reload 2>/dev/null || true
    rm -f /usr/local/sbin/vpn-panel-deploy /usr/local/sbin/vpn-panel-routing
    rm -rf /opt/vpn-panel
    rm -f /etc/systemd/system/vpn-healthcheck.*
    rm -f /var/run/vpn-panel-*.state /var/run/vpn-panel-*.state.tmp /var/run/vpn-panel-*.pid
    rm -f /var/www/vpn-state /var/www/vpn-state.tmp /var/www/shell-token
    rm -f /etc/openvpn/*.conf /etc/wireguard/*.conf
    a2disconf vpn-panel-shell 2>/dev/null || true
    rm -f /etc/apache2/conf-available/vpn-panel-shell.conf

    crontab -l 2>/dev/null | grep -vE "(run-update|vpn-panel-update|vpn-panel-deploy)" | crontab - 2>/dev/null || true

    iptables -F; iptables -t nat -F; iptables -X 2>/dev/null || true
    iptables -P FORWARD ACCEPT
    if [ "$mode" = "full" ]; then
        iptables -t mangle -F 2>/dev/null || true
        iptables -P INPUT ACCEPT; iptables -P OUTPUT ACCEPT
        [ -d /etc/iptables ] && { echo "" > /etc/iptables/rules.v4 2>/dev/null || true; }
    else
        [ -d /etc/iptables ] && { iptables-save > /etc/iptables/rules.v4 2>/dev/null || true; }
    fi

    if [ "$mode" = "full" ]; then
        rm -f "$NETPLAN_FILE" "$NETPLAN_LEGACY" /etc/dnsmasq.conf

        for f in /etc/netplan/*.disabled-by-vpn-panel; do
            [ -e "$f" ] || continue
            mv "$f" "${f%.disabled-by-vpn-panel}"
            log_info "Восстановлен netplan-файл: $(basename "${f%.disabled-by-vpn-panel}")"
        done

        [ -f /etc/dnsmasq.conf.original.backup ] && mv /etc/dnsmasq.conf.original.backup /etc/dnsmasq.conf

        log_step "Возврат сети к исходной конфигурации..."
        netplan apply 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            ip route show default 2>/dev/null | grep -q . && break
            sleep 1
        done
        log_info "Маршрут по умолчанию: $(ip route show default 2>/dev/null | head -1 | cut -c1-60)"

        log_step "Восстановление DNS..."
        systemctl unmask systemd-resolved 2>/dev/null || true
        systemctl enable --now systemd-resolved 2>/dev/null || true
        rm -f /etc/resolv.conf
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true

        log_step "Удаление пакетов..."
        apt_run 900 purge -y -qq \
            apache2 libapache2-mod-php \
            php php-yaml php-mbstring \
            dnsmasq iptables-persistent netfilter-persistent \
            resolvconf shellinabox 2>/dev/null || true
        apt_run 600 autoremove -y -qq 2>/dev/null || true
        apt_run 300 autoclean -y -qq 2>/dev/null || true
        rm -rf /etc/apache2 /var/log/apache2

        rm -f /etc/resolv.conf
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true

        local fallback_iface
        fallback_iface=$(ip -o link show 2>/dev/null | awk -F': ' '$2 != "lo" {print $2; exit}')
        [ -z "$fallback_iface" ] && fallback_iface="eth0"
        if [ -z "$(ls -A /etc/netplan/ 2>/dev/null)" ]; then
            cat > /etc/netplan/00-default.yaml << NETPLAN_EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $fallback_iface:
      dhcp4: true
      dhcp-identifier: mac
NETPLAN_EOF
            chmod 600 /etc/netplan/00-default.yaml
            log_warn "Создан базовый netplan для $fallback_iface"
        fi
        netplan apply 2>/dev/null || true
    fi

    timeout 120 dpkg --configure -a </dev/null >/dev/null 2>&1 || true
    systemctl daemon-reload

    if [ "$mode" = "full" ]; then
        {
            echo ""
            echo -e "${GREEN}══════ ПОЛНОЕ УДАЛЕНИЕ ЗАВЕРШЕНО ══════${NC}"
            echo ""
            echo -e "  ${YELLOW}Не удалены:${NC} openvpn, wireguard (могут использоваться)"
            echo -e "  Для их удаления: ${WHITE}apt purge openvpn wireguard${NC}"
            echo -e "  ${CYAN}Рекомендуется:${NC} ${WHITE}reboot${NC}"
            echo ""
        } >&3
    else
        log_info "Удалено"
    fi
}

full_remove_silent() { do_remove silent; }
full_remove()        { do_remove full; }

update_installation() {
    echo "" >&3
    echo -e "${YELLOW}═══ ОБНОВЛЕНИЕ ═══${NC}" >&3
    echo "" >&3

    if [ ! -x /usr/local/sbin/vpn-panel-deploy ]; then
        log_warn "vpn-panel-deploy не установлен — переустановите панель"
        return 1
    fi

    log_step "Обновление веб-панели..."
    if /usr/local/sbin/vpn-panel-deploy deploy >&3 2>&4; then
        log_info "Обновлено"
    else
        log_error "Обновление не удалось — панель откачена на предыдущую версию"
        return 1
    fi
}

main_menu() {
    check_root
    show_banner

    local installed=false ver="0"
    [ -d "$WEB_DIR" ] && [ -f "$WEB_DIR/cabinet.php" ] && installed=true
    [ -f "$VERSION_FILE" ] && ver=$(cat "$VERSION_FILE")

    echo "" >&3
    if $installed; then
        local rel=""
        [ -f /var/lib/vpn-panel/deployed ] && rel=$(awk '{print $1}' /var/lib/vpn-panel/deployed 2>/dev/null)
        if [ -n "$rel" ]; then
            echo -e "    ${WHITE}Статус:${NC} ${GREEN}● УСТАНОВЛЕН${NC}  выпуск ${WHITE}${rel}${NC}, схема ${WHITE}v${ver}${NC}" >&3
        else
            echo -e "    ${WHITE}Статус:${NC} ${GREEN}● УСТАНОВЛЕН${NC}  схема ${WHITE}v${ver}${NC}" >&3
        fi
        ip link show tun0 &>/dev/null && echo -e "    ${WHITE}VPN:${NC}    ${GREEN}● Активен${NC}" >&3
    else
        echo -e "    ${WHITE}Статус:${NC} ${RED}○ НЕ УСТАНОВЛЕН${NC}" >&3
    fi

    {
        echo ""
        echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"
        echo ""
    } >&3

    if ! $installed; then
        {
            echo -e "    ${GREEN}1)${NC} Установить"
            echo -e "    ${CYAN}2)${NC} Выход"
            echo ""
        } >&3
        while true; do
            ask_var "    Выбор [1/2]: " c
            case "$c" in
                1) full_remove_silent && full_install; break ;;
                2) exit 0 ;;
            esac
        done
    else
        {
            echo -e "    ${GREEN}1)${NC} Переустановить"
            echo -e "    ${YELLOW}2)${NC} Обновить панель"
            echo -e "    ${RED}3)${NC} Полное удаление"
            echo -e "    ${CYAN}4)${NC} Выход"
            echo ""
        } >&3
        while true; do
            ask_var "    Выбор [1/4]: " c
            case "$c" in
                1) full_remove_silent && full_install; break ;;
                2) update_installation; break ;;
                3) full_remove; break ;;
                4) exit 0 ;;
            esac
        done
    fi
}

main_menu
