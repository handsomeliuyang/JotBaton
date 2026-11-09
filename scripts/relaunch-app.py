#!/usr/bin/env python3
"""Relaunch only the matching app executable, leaving the other channel running."""
import plistlib
import subprocess
import sys
import time
from pathlib import Path

app = Path(sys.argv[1]).resolve()
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
executable = info['CFBundleExecutable']
subprocess.run(['pkill', '-x', executable], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.5)
subprocess.run(['open', str(app), '--args', *sys.argv[2:]], check=True)
time.sleep(3)
subprocess.run(['pgrep', '-x', executable], check=True, stdout=subprocess.DEVNULL)
print('Running: ' + str(app))
