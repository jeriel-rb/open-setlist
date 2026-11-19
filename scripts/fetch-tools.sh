#!/usr/bin/env bash
# Downloads the command-line tools Setlist bundles into bin/.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p bin
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fetch() { # url dest
  echo "fetching $1"
  curl -fL --retry 3 -o "$2" "$1"
}

# yt-dlp: official standalone macOS build (bundles its own Python runtime).
fetch https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos bin/yt-dlp

# ffmpeg: static builds per arch, merged into one universal binary.
fetch https://github.com/eugeneware/ffmpeg-static/releases/latest/download/ffmpeg-darwin-arm64 "$TMP/ffmpeg-arm64"
fetch https://github.com/eugeneware/ffmpeg-static/releases/latest/download/ffmpeg-darwin-x64 "$TMP/ffmpeg-x64"
lipo -create "$TMP/ffmpeg-arm64" "$TMP/ffmpeg-x64" -output bin/ffmpeg

# fpcalc: Chromaprint universal macOS build.
FP_URL=$(curl -fsSL https://api.github.com/repos/acoustid/chromaprint/releases/latest \
  | grep -o 'https://[^"]*fpcalc-[^"]*macos-universal\.tar\.gz' | head -1)
[ -n "$FP_URL" ] || { echo "could not find fpcalc macos-universal asset" >&2; exit 1; }
fetch "$FP_URL" "$TMP/fpcalc.tar.gz"
tar -xzf "$TMP/fpcalc.tar.gz" -C "$TMP"
cp "$(find "$TMP" -type f -name fpcalc | head -1)" bin/fpcalc

chmod +x bin/yt-dlp bin/ffmpeg bin/fpcalc

echo
bin/yt-dlp --version
bin/ffmpeg -version | head -1
bin/fpcalc -version
