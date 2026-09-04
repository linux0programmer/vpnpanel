#!/bin/bash

CONF="/etc/vpn-panel.conf"
SRC="/opt/vpn-panel/src"
SNAPSHOTS="/opt/vpn-panel/releases"
STATE_DIR="/var/lib/vpn-panel"
DEPLOYED_FILE="$STATE_DIR/deployed"
PENDING_FILE="$STATE_DIR/pending"
LOCK_FILE="/var/lock/vpn-panel-deploy.lock"
WEB_DIR="/var/www/html"
LOG="/var/log/vpn-panel/update.log"
EVENTS="/var/log/vpn-panel/events.log"
DIAG=""
KEEP_SNAPSHOTS=5
MAX_JITTER=600
MANIFEST_FILE="release.conf"
MANIFEST_BRANCH="main"

RSYNC_EXCLUDES=(--exclude '.git' --exclude '.gitignore' --exclude '.github')

log() {
    local level="$1" msg="$2" line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg"
    mkdir -p "$(dirname "$LOG")" 2>/dev/null
    printf '%s\n' "$line" >> "$LOG" 2>/dev/null
    printf '%s\n' "$line"
}

log_event() {
    local type="$1" f1="${2:-}" f2="${3:-}"
    mkdir -p "$(dirname "$EVENTS")" 2>/dev/null
    printf '%s|%s|%s|%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$type" "$f1" "$f2" >> "$EVENTS" 2>/dev/null
    chmod 666 "$EVENTS" 2>/dev/null || true
}

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

repo_url() {
    local url
    url=$(conf_get REPO_URL)
    [ -z "$url" ] && url=$(git -C "$SRC" remote get-url origin 2>/dev/null)
    [ -z "$url" ] && url=$(git -C "$WEB_DIR" remote get-url origin 2>/dev/null)
    printf '%s' "$url"
}

src_web_root() {
    if [ -f "$SRC/panel/cabinet.php" ]; then
        printf '%s' "$SRC/panel"
    else
        printf '%s' "$SRC"
    fi
}

find_diagnostic() {
    local candidate
    for candidate in "$WEB_DIR/diagnostic.sh" "$SRC/installer/diagnostic.sh" "$SRC/diagnostic.sh"; do
        [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
    done
    return 1
}

installed_version() {
    local v
    v=$(cat /var/www/version 2>/dev/null)
    case "$v" in
        ''|*[!0-9]*) printf '0' ;;
        *)           printf '%s' "$v" ;;
    esac
}
deployed_ref()      { cat "$DEPLOYED_FILE" 2>/dev/null || printf ''; }

ensure_src() {
    local url
    url=$(repo_url)
    if [ -z "$url" ]; then
        log ERROR "не задан REPO_URL в $CONF и нет origin у существующей копии"
        return 1
    fi
    if [ ! -d "$SRC/.git" ]; then
        mkdir -p "$(dirname "$SRC")"
        log INFO "клонирую $url -> $SRC"
        local clone_out clone_rc=0
        clone_out=$(git clone "$url" "$SRC" 2>&1) || clone_rc=$?
        if [ "$clone_rc" -ne 0 ]; then
            log ERROR "клонирование не удалось (код $clone_rc)"
            log_lines ERROR "$clone_out"
            return 1
        fi
        conf_set REPO_URL "$url"
    fi
    git config --global --get-all safe.directory 2>/dev/null | grep -qx "$SRC" || \
        git config --global --add safe.directory "$SRC"
    return 0
}

log_lines() {
    local level="$1" text="$2" line
    [ -z "$text" ] && return 0
    printf '%s\n' "$text" | while IFS= read -r line; do
        [ -n "$line" ] && log "$level" "  $line"
    done
}

