#!/bin/zsh
osascript -e 'tell application "TheCity" to quit' 2>/dev/null
python3 -c "
import subprocess,time
t=time.time()
while subprocess.run(['pgrep','-x','TheCity'],capture_output=True).stdout and time.time()-t<10: time.sleep(0.2)"
open "${0:A:h}/../../build/Build/Products/Debug/TheCity.app" --args "$@"
