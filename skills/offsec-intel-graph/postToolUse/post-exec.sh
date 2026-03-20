#!/usr/bin/env bash
# trace.sh — PostToolUse hook: OTLP tracing + Neo4j command_log + intel extraction
#
# Fires AFTER kali MCP tool calls. Three responsibilities:
#
#   1. command_log write  — MERGE command_log node with result, EXECUTED_ON
#   2. intel extraction   — extract credentials/services from cmd+result,
#                           write directly to Neo4j (no model cooperation needed)
#   3. OTLP tracing       — emit child spans for observability
#
# Reads _otel_trace from tool_input (injected by PreToolUse trace.sh).
# Telemetry failures are silent — never blocks execution.

set -euo pipefail

LOGDIR="${CLAUDE_PLUGIN_DATA:-${CLAUDE_PROJECT_DIR:-.}/.claude}/logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/post-exec-log.log"

INPUT=$(cat)

HOOK_INPUT="$INPUT" LOGFILE="$LOGFILE" NEO4J_CONTAINER="${POWNIE_PREFIX:-pownie}-neo4j" python3 << 'PYEOF'
import urllib.request, json, hashlib, time, os, re, sys, subprocess
from datetime import datetime, timezone

TEMPO_ENDPOINT = os.environ.get("TEMPO_ENDPOINT", "http://localhost:4318/v1/traces")
NEO4J_CONTAINER = os.environ.get('NEO4J_CONTAINER', 'pownie-neo4j')
LOGFILE = os.environ.get('LOGFILE', 'post-exec-log.log')

def log(status, cmd_short, detail=''):
    try:
        with open(LOGFILE, 'a') as f:
            ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
            f.write(f"{ts} {status} {cmd_short}")
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

def cypher_write(query):
    """Execute a write Cypher query via cypher-shell."""
    try:
        r = subprocess.run(
            ['docker', 'exec', NEO4J_CONTAINER, 'cypher-shell',
             '-u', 'neo4j', '-p', 'pownie-graph', '--format', 'plain', query],
            capture_output=True, text=True, timeout=5
        )
        return r.returncode == 0, r.stderr.strip()[:120]
    except Exception as e:
        return False, str(e)[:120]

def extract_result(d):
    """Extract result text and error flag from tool_response."""
    tool_result = d.get('tool_response', [])
    result_text = ""
    is_error = False
    if isinstance(tool_result, list):
        for content in tool_result:
            if isinstance(content, dict) and content.get('type') == 'text':
                result_text = content.get('text', '')
                break
    elif isinstance(tool_result, dict):
        is_error = tool_result.get('isError', False)
        for content in tool_result.get('content', []):
            if content.get('type') == 'text':
                result_text = content.get('text', '')
                break
    return result_text, is_error

# ── INTEL EXTRACTION (V3.5) ──────────────────────────────────────────

PROTO_PORTS = {
    'ssh': 22, 'smb': 445, 'winrm': 5985, 'rdp': 3389,
    'ftp': 21, 'mysql': 3306, 'postgres': 5432, 'mssql': 1433,
    'ldap': 389, 'ldaps': 636, 'http': 80, 'https': 443,
}

def safe_str(s):
    """Escape string for Cypher single-quoted literal."""
    return str(s).replace('\\', '\\\\').replace("'", "\\'").replace('\n', ' ').replace('\r', '')

def extract_flag(cmd, short, long_flag=None):
    """Extract value of a CLI flag like -u USER or --username 'USER'."""
    for flag in ([short] + ([long_flag] if long_flag else [])):
        # Quoted values first
        m = re.search(flag + r"\s+'([^']*)'", cmd)
        if m:
            return m.group(1)
        m = re.search(flag + r'\s+"([^"]*)"', cmd)
        if m:
            return m.group(1)
        # Unquoted
        m = re.search(flag + r'\s+(\S+)', cmd)
        if m:
            return m.group(1)
    return None