repo_diag() {
    local url host code
    url=$(repo_url)
    log INFO "диагностика доступа к репозиторию"
    log INFO "  REPO_URL: ${url:-не задан}"
    log INFO "  origin:   $(git -C "$SRC" remote get-url origin 2>&1 | head -1)"

    host=$(printf '%s' "$url" | sed -E 's#^[a-z+]+://##; s#^[^@]*@##; s#[:/].*$##')
    if [ -n "$host" ]; then
        if getent hosts "$host" >/dev/null 2>&1; then
            log INFO "  DNS $host: $(getent hosts "$host" | head -1 | awk '{print $1}')"
        else
            log ERROR "  DNS $host: не резолвится — смотрите /etc/resolv.conf"
        fi
    fi

    if command -v curl >/dev/null 2>&1 && [ -n "$url" ]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null)
        if [ "$code" = "000" ]; then
            log ERROR "  HTTPS $url: соединение не установлено"
        else
            log INFO "  HTTPS $url: HTTP $code"
        fi
    fi
}

fetch_src() {
    local out rc=0 moved
    out=$(git -C "$SRC" fetch --tags --prune --prune-tags --force origin 2>&1) || rc=$?

    if [ "$rc" -ne 0 ]; then
        log ERROR "git fetch завершился с кодом $rc"
        log_lines ERROR "$out"
        repo_diag
        return 1
    fi

    moved=$(printf '%s\n' "$out" | grep -c 'forced update' 2>/dev/null || printf '0')
    if [ "${moved:-0}" -gt 0 ]; then
        log WARN "теги в репозитории были передвинуты ($moved) — под прежним именем теперь другой код"
        log_lines WARN "$(printf '%s\n' "$out" | grep 'forced update')"
    fi
    return 0
}

manifest_raw() {
    git -C "$SRC" show "origin/$MANIFEST_BRANCH:$MANIFEST_FILE" 2>/dev/null
}

manifest_get() {
    local key="$1"
    manifest_raw | grep "^$key=" | head -1 | cut -d= -f2- | tr -d '\n'
}

channel_name() {
    local channel
    channel=$(conf_get CHANNEL)
    [ -z "$channel" ] && channel="stable"
    printf '%s' "$channel"
}

server_bucket() {
    local id hex
    id=$(cat /etc/machine-id 2>/dev/null)
    [ -z "$id" ] && id=$(hostname 2>/dev/null)
    [ -z "$id" ] && id="unknown"
    hex=$(printf '%s' "$id" | md5sum 2>/dev/null | cut -c1-4)
    case "$hex" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f]) printf '%s' "$(( 16#$hex % 100 ))" ;;
        *) printf '0' ;;
    esac
}

rollout_allows_me() {
    local percent="$1" bucket
    case "$percent" in
        '') return 0 ;;
        *[!0-9]*) log WARN "rollout в манифесте не число ($percent) — считаю 100%"; return 0 ;;
    esac
    [ "$percent" -ge 100 ] && return 0
    [ "$percent" -le 0 ] && return 1
    bucket=$(server_bucket)
    [ "$bucket" -lt "$percent" ]
}

latest_tag() {
    git -C "$SRC" tag --list 'v[0-9]*' --sort=-v:refname 2>/dev/null | head -1
}

target_ref() {
    local pinned channel manifest_tag
    pinned=$(conf_get PINNED_TAG)
    if [ -n "$pinned" ]; then printf '%s' "$pinned"; return 0; fi

    channel=$(channel_name)

    manifest_tag=$(manifest_get "$channel.tag")
    if [ -n "$manifest_tag" ]; then
        printf '%s' "$manifest_tag"
        return 0
    fi

    if [ "$channel" = "edge" ]; then
        printf 'origin/main'
        return 0
    fi

    local tag
    tag=$(latest_tag)
    if [ -z "$tag" ]; then
        log WARN "теги не найдены — канал stable не может выбрать релиз"
        return 1
    fi
    printf '%s' "$tag"
}

