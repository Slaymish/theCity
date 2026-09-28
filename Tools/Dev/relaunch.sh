#!/bin/zsh
# Relaunches only this checkout's dev build, on its own data, so the installed city and its jobs keep running.
# Tools/Dev/relaunch.sh [--quit] [app arguments…]
root="${0:A:h}/../.."
app="${root:A}/build/Build/Products/Debug/TheCity.app"
binary="$app/Contents/MacOS/TheCity"

for pid in $(pgrep -f "^$binary"); do
  osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid).terminate" >/dev/null
done
python3 -c "
import subprocess,sys,time
t=time.time()
while subprocess.run(['pgrep','-f','^'+sys.argv[1]],capture_output=True).stdout and time.time()-t<10: time.sleep(0.2)" "$binary"

[[ "$1" == "--quit" ]] && exit 0
open -n "$app" --args -data "${root:A}/build/data" "$@"
