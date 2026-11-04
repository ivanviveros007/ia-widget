#!/usr/bin/env python3
"""Read-only subscription monitor. No inference calls or provider secrets in snapshots."""
import argparse
import concurrent.futures
import datetime as dt
import http.server
import json
import math
import os
from pathlib import Path
import secrets
import selectors
import shutil
import subprocess
import threading
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent
STATE = Path(os.environ.get('QUOTA_STATE', Path.home() / 'Library/Application Support/QuotaGarden'))
LOCK = threading.RLock()
NAMES = {'codex': 'Codex', 'chatgpt': 'ChatGPT', 'claude': 'Claude', 'gemini': 'Gemini'}


def now():
    return time.time()


def window(label, percent, reset=None):
    if isinstance(percent, bool) or not isinstance(percent, (int, float)) or not math.isfinite(percent) or not 0 <= percent <= 100:
        return None
    if isinstance(reset, str):
        try:
            reset = dt.datetime.fromisoformat(reset.replace('Z', '+00:00')).timestamp()
        except ValueError:
            reset = None
    if isinstance(reset, bool) or not isinstance(reset, (int, float)) or not math.isfinite(reset):
        reset = None
    return {'label': label, 'usedPercent': percent, 'resetsAt': reset}


def provider(key, windows=None, message='', status='ok', **extra):
    return dict(id=key, name=NAMES[key], status=status, windows=[w for w in windows or [] if w],
                message=message, updatedAt=now(), **extra)


def unavailable(key, message):
    return provider(key, message=message, status='unavailable')


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=path.name + '.', dir=str(path.parent))
    with os.fdopen(fd, 'w') as f:
        json.dump(value, f, ensure_ascii=False, allow_nan=False)
    os.replace(temporary, path)


