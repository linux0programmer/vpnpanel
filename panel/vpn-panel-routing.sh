#!/bin/bash

CONF="/etc/vpn-panel.conf"
NETPLAN_FILE="/etc/netplan/99-vpn-panel.yaml"
TABLE_BASE=100
RULE_PRIO_BASE=1000
PING_HOSTS=("8.8.8.8" "1.1.1.1" "9.9.9.9")
PING_TIMEOUT=2

conf_get() {
    [ -f "$CONF" ] || return 1
    grep "^$1=" "$CONF" 2>/dev/null | head -1 | cut -d= -f2-
}

conf_set() {
    local key="$1" value="$2"
    [ -f "$CONF" ] || return 1
    if grep -q "^$key=" "$CONF"; then
        sed -i "s|^$key=.*|$key=$value|" "$CONF"
    else
        printf '%s=%s\n' "$key" "$value" >> "$CONF"
    fi
}

safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

wan_list() {
    local list
    list=$(conf_get WAN_LIST)
    [ -z "$list" ] && list=$(conf_get WAN)
    printf '%s' "$list"
}

iface_exists() { ip link show "$1" >/dev/null 2>&1; }

iface_cidr()  { ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | head -1; }
iface_ip()    { iface_cidr "$1" | cut -d/ -f1; }
iface_link_net() {
    ip -4 -o route show dev "$1" scope link 2>/dev/null | awk '{print $1}' | head -1
}

iface_gw() {
    local iface="$1" gw
    gw=$(ip -4 route show default dev "$iface" 2>/dev/null | grep -oP 'via \K\S+' | head -1)
    [ -z "$gw" ] && gw=$(ip -4 route show table all default dev "$iface" 2>/dev/null | grep -oP 'via \K\S+' | head -1)
    [ -z "$gw" ] && gw=$(conf_get "GW_$(safe_name "$iface")")
    printf '%s' "$gw"
}

iface_index() {
    local want="$1" i=0 w
    for w in $(wan_list); do
        i=$((i + 1))
        [ "$w" = "$want" ] && { printf '%s' "$i"; return 0; }
    done
    return 1
}

active_wan() {
    ip -4 route show default 2>/dev/null \
        | grep -v "dev tun\|dev wg" \
        | grep -oP 'dev \K\S+' | head -1
}

apply_rules() {
    local i=0 w ip cidr net gw table prio applied=0
    for w in $(wan_list); do
        i=$((i + 1))
        iface_exists "$w" || continue
        ip=$(iface_ip "$w")
        [ -z "$ip" ] && continue

        table=$((TABLE_BASE + i))
        prio=$((RULE_PRIO_BASE + i))
        cidr=$(iface_cidr "$w")
        net=$(iface_link_net "$w")
        gw=$(iface_gw "$w")
        [ -n "$gw" ] && conf_set "GW_$(safe_name "$w")" "$gw"

        ip route flush table "$table" 2>/dev/null
        [ -n "$net" ] && ip route add "$net" dev "$w" scope link table "$table" 2>/dev/null

        if [ -z "$gw" ] || ! ip route add default via "$gw" dev "$w" table "$table" 2>/dev/null; then
            printf 'канал %s: не удалось задать шлюз, правило не добавляю\n' "$w" >&2
            del_rules_for "$ip" "$table"
            continue
        fi

        for connected in $(ip -4 -o route show scope link 2>/dev/null | awk '{print $1}'); do
            [ "$connected" = "$net" ] && continue
            ip route add "$connected" dev "$(ip -4 -o route show "$connected" scope link 2>/dev/null | grep -oP 'dev \K\S+' | head -1)" \
                scope link table "$table" 2>/dev/null || true
        done

        del_rules_for "$ip" "$table"
        ip rule add from "$ip" table "$table" priority "$prio" 2>/dev/null

        applied=$((applied + 1))
    done
    [ "$applied" -gt 0 ]
}

del_rules_for() {
    local ip="$1" table="$2" n=0
    while [ "$n" -lt 64 ] && ip rule del from "$ip" table "$table" 2>/dev/null; do
        n=$((n + 1))
    done
    return 0
}

drop_rules() {
    local i=0 w table n
    for w in $(wan_list); do
        i=$((i + 1))
        table=$((TABLE_BASE + i))
        n=0
        while [ "$n" -lt 64 ] && ip rule del table "$table" 2>/dev/null; do
            n=$((n + 1))
        done
        ip route flush table "$table" 2>/dev/null
    done
}

check_wan() {
    local iface="$1"
    iface_exists "$iface" || return 1
    ip -4 addr show "$iface" 2>/dev/null | grep -q "inet " || return 1

    local tmpdir host pids=()
    tmpdir=$(mktemp -d /tmp/vp-wan-check.XXXX) || return 1
    for host in "${PING_HOSTS[@]}"; do
        ( ping -c 1 -W "$PING_TIMEOUT" -I "$iface" "$host" >/dev/null 2>&1 && touch "$tmpdir/ok" ) &
        pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null
    local result=1
    [ -f "$tmpdir/ok" ] && result=0
    rm -rf "$tmpdir"
    return $result
}

