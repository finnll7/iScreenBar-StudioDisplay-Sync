#!/bin/zsh
set -euo pipefail

label="local.qiu.iScreenBarStudioSync"
account_uid=$(id -u)
plist="$HOME/Library/LaunchAgents/$label.plist"

if launchctl print "gui/$account_uid/$label" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$account_uid/$label"
else
  if [[ ! -f "$plist" ]]; then
    echo "未找到 LaunchAgent，请先运行 ./scripts/install.sh" >&2
    exit 1
  fi
  launchctl bootstrap "gui/$account_uid" "$plist"
fi

echo "iScreen Menu 已启动。"