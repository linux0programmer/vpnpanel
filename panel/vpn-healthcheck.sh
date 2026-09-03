#!/bin/bash

INTERFACE="tun0"
SETTINGS="/var/www/settings"
VPN_STATE_FILE="/var/www/vpn-state"
LOG="/var/log/vpn-panel/vpn.log"
EVENTS="/var/log/vpn-panel/events.log"
VP_CONF="/etc/vpn-panel.conf"

VP_CONF_FILE="/etc/vpn-panel.conf"
LAN_IP="10.10.1.1"
LAN_NET="10.10.1.0/20"
LAN_PREFIX="20"

load_lan_params() {
    [ -f "$VP_CONF_FILE" ] || return 0
    local v
    v=$(grep "^LAN_IP=" "$VP_CONF_FILE" 2>/dev/null | cut -d= -f2);     [ -n "$v" ] && LAN_IP="$v"
    v=$(grep "^LAN_NET=" "$VP_CONF_FILE" 2>/dev/null | cut -d= -f2);    [ -n "$v" ] && LAN_NET="$v"
    v=$(grep "^LAN_PREFIX=" "$VP_CONF_FILE" 2>/dev/null | cut -d= -f2); [ -n "$v" ] && LAN_PREFIX="$v"
    return 0
}
load_lan_params
CONFIGS_JSON="/var/www/vpn-configs/configs.json"
CONFIGS_DIR="/var/www/vpn-configs"
MAX_LOG=5242880
MAX_EVENTS=262144

PING_HOSTS=("8.8.8.8" "1.1.1.1" "9.9.9.9")
IP_SERVICES=("ifconfig.me" "icanhazip.com" "api.ipify.org")

PING_INTERVAL=5
PING_TIMEOUT=2
IPTABLES_INTERVAL=15
LEAK_INTERVAL=300
COOLDOWN_INITIAL=10
COOLDOWN_MAX=60
WG_POLL_MAX=10
OVPN_POLL_MAX=20
WARMUP_TIMEOUT=120
EVENT_DEDUP_WINDOW=300

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [ -f "$LOG" ]; then
        local sz
        sz=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
        [ "$sz" -gt "$MAX_LOG" ] && mv "$LOG" "$LOG.old"
    fi
    echo "[$ts] [$1] $2" >> "$LOG"
    logger -t "VPN Panel" "[$1] $2"
}

log_event() {
    local ts type
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    type="$1"
    shift
    local line="${ts}|${type}"
    local f
    for f in "$@"; do
        f=$(printf '%s' "$f" | tr '|\n\r' '/  ')
        line="${line}|${f}"
    done
    echo "$line" >> "$EVENTS"
    local sz
    sz=$(stat -c%s "$EVENTS" 2>/dev/null || echo 0)
    if [ "$sz" -gt "$MAX_EVENTS" ]; then
        tail -n 500 "$EVENTS" > "${EVENTS}.tmp" && mv -f "${EVENTS}.tmp" "$EVENTS" && chmod 666 "$EVENTS" 2>/dev/null
    fi
}

read_vpn_state() {
    VPN_STATE="stopped"
    ACTIVE_ID=""
    PRIMARY_ID=""
    ACTIVATED_BY=""
    [ ! -f "$VPN_STATE_FILE" ] && return
    local line key val
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        case "$key" in
            STATE)        VPN_STATE="$val" ;;
            ACTIVE_ID)    ACTIVE_ID="$val" ;;
            PRIMARY_ID)   PRIMARY_ID="$val" ;;
            ACTIVATED_BY) ACTIVATED_BY="$val" ;;
        esac
    done < "$VPN_STATE_FILE"
}

save_vpn_state() {
    local tmp="${VPN_STATE_FILE}.hc.tmp"
    if printf 'STATE=%s\nACTIVE_ID=%s\nPRIMARY_ID=%s\nACTIVATED_BY=%s\n' \
        "$VPN_STATE" "$ACTIVE_ID" "$PRIMARY_ID" "$ACTIVATED_BY" > "$tmp" \
        && mv -f "$tmp" "$VPN_STATE_FILE"; then
        chmod 666 "$VPN_STATE_FILE" 2>/dev/null || true
    else
        rm -f "$tmp"
    fi
}

get_vpn_type() {
    [ -f "/etc/wireguard/${INTERFACE}.conf" ] && echo "wg" && return
    [ -f "/etc/openvpn/${INTERFACE}.conf" ] && echo "ovpn" && return
    echo ""
}

get_config_name() {
    local type
    type=$(get_vpn_type)
    if [ "$type" = "wg" ]; then
        grep -oP 'Endpoint\s*=\s*\K[^:]+' /etc/wireguard/${INTERFACE}.conf 2>/dev/null | head -1 || echo "wg-$INTERFACE"
    elif [ "$type" = "ovpn" ]; then
        grep -oP 'remote\s+\K\S+' /etc/openvpn/${INTERFACE}.conf 2>/dev/null | head -1 || echo "ovpn-$INTERFACE"
    else
        echo "none"
    fi
}