first_healthy_wan() {
    local w
    for w in $(wan_list); do
        if check_wan "$w"; then
            printf '%s' "$w"
            return 0
        fi
    done
    return 1
}

pin_endpoint() {
    local endpoint="$1" iface gw
    [ -z "$endpoint" ] && return 1
    iface=$(active_wan)
    [ -z "$iface" ] && return 1
    gw=$(iface_gw "$iface")
    [ -z "$gw" ] && return 1
    if ip route replace "$endpoint/32" via "$gw" dev "$iface" 2>/dev/null; then
        conf_set VPN_ENDPOINT "$endpoint"
        return 0
    fi
    return 1
}

repin_saved_endpoint() {
    local endpoint
    endpoint=$(conf_get VPN_ENDPOINT)
    [ -z "$endpoint" ] && return 0
    pin_endpoint "$endpoint" || {
        ip route del "$endpoint/32" 2>/dev/null || true
        printf 'не удалось перепривязать маршрут до %s — снят старый\n' "$endpoint" >&2
    }
    return 0
}

unpin_endpoint() {
    local endpoint="$1"
    [ -z "$endpoint" ] && return 1
    ip route del "$endpoint/32" 2>/dev/null || true
}

set_active() {
    local iface="$1" force="${2:-}" gw current
    iface_exists "$iface" || { printf 'нет такого интерфейса: %s\n' "$iface" >&2; return 1; }
    gw=$(iface_gw "$iface")
    [ -z "$gw" ] && { printf 'у канала %s нет шлюза — переключение отменено\n' "$iface" >&2; return 1; }

    if [ "$force" != "--force" ] && ! check_wan "$iface"; then
        printf 'канал %s не отвечает — переключение отменено (--force чтобы всё равно)\n' "$iface" >&2
        return 1
    fi

    current=$(active_wan)
    [ "$current" = "$iface" ] && { conf_set WAN "$iface"; return 0; }

    if ip -4 route show default 2>/dev/null | grep -qE "dev (tun|wg)"; then
        printf 'внимание: default route сейчас через туннель, меняю только underlay\n' >&2
    fi

    ip route replace default via "$gw" dev "$iface" 2>/dev/null || return 1
    conf_set WAN "$iface"
    apply_rules
    repin_saved_endpoint
    return 0
}

lan_iface() { conf_get LAN; }

netplan_edit() {
    local action="$1" iface="$2" metric="${3:-100}"
    [ -f "$NETPLAN_FILE" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1

    python3 - "$NETPLAN_FILE" "$action" "$iface" "$metric" <<'PYEOF'
import sys

try:
    import yaml
except ImportError:
    sys.exit(2)

path, action, iface, metric = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])

try:
    with open(path) as fh:
        data = yaml.safe_load(fh) or {}
except Exception:
    sys.exit(3)

net = data.setdefault("network", {})
net.setdefault("version", 2)
eth = net.setdefault("ethernets", {})

if action == "add":
    if iface in eth:
        sys.exit(0)
    eth[iface] = {
        "dhcp4": True,
        "dhcp-identifier": "mac",
        "dhcp4-overrides": {"use-dns": False, "route-metric": metric},
        "optional": True,
    }
elif action == "remove":
    if iface not in eth:
        sys.exit(0)
    del eth[iface]
else:
    sys.exit(4)

try:
    with open(path, "w") as fh:
        yaml.safe_dump(data, fh, default_flow_style=False, sort_keys=False)
except Exception:
    sys.exit(5)
PYEOF
}

netplan_reload() {
    chmod 600 "$NETPLAN_FILE" 2>/dev/null || true
    netplan apply 2>/dev/null
}

add_wan() {
    local iface="$1" list
    [ -z "$iface" ] && return 1
    iface_exists "$iface" || { printf 'нет такого интерфейса: %s\n' "$iface" >&2; return 1; }
    [ "$iface" = "$(lan_iface)" ] && { printf 'это LAN-интерфейс: %s\n' "$iface" >&2; return 1; }
    case "$iface" in
        lo|tun*|wg*|docker*|veth*|br-*)
            printf 'нельзя использовать как канал: %s\n' "$iface" >&2
            return 1 ;;
    esac

    list=$(wan_list)
    if printf '%s\n' $list | grep -qx "$iface"; then
        printf 'канал уже в списке: %s\n' "$iface" >&2
        return 1
    fi
    conf_set WAN_LIST "${list:+$list }$iface"

    local note=""
    if ip -4 addr show "$iface" 2>/dev/null | grep -q "inet "; then
        note="адрес уже есть"
    elif netplan_edit add "$iface" "$((100 + $(iface_index "$iface") * 100))"; then
        if netplan_reload; then
            local waited=0
            while [ "$waited" -lt 15 ]; do
                ip -4 addr show "$iface" 2>/dev/null | grep -q "inet " && break
                sleep 1
                waited=$((waited + 1))
            done
            if ip -4 addr show "$iface" 2>/dev/null | grep -q "inet "; then
                note="получен адрес по DHCP"
            else
                note="DHCP пока не ответил, интерфейс описан в netplan"
            fi
        else
            note="netplan apply не отработал"
        fi
    else
        note="не удалось описать интерфейс в netplan — задайте адрес вручную"
    fi

    apply_rules
    printf 'добавлен канал %s (приоритет %s): %s\n' "$iface" "$(iface_index "$iface")" "$note"
}

