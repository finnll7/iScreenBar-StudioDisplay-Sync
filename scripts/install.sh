#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
account_name=$(id -un)
account_uid=$(id -u)
user_home_dir=$(dscl . -read "/Users/$account_name" NFSHomeDirectory | awk '{print $2}')
source_app="$project_dir/build/iScreen Menu.app"
# 默认装到用户级目录；传 INSTALL_DIR=/Applications 可装进系统应用目录（自动判断是否需要 sudo）。
install_dir="${INSTALL_DIR:-$user_home_dir/Applications}"
installed_app="$install_dir/iScreen Menu.app"
launch_agents_dir="$user_home_dir/Library/LaunchAgents"
launch_agent="$launch_agents_dir/local.qiu.iScreenBarStudioSync.plist"
logs_dir="$user_home_dir/Library/Logs"
log_file="$logs_dir/iScreenBarStudioSync.log"
label="local.qiu.iScreenBarStudioSync"

"$script_dir/build.sh"

launchctl bootout "gui/$account_uid/$label" 2>/dev/null || true
# 等旧进程完全退出，否则新实例会被单实例保护判定为重复运行而直接退出。
for _ in {1..60}; do
  pgrep -f iScreenBarStudioSync >/dev/null || break
  sleep 0.1
done
# bootout 可能留下孤儿进程，它们会独占 HID 并让新实例退出。
pkill -f "Contents/MacOS/iScreenBarStudioSync" 2>/dev/null || true
sleep 0.5
mkdir -p "$launch_agents_dir" "$logs_dir"
if [[ ! -d "$install_dir" ]]; then
  if [[ "$install_dir" == /Applications ]]; then
    sudo mkdir -p "$install_dir"
  else
    mkdir -p "$install_dir"
  fi
fi
if [[ -w "$install_dir" ]]; then
  ditto "$source_app" "$installed_app"
else
  echo "目标目录需要管理员权限，正在用 sudo 复制到 $install_dir ?"
  sudo ditto "$source_app" "$installed_app"
  sudo chown -R "$account_name":staff "$installed_app"
fi

escaped_executable=${installed_app//&/&amp;}
escaped_log=${log_file//&/&amp;}

{
  print '<?xml version="1.0" encoding="UTF-8"?>'
  print '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  print '<plist version="1.0"><dict>'
  print '<key>Label</key><string>local.qiu.iScreenBarStudioSync</string>'
  print '<key>ProgramArguments</key><array>'
  print "<string>$escaped_executable/Contents/MacOS/iScreenBarStudioSync</string>"
  print '</array>'
  print '<key>RunAtLoad</key><true/>'
  print '<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>'
  print '<key>ThrottleInterval</key><integer>10</integer>'
  print "<key>StandardOutPath</key><string>$escaped_log</string>"
  print "<key>StandardErrorPath</key><string>$escaped_log</string>"
  print '</dict></plist>'
} > "$launch_agent"

plutil -lint "$launch_agent"
launchctl bootstrap "gui/$account_uid" "$launch_agent"

echo "iScreen Menu 已安装并启动，请从菜单栏打开。"
echo "Log: $log_file"
