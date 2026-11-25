#!/bin/bash
set -u
umask 077

base=$(cd "$(dirname "$0")" && pwd -P) || exit 1
state="$base/state"
device="$base/device"
label='com.jamie.djonehub'
domain="gui/$(/usr/bin/id -u)"
job="$domain/$label"
plist="$HOME/Library/LaunchAgents/$label.plist"
restart_marker="$state/restore-djonehub"
last_healthy="$state/last-healthy-usb"

/bin/mkdir -p "$state" || exit 1

read_link() {
    status=absent
    location=-
    registry=-
    mode=-
    iface=-
    owner_pid=0
    owner_name=-
    ipv4=
    link=missing

    local snapshot config
    snapshot=$("$device" inspect) || return 1
    IFS='|' read -r status location registry mode iface owner_pid owner_name <<< "$snapshot"
    if [[ "$status" == module && "$iface" =~ ^en[0-9]+$ ]]; then
        config=$(/sbin/ifconfig "$iface" 2>/dev/null) || return 0
        link=$(awk '$1 == "status:" {print $2; exit}' <<< "$config")
        ipv4=$(awk '$1 == "inet" && $2 != "192.0.0.2" && $2 !~ /^(169\.254\.|0\.|127\.)/ {print $2; exit}' <<< "$config")
    fi
}

remember_healthy_usb() {
    [[ "$status" == module && "$mode" == ecm && "$link" == active && -n "$ipv4" ]] || return 0
    if [[ ! -f "$last_healthy" || $(<"$last_healthy") != "$registry" ]]; then
        printf '%s\n' "$registry" > "$last_healthy.$$" &&
            /bin/mv -f "$last_healthy.$$" "$last_healthy"
    fi
}

trim_log() {
    local file=$1 size
    [[ -f "$file" ]] || return 0
    size=$(/usr/bin/stat -f %z "$file") || return 1
    if ((size > 32768)); then
        /usr/bin/tail -c 24576 "$file" | LC_ALL=C /usr/bin/sed '1d' > "$file.$$" &&
            /bin/mv -f "$file.$$" "$file"
    fi
}

technical_log() {
    local result
    "$@" >> "$state/technical.log" 2>&1
    result=$?
    trim_log "$state/technical.log"
    return "$result"
}

publish() {
    local phase=$1 message=$2 now temp
    now=$(/bin/date +%s)
    temp="$state/current.$$"
    printf '%s|%s|%s|%s\n' "$phase" "$now" "$reason" "$message" > "$temp" &&
        /bin/mv -f "$temp" "$state/current"
}

finish() {
    local phase=$1 message=$2
    case "$phase" in healthy|recovered) remember_healthy_usb ;; esac
    printf '%s  %s · %s\n' "$(/bin/date '+%m-%d %H:%M:%S')" "$reason" "$message" >> "$state/history.log"
    trim_log "$state/history.log"
    publish "$phase" "$message"
}

restore_service() {
    [[ -f "$restart_marker" ]] || return 0
    if ! /bin/launchctl print "$job" >/dev/null 2>&1; then
        technical_log /bin/launchctl bootstrap "$domain" "$plist" || return 1
    fi
    /bin/rm -f "$restart_marker"
}

pause_usb_owner() {
    [[ "$owner_pid" != 0 && ! -f "$restart_marker" ]] || return 0
    local job_info job_pid
    job_info=$(/bin/launchctl print "$job" 2>/dev/null)
    job_pid=$(awk '$1 == "pid" && $2 == "=" {print $3; exit}' <<< "$job_info")
    if [[ "$owner_name" != djonehub-macos || "$owner_pid" != "$job_pid" || ! -r "$plist" ]]; then
        finish failed 'USB 正由其他进程占用'
        return 1
    fi
    publish recovering '正在释放 DJOneHub 的 USB 句柄'
    if ! : > "$restart_marker"; then
        finish failed '无法记录 DJOneHub 后台恢复状态'
        return 1
    fi
    if ! technical_log /bin/launchctl bootout "$job"; then
        finish failed '无法暂停 DJOneHub 后台'
        return 1
    fi
}

show_link() {
    if read_link; then
        remember_healthy_usb
    else
        status=error
    fi
    printf '%s|%s|%s|%s|%s\n' "$status" "$mode" "$iface" "$link" "$ipv4"
}

if [[ ${1:-} == status ]]; then
    show_link
    exit 0
fi
if [[ ${1:-} != --locked ]]; then
    case "${1:-}" in
        wake|manual|resume)
            exec /usr/bin/lockf -k -t 0 "$state/recovery.lock" "$0" --locked "$@"
            ;;
        *) exit 2 ;;
    esac
fi
shift
action=$1
reason=${2:-手动}
if [[ "$action" == resume ]]; then
    trim_log "$state/history.log"
    trim_log "$state/technical.log"
    trim_log "$state/listener.log"
    restore_service
    exit $?
