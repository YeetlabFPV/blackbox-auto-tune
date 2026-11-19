#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname -m)" != arm64 ]]; then
    echo "This packaging script requires an Apple Silicon Mac." >&2
    exit 1
fi

revision=57c76957a88a5bf7e05017e900aaa5663fdb3051
runtime_url='https://github.com/astral-sh/python-build-standalone/releases/download/20261110/cpython-3.12.16%2B20261110-aarch64-apple-darwin-install_only_stripped.tar.gz'
runtime_hash=2f11b8aa3726bdbd87dd9eb76568412faddf4f47e26913fa45d6a2e424972acd
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
curl -fLsS "$runtime_url" -o "$staging/python.tar.gz"
printf '%s  %s\n' "$runtime_hash" "$staging/python.tar.gz" | shasum -a 256 -c
git clone --quiet https://github.com/betaflight/blackbox-tools.git "$staging/decoder"
git -C "$staging/decoder" checkout --quiet --detach "$revision"
make -C "$staging/decoder" obj/blackbox_decode

image="$staging/image"
app="$image/Blackbox Auto-Tune.app"
resources="$app/Contents/Resources"
mkdir -p "$resources" "$app/Contents/MacOS"
cp assets/Info.plist "$app/Contents/"
if [[ -f assets/AppIcon.icns ]]; then
    cp assets/AppIcon.icns "$resources/"
else
    /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$app/Contents/Info.plist"
fi
cp outputs/bb_tune.py outputs/Anleitung.md "$resources/"
cp "$staging/decoder/obj/blackbox_decode" "$resources/"
tar -xzf "$staging/python.tar.gz" -C "$resources"
"$resources/python/bin/python3" -m pip install --no-cache-dir 'numpy==2.0.2'
swiftc -target arm64-apple-macosx14.0 -parse-as-library -O work/BlackboxUI.swift \
    -o "$app/Contents/MacOS/Blackbox Auto-Tune"
git -C "$staging/decoder" archive --format=tar.gz --prefix=blackbox-tools/ \
    -o "$image/Blackbox Tools Source.tar.gz" "$revision"
cp "$staging/decoder/LICENSE" "$image/Blackbox Tools License.txt"
ln -s /Applications "$image/Applications"
xattr -cr "$app"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
destination="${1:-outputs/Blackbox-Auto-Tune-macOS-arm64.dmg}"
hdiutil create -fs HFS+ -volname 'Blackbox Auto-Tune' -srcfolder "$image" -format UDZO "$destination"
