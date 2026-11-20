#!/usr/bin/env bash
# Run in a UCRT64 MSYS2 shell with GCC installed.
set -euo pipefail
cd "$(dirname "$0")/.."
revision=57c76957a88a5bf7e05017e900aaa5663fdb3051
git clone --quiet https://github.com/betaflight/blackbox-tools.git work/blackbox-tools
git -C work/blackbox-tools checkout --quiet --detach "$revision"
sources=(parser tools platform stream decoders units blackbox_fielddefs semver utils blackbox_decode gpxwriter imu battery stats)
for i in "${!sources[@]}"; do
    sources[i]="work/blackbox-tools/src/${sources[i]}.c"
done
gcc -std=gnu99 -O2 -static -DWIN32 -D_USE_MATH_DEFINES -Iwork/blackbox-tools/lib/getopt_mb_uni \
    "${sources[@]}" work/blackbox-tools/lib/getopt_mb_uni/getopt.c -o windows/blackbox_decode.exe -lm
