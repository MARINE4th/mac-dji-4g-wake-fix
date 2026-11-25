#!/bin/bash
set -euo pipefail
umask 077

source_dir=$(cd "$(dirname "$0")" && pwd -P)
dest="$HOME/.dji4g-wake"
plugin_dir=$(/usr/bin/defaults read com.ameba.SwiftBar PluginDirectory)
[[ -d "$plugin_dir" ]] || { echo '请先在 SwiftBar 里选择插件文件夹。' >&2; exit 1; }

label='local.dji4g.wake'
domain="gui/$(/usr/bin/id -u)"
agents="$HOME/Library/LaunchAgents"
plist="$agents/$label.plist"
tmp=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf "$tmp"' EXIT

/usr/bin/clang -std=c17 -Wall -Wextra -Werror -framework IOKit -framework CoreFoundation \
    -o "$tmp/device" "$source_dir/device.c"
/usr/bin/clang -fobjc-arc -Wall -Wextra -Werror -framework AppKit -framework IOKit \
    -o "$tmp/listener" "$source_dir/listener.m"

/usr/bin/plutil -create xml1 "$tmp/agent.plist"
/usr/bin/plutil -insert Label -string "$label" "$tmp/agent.plist"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$tmp/agent.plist"
/usr/bin/plutil -insert ProgramArguments.0 -string "$dest/listener" "$tmp/agent.plist"
/usr/bin/plutil -insert ProgramArguments.1 -string "$dest/recover.sh" "$tmp/agent.plist"
/usr/bin/plutil -insert KeepAlive -bool YES "$tmp/agent.plist"
/usr/bin/plutil -insert ProcessType -string Background "$tmp/agent.plist"
/usr/bin/plutil -lint "$tmp/agent.plist"

/bin/mkdir -p "$dest/state" "$dest/icons" "$agents"
if /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
    if ! /usr/bin/lockf -k -t 0 "$dest/state/recovery.lock" /usr/bin/true; then
        echo '正在恢复 USB，请等恢复完成后再运行安装。' >&2
        exit 1
    fi
    /bin/launchctl bootout "$domain/$label"
fi

/usr/bin/install -m 700 "$tmp/device" "$tmp/listener" "$source_dir/recover.sh" "$dest/"
/usr/bin/install -m 600 "$source_dir"/icons/*[0-4].png "$dest/icons/"
/usr/bin/install -m 600 "$tmp/agent.plist" "$plist"
/usr/bin/install -m 700 "$source_dir/dji4g.10s.sh" "$plugin_dir/"
/bin/launchctl bootstrap "$domain" "$plist"
/usr/bin/open -g 'swiftbar://refreshallplugins' >/dev/null 2>&1 || :
printf '已安装 DJI 4G 唤醒监听与 SwiftBar 插件。\n'
