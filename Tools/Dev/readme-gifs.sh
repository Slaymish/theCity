#!/bin/zsh
# Renders the README reels offscreen and encodes them to Docs/Media as GIF and H.264 MP4. Needs `make build`, ffmpeg and gifsicle.
set -euo pipefail
cd "${0:A:h}/../.."

app=build/Build/Products/Debug/TheCity.app/Contents/MacOS/TheCity
frames=$(mktemp -d)
trap 'rm -rf "$frames"' EXIT
mkdir -p Docs/Media

typeset -A fps=(showcase 12 city 15 office 20)
typeset -A width=(showcase 800 city 800 office 880)
typeset -A colours=(showcase 192 city 128 office 192)
typeset -A lossy=(showcase 35 city 45 office 20)
typeset -A hour=(showcase 18.55 city 18.15 office 18.2)
reels=("$@")
(( ${#reels} )) || reels=(showcase city office)
for reel in "${reels[@]}"; do
  [[ -n "${fps[$reel]-}" ]] || { print -u2 "Unknown reel: $reel"; exit 1; }
  perl -e 'alarm 600; exec @ARGV' "$app" -render-reel "$reel" "$frames/$reel" -fps "${fps[$reel]}" \
    -theme light -hour "${hour[$reel]}" -graphics medium -grade -workspace "$PWD/SampleWorkspace"
  ffmpeg -v error -y -framerate "${fps[$reel]}" -i "$frames/$reel/frame-%05d.png" \
    -vf "scale=${width[$reel]}:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=${colours[$reel]}:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
    -loop 0 "$frames/$reel.gif"
  ffmpeg -v error -y -framerate "${fps[$reel]}" -i "$frames/$reel/frame-%05d.png" \
    -vf "scale=${width[$reel]}:-2:flags=lanczos,format=yuv420p" -c:v libx264 -preset veryslow -tune animation \
    -crf 23 -movflags +faststart -an "Docs/Media/$reel.mp4"
  echo "Docs/Media/$reel.mp4 $(du -h "Docs/Media/$reel.mp4" | cut -f1)"
  gifsicle -O3 --lossy=${lossy[$reel]} "$frames/$reel.gif" -o "$frames/$reel-final.gif"
  bytes=$(stat -f%z "$frames/$reel-final.gif")
  if (( bytes > 8 * 1024 * 1024 )); then
    print -u2 "$reel exceeds the 8 MiB media budget ($bytes bytes). Frames kept at $frames"
    trap - EXIT
    exit 1
  fi
  mv "$frames/$reel-final.gif" "Docs/Media/$reel.gif"
  echo "Docs/Media/$reel.gif $(du -h "Docs/Media/$reel.gif" | cut -f1)"
done
