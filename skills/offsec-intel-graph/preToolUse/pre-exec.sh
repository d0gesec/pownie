#!/usr/bin/env bash
# trace.sh — PreToolUse hook: OTLP tracing + graph context retrieval
#
# Fires BEFORE kali MCP tool calls. Emits two spans and injects context:
#
#   [root span]  trigger reasoning → tool: command summary
#   └─[vet span] neo4j query results, verdict, counts
#
# Also injects:
#   - _otel_trace via updatedInput (for MCP server + PostToolUse child spans)
#   - additionalContext with graph data (for model judgment)
#
# Telemetry failures are silent — never blocks execution.

set -euo pipefail

LOGDIR="${CLAUDE_PLUGIN_DATA:-${CLAUDE_PROJECT_DIR:-.}/.claude}/logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/vet-command.log"

INPUT=$(cat)

HOOK_INPUT="$INPUT" LOGFILE="$LOGFILE" NEO4J_CONTAINER="${POWNIE_PREFIX:-pownie}-neo4j" python3 << 'PYEOF'
import urllib.request, json, hashlib, time, os, re, sys, subprocess
from datetime import datetime, timezone
from concurrent.futures import ThreadPoolExecutor, as_completed

TEMPO_ENDPOINT = os.environ.get("TEMPO_ENDPOINT", "http://localhost:4318/v1/traces")
NEO4J_CONTAINER = os.environ.get('NEO4J_CONTAINER', 'pownie-neo4j')
LOGFILE = os.environ.get('LOGFILE', 'vet-command.log')

def log(verdict, cmd_short, detail=''):
    try:
        with open(LOGFILE, 'a') as f:
            ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
            f.write(f"{ts} {verdict} {cmd_short}")
            if detail:
                f.write(f" | {detail}")
            f.write('\n')
    except Exception:
        pass

def emit_spans(spans, service_name):
    """Ship OTLP JSON to Tempo. Fire-and-forget."""
    body = json.dumps({
        "resourceSpans": [{
            "resource": {"attributes": [
                {"key": "service.name", "value": {"stringValue": service_name}}
            ]},
            "scopeSpans": [{"spans": spans}]
        }]
    }).encode()
    req = urllib.request.Request(TEMPO_ENDPOINT, data=body,
        headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=2)
    except Exception:
        pass

def extract_trigger_context(transcript_path):
    """Read the last assistant text message from the transcript JSONL."""
    try:
        with open(transcript_path, 'rb') as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 65536))
            tail = f.read().decode('utf-8', errors='replace')
        lines = [l.strip() for l in tail.strip().split('\n') if l.strip()]
        for line in reversed(lines):
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            if d.get('type') != 'assistant':
                continue
            msg = d.get('message', {})
            if not isinstance(msg, dict):
                continue
            content = msg.get('content', [])
            if not isinstance(content, list):
                continue
            for c in content:
                if isinstance(c, dict) and c.get('type') == 'text':
                    text = c.get('text', '').strip()
                    if text:
                        return text
    except Exception:
        pass
    return ""

def cypher_query(query):
    """Run a read-only Cypher query and return parsed result lines."""
    try:
        r = subprocess.run(
            ['docker', 'exec', NEO4J_CONTAINER, 'cypher-shell',
             '-u', 'neo4j', '-p', 'pownie-graph', '--format', 'plain', query],
            capture_output=True, text=True, timeout=5
        )
        return [l.strip().strip('"') for l in r.stdout.strip().split('\n')[1:] if l.strip()]
    except Exception:
        return []

FILE_EXTS = {'.txt', '.py', '.sh', '.php', '.js', '.json', '.xml', '.conf', '.log',
             '.html', '.css', '.csv', '.yml', '.yaml', '.md', '.sql', '.exe', '.dll',
             '.so', '.o', '.pcap', '.cap', '.ejs', '.go', '.rs', '.rb', '.pl',
             '.bat', '.ps1', '.psm1', '.psd1', '.nse', '.chk', '.bak', '.old',
             '.zip', '.tar', '.gz', '.xz', '.7z', '.rar', '.war', '.jar', '.sid',
             '.server'}

