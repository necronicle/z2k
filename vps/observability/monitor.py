#!/usr/bin/env python3
"""Minute relay checks. Writes local status and prints each alert once per half hour.

Counters are compared per endpoint over contiguous samples (at most 90s apart).
Install Bytes and session_close.streams are deliberately not used as live rates.
Requires Python 3 stdlib and curl, both already installed on the VPS.
"""
import collections
import datetime as dt
import fcntl
import gzip
import io
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time

METRICS_A = 'http://127.0.0.1:9098/metrics'
METRICS_B = 'http://127.0.0.1:9097/metrics'
DIAL_RESULTS = ('ok', 'fail', 'throttle')
DIAL_KEYS = tuple(f'relay_dial_total{{result="{r}"}}' for r in DIAL_RESULTS)
KERNEL_DROPS = ('ListenDrops', 'ListenOverflows', 'TCPReqQFullDrop')
NODE_FLOORS = (
    ('memory_available_ratio', 'memory_low', 'доступно меньше 10% оперативной памяти'),
    ('disk_free_ratio', 'disk_low', 'на разделе журнала свободно меньше 10%'),
)
NGINX_LOGS = ('/var/log/nginx/z2k-stream-error.log.1', '/var/log/nginx/z2k-stream-error.log')
NGINX_TAIL = 4 * 1024 * 1024
NGINX_PATTERNS = (
    ('whatsapp_dns_timeout', ('whatsapp.', 'could not be resolved', 'timed out')),
    ('upstream_reset', ('Connection reset by peer',)),
    ('upstream_connect_timeout', ('upstream timed out', 'while connecting')),
    ('per_ip_limit', ('limiting connections',)),
)
NGINX_CEILINGS = (
    ('whatsapp_dns_timeout', 3, 'whatsapp_dns', 'таймауты DNS WhatsApp за 5 минут'),
    ('upstream_connect_timeout', 10, 'upstream_connect', 'таймауты TCP до upstream за 5 минут'),
)
REPORT_EVERY = 1800


def parse_metrics(text):
    result = {}
    for line in text.splitlines():
        fields = line.split()
        if len(fields) != 2 or fields[0].startswith('#'):
            continue
        try:
            value = float(fields[1])
        except ValueError:
            continue
        if math.isfinite(value) and value >= 0:
            result[fields[0]] = int(value)
    return result


def gauge(snapshots, name):
    values = [s[name] for s in snapshots.values() if name in s]
    return sum(values) if values else None


def read_events(directory, now):
    for offset in (86400, 0):
        date = dt.datetime.fromtimestamp(now - offset, dt.timezone.utc).strftime('%Y-%m-%d')
        path = directory / f'events-{date}.jsonl'
        opener = open
        if not path.exists():
            path = Path(str(path) + '.gz')
            opener = gzip.open
        try:
            with opener(path, 'rt', errors='replace') as source:
                for line in source:
                    try:
                        event = json.loads(line)
                        stamp = dt.datetime.fromisoformat(event['ts'].replace('Z', '+00:00')).timestamp()
                        event['ts_epoch'] = stamp
                        yield event
                    except (ValueError, KeyError, TypeError):
                        continue  # partial last line during append
        except (OSError, EOFError):
            continue  # next invocation sees completed rotation


EVENT_LIMIT = 8 * 1024 * 1024
EVENT_CACHE_LIMIT = 5000
EVENT_CACHE_BYTES = 1024 * 1024


def recent_event(line, now):
    try:
        event = json.loads(line)
        stamp = dt.datetime.fromisoformat(event['ts'].replace('Z', '+00:00')).timestamp()
        if not 0 <= now - stamp <= 300:
            return None
        # Only these fields participate in the existing rules. Keeping session_open
        # records or lifetime byte counters here would inflate the rolling cache.
        if event.get('ev') not in ('session_close', 'auth_reject', 'dial_fail') and event.get('reason') not in ('stream_limit', 'udp_protocol'):
            return None
        result = {k: event[k] for k in ('ev', 'asn', 'reason', 'detail', 'install') if k in event}
        result['ts_epoch'] = stamp
        return result
    except (ValueError, KeyError, TypeError, AttributeError):
        return None


