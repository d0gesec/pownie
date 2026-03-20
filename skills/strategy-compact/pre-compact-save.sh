#!/usr/bin/env bash
# pre-compact-save.sh — PreCompact hook
#
# Fires BEFORE every compaction (auto or manual). Queries Neo4j via HTTP API
# with batched Cypher statements (single POST) and writes a rich compact-state.md
# for post-compaction recovery.
#
# Flow:
#   PreCompact fires → this script queries Neo4j → writes compact-state.md
#   Post-compact agent → reads compact-state.md → runs recovery Cypher
#   → full context rebuilt from Neo4j graph (not from this file)

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
PROJECT_STATE="$HOME/.claude/projects/$(echo "$PROJECT_DIR" | sed 's|/|-|g')"
COMPACT_STATE="$PROJECT_STATE/compact-state.md"

mkdir -p "$PROJECT_STATE"

export COMPACT_STATE

python3 << 'PYEOF'
import urllib.request, json, base64, sys, os

NEO4J_URL = "http://localhost:7474/db/neo4j/tx/commit"
AUTH = "Basic " + base64.b64encode(b"neo4j:pownie-graph").decode()
COMPACT_STATE = os.environ["COMPACT_STATE"]

def batched_cypher(statements):
    """Execute multiple Cypher statements in a single HTTP POST. Returns list of result sets."""
    body = json.dumps({"statements": [{"statement": s} for s in statements]}).encode()
    req = urllib.request.Request(NEO4J_URL, data=body,
        headers={"Content-Type": "application/json", "Authorization": AUTH})
    try:
        resp = urllib.request.urlopen(req, timeout=10)
        data = json.loads(resp.read())
        results = [r.get("data", []) for r in data.get("results", [])]
        # Pad to statement count — partial results are still useful on error
        while len(results) < len(statements):
            results.append([])
        return results
    except Exception:
        return None

def rows_to_strings(result_set):
    """Extract first column string from each row."""
    out = []
    for row in result_set:
        vals = row.get("row", [])
        if vals and vals[0] is not None:
            out.append(str(vals[0]))
    return out

# Guard: check if Neo4j is reachable
test = batched_cypher(["RETURN 1"])
if test is None:
    sys.exit(0)

# Batched queries — single HTTP POST
results = batched_cypher([
    # 0: Target name
    "MATCH (t:target) RETURN t.name LIMIT 1",
    # 1: Services with ports
    "MATCH (s:service)<-[:RUNS_SERVICE]-(p:port) "
    "RETURN s.key + ' (' + p.key + ')' AS svc ORDER BY s.key LIMIT 20",
    # 2: Credentials with auth status
    "MATCH (c:credential)-[r:AUTHENTICATES_TO]->(s:service) "
    "RETURN c.key + ' -> ' + s.service + ' (' + r.status + ')' AS cred ORDER BY r.status LIMIT 20",
    # 3: Shells
    "MATCH (s:shell) RETURN s.key + ' [' + coalesce(s.access_level, s.user, '?') + ']' AS shell LIMIT 10",
    # 4: Flags
    "MATCH (f:flag) RETURN f.key + ' = ' + coalesce(f.value, '?') AS flag LIMIT 10",
    # 5: In-progress strategies
    "MATCH (st:strategy) WHERE st.status = 'in_progress' "
    "RETURN st.method + ': ' + coalesce(left(st.result, 120), '(no result yet)') AS strat LIMIT 10",
    # 6: Failed attempts (top 10)
    "MATCH (a:attempt {outcome: 'failed'}) "
    "RETURN a.technique + ' via ' + a.tool + ': ' + coalesce(left(a.output_summary, 120), '?') "
    "+ CASE WHEN a.error_signature IS NOT NULL THEN ' [' + a.error_signature + ']' ELSE '' END AS fail "
    "ORDER BY a.created_at DESC LIMIT 10",
    # 7: Recent command chain
    "MATCH (c:command_log) WHERE c.target IS NOT NULL AND c.target <> '' "
    "RETURN c.target + ': ' + c.summary + ' -> ' + coalesce(left(c.result, 80), '?') "
    "+ CASE WHEN c.is_error THEN ' [ERROR]' ELSE '' END AS cmd "
    "ORDER BY c.timestamp DESC LIMIT 10",
    # 8: Write compaction_event node
    "CREATE (e:compaction_event {timestamp: datetime(), type: 'auto'})",
    # 9: Command log count (for empty-graph diagnostic)
    "MATCH (c:command_log) RETURN count(c) AS cnt",
])