check_settings()         { [ -f "$SETTINGS" ] && grep -q "^vpnchecker=true$" "$SETTINGS"; }
check_autoup()           { [ -f "$SETTINGS" ] && grep -q "^autoupvpn=true$" "$SETTINGS"; }
check_failover_enabled() { [ -f "$SETTINGS" ] && grep -q "^failover=true$" "$SETTINGS"; }
check_failover_first()   { [ -f "$SETTINGS" ] && grep -q "^failover_first=true$" "$SETTINGS"; }
check_iface()            { ip link show "$INTERFACE" &>/dev/null; }
check_ip()               { ip -4 addr show "$INTERFACE" 2>/dev/null | grep -q "inet "; }
check_wan_has_ip()       { [ -z "$WAN_IF" ] && return 0; ip -4 addr show "$WAN_IF" 2>/dev/null | grep -q "inet "; }

note_down() {
    local reason="$1"
    LAST_DOWN_REASON="$reason"

    local now
    now=$(date +%s)
    if [ "$LAST_VPN_DOWN_REASON" = "$reason" ] && \
       [ $((now - LAST_VPN_DOWN_TIME)) -lt "$EVENT_DEDUP_WINDOW" ]; then
        return
    fi
    LAST_VPN_DOWN_REASON="$reason"
    LAST_VPN_DOWN_TIME="$now"
    log_event vpn_down "$ACTIVE_ID" "$reason"
}

log_recovery_attempt() {
    local reason="${1:-restart}"
    local now
    now=$(date +%s)
    if [ "$LAST_RECOVERY_REASON" = "$reason" ] && \
       [ $((now - LAST_RECOVERY_TIME)) -lt "$EVENT_DEDUP_WINDOW" ]; then
        RECOVERY_ATTEMPT_DEDUPED=1
        return
    fi
    RECOVERY_ATTEMPT_DEDUPED=0
    LAST_RECOVERY_REASON="$reason"
    LAST_RECOVERY_TIME="$now"
    log_event recovery_attempt "$ACTIVE_ID" "$reason"
}

log_event_firewall_restored() {
    local now_fw
    now_fw=$(date +%s)
    if [ $((now_fw - LAST_FIREWALL_RESTORED_TIME)) -lt "$EVENT_DEDUP_WINDOW" ]; then
        return
    fi
    LAST_FIREWALL_RESTORED_TIME="$now_fw"
    log_event firewall_restored
}

reset_event_dedup() {
    LAST_VPN_DOWN_REASON=""
    LAST_VPN_DOWN_TIME=0
    LAST_RECOVERY_REASON=""
    LAST_RECOVERY_TIME=0
}

