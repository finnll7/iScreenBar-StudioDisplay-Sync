#!/bin/zsh
set -euo pipefail

label="local.qiu.iScreenBarStudioSync"
account_uid=$(id -u)

launchctl bootout "gui/$account_uid/$label" 2>/dev/null || true
echo "iScreen Menu 已停止。重新开启运行 ./scripts/start.sh；下次登录仍会自动启动。"