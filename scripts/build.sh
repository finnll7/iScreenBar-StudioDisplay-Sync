#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
build_dir="$project_dir/build"
app_dir="$build_dir/iScreenBar Menu.app"
executable_dir="$app_dir/Contents/MacOS"

mkdir -p "$executable_dir"

xcrun swiftc -O \
  -framework AppKit \
  -framework CoreGraphics \
  -framework IOKit \
  "$project_dir/Sources/main.swift" \
  "$project_dir/Sources/PanelUI.swift" \
  -o "$executable_dir/iScreenBarStudioSync"

install -m 644 "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
mkdir -p "$app_dir/Contents/Resources"
install -m 644 "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app_dir"

echo "Built: $app_dir"