switch_to_config() {
    local target_id="$1"
    [ -z "$target_id" ] && return 1
    [ ! -f "$CONFIGS_JSON" ] && return 1

    local cfg_info
    cfg_info=$(php -r '
        $configs=json_decode(file_get_contents($argv[1]),true);
        if(isset($configs[$argv[2]])){
            $c=$configs[$argv[2]];
            echo ($c["filename"]??"")."|".($c["type"]??"unknown")."|".($c["name"]??"");
        }
    ' -- "$CONFIGS_JSON" "$target_id" 2>/dev/null)
    [ -z "$cfg_info" ] && return 1

    local cfg_file cfg_type cfg_name
    IFS='|' read -r cfg_file cfg_type cfg_name <<< "$cfg_info"
    [ -z "$cfg_file" ] && return 1

    local source_path="${CONFIGS_DIR}/${cfg_file}"
    [ ! -f "$source_path" ] && { log "ERR" "Файл $source_path не найден"; return 1; }

    log "INFO" "Переключение на '${cfg_name}' (${cfg_type})"

    systemctl stop "wg-quick@${INTERFACE}" 2>/dev/null
    systemctl stop "openvpn@${INTERFACE}" 2>/dev/null
    sleep 1

    rm -f "/etc/wireguard/${INTERFACE}.conf" "/etc/openvpn/${INTERFACE}.conf"

    local poll_max=$WG_POLL_MAX
    if [ "$cfg_type" = "wireguard" ]; then
        cp "$source_path" "/etc/wireguard/${INTERFACE}.conf"
        chmod 600 "/etc/wireguard/${INTERFACE}.conf"
        systemctl enable "wg-quick@${INTERFACE}" 2>/dev/null
        systemctl start "wg-quick@${INTERFACE}" 2>/dev/null
    else
        cp "$source_path" "/etc/openvpn/${INTERFACE}.conf"
        chmod 600 "/etc/openvpn/${INTERFACE}.conf"
        systemctl disable "wg-quick@${INTERFACE}" 2>/dev/null
        systemctl enable "openvpn@${INTERFACE}" 2>/dev/null
        systemctl start "openvpn@${INTERFACE}" 2>/dev/null
        poll_max=$OVPN_POLL_MAX
    fi

    local i=0
    while [ $i -lt $poll_max ]; do
        sleep 1; i=$((i + 1))
        if check_iface && check_ip && ping_vpn; then
            log "OK" "'${cfg_name}' поднят за ${i}с"
            return 0
        fi
    done

    log "ERR" "'${cfg_name}' не поднялся за ${poll_max}с"
    return 1
}

reset_after_recovery() {
    local now
    now=$(date +%s)
    if [ "$LAST_RESTART_OK" -gt 0 ] && [ $((now - LAST_RESTART_OK)) -lt 120 ]; then
        COOLDOWN=$COOLDOWN_INITIAL
        COOLDOWN_UNTIL=$((now + COOLDOWN_INITIAL))
        log "WARN" "Частые перезапуски (flapping) — cooldown ${COOLDOWN_INITIAL}с"
    else
        COOLDOWN=0; COOLDOWN_UNTIL=0
    fi
    RESTART_FAILS=0; LAST_RESTART_OK=$now
    reset_event_dedup
}

do_recovery() {
    VPN_STATE="recovering"
    save_vpn_state
    log "INFO" "Восстановление VPN..."

    local skip_restart=0
    if check_failover_first && check_failover_enabled && [ -f "$CONFIGS_JSON" ]; then
        local has_backups
        has_backups=$(php -r '
            $c=json_decode(file_get_contents($argv[1]),true);
            if(!is_array($c))exit(1);
            foreach($c as $cid=>$cfg){
                if(($cfg["role"]??"")==="backup" && $cid!==$argv[2]){echo "1";exit;}
                if(($cfg["role"]??"")==="primary" && $cid!==$argv[2]){echo "1";exit;}
            }
        ' -- "$CONFIGS_JSON" "$ACTIVE_ID" 2>/dev/null)
        [ "$has_backups" = "1" ] && skip_restart=1
    fi

    local type
    type=$(get_vpn_type)
    if [ -n "$type" ] && [ "$skip_restart" -eq 0 ]; then
        local cur_name
        cur_name=$(get_config_name)
        log "INFO" "Перезапуск текущего конфига ($cur_name, $type)..."
        log_recovery_attempt "${LAST_DOWN_REASON:-restart}"
        local poll_max
        if [ "$type" = "wg" ]; then
            systemctl restart "wg-quick@${INTERFACE}" 2>/dev/null
            poll_max=$WG_POLL_MAX
        else
            systemctl restart "openvpn@${INTERFACE}" 2>/dev/null
            poll_max=$OVPN_POLL_MAX
        fi
        local i=0
        while [ $i -lt $poll_max ]; do
            sleep 1; i=$((i + 1))
            if check_iface && check_ip && ping_vpn; then
                log "OK" "Текущий конфиг восстановлен за ${i}с"
                VPN_STATE="running"; save_vpn_state
                if [ "${RECOVERY_ATTEMPT_DEDUPED:-0}" != "1" ]; then
                    log_event recovery_succeeded "$ACTIVE_ID" "${LAST_DOWN_REASON:-restart}"
                fi
                reset_after_recovery
                DAEMON_JUST_STARTED=0
                return 0
            fi
        done
        RESTART_FAILS=$((RESTART_FAILS + 1))
        log "WARN" "Restart текущего конфига не помог (попытка $RESTART_FAILS)"
    elif [ "$skip_restart" -eq 1 ]; then
        log "INFO" "Пропуск restart — сразу failover (failover_first=true)"
    fi

    local primary_tried_in_step2=0
    if ! check_failover_first && [ -n "$PRIMARY_ID" ] && [ "$ACTIVE_ID" != "$PRIMARY_ID" ]; then
        log "INFO" "Попытка вернуться на основной конфиг..."
        primary_tried_in_step2=1
        if switch_to_config "$PRIMARY_ID"; then
            ACTIVE_ID="$PRIMARY_ID"
            ACTIVATED_BY="manual"
            VPN_STATE="running"; save_vpn_state
            reset_after_recovery
            log_event failover_restored "$PRIMARY_ID"
            update_configs_json "$PRIMARY_ID" "manual"
            DAEMON_JUST_STARTED=0
            return 0
        fi
    fi

    if ! check_failover_enabled; then
        log "INFO" "Failover отключён в настройках"
    elif [ ! -f "$CONFIGS_JSON" ]; then
        log "ERR" "configs.json не найден: $CONFIGS_JSON"
    else
        log "INFO" "Failover: поиск backup-конфигов (текущий ACTIVE_ID=$ACTIVE_ID, primary_tried_in_step2=$primary_tried_in_step2)..."
        local backup_list
        backup_list=$(php -r '
            $configs=json_decode(file_get_contents($argv[1]),true);
            if(!is_array($configs))exit(1);
            $cur=$argv[2];
            $exclude_primary=($argv[3]==="1");
            uasort($configs,function($a,$b){return ($a["priority"]??99)-($b["priority"]??99);});
            $backups=[];
            foreach($configs as $cid=>$cfg){
                if(($cfg["role"]??"")==="backup" && $cid!==$cur)$backups[]=$cid;
            }
            if(!$exclude_primary){
                foreach($configs as $cid=>$cfg){
                    if(($cfg["role"]??"")==="primary" && $cid!==$cur && !in_array($cid,$backups)){
                        array_unshift($backups,$cid);
                    }
                }
            }
            foreach($backups as $cid)echo $cid."\n";
        ' -- "$CONFIGS_JSON" "$ACTIVE_ID" "$primary_tried_in_step2" 2>/dev/null)
        if [ -z "$backup_list" ]; then
            log "WARN" "Нет доступных backup-конфигов"
        else
            log "INFO" "Найдены backup-конфиги: $(echo "$backup_list" | tr '\n' ' ')"
            local old_id="$ACTIVE_ID"
            while IFS= read -r backup_id; do
                [ -z "$backup_id" ] && continue
                log "INFO" "Failover: пробуем конфиг $backup_id..."
                if switch_to_config "$backup_id"; then
                    ACTIVE_ID="$backup_id"
                    ACTIVATED_BY="failover"
                    VPN_STATE="running"; save_vpn_state
                    reset_after_recovery
                    log_event failover "$backup_id" "$old_id" "${LAST_DOWN_REASON:-unknown}"
                    update_configs_json "$backup_id" "failover"
                    DAEMON_JUST_STARTED=0
                    return 0
                fi
            done <<< "$backup_list"
        fi
    fi

    log "ERR" "Все конфиги недоступны"
    log_event recovery_failed "${LAST_DOWN_REASON:-all configs unreachable}"
    VPN_STATE="recovering"; save_vpn_state

    COOLDOWN=$((COOLDOWN + COOLDOWN_INITIAL))
    [ "$COOLDOWN" -gt "$COOLDOWN_MAX" ] && COOLDOWN=$COOLDOWN_MAX
    local now
    now=$(date +%s)
    COOLDOWN_UNTIL=$((now + COOLDOWN))
    log "INFO" "Cooldown ${COOLDOWN}с"
    return 1
}

update_configs_json() {
    local cfg_id="$1" by="$2"
    (
        flock -w 5 200 || { log "WARN" "flock configs.json timeout"; return; }
        php -r '
            $f=$argv[1]; $id=$argv[2]; $by=$argv[3];
            $data=json_decode(file_get_contents($f),true);
            if(!is_array($data))exit(1);
            foreach($data as $cid=>&$cfg){
                if(($cfg["activated_by"]??"")==="failover")$cfg["activated_by"]="";
            } unset($cfg);
            if(isset($data[$id])){
                $data[$id]["last_used"]=date("Y-m-d H:i:s");
                $data[$id]["activated_by"]=$by;
            }
            file_put_contents($f,json_encode($data,JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE));
        ' -- "$CONFIGS_JSON" "$cfg_id" "$by" 2>/dev/null || true
    ) 200>"${CONFIGS_JSON}.lock"
}

ROUTING_BIN="/usr/local/sbin/vpn-panel-routing"
WAN_LIST=""
WAN_PRIMARY_STREAK=0
WAN_PRIMARY_STREAK_NEEDED=3
WAN_PRIMARY_CHECK_INTERVAL=60
LAST_PRIMARY_CHECK=0

routing_available() { [ -x "$ROUTING_BIN" ]; }

wan_primary() { printf '%s' "$WAN_LIST" | awk '{print $1}'; }

wan_count() { printf '%s\n' $WAN_LIST | grep -c . ; }

vpn_endpoint_ip() {
    local vtype host
    vtype=$(get_vpn_type)
    if [ "$vtype" = "wg" ]; then
        host=$(grep -iE '^[[:space:]]*Endpoint' "/etc/wireguard/${INTERFACE}.conf" 2>/dev/null                | head -1 | cut -d= -f2 | tr -d ' ' | rev | cut -d: -f2- | rev)
    elif [ "$vtype" = "ovpn" ]; then
        host=$(grep -iE '^[[:space:]]*remote[[:space:]]' "/etc/openvpn/${INTERFACE}.conf" 2>/dev/null                | head -1 | awk '{print $2}')
    fi
    [ -z "$host" ] && return 1
    if printf '%s' "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        printf '%s' "$host"
    else
        getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -1
    fi
}

repin_endpoint() {
    routing_available || return 1
    local ep
    ep=$(vpn_endpoint_ip) || return 1
    [ -z "$ep" ] && return 1
    "$ROUTING_BIN" pin "$ep" >/dev/null 2>&1
}

switch_wan_to() {
    local target="$1" previous="$WAN_IF"
    routing_available || return 1
    [ -z "$target" ] && return 1
    [ "$target" = "$previous" ] && return 1
    "$ROUTING_BIN" set-active "$target" --force >/dev/null 2>&1 || return 1
    WAN_IF="$target"
    if ! repin_endpoint; then
        log "WARN" "маршрут до VPN-эндпоинта не перепривязан — туннель может не подняться на новом канале"
    fi
    log "WARN" "Канал переключён: ${previous:-неизвестно} -> $target"
    log_event wan_switch "${previous:-unknown}" "$target"
    return 0
}

try_wan_failover() {
    routing_available || return 1
    [ "$(wan_count)" -lt 2 ] && return 1
    local target
    target=$("$ROUTING_BIN" healthy 2>/dev/null)
    [ -z "$target" ] && return 1
    switch_wan_to "$target"
}

try_return_to_primary() {
    routing_available || return 1
    [ "$(wan_count)" -lt 2 ] && return 1

    local now
    now=$(date +%s)
    [ $((now - LAST_PRIMARY_CHECK)) -lt "$WAN_PRIMARY_CHECK_INTERVAL" ] && return 1
    LAST_PRIMARY_CHECK="$now"

    local primary
    primary=$(wan_primary)
    [ -z "$primary" ] && return 1
    [ "$primary" = "$WAN_IF" ] && { WAN_PRIMARY_STREAK=0; return 1; }

    if "$ROUTING_BIN" check "$primary" >/dev/null 2>&1; then
        WAN_PRIMARY_STREAK=$((WAN_PRIMARY_STREAK + 1))
    else
        WAN_PRIMARY_STREAK=0
        return 1
    fi
    [ "$WAN_PRIMARY_STREAK" -lt "$WAN_PRIMARY_STREAK_NEEDED" ] && return 1
    WAN_PRIMARY_STREAK=0
    switch_wan_to "$primary"
}

load_interfaces() {
    WAN_IF=""; LAN_IF=""; WAN_LIST=""
    if [ -f "$VP_CONF" ]; then
        WAN_IF=$(grep "^WAN=" "$VP_CONF" 2>/dev/null | cut -d= -f2)
        LAN_IF=$(grep "^LAN=" "$VP_CONF" 2>/dev/null | cut -d= -f2)
    fi
    [ -z "$LAN_IF" ] && LAN_IF=$(ip -4 addr show 2>/dev/null | grep -F "$LAN_IP/" | awk '{print $NF}')
    [ -z "$WAN_IF" ] && WAN_IF=$(ip route show default 2>/dev/null | grep -v "dev tun\|dev wg" | grep -oP 'dev \K[^ ]+' | head -1)
    WAN_LIST=$(grep "^WAN_LIST=" "$VP_CONF" 2>/dev/null | head -1 | cut -d= -f2-)
    [ -z "$WAN_LIST" ] && WAN_LIST="$WAN_IF"

    if routing_available; then
        local live
        live=$("$ROUTING_BIN" active 2>/dev/null)
        [ -n "$live" ] && WAN_IF="$live"
    fi

    [ -z "$LAN_IF" ] && log "WARN" "Не удалось определить LAN интерфейс"
    [ -z "$WAN_IF" ] && log "WARN" "Не удалось определить WAN интерфейс"
}

is_full_tunnel() {
    ip route show default 2>/dev/null | grep -q "dev $INTERFACE" && return 0
    if ip rule show 2>/dev/null | grep -q "fwmark.*lookup"; then
        local t
        t=$(ip rule show 2>/dev/null | grep "fwmark" | grep -oP 'lookup \K\d+' | head -1)
        [ -n "$t" ] && ip route show table "$t" 2>/dev/null | grep -q "dev $INTERFACE" && return 0
    fi
    local vt
    vt=$(get_vpn_type)
    [ "$vt" = "wg" ] && grep -q "AllowedIPs.*0\.0\.0\.0/0" /etc/wireguard/${INTERFACE}.conf 2>/dev/null && return 0
    [ "$vt" = "ovpn" ] && grep -q "redirect-gateway" /etc/openvpn/${INTERFACE}.conf 2>/dev/null && return 0
    return 1
}

ping_vpn() {
    local tmpdir
    tmpdir=$(mktemp -d /tmp/hc-ping.XXXX) || { log "WARN" "mktemp не сработал — проверка VPN пропущена"; return 1; }
    local pids=()
    local h
    for h in "${PING_HOSTS[@]}"; do
        ( ping -c 1 -W "$PING_TIMEOUT" -I "$INTERFACE" "$h" &>/dev/null && touch "$tmpdir/ok" ) &
        pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null
    local result=1
    [ -f "$tmpdir/ok" ] && result=0
    rm -rf "$tmpdir"
    return $result
}

ping_wan() {
    [ -z "$WAN_IF" ] && return 0
    check_wan_has_ip || return 1
    local tmpdir
    tmpdir=$(mktemp -d /tmp/hc-wan-ping.XXXX) || { log "WARN" "mktemp не сработал — проверка WAN пропущена"; return 1; }
    local pids=()
    local h
    for h in "${PING_HOSTS[@]}"; do
        ( ping -c 1 -W "$PING_TIMEOUT" -I "$WAN_IF" "$h" &>/dev/null && touch "$tmpdir/ok" ) &
        pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null
    local result=1
    [ -f "$tmpdir/ok" ] && result=0
    rm -rf "$tmpdir"
    return $result
}

restart_vpn() {
    read_vpn_state
    [ "$VPN_STATE" = "stopped" ] && return 1
    [ "$VPN_STATE" = "restarting" ] && return 1

    if ! check_wan_has_ip; then
        WAN_WAS_DOWN=1; return 1
    fi

    local now
    now=$(date +%s)
    if [ "$COOLDOWN_UNTIL" -gt 0 ] && [ "$now" -lt "$COOLDOWN_UNTIL" ]; then
        return 1
    fi
    do_recovery
    return $?
}

check_vpn_routing() {
    local type
    type=$(get_vpn_type)

    if [ "$type" = "wg" ]; then
        grep -q "AllowedIPs.*0\.0\.0\.0/0" /etc/wireguard/${INTERFACE}.conf 2>/dev/null || return 0
        local fwmark
        fwmark=$(wg show "$INTERFACE" fwmark 2>/dev/null)
        [ -z "$fwmark" ] || [ "$fwmark" = "off" ] && return 0
        local hex_fwmark
        hex_fwmark=$(printf "0x%x" "$fwmark" 2>/dev/null)
        if ip rule show 2>/dev/null | grep -qE "fwmark\s+($fwmark|$hex_fwmark)"; then
            return 0
        fi

        log "WARN" "WG fwmark rule пропало, пробую восстановить напрямую (fwmark=$fwmark)..."
        ip -4 rule add not fwmark "$fwmark" table "$fwmark" 2>/dev/null
        ip -4 rule add table main suppress_prefixlength 0 2>/dev/null

        if ip rule show 2>/dev/null | grep -qE "fwmark\s+($fwmark|$hex_fwmark)"; then
            log "OK" "WG fwmark rule восстановлено напрямую (без перезапуска VPN)"
            return 0
        fi

        log "CRIT" "WireGuard fwmark rule потеряно и не восстанавливается! (fwmark=$fwmark)"
        note_down "WG fwmark rule потеряно"
        return 1
    elif [ "$type" = "ovpn" ]; then
        grep -q "redirect-gateway" /etc/openvpn/${INTERFACE}.conf 2>/dev/null || return 0
        if ip route show 2>/dev/null | grep -q "0\.0\.0\.0/1.*dev $INTERFACE"; then
            return 0
        fi
        log "CRIT" "OpenVPN маршруты потеряны! (нет 0.0.0.0/1 через $INTERFACE)"
        note_down "OVPN маршруты потеряны"
        return 1
    fi
    return 0
}

check_iptables() {
    local now
    now=$(date +%s)
    [ $((now - LAST_IPTABLES_CHECK)) -lt "$IPTABLES_INTERVAL" ] && return 0
    LAST_IPTABLES_CHECK=$now

    [ -z "$LAN_IF" ] && return 0

    local bad=0
    local policy
    policy=$(iptables -L FORWARD -n 2>/dev/null | head -1 | grep -oP '(?<=policy )\w+')
    [ "$policy" != "DROP" ] && bad=1
    [ "$bad" -eq 0 ] && ! iptables -t nat -C POSTROUTING -o tun0 -s "$LAN_NET" -j MASQUERADE 2>/dev/null && bad=1
    [ "$bad" -eq 0 ] && ! iptables -C FORWARD -i "$LAN_IF" -o tun0 -j ACCEPT 2>/dev/null && bad=1
    [ "$bad" -eq 0 ] && return 0

    log "WARN" "Восстановление iptables Kill Switch..."
    note_down "iptables правила потеряны"

    if [ -f /etc/iptables/rules.v4 ] && [ -s /etc/iptables/rules.v4 ]; then
        if iptables-restore < /etc/iptables/rules.v4 2>/dev/null; then
            log "OK" "iptables восстановлены из rules.v4"
            log_event_firewall_restored
            return 0
        fi
    fi

    iptables -P FORWARD DROP; iptables -F FORWARD
    iptables -A FORWARD -i "$LAN_IF" -o tun0 -j ACCEPT
    iptables -A FORWARD -i tun0 -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i "$LAN_IF" -o "$LAN_IF" -j ACCEPT
    [ -n "$WAN_IF" ] && iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -j REJECT --reject-with icmp-net-unreachable
    iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -t nat -C POSTROUTING -o tun0 -s "$LAN_NET" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o tun0 -s "$LAN_NET" -j MASQUERADE
    iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -A INPUT -i lo -j ACCEPT
    iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    if [ -n "$LAN_IF" ]; then
        local p proto port
        for p in "udp:53" "tcp:53" "udp:67"; do
            proto=${p%%:*}; port=${p##*:}
            iptables -C INPUT -i "$LAN_IF" -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || \
                iptables -A INPUT -i "$LAN_IF" -p "$proto" --dport "$port" -j ACCEPT
        done
    fi
    iptables-save > /etc/iptables/rules.v4 2>/dev/null
    log "OK" "iptables Kill Switch восстановлен"
    log_event_firewall_restored
}

check_leak() {
    local now
    now=$(date +%s)
    [ $((now - LAST_LEAK_CHECK)) -lt "$LEAK_INTERVAL" ] && return 0
    LAST_LEAK_CHECK=$now

    is_full_tunnel || return 0

    local vpn_ip="" def_ip="" s
    for s in "${IP_SERVICES[@]}"; do
        vpn_ip=$(curl -s --interface "$INTERFACE" --max-time 5 "$s" 2>/dev/null)
        [[ "$vpn_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break || vpn_ip=""
    done
    [ -z "$vpn_ip" ] && return 0

    for s in "${IP_SERVICES[@]}"; do
        def_ip=$(curl -s --max-time 5 "$s" 2>/dev/null)
        [[ "$def_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break || def_ip=""
    done
    [ -z "$def_ip" ] && return 0
    [ "$def_ip" = "$vpn_ip" ] && return 0

    log "CRIT" "IP УТЕЧКА! Default:$def_ip VPN:$vpn_ip"
    note_down "IP утечка"
    return 1
}

main_loop() {
    COOLDOWN=0
    COOLDOWN_UNTIL=0
    LAST_IPTABLES_CHECK=0
    LAST_LEAK_CHECK=0
    LAST_IFACE_LOAD=0
    WAN_WAS_DOWN=0
    RESTART_FAILS=0
    LAST_RESTART_OK=0
    LAST_DOWN_REASON=""
    IFACE_RELOAD_INTERVAL=300

    LAST_VPN_DOWN_REASON=""
    LAST_VPN_DOWN_TIME=0
    LAST_RECOVERY_REASON=""
    LAST_RECOVERY_TIME=0
    LAST_FIREWALL_RESTORED_TIME=0
    RECOVERY_ATTEMPT_DEDUPED=0

    DAEMON_JUST_STARTED=1

    SYSTEM_UPTIME=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 999)
    if [ "$SYSTEM_UPTIME" -lt 90 ]; then
        BOOTED_RECENTLY=1
        log "INFO" "Cold boot detected (uptime=${SYSTEM_UPTIME}с) — auto_start будет записан независимо от ACTIVATED_BY"
    else
        BOOTED_RECENTLY=0
    fi

    WAN_STATE="ok"
    WAN_DOWN_SINCE=0

    load_interfaces
    LAST_IFACE_LOAD=$(date +%s)

    log "INFO" "Health Check v5 daemon запущен"

    trap 'log "INFO" "Daemon остановлен"; exit 0' TERM INT

    local warmup_start warmup_elapsed warmup_done
    warmup_start=$(date +%s)
    warmup_elapsed=0
    warmup_done=0
    log "INFO" "Warmup phase: ожидаем стабильности VPN (до ${WARMUP_TIMEOUT}с после старта)..."

    while [ "$warmup_elapsed" -lt "$WARMUP_TIMEOUT" ]; do
        read_vpn_state

        if [ "$VPN_STATE" = "stopped" ]; then
            log "INFO" "VPN остановлен — warmup прерван"
            warmup_done=1; break
        fi

        if ! check_settings; then
            log "INFO" "Мониторинг VPN отключён — warmup прерван"
            warmup_done=1; break
        fi

        if [ -z "$(get_vpn_type)" ]; then
            log "WARN" "Активный конфиг отсутствует — warmup прерван"
            warmup_done=1; break
        fi

        if check_iface && check_ip && ping_vpn; then
            log "OK" "VPN стабилен после ${warmup_elapsed}с warmup"
            warmup_done=1; break
        fi

        sleep 3
        warmup_elapsed=$(( $(date +%s) - warmup_start ))
    done

    if [ "$warmup_done" != "1" ]; then
        log "WARN" "VPN не установился за ${WARMUP_TIMEOUT}с warmup — переходим в recovery"
        LAST_DOWN_REASON="VPN не установился за ${WARMUP_TIMEOUT}с после старта сервера"
    fi

    local vpn_ok=0
    local now_iface

    while true; do
        read_vpn_state

        if [ "$VPN_STATE" = "stopped" ]; then
            vpn_ok=0
            sleep 5; continue
        fi

        if [ "$VPN_STATE" = "restarting" ]; then
            sleep 2; continue
        fi

        if ! check_settings; then
            sleep 30; continue
        fi

        if [ -z "$(get_vpn_type)" ]; then
            if [ "$VPN_STATE" = "running" ] || [ "$VPN_STATE" = "recovering" ]; then
                check_autoup && restart_vpn
            fi
            sleep 5; continue
        fi

        if [ "$WAN_STATE" = "ok" ] && try_return_to_primary; then
            COOLDOWN=0; COOLDOWN_UNTIL=0; RESTART_FAILS=0
            check_autoup && restart_vpn
            sleep "$PING_INTERVAL"; continue
        fi

        if [ "$WAN_WAS_DOWN" -eq 1 ] && check_wan_has_ip; then
            log "INFO" "WAN вернулся — сбрасываю cooldown"
            COOLDOWN=0; COOLDOWN_UNTIL=0; RESTART_FAILS=0; WAN_WAS_DOWN=0
        fi

        if [ "$WAN_STATE" = "down" ]; then
            wan_now=$(date +%s)
            if [ $((wan_now - LAST_IFACE_LOAD)) -ge "$IFACE_RELOAD_INTERVAL" ]; then
                load_interfaces
                LAST_IFACE_LOAD="$wan_now"
                log "INFO" "WAN недоступен — перечитал интерфейсы (WAN=$WAN_IF, список: ${WAN_LIST:-нет})"
            fi
            if ! ping_wan && try_wan_failover; then
                WAN_STATE="ok"
                COOLDOWN=0; COOLDOWN_UNTIL=0; RESTART_FAILS=0
                check_autoup && restart_vpn
                sleep "$PING_INTERVAL"; continue
            fi
            if ping_wan; then
                local wan_now wan_duration
                wan_now=$(date +%s)
                wan_duration=$((wan_now - WAN_DOWN_SINCE))
                log "OK" "Интернет провайдера восстановлен (был недоступен ${wan_duration}с)"
                log_event isp_restored "$wan_duration"
                WAN_STATE="ok"
                COOLDOWN=0; COOLDOWN_UNTIL=0; RESTART_FAILS=0

                local vpn_type
                vpn_type=$(get_vpn_type)
                if [ -n "$vpn_type" ] && [ "$VPN_STATE" != "stopped" ] && [ "$VPN_STATE" != "restarting" ]; then
                    log "INFO" "Проактивный перезапуск VPN для восстановления маршрутов..."
                    if [ "$vpn_type" = "wg" ]; then
                        systemctl restart "wg-quick@${INTERFACE}" 2>/dev/null
                    else
                        systemctl restart "openvpn@${INTERFACE}" 2>/dev/null
                    fi
                    local i=0
                    local recovered=0
                    while [ $i -lt 10 ]; do
                        sleep 1; i=$((i + 1))
                        if check_iface && check_ip && ping_vpn; then
                            log "OK" "VPN восстановлен за ${i}с после возврата WAN"
                            recovered=1
                            vpn_ok=1
                            LAST_DOWN_REASON=""
                            break
                        fi
                    done
                    if [ "$recovered" -eq 1 ]; then
                        log_event auto_start "${ACTIVE_ID:-}"
                        reset_event_dedup
                    else
                        log "WARN" "VPN не поднялся за 10с после возврата WAN — идём в recovery/failover"
                        LAST_DOWN_REASON="VPN недоступен после возврата WAN"
                        vpn_ok=0
                    fi
                else
                    sleep 3
                fi
                continue
            else
                sleep "$PING_INTERVAL"
                continue
            fi
        fi

        if ! check_iface; then
            [ "$vpn_ok" -eq 1 ] && { log "WARN" "$INTERFACE пропал"; note_down "Интерфейс пропал"; vpn_ok=0; }
            check_autoup && restart_vpn
            sleep "$PING_INTERVAL"; continue
        fi

        if ! check_ip; then
            [ "$vpn_ok" -eq 1 ] && { log "WARN" "$INTERFACE без IP"; note_down "Нет IP"; vpn_ok=0; }
            check_autoup && restart_vpn
            sleep "$PING_INTERVAL"; continue
        fi

        if ! ping_vpn; then
            sleep 1
            if ! ping_vpn; then
                if ! ping_wan; then
                    if try_wan_failover; then
                        vpn_ok=0
                        COOLDOWN=0; COOLDOWN_UNTIL=0; RESTART_FAILS=0
                        check_autoup && restart_vpn
                        sleep "$PING_INTERVAL"; continue
                    fi
                    log "WARN" "Интернет провайдера недоступен — VPN не трогаем, ждём возврата"
                    log_event isp_down
                    WAN_STATE="down"
                    WAN_DOWN_SINCE=$(date +%s)
                    vpn_ok=0
                    sleep "$PING_INTERVAL"; continue
                fi
                [ "$vpn_ok" -eq 1 ] && { log "WARN" "Нет связи через $INTERFACE"; note_down "Нет связи"; vpn_ok=0; }
                check_autoup && restart_vpn
                sleep "$PING_INTERVAL"; continue
            fi
        fi

        if ! check_vpn_routing; then
            vpn_ok=0
            check_autoup && restart_vpn
            sleep "$PING_INTERVAL"; continue
        fi

        if [ "$vpn_ok" -eq 0 ]; then
            vpn_ok=1; RESTART_FAILS=0
            if [ "$VPN_STATE" != "running" ]; then
                VPN_STATE="running"; save_vpn_state
            fi
            if [ "$DAEMON_JUST_STARTED" = "1" ]; then
                if [ "$BOOTED_RECENTLY" = "1" ]; then
                    log_event auto_start "${ACTIVE_ID:-}"
                elif [ "$ACTIVATED_BY" != "manual" ] && [ "$ACTIVATED_BY" != "failover" ]; then
                    log_event auto_start "${ACTIVE_ID:-}"
                fi
                DAEMON_JUST_STARTED=0
            fi
            LAST_DOWN_REASON=""
            reset_event_dedup
            log "OK" "VPN стабилен"
        fi

        now_iface=$(date +%s)
        if [ $((now_iface - LAST_IFACE_LOAD)) -ge "$IFACE_RELOAD_INTERVAL" ]; then
            load_interfaces; LAST_IFACE_LOAD=$now_iface
        fi
        check_iptables
        if ! check_leak; then
            check_autoup && restart_vpn
            vpn_ok=0; sleep "$PING_INTERVAL"; continue
        fi

        sleep "$PING_INTERVAL"
    done
}

main_loop