def extract_targets(cmd):
    """Extract IPv4 addresses and hostnames from command."""
    ips = re.findall(r'[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+', cmd)
    hosts = []
    for domain in re.findall(r'[\w][\w.-]+\.[a-zA-Z]{2,}', cmd):
        if re.match(r'^[0-9.]+$', domain):
            continue
        # Skip filenames (e.g. exploit.py, challenge.pcap)
        ext = '.' + domain.rsplit('.', 1)[-1].lower()
        if ext in FILE_EXTS:
            continue
        hosts.append(domain)
    return ips, hosts

try:
    d = json.loads(os.environ['HOOK_INPUT'])
    tool_use_id = d.get("tool_use_id", "")
    tool_name = d.get("tool_name", "")
    transcript_path = d.get("transcript_path", "")
    ti = d.get("tool_input", {})
    cmd = ti.get("command", "") or ti.get("input", "")

    if not cmd.strip():
        log('SKIP', '(empty)')
        print("{}")
        sys.exit(0)

    cmd_short = re.sub(r'\s+', ' ', cmd.strip().split('\n')[0].strip())[:120]
    cmd_sha256 = hashlib.sha256(cmd.encode()).hexdigest()[:16]
    ips, hosts = extract_targets(cmd)
    target = ips[0] if ips else (hosts[0] if hosts else '')

    # ── VET: Query Neo4j for graph context ──────────────────────────────

    vet_start = time.time()
    chain, attempts, creds, strategies = [], [], [], []
    progress, phases, attack_classes, tasks = [], [], [], []
    query_timings = []  # (name, cypher, start, end, count)

    if target:
        safe_target = target.replace("\\", "\\\\").replace("'", "\\'")

        queries = [
            ("chain",
             f"MATCH (c:command_log) "
             f"WHERE c.target = '{safe_target}' AND c.target <> '' "
             f"RETURN c.summary + ' → ' + coalesce(left(c.result, 120), '(no result)') "
             f"+ CASE WHEN c.trigger_reason IS NOT NULL "
             f"THEN ' | WHY: ' + left(c.trigger_reason, 80) ELSE '' END "
             f"+ CASE WHEN c.is_error THEN ' [ERROR]' ELSE '' END "
             f"+ ' [' + toString(c.timestamp) + ']' AS hit "
             f"ORDER BY c.timestamp DESC LIMIT 8"),
            ("attempts",
             f"MATCH (a:attempt)-[:TRIED_ON]->(t) "
             f"WHERE t.key CONTAINS '{safe_target}' "
             f"OR t.name CONTAINS '{safe_target}' OR t.domain CONTAINS '{safe_target}' "
             f"RETURN a.technique + ' via ' + a.tool + ' -> ' + a.outcome + ': ' + "
             f"left(coalesce(a.output_summary,''), 120) + ' [' + toString(a.created_at) + ']' AS hit "
             f"ORDER BY a.created_at DESC LIMIT 10"),
            ("credentials",
             f"MATCH (c:credential)-[r:AUTHENTICATES_TO]->(s:service) "
             f"WHERE s.key CONTAINS '{safe_target}' "
             f"RETURN c.key + ' -> ' + s.service + ' (' + r.status + ')' AS hit "
             f"UNION ALL "
             f"MATCH (c:credential)-[:FOUND_ON]->(tgt:target)-[:HAS_IP]->(ip:ip {{addr: '{safe_target}'}}) "
             f"RETURN c.key + ' (found on ' + tgt.name + ')' AS hit "
             f"UNION ALL "
             f"MATCH (c:credential)-[:FOUND_ON|FOUND_IN]->(n) "
             f"WHERE n.key CONTAINS '{safe_target}' OR n.name CONTAINS '{safe_target}' "
             f"RETURN c.key + ' (found: ' + coalesce(n.name, n.key) + ')' AS hit"),
            ("strategies",
             f"MATCH (st:strategy)-[:ON_TARGET|TARGETS]->(t) "
             f"WHERE t.key CONTAINS '{safe_target}' "
             f"OR t.name CONTAINS '{safe_target}' OR t.domain CONTAINS '{safe_target}' "
             f"RETURN st.method + ' [' + st.status + ']' + "
             f"CASE WHEN st.result IS NOT NULL THEN ': ' + left(st.result, 120) ELSE '' END AS hit "
             f"ORDER BY st.status DESC LIMIT 5"),
            ("progress",
             f"MATCH (cl:command_log)-[:EXECUTED_ON]->(i:ip {{addr: '{safe_target}'}}) "
             f"WITH count(cl) AS total "
             f"OPTIONAL MATCH (cl2:command_log)-[:DISCOVERED]->() "
             f"WHERE (cl2)-[:EXECUTED_ON]->(:ip {{addr: '{safe_target}'}}) "
             f"WITH total, count(DISTINCT cl2) AS productive "
             f"RETURN toString(total) + ' commands, ' + toString(productive) + ' productive' AS hit"),
            ("phases",
             f"MATCH (cl:command_log)-[:EXECUTED_ON]->(i:ip {{addr: '{safe_target}'}}) "
             f"WHERE cl.phase IS NOT NULL "
             f"WITH cl.phase AS phase, count(cl) AS total, "
             f"size([x IN collect(cl) WHERE (x)-[:DISCOVERED]->()]) AS productive "
             f"RETURN phase + ': ' + toString(total) + ' cmds, ' + toString(productive) + ' productive' AS hit "
             f"ORDER BY total DESC"),
            ("attack_classes",
             f"MATCH (ac:attack_class)-[:ON_TARGET]->(tgt) "
             f"WHERE tgt.key CONTAINS '{safe_target}' OR tgt.name CONTAINS '{safe_target}' "
             f"OR EXISTS {{ MATCH (tgt)-[:HAS_IP]->(ip:ip {{addr: '{safe_target}'}}) }} "
             f"RETURN "
             f"CASE ac.status WHEN 'disproven' THEN 'DEAD' ELSE upper(ac.status) END "
             f"+ ': ' + ac.key + ' — ' + coalesce(ac.reason, '') "
             f"+ CASE WHEN ac.blocked_techniques IS NOT NULL "
             f"THEN ' | Blocks: ' + ac.blocked_techniques ELSE '' END AS hit "
             f"ORDER BY ac.status DESC"),
            ("tasks",
             f"MATCH (t:task) "
             f"WHERE t.target CONTAINS '{safe_target}' "
             f"OR EXISTS {{ MATCH (tgt:target)-[:HAS_IP]->(ip:ip {{addr: '{safe_target}'}}) WHERE t.target = tgt.name }} "
             f"RETURN t.role + ': ' + coalesce(left(t.description, 80), '') "
             f"+ ' [' + t.status + '] depth=' + toString(coalesce(t.depth, 0)) "
             f"+ CASE WHEN t.findings_summary IS NOT NULL "
             f"THEN ' — ' + left(t.findings_summary, 100) ELSE '' END AS hit "
             f"ORDER BY t.depth, t.spawned_at DESC LIMIT 10"),
        ]

        def timed_query(name, query):
            t0 = time.time()
            rows = cypher_query(query)
            return (name, query, t0, time.time(), len(rows), rows)

        results = {}
        with ThreadPoolExecutor(max_workers=6) as pool:
            futures = [pool.submit(timed_query, n, q) for n, q in queries]
            for f in as_completed(futures):
                name, qtext, t0, t1, count, rows = f.result()
                query_timings.append((name, qtext, t0, t1, count))
                results[name] = rows

        chain = results.get("chain", [])
        attempts = results.get("attempts", [])
        creds = results.get("credentials", [])
        strategies = results.get("strategies", [])
        progress = results.get("progress", [])
        phases = results.get("phases", [])
        attack_classes = results.get("attack_classes", [])
        tasks = results.get("tasks", [])

    vet_end = time.time()
    has_graph_data = chain or attempts or creds or strategies or progress or phases or attack_classes or tasks
    failed_count = sum(1 for a in attempts if '-> failed:' in a)

    if not has_graph_data:
        verdict = "PASS"
    else:
        verdict = "CONTEXT"

    # Build additionalContext for model judgment
    vet_context = ""
    if has_graph_data:
        parts = [f'[EXECUTION CONTEXT for {target}]', '']

        if attack_classes:
            dead = [a for a in attack_classes if a.startswith('DEAD:')]
            viable = [a for a in attack_classes if not a.startswith('DEAD:')]
            if dead:
                parts.append(f'ATTACK CLASSES DISPROVEN ({len(dead)}) — do NOT attempt techniques in these categories:')
                for a in dead:
                    parts.append(f'  {a}')
                parts.append('')
            if viable:
                parts.append(f'Attack classes viable ({len(viable)}):')
                for a in viable:
                    parts.append(f'  {a}')
                parts.append('')

        if tasks:
            parts.append(f'Task board ({len(tasks)} tasks):')
            for t in tasks:
                parts.append(f'  {t}')
            parts.append('')

        if chain:
            parts.append(f'Command history ({len(chain)} recent):')
            for c in chain:
                parts.append(f'  {c}')
            parts.append('')

        if attempts:
            succeeded = sum(1 for a in attempts if '-> succeeded:' in a)
            counts = []
            if failed_count:
                counts.append(f'{failed_count} failed')
            if succeeded:
                counts.append(f'{succeeded} succeeded')
            other = len(attempts) - failed_count - succeeded
            if other:
                counts.append(f'{other} other')
            parts.append(f'Prior attempts ({", ".join(counts)}):')
            for a in attempts:
                parts.append(f'  {a}')
            parts.append('')

        if creds:
            parts.append('Known credentials:')
            for c in creds:
                parts.append(f'  {c}')
            parts.append('')

        if strategies:
            parts.append('Strategies:')
            for s in strategies:
                parts.append(f'  {s}')
            parts.append('')

        if progress:
            parts.append(f'Progress: {progress[0]}')
            parts.append('')

        if phases:
            parts.append(f'Phase breakdown ({len(phases)}):')
            for p in phases:
                parts.append(f'  {p}')
            parts.append('')

        parts.append(f'Proposed command: {cmd_short}')
        parts.append('')
        parts.append('This context is informational only — it does not block execution.')
        parts.append('Use it to avoid repeating failed approaches or to leverage known credentials.')

        vet_context = '\n'.join(parts)

    # ── TRACE: Emit OTLP spans ──────────────────────────────────────────

    hook_output = {"hookEventName": "PreToolUse"}

    if tool_use_id:
        trace_id = hashlib.sha256(tool_use_id.encode()).hexdigest()[:32]
        root_span_id = os.urandom(8).hex()
        now_ns = str(int(time.time() * 1e9))

        trigger_context = extract_trigger_context(transcript_path) if transcript_path else ""

        # Root span attributes
        root_attrs = [
            {"key": "tool.name", "value": {"stringValue": tool_name}},
            {"key": "command.sha256", "value": {"stringValue": cmd_sha256}},
        ]
        if target:
            root_attrs.append({"key": "target.ip", "value": {"stringValue": target}})
        if trigger_context:
            root_attrs.append({"key": "trigger.context", "value": {"stringValue": trigger_context[:2000]}})

        # Span name: trigger context (why) + command (what)
        short_tool = tool_name.replace("mcp__kali__", "")
        trigger_short = trigger_context.split('\n')[0].strip()[:80] if trigger_context else ""
        if trigger_short and cmd_short:
            span_name = f"{trigger_short} → {short_tool}: {cmd_short}"
        elif trigger_short:
            span_name = f"{trigger_short} → {short_tool}"
        elif cmd_short:
            span_name = f"{short_tool}: {cmd_short}"
        else:
            span_name = short_tool

        root_span = {
            "traceId": trace_id,
            "spanId": root_span_id,
            "name": span_name[:200],
            "kind": 1,
            "startTimeUnixNano": now_ns,
            "endTimeUnixNano": now_ns,
            "attributes": root_attrs,
        }

        # Vet child span — captures Neo4j query results and verdict
        vet_span_id = os.urandom(8).hex()
        vet_start_ns = str(int(vet_start * 1e9))
        vet_end_ns = str(int(vet_end * 1e9))

        vet_attrs = [
            {"key": "vet.verdict", "value": {"stringValue": verdict}},
            {"key": "vet.chain", "value": {"intValue": str(len(chain))}},
            {"key": "vet.attempts", "value": {"intValue": str(len(attempts))}},
            {"key": "vet.failed_attempts", "value": {"intValue": str(failed_count)}},
            {"key": "vet.credentials", "value": {"intValue": str(len(creds))}},
            {"key": "vet.strategies", "value": {"intValue": str(len(strategies))}},
            {"key": "vet.attack_classes", "value": {"intValue": str(len(attack_classes))}},
            {"key": "vet.tasks", "value": {"intValue": str(len(tasks))}},
        ]
        if vet_context:
            vet_attrs.append({"key": "vet.context", "value": {"stringValue": vet_context[:2000]}})

        vet_span = {
            "traceId": trace_id,
            "spanId": vet_span_id,
            "parentSpanId": root_span_id,
            "name": f"vet: {verdict.lower()} target={target or '(none)'}",
            "kind": 1,
            "startTimeUnixNano": vet_start_ns,
            "endTimeUnixNano": vet_end_ns,
            "attributes": vet_attrs,
        }

        # Neo4j query child spans under vet
        neo4j_spans = []
        for qname, qtext, qstart, qend, qcount in query_timings:
            neo4j_spans.append({
                "traceId": trace_id,
                "spanId": os.urandom(8).hex(),
                "parentSpanId": vet_span_id,
                "name": f"neo4j.query: {qname} ({qcount} hits)",
                "kind": 3,
                "startTimeUnixNano": str(int(qstart * 1e9)),
                "endTimeUnixNano": str(int(qend * 1e9)),
                "attributes": [
                    {"key": "db.system", "value": {"stringValue": "neo4j"}},
                    {"key": "db.statement", "value": {"stringValue": qtext}},
                    {"key": "db.result_count", "value": {"intValue": str(qcount)}},
                ],
            })

        emit_spans([root_span, vet_span] + neo4j_spans, "pownie-pre-hook")

        # Inject trace context for MCP server + PostToolUse
        otel_trace = {
            "trace_id": trace_id,
            "parent_span_id": root_span_id,
            "trigger_reason": trigger_context[:500],
            "target": target,
        }
        merged_input = dict(ti)
        merged_input["_otel_trace"] = otel_trace
        hook_output["updatedInput"] = merged_input

    if vet_context:
        hook_output["additionalContext"] = vet_context[:4000]

    # Log verdict
    log_detail = f'target={target}' if target else 'no-target'
    if has_graph_data:
        log_detail += (f' chain={len(chain)} '
                       f'attempts={len(attempts)} creds={len(creds)} '
                       f'strategies={len(strategies)}')
    log(verdict, cmd_short[:80], log_detail)

    json.dump({"hookSpecificOutput": hook_output}, sys.stdout)

except Exception as e:
    try:
        log('ERROR', '(exception)', str(e)[:120])
    except Exception:
        pass
    print("{}")
PYEOF