def extract_credentials(cmd):
    """Extract credentials from command patterns. Returns list of dicts."""
    creds = []

    # sshpass -p 'PASS' ssh USER@HOST
    m = re.search(r'sshpass\s+-p\s+(?:\'([^\']*)\'|"([^"]*)"|(\S+))', cmd)
    if m:
        password = m.group(1) or m.group(2) or m.group(3)
        uh = re.search(r'(\S+)@([^\s@:]+)', cmd[m.end():])
        if uh:
            creds.append({
                'user': uh.group(1), 'secret': password, 'secret_type': 'password',
                'protocol': 'ssh', 'host': uh.group(2)
            })
            return creds

    # nxc/crackmapexec/netexec PROTO HOST -u USER -p PASS / -H HASH
    nxc = re.search(r'(?:nxc|crackmapexec|netexec)\s+(\w+)\s+(\S+)', cmd)
    if nxc:
        protocol = nxc.group(1).lower()
        host = nxc.group(2)
        user = extract_flag(cmd, '-u', '--username')
        password = extract_flag(cmd, '-p', '--password')
        ntlm_hash = extract_flag(cmd, '-H', '--hash')
        if user and (password or ntlm_hash):
            creds.append({
                'user': user,
                'secret': password if password else ntlm_hash,
                'secret_type': 'password' if password else 'hash',
                'protocol': protocol, 'host': host
            })
            return creds

    # evil-winrm -i HOST -u USER -p PASS
    if 'evil-winrm' in cmd:
        host = extract_flag(cmd, '-i', '--ip')
        user = extract_flag(cmd, '-u', '--user')
        password = extract_flag(cmd, '-p', '--password')
        if host and user and password:
            creds.append({
                'user': user, 'secret': password, 'secret_type': 'password',
                'protocol': 'winrm', 'host': host
            })
            return creds

    # impacket: [DOMAIN/]USER:PASS@HOST
    imp = re.search(
        r'(?:impacket-\w+|(?:psexec|wmiexec|smbexec|atexec|dcomexec|secretsdump|'
        r'getTGT|getST|GetNPUsers|GetUserSPNs)\.py)\s', cmd)
    if imp:
        # Use (.+)@ to greedily match password up to LAST @ (handles P@ss in passwords)
        cred = re.search(r'(?:(\S+)/)?([^:\s]+):(.+)@(\S+)', cmd[imp.end():])
        if cred:
            creds.append({
                'user': cred.group(2), 'secret': cred.group(3), 'secret_type': 'password',
                'protocol': 'smb', 'host': cred.group(4)
            })
            return creds

    return creds

def determine_auth_status(result_text):
    """Determine authentication outcome from command result."""
    if not result_text.strip():
        return 'untested'
    # Explicit success
    if '[+]' in result_text or '(Pwn3d!)' in result_text:
        return 'confirmed'
    # Explicit failure
    if '[-]' in result_text:
        return 'failed'
    r = result_text.lower()
    fail_signals = ['permission denied', 'logon_failure', 'status_logon_failure',
                    'authentication failed', 'access denied', 'login failed',
                    'kdc_err_preauth_failed']
    if any(s in r for s in fail_signals):
        return 'failed'
    return 'untested'

def extract_services(cmd, result_text, target_ip):
    """Extract open services from nmap output."""
    if 'nmap' not in cmd.lower():
        return []
    if not target_ip:
        return []
    services = []
    for m in re.finditer(r'(\d+)/(tcp|udp)\s+open\s+(\S+)(?:\s+(.+?))?(?:\n|$)', result_text):
        services.append({
            'host': target_ip, 'port': int(m.group(1)), 'proto': m.group(2),
            'service': m.group(3), 'version': (m.group(4) or '').strip()
        })
    return services[:15]  # cap to avoid huge writes

