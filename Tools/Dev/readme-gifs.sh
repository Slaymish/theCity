#!/bin/zsh
# Renders the README reels offscreen and encodes them to Docs/Media. Needs `make build`, ffmpeg and gifsicle.
set -euo pipefail
cd "${0:A:h}/../.."

app=build/Build/Products/Debug/TheCity.app/Contents/MacOS/TheCity
frames=$(mktemp -d)
trap 'rm -rf "$frames"' EXIT
mkdir -p Docs/Media

typeset -A fps=(city 12 office 15)
for reel in city office; do
  "$app" -render-reel "$reel" "$frames/$reel" -fps 20 -theme light -workspace "$PWD/SampleWorkspace"
  ffmpeg -v error -y -framerate 20 -i "$frames/$reel/frame-%05d.png" \
    -vf "fps=${fps[$reel]},scale=800:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
    -loop 0 "$frames/$reel.gif"
  gifsicle -O3 --lossy=40 "$frames/$reel.gif" -o "Docs/Media/$reel.gif"
  echo "Docs/Media/$reel.gif $(du -h "Docs/Media/$reel.gif" | cut -f1)"
done