def codex_usage():
    exe = shutil.which('codex')
    candidates = [Path('/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'),
                  Path('/Applications/Codex.app/Contents/Resources/codex')]
    exe = exe or next((str(p) for p in candidates if p.is_file()), None)
    if not exe:
        return unavailable('codex', 'Abrí Codex e iniciá sesión para conectar tu plan.')
    proc = subprocess.Popen([exe, 'app-server'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, start_new_session=True)
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    def send(value):
        proc.stdin.write((json.dumps(value) + '\n').encode()); proc.stdin.flush()
    result = {}
    pending = b''
    try:
        send({'id': 0, 'method': 'initialize', 'params': {'clientInfo': {'name': 'quota_garden', 'version': '0.1.0'}}})
        deadline = now() + 25
        while now() < deadline and len(result) < 2:
            if not selector.select(timeout=1):
                continue
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                break
            pending += chunk
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                try:
                    item = json.loads(line)
                except ValueError:
                    continue
                ident = item.get('id')
                if ident == 0:
                    if 'error' in item:
                        raise RuntimeError('initialization')
                    send({'method': 'initialized', 'params': {}})
                    send({'id': 1, 'method': 'account/rateLimits/read'})
                    send({'id': 2, 'method': 'account/usage/read'})
                elif ident in (1, 2):
                    result[ident] = item.get('result', {})
        rate = result.get(1, {})
        bucket = rate.get('rateLimitsByLimitId', {}).get('codex') or rate.get('rateLimits') or {}
        windows = []
        for field, label in [('primary', 'Sesión'), ('secondary', 'Semanal')]:
            raw = bucket.get(field) or {}
            w = window(label, raw.get('usedPercent'), raw.get('resetsAt'))
            if w:
                minutes = raw.get('windowDurationMins')
                if minutes == 300: w['label'] = '5 horas'
                elif minutes == 10080: w['label'] = 'Semanal'
                windows.append(w)
        if not windows:
            return unavailable('codex', 'No se pudieron leer los límites. Revisá tu sesión de Codex.')
        summary = result.get(2, {}).get('summary') or {}
        tokens = summary.get('lifetimeTokens')
        # Account activity is a historical metric, never a subscription allowance.
        return provider('codex', windows, 'Cuota de tu plan · fuente: Codex', plan=bucket.get('planType'),
                        lifetimeTokens=tokens if isinstance(tokens, int) and tokens >= 0 else None)
    finally:
        selector.close()
        proc.terminate()
        try: proc.wait(timeout=3)
        except subprocess.TimeoutExpired: proc.kill(); proc.wait()
        proc.stdin.close(); proc.stdout.close()


def claude_usage():
    credentials = Path.home() / '.claude/.credentials.json'
    if credentials.is_file():
        raw = json.loads(credentials.read_text())
    else:
        helper = ROOT / 'keychain-reader'
        if not helper.is_file():
            return unavailable('claude', 'Falta el lector del Llavero. Ejecutá la instalación.')
        r = subprocess.run([str(helper)], capture_output=True, timeout=8)
        if r.returncode:
            return unavailable('claude', 'Iniciá sesión en Claude Code y permití acceso al Llavero desde Conectar.')
        raw = json.loads(r.stdout)
    auth = raw.get('claudeAiOauth') or {}
    token = auth.get('accessToken')
    if not token:
        return unavailable('claude', 'Iniciá sesión en Claude Code con tu suscripción.')
    if (auth.get('expiresAt') or 0) < now() * 1000:
        return unavailable('claude', 'Sesión vencida. Abrí Claude Code para renovarla.')
    req = urllib.request.Request('https://api.anthropic.com/api/oauth/usage', headers={
        'Authorization': 'Bearer ' + token, 'anthropic-beta': 'oauth-2025-04-20', 'User-Agent': 'QuotaGarden/0.1'})
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            data = json.load(response)
    except urllib.error.HTTPError as error:
        if error.code in (401, 403):
            return unavailable('claude', 'Reconectá Claude Code: la sesión no permite consultar el uso.')
        return unavailable('claude', 'Claude no respondió. Reintentaremos sin modificar tu sesión.')
    windows = []
    for key, label in [('five_hour', '5 horas'), ('seven_day', 'Semanal'),
                       ('seven_day_sonnet', 'Sonnet semanal'), ('seven_day_opus', 'Opus semanal')]:
        raw = data.get(key) or {}
        w = window(label, raw.get('utilization'), raw.get('resets_at'))
        if w: windows.append(w)
    if not windows:
        return unavailable('claude', 'Claude no devolvió una medición válida.')
    return provider('claude', windows, 'Claude y Claude Code · cuota de tu plan', plan=auth.get('subscriptionType'))


def gemini_from_web(data):
    """Accept only normalized Gemini subscription response, never browser cookies."""
    if isinstance(data, list):
        data = next((item for item in data if isinstance(item, dict) and isinstance(item.get('data'), dict)
                     and 'viewer' in item['data']), {})
    try: pools = data['data']['viewer']['rpcs']['getUsageInfo']['pools']
    except (KeyError, TypeError): raise ValueError('Gemini no devolvió cuotas de la app.')
    windows = []
    if not isinstance(pools, list): raise ValueError('pools')
    for pool in pools:
        if not isinstance(pool, dict): continue
        label = {'GXU_FIVE_HOURLY': '5 horas', 'GXU_WEEKLY': 'Semanal'}.get(pool.get('poolType'))
        percent = pool.get('percentageUsed')
        if label and isinstance(percent, (int, float)) and not isinstance(percent, bool) and 0 <= percent <= 1:
            reset = (pool.get('gxu') or {}).get('windowRefreshesAt')
            # GraphQL may supply an ISO string or Unix seconds.
            if isinstance(reset, dict): reset = reset.get('seconds')
            w = window(label, percent * 100, reset)
            if w: windows.append(w)
    if not windows: raise ValueError('Sin datos de uso válidos para Gemini.')
    windows.sort(key=lambda entry: 0 if entry['label'] == '5 horas' else 1)
    return provider('gemini', windows, 'Gemini app · lectura desde tu sesión web')


def validate_snapshot(data):
    """Whitelist every exported field so arbitrary account data can never be synchronized."""
    output = []
    if not isinstance(data, dict) or data.get('schemaVersion') != 1: raise ValueError('schema')
    generated = data.get('generatedAt')
    if not isinstance(generated, (int, float)) or not math.isfinite(generated): raise ValueError('timestamp')
    items = data.get('providers')
    if not isinstance(items, list) or len(items) != 4: raise ValueError('providers')
    for key in NAMES:
        raw = next((p for p in items if isinstance(p, dict) and p.get('id') == key), None)
        if not raw: raise ValueError('provider')
        status = raw.get('status')
        if status not in ('ok', 'unavailable', 'stale'): raise ValueError('status')
        timestamp = raw.get('updatedAt')
        if not isinstance(timestamp, (int, float)) or not math.isfinite(timestamp): raise ValueError('timestamp')
        windows = [window(str(w.get('label', 'Cuota'))[:60], w.get('usedPercent'), w.get('resetsAt'))
                   for w in raw.get('windows', [])[:12] if isinstance(w, dict)]
        entry = provider(key, windows, str(raw.get('message', ''))[:250], status,
                         plan=str(raw['plan'])[:40] if raw.get('plan') else None)
        entry['updatedAt'] = timestamp
        tokens = raw.get('lifetimeTokens')
        if isinstance(tokens, int) and not isinstance(tokens, bool) and tokens >= 0: entry['lifetimeTokens'] = tokens
        output.append(entry)
    return dict(schemaVersion=1, generatedAt=generated, providers=output)


def initial_snapshot():
    return dict(schemaVersion=1, generatedAt=now(), providers=[
        unavailable('codex', 'Conectando con Codex…'),
        unavailable('chatgpt', 'Sin contador independiente verificado. Abrí ChatGPT para consultar sus límites.'),
        unavailable('claude', 'Conectando con Claude…'),
        unavailable('gemini', 'Conectá Gemini desde la app para leer su consumo.')])


def read_snapshot():
    try: return validate_snapshot(json.loads((STATE / 'snapshot.json').read_text()))
    except (OSError, ValueError, TypeError): return initial_snapshot()


def collect():
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = {key: pool.submit(fn) for key, fn in [('codex', codex_usage), ('claude', claude_usage)]}
        results = {}
        for key, future in futures.items():
            try: results[key] = future.result()
            except Exception: results[key] = unavailable(key, 'No se pudo actualizar. Reintentaremos automáticamente.')
    with LOCK:
        snapshot = read_snapshot()
        for i, old in enumerate(snapshot['providers']):
            new = results.get(old['id'])
            if new:
                if new['status'] != 'ok' and old['windows']:
                    old['status'] = 'stale'; old['message'] = new['message']
                else: snapshot['providers'][i] = new
        snapshot['generatedAt'] = now()
        atomic_json(STATE / 'snapshot.json', validate_snapshot(snapshot))


def sync_remote():
    config_path = STATE / 'config.json'
    try: config = json.loads(config_path.read_text())
    except (OSError, ValueError): return
    # Use an SSH config alias, never shell interpolation or a provider credential.
    alias = config.get('sshAlias')
    if not alias or not all(c.isalnum() or c in '-_' for c in alias): return
    snapshot = json.dumps(read_snapshot(), ensure_ascii=False).encode()
    command = ['ssh', '-F', str(STATE / 'ssh.config'), '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', alias,
               'python3 "$HOME/QuotaGarden/collector/quota_service.py" --ingest']
    try:
        result = subprocess.run(command, input=snapshot, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=12)
        atomic_json(STATE / 'sync.json', {'ok': result.returncode == 0, 'attemptedAt': now()})
    except (OSError, subprocess.TimeoutExpired):
        atomic_json(STATE / 'sync.json', {'ok': False, 'attemptedAt': now()})


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def respond(self, code, data):
        body = json.dumps(data, ensure_ascii=False, allow_nan=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path == '/health': return self.respond(200, {'ok': True})
        if self.path != '/v1/usage': return self.respond(404, {'error': 'not_found'})
        with LOCK: self.respond(200, read_snapshot())
    def do_POST(self):
        # No CORS; writes require an installation-specific secret, not browser cookies.
        expected = (STATE / 'control.key').read_text().strip()
        if not secrets.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + expected):
            return self.respond(401, {'error': 'unauthorized'})
        if self.path not in ('/v1/gemini', '/v1/chatgpt/capability'): return self.respond(404, {'error': 'not_found'})
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 262144: raise ValueError('size')
            body = json.loads(self.rfile.read(length))
            if self.path == '/v1/chatgpt/capability':
                if not isinstance(body, dict) or body.get('chatMessagesExcluded') is not True: raise ValueError('capability')
                item = unavailable('chatgpt', 'Cuenta conectada. La página de uso excluye los chats normales; su contador corresponde a Codex y Work.')
            else:
                item = gemini_from_web(body)
            with LOCK:
                snapshot = read_snapshot()
                snapshot['providers'] = [item if p['id'] == item['id'] else p for p in snapshot['providers']]
                snapshot['generatedAt'] = now()
                atomic_json(STATE / 'snapshot.json', validate_snapshot(snapshot))
            self.respond(200, {'ok': True})
            threading.Thread(target=sync_remote, daemon=True).start()
        except (ValueError, TypeError, KeyError): self.respond(400, {'error': 'invalid_usage'})


def main():
    import sys
    parser = argparse.ArgumentParser()
    parser.add_argument('--receiver', action='store_true')
    parser.add_argument('--once', action='store_true')
    parser.add_argument('--ingest', action='store_true')
    parser.add_argument('--port', type=int, default=8769)
    args = parser.parse_args()
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    if args.ingest:
        raw = sys.stdin.buffer.read(262145)
        if len(raw) > 262144: raise ValueError('size')
        value = validate_snapshot(json.loads(raw))
        with LOCK: atomic_json(STATE / 'snapshot.json', value)
        return
    if args.once:
        collect(); sync_remote(); return
    key = STATE / 'control.key'
    if not key.exists():
        fd = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as f: f.write(secrets.token_urlsafe(32))
    def polling():
        while True:
            if not args.receiver: collect(); sync_remote()
            time.sleep(180)
    threading.Thread(target=polling, daemon=True).start()
    http.server.ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()


if __name__ == '__main__': main()
