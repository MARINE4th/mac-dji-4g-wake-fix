#!/bin/bash
# <xbar.title>大疆 4G 唤醒恢复</xbar.title>
# <xbar.desc>显示 LTE 信号、USB 网卡状态和开盖恢复记录。</xbar.desc>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.type>streamable</swiftbar.type>

umask 077
base="$HOME/.dji4g-wake"
state="$base/state"
controller="$base/recover.sh"
device="$base/device"
[[ -x "$device" ]] || exit 1

for color in red yellow green gray; do
    for level in 0 1 2 3 4; do
        light="$base/icons/${color}_light${level}.png"
        dark="$base/icons/${color}_dark${level}.png"
        [[ -r "$light" && -r "$dark" ]] || continue
        printf -v "icon_${color}_${level}" '%s,%s' \
            "$(/usr/bin/base64 -i "$light")" "$(/usr/bin/base64 -i "$dark")"
    done
done

query_signal() {
    local reading
    reading=$(
        /usr/bin/curl -q --noproxy '*' --silent --fail --max-time 2 \
            -H 'Content-Type: application/json' --data-binary '{"command":"AT+QCSQ"}' \
            'http://127.0.0.1:7575/api/at' |
        /usr/bin/plutil -extract response raw -o - - 2>/dev/null |
        /usr/bin/awk '
            /^[[:space:]]*\+QCSQ:[[:space:]]*/ {
                sub(/^[[:space:]]*\+QCSQ:[[:space:]]*/, "")
                gsub(/[[:space:]"]/, "")
                split($0, value, ",")
                if (value[1] == "NOSERVICE") {
                    print "ok|0|蜂窝网络无服务"
                    exit
                }
                if (value[1] != "LTE" || value[3] !~ /^-[0-9]+$/ || value[3] < -140 || value[3] > -44)
                    next
                rsrp = value[3] + 0
                bars = (rsrp >= -120) + (rsrp >= -110) + (rsrp >= -100) + (rsrp >= -90)
                printf "ok|%d|LTE 信号 · RSRP %d dBm · %d/4 格\n", bars, rsrp, bars
                exit
            }'
    )
    printf '%s|%s\n' "$1" "${reading:-unavailable|0|暂未读到 LTE 信号}" > "$state/signal-reading"
}

remembered=
[[ ! -r "$state/last-healthy-usb" ]] || IFS= read -r remembered < "$state/last-healthy-usb"
previous_frame=
previous_record=unset
history=
phase= ts= reason= message=
signal_target=
signal_generation=0
pending=0
bars=0
signal=
next_signal=0
sample=0
# The native sampler emits one sample every half-second.
signal_interval=4
signal_backoff=20

# One persistent native sampler. Bash does not spawn status or rendering commands on each tick.
while IFS='|' read -r status mode iface link ipv4 registry now; do
    ((++sample))
    record=
    [[ ! -r "$state/current" ]] || IFS= read -r record < "$state/current"
    if [[ "$record" != "$previous_record" ]]; then
        previous_record=$record
        IFS='|' read -r phase ts reason message <<< "$record"
        history=
        if [[ -s "$state/history.log" ]]; then
            history=$(/usr/bin/tail -n 5 "$state/history.log" | /usr/bin/tail -r)
        fi
    fi

    target=
    if [[ "$phase" =~ ^(checking|recovering)$ && "$ts" =~ ^[0-9]+$ ]] && ((now - ts < 45)); then
        color=yellow
        summary="$message"
    elif [[ "$status" == module && "$mode" == ecm && "$link" == active && -n "$ipv4" ]]; then
        color=green
        target=$registry
        summary="已连接 · $iface · $ipv4"
        if [[ "$registry" != "$remembered" ]]; then
            if printf '%s\n' "$registry" > "$state/last-healthy-usb.$$" &&
                /bin/mv -f "$state/last-healthy-usb.$$" "$state/last-healthy-usb"; then
                remembered=$registry
            fi
        fi
    elif [[ "$status" == module && "$mode" == ecm ]]; then
        color=red
        target=$registry
        if [[ "$link" == active ]]; then summary="等待 DHCP · $iface"; else summary="USB 网卡链路未连接"; fi
    elif [[ "$status" == multiple || "$status" == error || -z "$status" ]]; then
        color=red
        if [[ "$status" == multiple ]]; then summary="检测到多个大疆模块"; else summary="无法读取 USB 状态"; fi
    else
        color=gray
        if [[ "$status" == module ]]; then summary="模块未处于上网模式"; else summary="未插入模块"; fi
    fi

    if [[ "$target" != "$signal_target" ]]; then
        signal_target=$target
        ((++signal_generation))
        bars=0
        signal=
    fi
    if ((pending)); then
        if [[ -r "$state/signal-reading" ]] &&
            IFS='|' read -r tag outcome level caption < "$state/signal-reading" &&
            [[ "$tag" == "$pending_tag" && "$level" =~ ^[0-4]$ && -n "$caption" ]]; then
            pending=0
            if [[ "$outcome" != ok ]]; then
                next_signal=$((sample + signal_backoff))
            fi
            if ((signal_generation == pending_generation)); then
                bars=$level
                signal=$caption
            fi
        elif ((sample >= pending_deadline)); then
            pending=0
            next_signal=$((sample + signal_backoff))
        fi
    fi
    if [[ -n "$target" ]] && ((!pending && sample >= next_signal)); then
        pending_generation=$signal_generation
        pending_tag="$$:$sample:$signal_generation"
        query_signal "$pending_tag" >/dev/null 2>&1 &
        pending=1
        pending_deadline=$((sample + 8))
        next_signal=$((sample + signal_interval))
    fi

    image_var="icon_${color}_${bars}"
    title='DJI'
    if [[ -n "${!image_var}" ]]; then
        title+=" | image=${!image_var} width=32 height=18"
    fi
    printf -v frame '%s\n---\n%s' "$title" "$summary"
    [[ -z "$signal" ]] || frame+=$'\n'"$signal"
    if [[ "$status" == module && "$mode" == ecm ]]; then
        frame+=$'\n'"立即重连 | bash=\"$controller\" param1=manual terminal=false"
    fi
    frame+=$'\n打开 DJOneHub | href=http://127.0.0.1:7575/'
    if [[ -n "$history" ]]; then
        frame+=$'\n---\n最近记录\n'"$history"
    fi
    if [[ -f "$state/technical.log" ]]; then
        frame+=$'\n'"打开诊断日志 | bash=/usr/bin/open param1=\"$state/technical.log\" terminal=false"
    fi
    if [[ "$frame" != "$previous_frame" ]]; then
        printf '~~~\n%s\n' "$frame" || exit 0
        previous_frame=$frame
    fi
done < <("$device" watch)
