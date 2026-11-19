#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

python="${PYTHON_BIN:-python3}"
"$python" -m venv work/venv
work/venv/bin/python -m pip install 'numpy==2.0.2'

decoder=work/blackbox-tools
revision=57c76957a88a5bf7e05017e900aaa5663fdb3051
if [[ ! -d "$decoder/.git" ]]; then
    git clone https://github.com/betaflight/blackbox-tools.git "$decoder"
fi
git -C "$decoder" checkout --detach "$revision"
make -C "$decoder" obj/blackbox_decode

app="outputs/Blackbox Auto-Tune.app"
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
bundle="$staging/Blackbox Auto-Tune.app"
mkdir -p "$bundle/Contents/MacOS"
cp assets/Info.plist "$bundle/Contents/"
if [[ -f assets/AppIcon.icns ]]; then
    mkdir -p "$bundle/Contents/Resources"
    cp assets/AppIcon.icns "$bundle/Contents/Resources/"
else
    /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$bundle/Contents/Info.plist"
fi
swiftc -parse-as-library -O work/BlackboxUI.swift -o "$bundle/Contents/MacOS/Blackbox Auto-Tune"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
if [[ -d "$app" ]]; then
    mv "$app" "$staging/previous.app"
fi
mv "$bundle" "$app"
printf 'Built %s\n' "$app"