def build_intel_cypher(credentials, services, auth_status, cmd_sha256=''):
    """Build Cypher statements for extracted intel. Returns (list_of_cypher, list_of_descriptions).
    When cmd_sha256 is provided, adds DISCOVERED edges from command_log to extracted intel."""
    statements = []
    descriptions = []

    for cred in credentials:
        host = cred['host']
        protocol = cred['protocol']
        port = PROTO_PORTS.get(protocol, 0)
        user = safe_str(cred['user'])
        secret = safe_str(cred['secret'])
        secret_type = cred['secret_type']
        svc_key = safe_str(f"{host}:{port}:{protocol}")
        cred_key = safe_str(f"{cred['user']}:{cred['secret']}")

        cypher = (
            f"MERGE (s:service {{key: '{svc_key}'}}) "
            f"SET s.service = '{safe_str(protocol)}', s.port = {port} "
            f"MERGE (c:credential {{key: '{cred_key}'}}) "
            f"SET c.username = '{user}', c.secret = '{secret}', c.secret_type = '{secret_type}' "
            f"MERGE (c)-[r:AUTHENTICATES_TO]->(s) "
            f"SET r.status = CASE WHEN r.status = 'confirmed' THEN 'confirmed' ELSE '{auth_status}' END"
        )
        if cmd_sha256:
            cypher += (
                f" WITH c "
                f"OPTIONAL MATCH (cl:command_log {{sha256: '{cmd_sha256}'}}) "
                f"FOREACH (_ IN CASE WHEN cl IS NOT NULL THEN [1] ELSE [] END | "
                f"MERGE (cl)-[:DISCOVERED]->(c))"
            )
        statements.append(cypher)
        descriptions.append(f"credential {cred['user']}:{cred['secret']} -> {protocol} ({auth_status})")

    if services:
        parts = []
        for i, svc in enumerate(services):
            host = svc['host']
            port = svc['port']
            proto = svc['proto']
            service = svc['service']
            version = svc.get('version', '')
            port_key = safe_str(f"{host}:{port}/{proto}")
            svc_key = safe_str(f"{host}:{port}:{service}")

            part = (
                f"MERGE (p{i}:port {{key: '{port_key}'}}) "
                f"SET p{i}.port = {port}, p{i}.proto = '{safe_str(proto)}' "
                f"MERGE (s{i}:service {{key: '{svc_key}'}}) "
                f"SET s{i}.service = '{safe_str(service)}'"
            )
            if version:
                part += f", s{i}.version = '{safe_str(version)}'"
            part += f" MERGE (p{i})-[:RUNS_SERVICE]->(s{i})"
            parts.append(part)
            descriptions.append(f"service {host}:{port}/{service}")

        svc_cypher = " ".join(parts)
        if cmd_sha256:
            with_vars = ", ".join(f"s{i}" for i in range(len(services)))
            disc_merges = " ".join(f"MERGE (cl)-[:DISCOVERED]->(s{i})" for i in range(len(services)))
            svc_cypher += (
                f" WITH {with_vars} "
                f"OPTIONAL MATCH (cl:command_log {{sha256: '{cmd_sha256}'}}) "
                f"FOREACH (_ IN CASE WHEN cl IS NOT NULL THEN [1] ELSE [] END | "
                f"{disc_merges})"
            )
        statements.append(svc_cypher)

    return statements, descriptions

