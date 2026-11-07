#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
project_root="$PWD"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.build/module-cache"
swift build -c release --disable-sandbox --cache-path "$project_root/.build/cache" --config-path "$project_root/.build/config" --security-path "$project_root/.build/security"
app_path="$project_root/dist/Countdown.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp .build/release/Countdown "$app_path/Contents/MacOS/Countdown"
codesign --force --sign - "$app_path"
printf 'Built: %s\n' "$app_path"
