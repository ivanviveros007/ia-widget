#!/usr/bin/env python3
"""Stop QuotaGarden agents. Keep account-free snapshots and app backups for recovery."""
from pathlib import Path
import os
import subprocess

home = Path.home()
for name in ['dev.bambam.QuotaGarden.service', 'dev.bambam.QuotaGarden.app']:
    path = home / 'Library/LaunchAgents' / (name + '.plist')
    subprocess.run(['launchctl', 'bootout', 'gui/' + str(os.getuid()), str(path)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if path.exists(): path.unlink()
print('Inicio automático desactivado. La app y sus datos se conservaron.')