fi

trap 'restore_service' EXIT
trap 'exit 1' HUP INT TERM
if ! restore_service; then
    finish failed 'DJOneHub 后台恢复失败'
    exit 1
fi

if [[ "$action" == wake && $("$device" lid) == closed ]]; then
    exit 0
fi

started=$(/bin/date +%s)
read_link || { finish failed '无法读取 USB 设备状态'; exit 1; }

if [[ "$action" == wake ]]; then
    previous_registry=
    [[ ! -r "$last_healthy" ]] || previous_registry=$(<"$last_healthy")
    inactive_samples=0
    for ((sample=0; sample<=24; sample++)); do
        [[ $("$device" lid) == closed ]] && exit 0
        if [[ "$status" == module && "$mode" == ecm && "$link" == active && -n "$ipv4" ]]; then
            finish healthy "连接正常 · $iface · $ipv4"
            exit 0
        fi
        if ((sample == 0)) && [[ "$status" == module && "$mode" == ecm ]]; then
            publish checking '正在检查 USB 网卡'
        fi
        # Only accelerate a known USB instance that previously had a working link.
        if [[ "$status" == module && "$mode" == ecm && "$link" == inactive && "$registry" == "$previous_registry" ]]; then
            ((++inactive_samples))
            ((inactive_samples >= 3)) && break
        else
            inactive_samples=0
        fi
        if ((sample == 24)) || { ((sample >= 8)) && [[ "$link" != active ]]; }; then
            break
        fi
        /bin/sleep 0.5
        read_link || { finish failed '无法读取 USB 设备状态'; exit 1; }
    done
fi

case "$status" in
    absent)
        if [[ "$action" == manual ]]; then finish absent '未找到大疆模块'; else publish absent '未插入大疆模块'; fi
        exit 0
        ;;
    multiple) finish failed '检测到多个同型号模块，无法确定恢复目标'; exit 1 ;;
esac
if [[ "$mode" != ecm ]]; then
    finish standby '模块未处于 ECM 上网模式'
    exit 0
fi
if [[ "$action" == wake ]]; then
    [[ $("$device" lid) == closed ]] && exit 0
    if [[ "$link" == active ]]; then
        if [[ -n "$ipv4" ]]; then
            finish healthy "连接正常 · $iface · $ipv4"
        else
            finish waiting 'USB 链路已连接，等待 DHCP 地址'
        fi
        exit 0
    fi
fi

target=$registry
target_location=$location
pause_usb_owner || exit 1

if [[ "$action" == wake && $("$device" lid) == closed ]]; then
    finish standby '已合盖，恢复将在下次唤醒时检查'
    exit 0
fi
if [[ "$action" == wake ]]; then
    read_link || { finish failed '无法读取 USB 设备状态'; exit 1; }
    if [[ "$status" == module && "$link" == active && -n "$ipv4" ]]; then
        finish healthy "连接已恢复 · $iface · $ipv4"
        exit 0
    fi
fi

publish recovering '正在重新枚举 USB'
technical_log printf '%s  %s · USB %s\n' "$(/bin/date '+%F %T')" "$reason" "$target"
for ((attempt=1; attempt<=5; attempt++)); do
    technical_log "$device" reenumerate "$target"
    result=$?
    # Code 75 means opening the device failed before any USB request was sent.
    if ((result != 75 || attempt == 5)); then
        break
    fi
    /bin/sleep 0.15
    read_link || break
    [[ "$status" == module && "$registry" == "$target" ]] || break
    pause_usb_owner || exit 1
done
if ((result != 0)); then
    restore_service || { finish failed 'USB 请求失败，DJOneHub 后台恢复失败'; exit 1; }
    finish failed 'USB 重新枚举请求失败'
    exit 1
fi

publish recovering '正在等待网卡与 DHCP'
restored=false
for ((sample=0; sample<80; sample++)); do
    /bin/sleep 0.25
    if ! read_link; then
        continue
    fi
    if [[ "$status" == module && "$location" == "$target_location" && "$registry" != "$target" ]]; then
        if ! restore_service; then
            finish failed 'USB 操作已完成，DJOneHub 后台恢复失败'
            exit 1
        fi
        if [[ "$link" == active && -n "$ipv4" ]]; then
            restored=true
            break
        fi
    fi
done

if ! restore_service; then
    finish failed 'USB 操作已完成，DJOneHub 后台恢复失败'
    exit 1
fi

if "$restored"; then
    elapsed=$(( $(/bin/date +%s) - started ))
    finish recovered "已重连 · ${elapsed} 秒 · $iface · $ipv4"
else
    finish failed 'USB 重新枚举后，网卡或 DHCP 未在 20 秒内恢复'
    exit 1
fi