def event_chunk(path, old, budget):
    """Return complete new lines, cursor, actual input bytes and coverage loss.

    Plain files are seekable. gzip has no cheap random access: never seek through
    an archive's prefix on every minute. Transfer completed plaintext offsets;
    decode a small archive once, or explicitly flag an oversized cold archive.
    """
    with path.open('rb') as raw:
        stat = os.fstat(raw.fileno())
        identity = [stat.st_dev, stat.st_ino]
        if path.suffix == '.gz':
            signature = [*identity, stat.st_size, stat.st_mtime_ns]
            if old.get('archive') == signature:
                return b'', old, 0, False
            # gzip ISIZE is modulo 2**32, so it is only used as an equality
            # optimization for a cursor known to have reached plaintext EOF.
            raw.seek(-4, 2)
            size = int.from_bytes(raw.read(4), 'little')
            if old.get('complete') and old.get('offset', -1) % (2 ** 32) == size:
                return b'', dict(old, archive=signature), 0, False
            # Bound compressed input too (e.g. enormous FNAME headers or
            # concatenated empty members), not just decompressed output.
            if stat.st_size > budget:
                return b'', dict(archive=signature), 4, True
            raw.seek(0)
            with gzip.GzipFile(fileobj=raw) as source:
                data = source.read(budget)
                decoded = len(data)
                # A full buffer is conservatively incomplete, even at exact EOF.
            if len(data) >= budget:
                return b'', dict(archive=signature), len(data), True
            start = old.get('offset', 0) if old.get('identity') else 0
            data = data[min(start, len(data)):]
            return data, dict(archive=signature, offset=size, complete=True), max(decoded, stat.st_size), False
        same = old.get('identity') == identity and stat.st_size >= old.get('offset', 0)
        checked = 0
        if same and old.get('anchor') and stat.st_mtime_ns != old.get('mtime_ns'):
            anchor = bytes.fromhex(old['anchor'])
            raw.seek(old['offset'] - len(anchor))
            checked = min(len(anchor), budget)
            same = raw.read(checked) == anchor
        budget -= checked
        start = old.get('offset', 0) if same else 0
        reset_gap = bool(old) and not same
        cut = stat.st_size - start > budget
        if cut:
            start = stat.st_size - budget
        raw.seek(start)
        data = raw.read(budget)
        consumed = len(data)
        # A tail starts inside an arbitrary record. Drop it within the budget,
        # never use unbounded readline() on a corrupt/multi-GB record.
        if cut or old.get('discard', False) and same:
            end = data.find(b'\n')
            if end < 0:
                return b'', dict(identity=identity, offset=start + consumed,
                                 complete=False, discard=True), consumed + checked, True
            start += end + 1
            data = data[end + 1:]
        end = data.rfind(b'\n') + 1
        # Retry an unfinished trailing record from its start next time.
        return data[:end], dict(identity=identity, offset=start + end,
                               complete=start + end == stat.st_size,
                               anchor=data[:end][-64:].hex() if end else old.get('anchor', '') if same else '',
                               mtime_ns=stat.st_mtime_ns), consumed + checked, cut or reset_gap