verify_ref() {
    local ref="$1"
    [ "$(conf_get VERIFY_TAGS)" = "1" ] || return 0
    case "$ref" in
        origin/*|*/*)
            log ERROR "VERIFY_TAGS=1, но цель деплоя не тег, а ветка ($ref) — подпись проверить нельзя, деплой отменён"
            return 1 ;;
    esac
    if git -C "$SRC" verify-tag "$ref" >/dev/null 2>&1; then
        log INFO "подпись тега $ref проверена"
        return 0
    fi
    log ERROR "подпись тега $ref не проверена — деплой остановлен"
    return 1
}

snapshot_now() {
    local name="$1" dir staging
    dir="$SNAPSHOTS/$name"
    staging="$dir.partial"
    rm -rf "$staging"
    mkdir -p "$staging" || return 1
    rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$WEB_DIR"/ "$staging"/ 2>/dev/null || { rm -rf "$staging"; return 1; }
    printf '%s' "$(installed_version)" > "$staging/.version" || { rm -rf "$staging"; return 1; }
    rm -rf "$dir"
    mv "$staging" "$dir" || return 1
    printf '%s' "$dir"
}

valid_snapshots() {
    local dir
    for dir in $(ls -1dt "$SNAPSHOTS"/*/ 2>/dev/null); do
        case "$dir" in *.partial/) continue ;; esac
        [ -f "${dir%/}/.version" ] || continue
        printf '%s\n' "${dir%/}"
    done
}

prune_snapshots() {
    local old
    rm -rf "$SNAPSHOTS"/*.partial 2>/dev/null
    old=$(valid_snapshots | tail -n +$((KEEP_SNAPSHOTS + 1)))
    [ -z "$old" ] && return 0
    printf '%s\n' "$old" | while read -r dir; do
        [ -n "$dir" ] && rm -rf "$dir" && log INFO "удалён старый снимок: $(basename "$dir")"
    done
}

sync_to_web() {
    local from="$1"
    rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$from"/ "$WEB_DIR"/ || return 1
    chown -R www-data:www-data "$WEB_DIR"
    local script
    for script in vpn-healthcheck.sh vpn-panel-routing.sh vpn-panel-deploy.sh diagnostic.sh; do
        [ -f "$WEB_DIR/$script" ] || continue
        chown root:root "$WEB_DIR/$script"
        chmod 755 "$WEB_DIR/$script"
    done
    return 0
}

run_migrations() {
    [ -f "$WEB_DIR/update.sh" ] || { log WARN "update.sh отсутствует — миграции пропущены"; return 0; }
    chmod +x "$WEB_DIR/update.sh"
    ( cd "$WEB_DIR" && AUTO_RUN=1 ./update.sh >> "$LOG" 2>&1 )
    local rc=$?
    [ "$rc" -ne 0 ] && log ERROR "миграции завершились с кодом $rc"
    return $rc
}

deploy_gate() {
    local missing="" f code

    for f in cabinet.php login.php index.php includes/vpn_helpers.php update.sh; do
        [ -f "$WEB_DIR/$f" ] || missing="${missing:+$missing }$f"
    done
    if [ -n "$missing" ]; then
        log ERROR "после выкладки не хватает файлов: $missing"
        return 1
    fi

    if ! systemctl is-active --quiet apache2 2>/dev/null; then
        systemctl restart apache2 2>/dev/null || true
        sleep 2
    fi
    if ! systemctl is-active --quiet apache2 2>/dev/null; then
        log ERROR "apache2 не поднялся после выкладки"
        return 1
    fi

    if command -v curl >/dev/null 2>&1; then
        code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1/login.php" 2>/dev/null)
        case "$code" in
            200|302|303) log INFO "панель отвечает по HTTP ($code)" ;;
            '') log WARN "curl не смог обратиться к панели — проверка пропущена" ;;
            *) log ERROR "панель отвечает HTTP $code — откат"; return 1 ;;
        esac
    fi

    log INFO "проверка после выкладки пройдена"
    return 0
}

health_report() {
    DIAG=$(find_diagnostic) || return 0
    bash "$DIAG" --quiet >> "$LOG" 2>&1
    local rc=$?
    case "$rc" in
        0) log INFO "diagnostic.sh: без замечаний" ;;
        1) log WARN "diagnostic.sh: есть предупреждения (см. $LOG)" ;;
        *) log WARN "diagnostic.sh: есть проваленные проверки (см. $LOG) — на откат не влияет" ;;
    esac
    return 0
}

restore_snapshot() {
    local dir="$1"
    [ -d "$dir" ] || { log ERROR "снимок не найден: $dir"; return 1; }
    log WARN "откат на снимок $(basename "$dir")"
    sync_to_web "$dir" || return 1
    local ver
    ver=$(cat "$dir/.version" 2>/dev/null)
    [ -n "$ver" ] && printf '%s' "$ver" > /var/www/version
    run_migrations || log WARN "миграции при откате завершились с ошибкой"
    systemctl restart vpn-healthcheck.service 2>/dev/null || true
    systemctl restart apache2 2>/dev/null || true
    return 0
}

manifest_gate() {
    local channel hold rollout note
    channel=$(channel_name)

    hold=$(manifest_get "$channel.hold")
    if [ "$hold" = "1" ]; then
        log INFO "выкатка остановлена в манифесте (hold=1, канал $channel)"
        return 1
    fi

    rollout=$(manifest_get "$channel.rollout")
    if [ -n "$rollout" ] && ! rollout_allows_me "$rollout"; then
        log INFO "сервер не входит в текущую волну выкатки ($rollout%, корзина $(server_bucket))"
        return 1
    fi

    note=$(manifest_get message)
    [ -n "$note" ] && log INFO "манифест: $note"
    return 0
}

unreleased_count() {
    local ref="$1" count
    [ -z "$ref" ] && return 1
    git -C "$SRC" rev-parse --verify --quiet "origin/$MANIFEST_BRANCH" >/dev/null 2>&1 || return 1
    count=$(git -C "$SRC" rev-list --count "$ref..origin/$MANIFEST_BRANCH" 2>/dev/null) || return 1
    case "$count" in ''|*[!0-9]*) return 1 ;; esac
    [ "$count" -gt 0 ] || return 1
    printf '%s' "$count"
}

report_unreleased() {
    local ref="$1" ahead
    ahead=$(unreleased_count "$ref") || return 0
    log INFO "в репозитории есть $ahead изменений после $ref — они ещё не выпущены"
    log INFO "они появятся, когда выйдет следующий релиз и release.conf укажет на него"
    return 0
}

code_version() {
    grep -m1 '^SCRIPT_VERSION=' "$WEB_DIR/update.sh" 2>/dev/null | cut -d= -f2
}

clamp_version_to_code() {
    local code_ver current_ver
    code_ver=$(code_version)
    current_ver=$(installed_version)
    [ -z "$code_ver" ] && return 0
    if [ "$current_ver" -gt "$code_ver" ] 2>/dev/null; then
        log WARN "откат схемы: /var/www/version $current_ver -> $code_ver (по коду развёрнутого релиза)"
        printf '%s' "$code_ver" > /var/www/version
    fi
    return 0
}

deploy() {
    local requested="$1" ref current snapshot stamp channel is_rollback

    if [ -s "$PENDING_FILE" ]; then
        log WARN "предыдущий деплой ($(cat "$PENDING_FILE")) не завершился — восстанавливаю последний снимок"
        local last
        last=$(valid_snapshots | head -1)
        if [ -n "$last" ]; then
            if restore_snapshot "$last"; then
                rm -f "$PENDING_FILE"
            else
                log ERROR "восстановление после прерванного деплоя не удалось"
                return 1
            fi
        else
            log ERROR "снимков нет — прерванный деплой восстановить нечем"
            rm -f "$PENDING_FILE"
        fi
    fi

    ensure_src || return 1
    fetch_src  || return 1

    if [ -z "$requested" ]; then
        manifest_gate || return 0
    fi

    if [ -n "$requested" ]; then
        ref="$requested"
    else
        ref=$(target_ref) || return 1
    fi

    git -C "$SRC" rev-parse --verify --quiet "$ref^{commit}" >/dev/null || {
        log ERROR "ссылка не найдена в репозитории: $ref"
        return 1
    }
    verify_ref "$ref" || return 1

    current=$(deployed_ref)
    local target_sha current_sha
    target_sha=$(git -C "$SRC" rev-parse --short "$ref^{commit}")
    current_sha=$(printf '%s' "$current" | awk '{print $2}')

    if [ "$current_sha" = "$target_sha" ] && [ -z "$requested" ]; then
        log INFO "установлена последняя выпущенная версия: $current"
        report_unreleased "$ref"
        return 0
    fi

    log INFO "деплой $ref ($target_sha), сейчас: ${current:-неизвестно}"
    log_event update_started "$ref" "$target_sha"

    stamp="$(date '+%Y%m%d-%H%M%S')-v$(installed_version)"
    snapshot=$(snapshot_now "$stamp") || { log ERROR "не удалось сделать снимок — деплой отменён"; return 1; }
    log INFO "снимок текущей версии: $snapshot"

    git -C "$SRC" checkout --quiet --detach "$ref" 2>/dev/null || {
        log ERROR "checkout $ref не удался"
        return 1
    }

    channel=$(channel_name)
    is_rollback=$(manifest_get "$channel.rollback")

    printf '%s %s\n' "$ref" "$target_sha" > "$PENDING_FILE"

    if ! sync_to_web "$(src_web_root)"; then
        log ERROR "синхронизация в $WEB_DIR не удалась"
        restore_snapshot "$snapshot" || log ERROR "ОТКАТ НЕ УДАЛСЯ — панель в несогласованном состоянии"
        log_event update_failed "$ref" "sync"
        rm -f "$PENDING_FILE"
        prune_snapshots
        return 1
    fi

    [ "$is_rollback" = "1" ] && clamp_version_to_code

    if ! run_migrations; then
        restore_snapshot "$snapshot" || log ERROR "ОТКАТ НЕ УДАЛСЯ — панель в несогласованном состоянии"
        log_event update_rollback "$ref" "migrations"
        rm -f "$PENDING_FILE"
        prune_snapshots
        return 1
    fi

    if ! deploy_gate; then
        restore_snapshot "$snapshot" || log ERROR "ОТКАТ НЕ УДАЛСЯ — панель в несогласованном состоянии"
        log_event update_rollback "$ref" "healthcheck"
        rm -f "$PENDING_FILE"
        prune_snapshots
        return 1
    fi

    health_report

    mkdir -p "$STATE_DIR"
    printf '%s %s\n' "$ref" "$target_sha" > "$DEPLOYED_FILE"
    rm -f "$PENDING_FILE"
    prune_snapshots
    log INFO "деплой завершён: $ref ($target_sha), версия $(installed_version)"
    log_event update_ok "$ref" "$target_sha"
    return 0
}

rollback() {
    local dir="$1" pin
    [ -z "$dir" ] && dir=$(valid_snapshots | head -1)
    [ -z "$dir" ] && { log ERROR "пригодных снимков нет"; return 1; }
    [ -d "$dir" ] || dir="$SNAPSHOTS/$dir"
    restore_snapshot "${dir%/}" || return 1
    rm -f "$PENDING_FILE"

    pin=$(deployed_ref | awk '{print $1}')
    if [ -n "$pin" ]; then
        conf_set PINNED_TAG "$pin"
        log WARN "сервер закреплён на $pin, иначе cron вернёт отклонённый релиз в течение часа"
        log WARN "снять закрепление: vpn-panel-deploy unpin"
    fi
    log_event update_rollback "$(basename "${dir%/}")" "manual"
    return 0
}

unpin() {
    conf_set PINNED_TAG ""
    log INFO "закрепление снято — сервер снова следует манифесту"
}

list_snapshots() {
    local dir
    if [ ! -d "$SNAPSHOTS" ]; then
        printf 'снимков нет\n'
        return 0
    fi
    for dir in $(valid_snapshots); do
        printf '%s\tверсия %s\n' "$(basename "$dir")" "$(cat "$dir/.version" 2>/dev/null || printf '?')"
    done
}

check() {
    ensure_src >/dev/null 2>&1 || true
    fetch_src  >/dev/null 2>&1 || true
    printf 'канал:        %s\n' "$(conf_get CHANNEL || printf 'stable')"
    printf 'закреплён:    %s\n' "$(conf_get PINNED_TAG || printf 'нет')"
    printf 'репозиторий:  %s\n' "$(repo_url || printf 'не задан')"
    printf 'развёрнуто:   %s\n' "$(deployed_ref || printf 'неизвестно')"
    printf 'версия схемы: %s\n' "$(installed_version)"
    printf 'доступно:     %s\n' "$(target_ref 2>/dev/null || printf 'не определено')"
    printf 'снимков:      %s\n' "$(ls -1d "$SNAPSHOTS"/*/ 2>/dev/null | wc -l)"

    local ref ahead
    ref=$(target_ref 2>/dev/null) || ref=""
    if ahead=$(unreleased_count "$ref"); then
        printf 'не выпущено:  %s изменений в %s после %s\n' "$ahead" "$MANIFEST_BRANCH" "$ref"
    else
        printf 'не выпущено:  нет\n'
    fi
}