if results is None:
    sys.exit(0)

# Parse results
target_rows = results[0] if len(results) > 0 else []
target = target_rows[0]["row"][0] if target_rows else "unknown"

services = rows_to_strings(results[1]) if len(results) > 1 else []
creds = rows_to_strings(results[2]) if len(results) > 2 else []
shells = rows_to_strings(results[3]) if len(results) > 3 else []
flags = rows_to_strings(results[4]) if len(results) > 4 else []
strategies = rows_to_strings(results[5]) if len(results) > 5 else []
failed = rows_to_strings(results[6]) if len(results) > 6 else []
cmd_chain = rows_to_strings(results[7]) if len(results) > 7 else []
cmd_log_count = int(results[9][0]["row"][0]) if len(results) > 9 and results[9] else 0
entity_count = len(services) + len(creds) + len(shells) + len(flags) + len(strategies)

# Write compact-state.md
with open(COMPACT_STATE, "w") as f:
    f.write("# Post-Compact Recovery\n\n")
    f.write(f"Target: **{target}**\n\n")

    # Current state summary
    f.write("## Current State\n\n")
    if services:
        f.write(f"Services: {', '.join(services[:10])}\n")
        if len(services) > 10:
            f.write(f"  (+{len(services) - 10} more)\n")
    if shells:
        f.write(f"Shells: {', '.join(shells)}\n")
    if flags:
        f.write(f"Flags: {', '.join(flags)}\n")
    if strategies:
        f.write(f"In-progress strategies: {', '.join(strategies)}\n")
    if not (services or shells or flags or strategies):
        if cmd_log_count > 10:
            f.write(f"WARNING: {cmd_log_count} commands executed but no structured intel recorded.\n")
            f.write("Intel may be lost after compaction. Write key findings to Neo4j before compacting.\n")
        else:
            f.write("(no structured data recorded yet)\n")
    f.write("\n")

    # Credentials
    if creds:
        f.write("## Known Credentials\n\n")
        for c in creds:
            f.write(f"- {c}\n")
        f.write("\n")

    # Failed attempts
    if failed:
        f.write("## DO NOT RETRY -- Prior Failed Attempts\n\n")
        for fa in failed:
            f.write(f"- {fa}\n")
        f.write("\n")

    # Recent command history
    if cmd_chain:
        f.write("## Recent Command History\n\n")
        for cmd in cmd_chain:
            f.write(f"- {cmd}\n")
        f.write("\n")

    # Recovery instructions
    f.write("## Recovery\n\n")
    f.write("Run via `mcp__neo4j__read_cypher`:\n\n")
    f.write("```cypher\n")
    f.write("MATCH (t:target)-[r*1..3]-(n)\n")
    f.write("UNWIND r AS rel\n")
    f.write("RETURN DISTINCT labels(n)[0] AS type, n.key AS key, properties(n) AS props\n")
    f.write("ORDER BY type, key\n")
    f.write("```\n")

# Stderr warnings for model context
warnings = []
if cmd_log_count > 10 and entity_count == 0:
    warnings.append(f"WARNING: {cmd_log_count} commands logged but 0 structured entities — intel will be lost after compaction")
if strategies:
    warnings.append(f"IN-PROGRESS strategies: {', '.join(strategies)}")
if failed:
    warnings.append(f"{len(failed)} failed attempts recorded (see compact-state.md)")

summary_parts = [f"Target: {target}"]
summary_parts.append(f"{len(services)} services, {len(creds)} creds, {len(shells)} shells, {len(flags)} flags")
if warnings:
    summary_parts.extend(warnings)

print(f"[PreCompact] Recovery state saved. {' | '.join(summary_parts)}", file=sys.stderr)
PYEOF