def incremental_events(directory, now, state, limit=EVENT_LIMIT):
    try:
        with (state / 'events-state.json').open() as source:
            saved = json.load(source)
        if saved.get('version') != 1:
            saved = {}
    except (OSError, ValueError, AttributeError):
        saved = {}
    events = collections.deque()
    sizes = collections.deque()
    cache_bytes = 0
    limited_until = saved.get('limited_until', 0)

    def retain(event):
        nonlocal cache_bytes, limited_until
        # Bound retained strings as well as object count. JSONL bytes alone do
        # not bound Python objects, cached history or serialization copies.
        size = len(json.dumps(event, ensure_ascii=False).encode()) + 256
        if size > EVENT_CACHE_BYTES:
            limited_until = now + 300
            return
        events.append(event)
        sizes.append(size)
        cache_bytes += size
        while len(events) > EVENT_CACHE_LIMIT or cache_bytes > EVENT_CACHE_BYTES:
            events.popleft()
            cache_bytes -= sizes.popleft()
            limited_until = now + 300

    for event in saved.pop('events', []):
        if 0 <= now - event['ts_epoch'] <= 300:
            retain(event)
    cursors = {}
    remaining = limit
    # Current file first: a huge yesterday must not starve current checks.
    for age in (0, 86400):
        date = dt.datetime.fromtimestamp(now - age, dt.timezone.utc).strftime('%Y-%m-%d')
        name = f'events-{date}.jsonl'
        old = saved.get('cursors', {}).get(name, {})
        # No event from yesterday is recent after 00:05 UTC.
        if age and now % 86400 > 300:
            continue
        path = directory / name
        if not path.exists():
            path = Path(str(path) + '.gz')
        if not path.exists():
            continue
        if remaining <= 0:
            cursors[name] = old
            limited_until = now + 300
            continue
        try:
            data, cursor, used, cut = event_chunk(path, old, remaining)
        except (OSError, EOFError):
            cursors[name] = old
            limited_until = now + 300
            continue
        remaining -= min(remaining, used)
        cursors[name] = cursor
        if cut:
            limited_until = now + 300
        for line in io.BytesIO(data):
            event = recent_event(line, now)
            if event is not None:
                retain(event)
    events = list(events)
    atomic_json(state / 'events-state.json', dict(version=1, cursors=cursors,
                events=events, limited_until=limited_until, bytes_read=limit - remaining))
    return events, now < limited_until