auto() {
    deploy ""
}

usage() {
    cat << 'EOF'
vpn-panel-deploy <команда>

  check              что установлено, что доступно, где репозиторий
  deploy [ref]       развернуть релиз (по умолчанию — по каналу из конфига)
  auto               то же, но со случайной задержкой (для cron)
  rollback [снимок]  вернуть предыдущее состояние панели и закрепить её
  unpin              снять закрепление, вернуться под управление манифеста
  list               список снимков

Настройки в /etc/vpn-panel.conf:
  REPO_URL=...       откуда тянуть код
  CHANNEL=stable     stable — последний тег vN, edge — origin/main
  PINNED_TAG=v1      развернуть строго этот тег и не обновляться дальше
  VERIFY_TAGS=1      требовать подписанный тег (git verify-tag)

Управление парком — файл release.conf в ветке main репозитория:
  stable.tag=v1      что разворачивать на канале
  stable.hold=1      остановить выкатку на всех серверах канала
  stable.rollout=25  выкатывать только на 25% серверов (канарка)
  stable.rollback=1  считать это откатом: номер схемы опустится до версии кода
  message=...        строка попадёт в лог каждого сервера
EOF
}

jitter() {
    local delay=$((RANDOM % MAX_JITTER))
    log INFO "автообновление: пауза ${delay}с перед проверкой обновлений"
    sleep "$delay"
}

with_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null
    command -v flock >/dev/null 2>&1 || { log ERROR "flock не установлен — параллельные запуски не защищены"; return 1; }
    : > "$LOCK_FILE" 2>/dev/null || { log ERROR "не удалось открыть $LOCK_FILE"; return 1; }
    exec 9>"$LOCK_FILE"
    flock -n 9 || { log ERROR "деплой уже выполняется"; return 1; }
    return 0
}

need_root() {
    if [ "$(id -u)" != "0" ]; then
        printf 'нужны права root\n' >&2
        exit 1
    fi
    mkdir -p "$STATE_DIR" "$SNAPSHOTS" 2>/dev/null
}

case "${1:-}" in
    check)    need_root; check ;;
    list)     need_root; list_snapshots ;;
    unpin)    need_root; unpin ;;
    deploy)   need_root; with_lock || exit 1; deploy "${2:-}" ;;
    auto)     need_root; jitter; with_lock || exit 1; auto ;;
    rollback) need_root; with_lock || exit 1; rollback "${2:-}" ;;
    *)        usage; exit 1 ;;
esac
