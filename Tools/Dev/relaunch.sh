#!/bin/zsh
osascript -e 'tell application "TheOffice" to quit' 2>/dev/null
python3 -c "
import subprocess,time
t=time.time()
while subprocess.run(['pgrep','-x','TheOffice'],capture_output=True).stdout and time.time()-t<10: time.sleep(0.2)"
open /Users/hamish/Documents/Personal/theOffice/build/Build/Products/Debug/TheOffice.app --args "$@"
