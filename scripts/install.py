#!/usr/bin/env python3
"""Install only this app's files and two per-user launch agents; no admin required."""
import argparse
import datetime
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
HOME = Path.home()
STATE = HOME / 'Library/Application Support/QuotaGarden'


def launch_agent(name, arguments, keep_alive=False):
    folder = HOME / 'Library/LaunchAgents'
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / (name + '.plist')
    spec = dict(Label=name, ProgramArguments=arguments, RunAtLoad=True,
                StandardOutPath=str(STATE / (name + '.out.log')),
                StandardErrorPath=str(STATE / (name + '.err.log')),
                EnvironmentVariables={'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/Users/' + HOME.name + '/.local/bin'})
    if keep_alive: spec.update(KeepAlive=True, ThrottleInterval=15)
    path.write_bytes(plistlib.dumps(spec))
    domain = 'gui/' + str(os.getuid())
    subprocess.run(['launchctl', 'bootout', domain, str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['launchctl', 'bootstrap', domain, str(path)], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--receiver', action='store_true')
    parser.add_argument('--app-source', type=Path, required=True)
    parser.add_argument('--server-ip')
    parser.add_argument('--server-user', default='ivanviveros')
    args = parser.parse_args()
    app_source = args.app_source.resolve()
    if not app_source.is_dir(): raise SystemExit('App no encontrada: ' + str(app_source))
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    runtime = STATE / 'runtime/collector'
    runtime.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / 'collector/quota_service.py', runtime)
    helper = ROOT / 'collector/keychain-reader'
    if helper.exists() and not args.receiver: shutil.copy2(helper, runtime)
    destination = HOME / 'Applications/Cuota IA.app'
    destination.parent.mkdir(exist_ok=True)
    if destination.exists():
        with (destination / 'Contents/Info.plist').open('rb') as f: old = plistlib.load(f)
        if old.get('CFBundleIdentifier') != 'dev.bambam.QuotaGarden':
            raise SystemExit('Ya existe otra aplicación con este nombre; no se reemplazó.')
        subprocess.run(['pkill', '-x', 'Cuota IA'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        backup = STATE / ('app-backup-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
        shutil.move(str(destination), str(backup))
    shutil.copytree(app_source, destination, symlinks=True)
    if args.receiver:
        # Ventura runs the universal companion; the desktop extension requires macOS 14.
        plugins = destination / 'Contents/PlugIns'
        if plugins.exists():
            shutil.rmtree(plugins)
            subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(destination)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        (STATE / 'config.json').write_text(json.dumps({'role': 'receiver'}))
    if args.server_ip and not args.receiver:
        address = str(ipaddress.ip_address(args.server_ip))
        if not args.server_user.replace('_', '').isalnum(): raise SystemExit('Usuario inválido')
        ssh_config = ('Host quota-server\n  HostName ' + address + '\n  User ' + args.server_user +
                      '\n  IdentityFile ' + str(HOME / '.ssh/id_fitness_server') +
                      '\n  IdentitiesOnly yes\n  HostKeyAlias 192.168.86.246\n  StrictHostKeyChecking yes\n')
        path = STATE / 'ssh.config'; path.write_text(ssh_config); path.chmod(0o600)
        (STATE / 'config.json').write_text(json.dumps({'sshAlias': 'quota-server'}))
    arguments = ['/usr/bin/python3', str(runtime / 'quota_service.py')]
    if args.receiver: arguments.append('--receiver')
    launch_agent('dev.bambam.QuotaGarden.service', arguments, keep_alive=True)
    launch_agent('dev.bambam.QuotaGarden.app', ['/usr/bin/open', str(destination)])
    print('Instalado:', destination)
    print('Servicio:', 'receptor SSH' if args.receiver else 'recolector local')


if __name__ == '__main__': main()
