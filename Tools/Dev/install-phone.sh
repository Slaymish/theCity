#!/bin/sh
# Builds the iPhone companion and installs it on your phone over Wi-Fi (or a cable), then launches it.
#
#   THECITY_TEAM=<team id> Tools/Dev/install-phone.sh [device name or UDID]
#
# THECITY_BUNDLE_ID overrides the bundle id, for a free account whose team can't register the default.
# First time only: plug the phone in, turn on Developer Mode, and in Xcode's Window > Devices and Simulators
# tick "Connect via network". After that the phone only needs to be unlocked and on the same Wi-Fi.
# A free Apple ID's install stops opening after 7 days; run this again to renew it.
set -eu
cd "$(dirname "$0")/../.."

: "${THECITY_TEAM:?Set THECITY_TEAM to your Apple team ID (see Docs/Companion.md).}"
bundle_id="${THECITY_BUNDLE_ID:-nz.hamish.thecity.companion}"
want="${1:-}"

list="$(mktemp)"
trap 'rm -f "$list"' EXIT
xcrun devicectl list devices --json-output "$list" >/dev/null

# The first available iPhone, or the one named on the command line.
udid="$(WANT="$want" python3 - "$list" <<'PY'
import json, os, sys
want = os.environ["WANT"].lower()
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    props, hw = d.get("deviceProperties", {}), d.get("hardwareProperties", {})
    if hw.get("deviceType") != "iPhone":
        continue
    if want and want not in (props.get("name", "").lower(), hw.get("udid", "").lower()):
        continue
    if d.get("connectionProperties", {}).get("tunnelState") == "unavailable":
        continue
    print(hw["udid"])
    break
PY
)"
if [ -z "$udid" ]; then
    echo "No iPhone found. Unlock it, keep it on the same Wi-Fi as this Mac, and check 'Connect via network' in Xcode's Devices window." >&2
    xcrun devicectl list devices >&2 || true
    exit 1
fi

make project
xcodebuild -project TheCity.xcodeproj -scheme TheCityCompanion -configuration Debug \
    -destination "id=$udid" -derivedDataPath build -allowProvisioningUpdates -quiet \
    PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" build

app="build/Build/Products/Debug-iphoneos/TheCityCompanion.app"
xcrun devicectl device install app --device "$udid" "$app"
xcrun devicectl device process launch --device "$udid" "$bundle_id"
