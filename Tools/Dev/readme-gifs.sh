#!/bin/zsh
# Renders the README reels offscreen and encodes them to Docs/Media. Needs `make build`, ffmpeg and gifsicle.
set -euo pipefail
cd "${0:A:h}/../.."

app=build/Build/Products/Debug/TheCity.app/Contents/MacOS/TheCity
frames=$(mktemp -d)
trap 'rm -rf "$frames"' EXIT
mkdir -p Docs/Media

typeset -A fps=(showcase 8 city 12 office 15)
typeset -A width=(showcase 720 city 800 office 800)
typeset -A lossy=(showcase 80 city 40 office 40)
typeset -A hour=(showcase 18.8 city 13 office 13)
for reel in showcase city office; do
  "$app" -render-reel "$reel" "$frames/$reel" -fps 20 -theme light -hour "${hour[$reel]}" -workspace "$PWD/SampleWorkspace"
  ffmpeg -v error -y -framerate 20 -i "$frames/$reel/frame-%05d.png" \
    -vf "fps=${fps[$reel]},scale=${width[$reel]}:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
    -loop 0 "$frames/$reel.gif"
  gifsicle -O3 --lossy=${lossy[$reel]} "$frames/$reel.gif" -o "Docs/Media/$reel.gif"
  echo "Docs/Media/$reel.gif $(du -h "Docs/Media/$reel.gif" | cut -f1)"
done