try:
    d = json.loads(os.environ['HOOK_INPUT'])
    ti = d.get("tool_input", {})
    otel_trace = ti.get("_otel_trace", {})
    trigger_reason = otel_trace.get("trigger_reason", "")
    target_from_pre = otel_trace.get("target", "")
    tool_use_id = d.get("tool_use_id", "")
    tool_name = d.get("tool_name", "")
    cmd = ti.get("command", "") or ti.get("input", "")

    if not cmd.strip():
        log('SKIP', '(empty)')
        sys.exit(0)

    cmd_sha256 = hashlib.sha256(cmd.encode()).hexdigest()[:16]
    cmd_short = re.sub(r'\s+', ' ', cmd.strip().split('\n')[0].strip())[:120]

    # Extract result from tool_response
    result_text, is_error = extract_result(d)
    result_excerpt = re.sub(r'\s+', ' ', result_text.strip())[:300]

    # ── LOG: Write command_log to Neo4j ─────────────────────────────────

    log_start = time.time()
    summary = re.sub(r'\s+', ' ', cmd.strip().split('\n')[0].strip())[:500]
    safe_summary = summary.replace('\\', '\\\\').replace("'", "\\'")
    safe_result = result_excerpt.replace('\\', '\\\\').replace("'", "\\'")

    ips = re.findall(r'[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+', cmd)
    target_ip = ips[0] if ips else ''
    target_val = target_from_pre or target_ip

    safe_trigger = re.sub(r'\s+', ' ', trigger_reason).replace('\\', '\\\\').replace("'", "\\'")[:500]
    safe_target_val = target_val.replace('\\', '\\\\').replace("'", "\\'")

    set_clause = (
        f"SET c.summary = '{safe_summary}', "
        f"c.result = '{safe_result}', "
        f"c.trigger_reason = '{safe_trigger}', "
        f"c.target = '{safe_target_val}', "
        f"c.is_error = {str(is_error).lower()}, "
        f"c.timestamp = datetime()"
    )

    # Build MERGE with optional NEXT chain + EXECUTED_ON
    cypher_parts = [
        f"MERGE (c:command_log {{sha256: '{cmd_sha256}'}}) {set_clause}"
    ]

    if target_val:
        cypher_parts.append(
            f"WITH c "
            f"OPTIONAL MATCH (prev:command_log) "
            f"WHERE prev.target = '{safe_target_val}' "
            f"AND prev.target <> '' "
            f"AND prev.sha256 <> '{cmd_sha256}' "
            f"AND prev.timestamp < c.timestamp "
            f"WITH c, prev ORDER BY prev.timestamp DESC LIMIT 1 "
            f"FOREACH (_ IN CASE WHEN prev IS NOT NULL THEN [1] ELSE [] END | "
            f"MERGE (prev)-[:NEXT]->(c))"
        )

    if target_ip:
        cypher_parts.append(
            f"WITH c "
            f"MERGE (i:ip {{addr: '{target_ip}'}}) "
            f"MERGE (c)-[:EXECUTED_ON]->(i)"
        )

    cypher = " ".join(cypher_parts)

    neo4j_ok, neo4j_err = cypher_write(cypher)
    log_end = time.time()

    if neo4j_ok:
        log('LOGGED', cmd_short[:80], f'target={target_val} err={is_error}' if target_val else f'no-target err={is_error}')
    else:
        log('NEO4J_ERR', cmd_short[:80], neo4j_err)

    # ── INTEL: Extract credentials/services and write to Neo4j ────────

    intel_start = time.time()
    intel_descriptions = []

    credentials = extract_credentials(cmd)
    auth_status = determine_auth_status(result_text) if credentials else 'untested'
    services = extract_services(cmd, result_text, target_ip)

    if credentials or services:
        statements, intel_descriptions = build_intel_cypher(credentials, services, auth_status, cmd_sha256)
        for stmt in statements:
            ok, err = cypher_write(stmt)
            if ok:
                log('INTEL_OK', cmd_short[:60], stmt[:80])
            else:
                log('INTEL_ERR', cmd_short[:60], err)

    intel_end = time.time()

    # ── TRACE: Emit OTLP child spans ───────────────────────────────────

    trace_id = None
    parent_span_id = ""
    if otel_trace:
        trace_id = otel_trace.get("trace_id", "")
        parent_span_id = otel_trace.get("parent_span_id", "")
    elif tool_use_id:
        trace_id = hashlib.sha256(tool_use_id.encode()).hexdigest()[:32]

    if trace_id:
        now_ns = str(int(time.time() * 1e9))

        # Post span — result summary
        post_span = {
            "traceId": trace_id,
            "spanId": os.urandom(8).hex(),
            "parentSpanId": parent_span_id,
            "name": "post_tool_use",
            "kind": 1,
            "startTimeUnixNano": now_ns,
            "endTimeUnixNano": str(int(time.time() * 1e9)),
            "attributes": [
                {"key": "tool.name", "value": {"stringValue": tool_name}},
                {"key": "command.sha256", "value": {"stringValue": cmd_sha256}},
                {"key": "command.full", "value": {"stringValue": cmd[:2000]}},
                {"key": "result.summary", "value": {"stringValue": result_text[:2000]}},
                {"key": "result.is_error", "value": {"boolValue": is_error}},
                {"key": "result.output_bytes", "value": {"intValue": str(len(result_text))}},
            ]
        }

        # Log span — Neo4j write result
        log_start_ns = str(int(log_start * 1e9))
        log_end_ns = str(int(log_end * 1e9))
        log_span = {
            "traceId": trace_id,
            "spanId": os.urandom(8).hex(),
            "parentSpanId": parent_span_id,
            "name": f"log: neo4j {'ok' if neo4j_ok else 'err'} target={target_val or '(none)'}",
            "kind": 1,
            "startTimeUnixNano": log_start_ns,
            "endTimeUnixNano": log_end_ns,
            "attributes": [
                {"key": "log.neo4j_ok", "value": {"boolValue": neo4j_ok}},
                {"key": "log.target_ip", "value": {"stringValue": target_ip}},
                {"key": "log.is_error", "value": {"boolValue": is_error}},
                {"key": "log.sha256", "value": {"stringValue": cmd_sha256}},
            ],
        }
        if not neo4j_ok:
            log_span["attributes"].append(
                {"key": "log.neo4j_error", "value": {"stringValue": neo4j_err}}
            )

        # Intel span — extraction results
        all_spans = [post_span, log_span]
        if intel_descriptions:
            intel_span = {
                "traceId": trace_id,
                "spanId": os.urandom(8).hex(),
                "parentSpanId": parent_span_id,
                "name": f"intel: {len(intel_descriptions)} items extracted",
                "kind": 1,
                "startTimeUnixNano": str(int(intel_start * 1e9)),
                "endTimeUnixNano": str(int(intel_end * 1e9)),
                "attributes": [
                    {"key": "intel.count", "value": {"intValue": str(len(intel_descriptions))}},
                    {"key": "intel.items", "value": {"stringValue": "; ".join(intel_descriptions)[:500]}},
                    {"key": "intel.auth_status", "value": {"stringValue": auth_status if credentials else "n/a"}},
                ],
            }
            all_spans.append(intel_span)

        emit_spans(all_spans, "pownie-post-hook")

    # ── FEEDBACK: Phase classification prompt + auto-recorded intel ─────
    hook_output = {"hookEventName": "PostToolUse"}

    feedback_parts = []
    if intel_descriptions:
        feedback_parts.append(
            "Auto-recorded to graph: " + "; ".join(intel_descriptions) + ". "
            "If this command also revealed vulnerabilities, shells, or flags, "
            "write those manually via mcp__neo4j__write_cypher."
        )

    # Always prompt for phase classification
    feedback_parts.append(
        f"Classify this command's phase. In your next write_cypher call, include: "
        f"MATCH (cl:command_log {{sha256: '{cmd_sha256}'}}) SET cl.phase = '<phase>' "
        f"— use dot-notation like recon.port-scan, enum.dir-brute, enum.web, "
        f"exploit.sqli, exploit.lfi, privesc.sudo, lateral.cred-reuse, access.login"
    )

    # ── BEHAVIORAL NUDGES: detect critical moments and inject specific prompts ──

    # Shell detection: uid= or common shell indicators in output
    shell_indicators = ['uid=', 'www-data', 'NT AUTHORITY\\SYSTEM', 'nt authority\\system']
    if result_text and any(s in result_text for s in shell_indicators):
        # Only nudge if this looks like a NEW shell (not just a command run from existing shell)
        if any(kw in cmd.lower() for kw in ['exploit', 'upload', 'reverse', 'shell', 'rce', 'inject', 'curl', 'wget']):
            feedback_parts.append(
                "SHELL OBTAINED. Spawn 2-3 parallel teammates NOW: "
                "(1) system enum — sudo, SUID, cron, writable paths, internal network; "
                "(2) CVE research — local software versions found during enum; "
                "(3) lateral paths — credential reuse, config files, databases. "
                "Do NOT enumerate serially — use the Agent tool to parallelize."
            )

    # Repeated failure detection: query Neo4j for recent failed commands on same target
    if target_val and is_error:
        try:
            r = subprocess.run(
                ['docker', 'exec', NEO4J_CONTAINER, 'cypher-shell',
                 '-u', 'neo4j', '-p', 'pownie-graph', '--format', 'plain',
                 f"MATCH (c:command_log) "
                 f"WHERE c.target = '{safe_target_val}' AND c.is_error = true "
                 f"AND c.timestamp > datetime() - duration('PT10M') "
                 f"RETURN count(c) AS cnt"],
                capture_output=True, text=True, timeout=3
            )
            if r.returncode == 0:
                cnt_match = re.search(r'(\d+)', r.stdout)
                if cnt_match and int(cnt_match.group(1)) >= 3:
                    feedback_parts.append(
                        f"WARNING: {cnt_match.group(1)} errors on {target_val} in last 10 min. "
                        "Stop and assess — is the entire ATTACK CLASS dead, not just this variant? "
                        "Write an attack_class node if the mechanism itself is impossible."
                    )
        except Exception:
            pass

    hook_output["additionalContext"] = " | ".join(feedback_parts)
    json.dump({"hookSpecificOutput": hook_output}, sys.stdout)

except Exception as e:
    try:
        log('ERROR', '(exception)', str(e)[:120])
    except Exception:
        pass
PYEOF