def event_alerts(now, events, live):
    alerts = {}
    if live is None:
        alerts['metrics_unavailable'] = 'метрики релея недоступны; число сессий неизвестно'
    window = [e for e in events if 0 <= now - e['ts_epoch'] <= 300]
    minute = [e for e in window if now - e['ts_epoch'] <= 60]
    closes = [e for e in minute if e.get('ev') == 'session_close']
    if live is not None and len(closes) >= max(20, live // 10):
        asns = collections.Counter(e.get('asn', 0) for e in closes).most_common(5)
        alerts['mass_close'] = f'за минуту закрылось {len(closes)} сессий, живых {live}; ASN: {asns}'
    rejects = sum(e.get('ev') == 'auth_reject' for e in minute)
    if rejects > 50:
        alerts['auth_reject'] = f'{rejects} отказов авторизации за минуту'
    return alerts, window


def endpoint_delta(current, before):
    """Dial counter deltas of one endpoint, or the reason they are not traffic."""
    if before is None:
        return None, 'new_endpoint'
    if 'relay_sessions' not in current or 'relay_sessions' not in before:
        return None, 'missing_gauge'
    # Counters are lazily created. Absent labels on a healthy endpoint mean zero.
    if not any(k in current for k in DIAL_KEYS) or not any(k in before for k in DIAL_KEYS):
        return None, 'missing_counters'
    delta = [current.get(k, 0) - before.get(k, 0) for k in DIAL_KEYS]
    if min(delta) < 0:
        return None, 'counter_reset'
    return delta, None


def observed_deltas(now, snapshots, previous):
    history = [x for x in previous.get('dial_history', []) if now - 300 <= x['start'] <= x['end'] <= now]
    reasons = {}
    old = previous.get('snapshots', {})
    for endpoint, current in snapshots.items():
        delta, reason = endpoint_delta(current, old.get(endpoint))
        if reason:
            reasons[endpoint] = reason
        else:
            history.append(dict(endpoint=endpoint, start=previous['time'], end=now, **dict(zip(DIAL_RESULTS, delta))))
    return history, reasons


def dial_history(now, snapshots, previous):
    # Do not turn a process restart, endpoint switch, or monitoring gap into traffic.
    if 0 < now - previous.get('time', 0) <= 90:
        history, reasons = observed_deltas(now, snapshots, previous)
    else:
        history = []
        reasons = {endpoint: ('first_sample' if not previous else 'sample_gap') for endpoint in snapshots}
    for endpoint in previous.get('snapshots', {}):
        if endpoint not in snapshots:
            reasons[endpoint] = 'endpoint_unavailable'
    return history, reasons


def covered_seconds(history):
    covered = 0
    until = 0
    for start, end in sorted({(x['start'], x['end']) for x in history}):
        covered += max(0, end - max(start, until))
        until = max(until, end)
    return covered


def dial_alerts(totals):
    alerts = {}
    attempted = totals['ok'] + totals['fail']
    if attempted >= 100 and totals['fail'] * 100 > attempted * 5:
        alerts['dial_fail'] = f"{totals['fail']} ошибок на {attempted} попыток за наблюдаемую часть последних 5 минут"
    if totals['throttle'] >= 50:
        alerts['dial_throttle'] = f"{totals['throttle']} отказов ограничителя дозвона за последние 5 минут"
    return alerts


def event_breakdown(window):
    targets = {}
    offenders = collections.Counter()
    for event in window:
        reason = event.get('reason', '')
        if event.get('ev') == 'dial_fail' and reason == 'dial_error':
            item = targets.setdefault(event.get('detail', 'unknown'), {'failures': 0, 'installs': set()})
            item['failures'] += 1
            if event.get('install'):
                item['installs'].add(event['install'])
        if reason in ('stream_limit', 'udp_protocol') and event.get('install'):
            offenders[(event['install'], reason)] += 1
    target_rows = sorted((dict(target=t, failures=v['failures'], installs=len(v['installs'])) for t, v in targets.items()), key=lambda x: x['failures'], reverse=True)
    offender_rows = [dict(install=i, reason=r, count=n) for (i, r), n in offenders.most_common(20)]
    return target_rows, offender_rows


def breakdown_alerts(target_rows, offender_rows):
    alerts = {}
    bad_targets = [x for x in target_rows if x['failures'] >= 20 and x['installs'] >= 5]
    if bad_targets:
        alerts['dial_target'] = f'ошибки отдельного адресата: {bad_targets[:5]}'
    repeated = [x for x in offender_rows if x['count'] >= 20]
    if repeated:
        alerts['install_errors'] = f'повторяющиеся ошибки установок (не доказательство злоупотребления): {repeated[:5]}'
    return alerts


def evaluate(now, snapshots, events, previous):
    live = gauge(snapshots, 'relay_sessions')
    alerts, window = event_alerts(now, events, live)
    history, reasons = dial_history(now, snapshots, previous)
    covered = covered_seconds(history)
    coverage = dict(observed_seconds=covered, partial=bool(reasons) or covered < 300,
                    reasons=reasons, available=bool(history), endpoints=list(snapshots))
    totals = {r: sum(x[r] for x in history) for r in DIAL_RESULTS}
    alerts.update(dial_alerts(totals))
    target_rows, offender_rows = event_breakdown(window)
    alerts.update(breakdown_alerts(target_rows, offender_rows))
    return dict(time=now, sessions=live, streams=gauge(snapshots, 'relay_streams'), snapshots=snapshots,
                dial_history=history, dial_window=totals if history else None, dial_coverage=coverage, dial_targets=target_rows[:20],
                install_errors=offender_rows, alerts=alerts)


def curl(*args):
    try:
        result = subprocess.run(['curl', '-fsS', '--max-time', '5', *args], capture_output=True, text=True, timeout=8)
        return result.stdout if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def atomic_json(path, data):
    tmp = path.with_suffix('.tmp')
    with tmp.open('w') as output:
        json.dump(data, output, ensure_ascii=False, separators=(',', ':'))
        output.write('\n')
        output.flush()
        os.fsync(output.fileno())
    tmp.replace(path)
    directory_fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def socket_key(fields):
    inode = next((x[4:] for x in fields if x.startswith('ino:')), None)
    if not inode:
        return None, None
    return fields[2] + '/' + fields[3] + '/' + inode, fields[3].rsplit(':', 1)[0].strip('[]')


def byte_counters(fields, counters):
    for field in fields:
        name, _, value = field.partition(':')
        if name in ('bytes_sent', 'bytes_received'):
            try:
                counters[name[len('bytes_'):]] = int(value)
            except ValueError:
                pass


def socket_counters(text):
    sockets = {}
    current = None
    for line in text.splitlines():
        fields = line.split()
        if len(fields) >= 4 and fields[0].isdigit() and fields[1].isdigit():
            current, peer = socket_key(fields)
            if current:
                sockets[current] = {'peer': peer, 'sent': 0, 'received': 0}
        elif current:
            byte_counters(fields, sockets[current])
    return sockets


def socket_rates(current, previous, seconds):
    # Lower bound: only sockets present at BOTH samples. Short completed
    # connections cannot be reconstructed from ss; never count their lifetime
    # bytes as if transferred in this interval.
    if not 0 < seconds <= 90:
        return []
    peers = collections.defaultdict(lambda: [0, 0])
    for key, value in current.items():
        old = previous.get(key)
        if old is None:
            continue
        sent = value['sent'] - old['sent']
        received = value['received'] - old['received']
        if min(sent, received) < 0:
            continue
        peers[value['peer']][0] += sent
        peers[value['peer']][1] += received
    rows = [dict(peer=p, down_mbps=round(v[0] * 8 / seconds / 1e6, 6),
                 up_mbps=round(v[1] * 8 / seconds / 1e6, 6)) for p, v in peers.items()]
    return sorted(rows, key=lambda x: x['down_mbps'] + x['up_mbps'], reverse=True)[:10]


def traffic_snapshot(now, previous):
    result = {'coverage': 'lower bound: TCP :443/:5222 sockets present in both samples; IP is not an install or owner'}
    try:
        output = subprocess.run(['ss', '-tinHe', 'state', 'established', '( sport = :443 or sport = :5222 )'],
                                capture_output=True, text=True, timeout=8, check=True)
        result['sockets'] = socket_counters(output.stdout)
        result['top_peers'] = socket_rates(result['sockets'], previous.get('traffic', {}).get('sockets', {}), now - previous.get('time', 0))
    except (OSError, subprocess.SubprocessError):
        result['unavailable'] = True
    return result


def collect_snapshots(urls):
    snapshots = {}
    for url in dict.fromkeys(urls):
        body = curl(url) if url else None
        if body is not None:
            snapshots[url] = parse_metrics(body)
    return snapshots


def tcp_ext_counters(text):
    lines = text.splitlines()
    for i in range(0, len(lines) - 1, 2):
        if lines[i].startswith('TcpExt:'):
            values = dict(zip(lines[i].split()[1:], map(int, lines[i + 1].split()[1:])))
            return {k: values[k] for k in KERNEL_DROPS if k in values}
    return {}


def memory_available_ratio(text):
    mem = {line.split(':')[0]: int(line.split()[1]) for line in text.splitlines()}
    return mem['MemAvailable'] / mem['MemTotal']


def node_snapshot(proc=Path('/proc'), log_dir='/var/log'):
    node = {'counters': {}}
    try:
        node['counters'] = tcp_ext_counters((proc / 'net/netstat').read_text())
        node['memory_available_ratio'] = memory_available_ratio((proc / 'meminfo').read_text())
        disk = os.statvfs(log_dir)
        node['disk_free_ratio'] = disk.f_bavail / disk.f_blocks
        node['load'] = os.getloadavg()
    except (OSError, ValueError, KeyError):
        node['unavailable'] = True
    return node


def counter_deltas(now, node, previous):
    if not 0 < now - previous.get('time', 0) <= 90:
        return {}
    old = previous.get('node', {}).get('counters', {})
    return {k: (v - old[k] if k in old and v >= old[k] else None) for k, v in node['counters'].items()}


def node_rules(now, node, previous, alerts):
    delta = counter_deltas(now, node, previous)
    node['delta'] = delta
    if any(v is not None and v > 0 for v in delta.values()):
        alerts['kernel_drops'] = f'потери в очередях TCP за интервал: {delta}'
    for key, rule, text in NODE_FLOORS:
        if node.get(key, 1) < .10:
            alerts[rule] = text
    if node.get('unavailable'):
        alerts['node_metrics_unavailable'] = 'часть метрик ядра/ресурсов недоступна'


def nginx_stamp(line):
    try:
        # nginx error timestamps use the host's local timezone.
        return dt.datetime.strptime(line[:19], '%Y/%m/%d %H:%M:%S').timestamp()
    except ValueError:
        return None


def nginx_errors(lines, now):
    counts = {name: 0 for name, _ in NGINX_PATTERNS}
    for line in lines:
        stamp = nginx_stamp(line)
        if stamp is None or not 0 <= now - stamp <= 300:
            continue
        for name, parts in NGINX_PATTERNS:
            if all(part in line for part in parts):
                counts[name] += 1
    return counts


def read_tail(filename, limit):
    with open(filename, 'rb') as source:
        source.seek(0, 2)
        size = source.tell()
        source.seek(max(0, size - limit))
        if size > limit:
            source.readline()
        return source.read().decode(errors='replace').splitlines(), size > limit


def nginx_snapshot(now, files=NGINX_LOGS, limit=NGINX_TAIL):
    # Bound work even during a flood. Inspect both sides of daily rotation.
    lines = []
    truncated = False
    found = False
    for filename in files:
        try:
            part, cut = read_tail(filename, limit)
        except OSError:
            continue
        lines.extend(part)
        truncated = truncated or cut
        found = True
    if not found:
        return {'unavailable': True}
    result = nginx_errors(lines, now)
    result['tail_limited'] = truncated
    return result


def node_checks(now, previous, status):
    status['traffic'] = traffic_snapshot(now, previous)
    status['node'] = node_snapshot()
    node_rules(now, status['node'], previous, status['alerts'])
    status['nginx'] = nginx_snapshot(now)
    for key, ceiling, rule, text in NGINX_CEILINGS:
        count = status['nginx'].get(key, 0)
        if count >= ceiling:
            status['alerts'][rule] = f'{text}: {count}'


def publish_status(state, status, now):
    for rule, detail in status['alerts'].items():
        if now - status['reported'].get(rule, 0) >= REPORT_EVERY:
            print(f'z2k relay: {rule} — {detail}', flush=True)
            status['reported'][rule] = now
    atomic_json(state / 'status.json', status)


def load_previous(state):
    try:
        return json.loads((state / 'status.json').read_text())
    except (OSError, ValueError):
        return {}


def run_once(directory, primary, state):
    now = int(time.time())
    previous = load_previous(state)
    snapshots = collect_snapshots((primary, os.environ.get('METRICS_B', METRICS_B)))
    events, limited = incremental_events(Path(directory), now, state)
    status = evaluate(now, snapshots, events, previous)
    if limited:
        status['alerts']['events_limited'] = 'неполное окно событий: превышен лимит чтения/кэша или архив недоступен; счётчики — нижняя граница'
    # Offline event replay may explicitly disable host-specific probes.
    if os.environ.get('Z2K_MONITOR_NODE', '1') == '1':
        node_checks(now, previous, status)
    status['reported'] = previous.get('reported', {})
    publish_status(state, status, now)


def main():
    os.umask(0o077)
    directory, primary, state = sys.argv[1:4]
    state = Path(state)
    state.mkdir(parents=True, exist_ok=True)
    with (state / 'monitor.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        run_once(directory, primary, state)


def gauges():
    snapshots = collect_snapshots((os.environ.get('METRICS', METRICS_A), os.environ.get('METRICS_B', METRICS_B)))
    values = (gauge(snapshots, key) for key in ('relay_sessions', 'relay_streams', 'relay_queue_bytes'))
    print('\t'.join('NA' if value is None else str(value) for value in values))


if __name__ == '__main__':
    if sys.argv[1:] == ['--gauges']:
        gauges()
    else:
        main()