remove_wan() {
    local iface="$1" list out w
    [ -z "$iface" ] && return 1
    list=$(wan_list)
    printf '%s\n' $list | grep -qx "$iface" || { printf 'канала нет в списке: %s\n' "$iface" >&2; return 1; }
    [ "$(printf '%s\n' $list | grep -c .)" -le 1 ] && { printf 'нельзя удалить единственный канал\n' >&2; return 1; }

    out=""
    for w in $list; do
        [ "$w" = "$iface" ] && continue
        out="${out:+$out }$w"
    done

    if [ "$(active_wan)" = "$iface" ]; then
        local target
        target=$(first_healthy_wan)
        if [ -z "$target" ] || [ "$target" = "$iface" ]; then
            printf 'канал %s сейчас активен, а живой замены нет — удаление отменено\n' "$iface" >&2
            printf 'сначала переключитесь вручную: vpn-panel-routing set-active <канал>\n' >&2
            return 1
        fi
        set_active "$target" || {
            printf 'не удалось переключиться на %s — удаление отменено\n' "$target" >&2
            return 1
        }
    fi

    drop_rules
    conf_set WAN_LIST "$out"

    if netplan_edit remove "$iface"; then
        netplan_reload || printf 'netplan apply после удаления канала не отработал\n' >&2
    fi

    apply_rules
    printf 'канал %s удалён, осталось: %s\n' "$iface" "$out"
}

free_ifaces() {
    local used w iface
    used="$(wan_list) $(lan_iface)"
    for iface in $(ls /sys/class/net 2>/dev/null); do
        [ "$iface" = "lo" ] && continue
        case "$iface" in tun*|wg*|docker*|veth*|br-*) continue ;; esac
        printf '%s\n' $used | grep -qx "$iface" && continue
        printf '%s\t%s\t%s\n' "$iface" "$(iface_cidr "$iface" || printf -)"             "$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || printf '?')"
    done
}

status() {
    local i=0 w ip gw table state active
    active=$(active_wan)
    for w in $(wan_list); do
        i=$((i + 1))
        table=$((TABLE_BASE + i))
        ip=$(iface_cidr "$w")
        gw=$(iface_gw "$w")
        if ! iface_exists "$w"; then
            state="missing"
        elif [ -z "$ip" ]; then
            state="no-ip"
        elif check_wan "$w"; then
            state="up"
        else
            state="down"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$w" "$i" "$table" "${ip:--}" "${gw:--}" \
            "$state$([ "$w" = "$active" ] && printf ',active')"
    done
}

usage() {
    cat << 'EOF'
vpn-panel-routing <команда>

  apply                 построить правила и таблицы маршрутизации для всех WAN
  drop                  удалить правила и таблицы, созданные панелью
  status                список WAN: интерфейс, индекс, таблица, адрес, шлюз, состояние
  active                интерфейс текущего активного WAN
  check <iface>         проверить канал (ping через интерфейс), код 0 = живой
  healthy               первый живой WAN по приоритету
  set-active <iface> [--force]  сделать WAN активным (по умолчанию только если канал живой)
  pin <ip>              маршрут до VPN-эндпоинта через активный WAN
  unpin <ip>            убрать маршрут до эндпоинта
  add-wan <iface>       добавить канал в конец списка приоритетов
  remove-wan <iface>    убрать канал из списка
  free                  сетевые карты, не занятые под WAN или LAN
EOF
}

case "${1:-}" in
    apply)      apply_rules ;;
    drop)       drop_rules ;;
    status)     status ;;
    active)     active_wan ;;
    check)      check_wan "$2" ;;
    healthy)    first_healthy_wan ;;
    set-active) set_active "$2" "$3" ;;
    pin)        pin_endpoint "$2" ;;
    unpin)      unpin_endpoint "$2" ;;
    add-wan)    add_wan "$2" ;;
    remove-wan) remove_wan "$2" ;;
    free)       free_ifaces ;;
    *)          usage; exit 1 ;;
esac
