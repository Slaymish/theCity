#!/bin/zsh
# Regenerate both app icon sets from the same miniature. Needs `make build`.
set -euo pipefail
cd "${0:A:h}/../.."

app=build/Build/Products/Debug/TheCity.app/Contents/MacOS/TheCity
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
icons=App/Assets.xcassets/AppIcon.appiconset

perl -e 'alarm 120; exec @ARGV' "$app" -render-icon "$scratch/mac.png" -theme light
for n in 16 32 128 256 512; do
  sips -z "$n" "$n" "$scratch/mac.png" --out "$icons/icon_${n}x${n}.png" >/dev/null
  double=$((n * 2))
  sips -z "$double" "$double" "$scratch/mac.png" --out "$icons/icon_${n}x${n}@2x.png" >/dev/null
done
# iOS supplies its own mask, so its source must be opaque and fill the square.
perl -e 'alarm 120; exec @ARGV' "$app" -render-icon "$scratch/ios.png" -icon-platform ios -theme light
sips -s format png "$scratch/ios.png" --out Companion/Assets.xcassets/AppIcon.appiconset/icon_1024.png >/dev/null
print 'Updated Mac and iPhone app icons.'
