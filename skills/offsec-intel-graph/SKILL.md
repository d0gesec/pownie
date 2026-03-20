---
name: offsec-intel-graph
description: Neo4j graph database for offensive security intel. Model writes Cypher directly via MCP tools — no scripts, no wrappers.
user-invocable: false
---

# Intel Graph — Neo4j Attack Knowledge Graph

The model writes Cypher directly to Neo4j using the `mcp__neo4j__write_cypher` and `mcp__neo4j__read_cypher` MCP tools. The model determines what entities and relationships exist in the data — this is LLM judgment, not scripted extraction.

## When to Activate

- Any offensive security engagement (CTF, pentest, lab, red team)
- At the start of every attack session
- After context compaction (recovery read)

## Before Any Attack Action (MANDATORY)

Before calling ANY kali MCP tool that targets a service, endpoint, or vulnerability:

1. **Query disproven attack classes** — entire categories ruled out:

```cypher
MATCH (ac:attack_class)-[:ON_TARGET]->(tgt:target {name: $targetName})
WHERE ac.status = 'disproven'
RETURN ac.key, ac.reason, ac.blocked_techniques
```

If your planned technique falls within a disproven class, STOP. Choose a different class entirely.

2. **Query prior attempts** on the target:

```cypher
MATCH (a:attempt)-[:TRIED_ON]->(target)
WHERE target.addr = $targetIp OR target.key CONTAINS $targetIp
RETURN a.technique, a.tool, a.outcome, a.output_summary, a.error_signature
ORDER BY a.created_at DESC
```

3. **Query untested edges** — credentials or services not yet tried:

```cypher
MATCH (c:credential)-[r:AUTHENTICATES_TO {status: 'untested'}]->(s:service)
WHERE s.key STARTS WITH $targetIp
RETURN c.key, s.service
```

4. **Decide**: If the attack class is disproven, do NOT try any variant — the entire class is dead. If the same technique already failed and nothing has materially changed, do NOT retry. Choose a different technique or gather new intel first.

4. **After execution, immediately RECORD**:

```cypher
MERGE (a:attempt {key: 'att:<technique>:<tool>@<target_component>'})
SET a.technique = '<technique>', a.tool = '<tool>',
    a.outcome = '<failed|succeeded|partial>',
    a.output_summary = '<1-2 sentence summary>',
    a.error_signature = '<access_denied|timeout|waf_blocked|...>',
    a.created_at = datetime()
```

A PreToolUse hook (`trace.sh`) queries Neo4j and surfaces prior attempts, credentials, and strategies as context BEFORE execution. This is a safety net — your own CHECK query above is the primary defense.

A PostToolUse hook (`trace.sh`) **auto-extracts credentials and services** from commands and writes them directly to Neo4j:

- **Credentials**: extracted from `sshpass`, `nxc`/`crackmapexec`, `evil-winrm`, impacket tools
- **Auth status**: determined from result (`[+]`=confirmed, `[-]`/`Permission denied`=failed)
- **Services**: extracted from nmap output (port/service/version)

Auto-extracted intel appears as `additionalContext` ("Auto-recorded to graph: ..."). You still need to manually write: target nodes (box name), vulnerabilities, shells, strategies, attempts, and flags.

## Phase Classification (MANDATORY)

After every kali MCP tool call, the PostToolUse hook prompts you to classify the command's phase. **Always include the phase SET in your next `write_cypher` call** — piggyback it on whatever intel you're already writing:

```cypher
MATCH (cl:command_log {sha256: '<sha256_from_prompt>'}) SET cl.phase = '<phase>'
```

Use dot-notation: `recon.port-scan`, `enum.dir-brute`, `enum.web`, `exploit.sqli`, `exploit.lfi`, `privesc.sudo`, `lateral.cred-reuse`, `access.login`. Create deeper keys freely: `exploit.deserialization.java`, `privesc.service.race`.

The PreToolUse vet surfaces phase breakdown — commands grouped by phase with productive counts. This lets you see at a glance which phases are stale (many commands, zero productive) and which are yielding results.

## Post-Compaction Recovery (MANDATORY)

After every compaction, before doing ANYTHING else:

1. Run the full graph recovery:

```cypher
MATCH (t:target)-[r*1..3]-(n)
UNWIND r AS rel
RETURN DISTINCT labels(n)[0] AS type, n.key AS key, properties(n) AS props
ORDER BY type, key
```

2. Check what has already been tried and FAILED:

```cypher
MATCH (a:attempt {outcome: 'failed'})
RETURN a.technique, a.tool, a.error_signature, a.output_summary
ORDER BY a.created_at DESC LIMIT 15
```

Do NOT proceed with any attack until you have reviewed both results.

## How It Works

1. Model discovers a finding via Kali MCP
2. Model determines what entities and relationships exist
3. Model calls `write_cypher` with MERGE statements using ONLY the schema defined below
4. Model reads graph context with `read_cypher` when planning next steps

## MCP Tools

| Tool | Use |
| ---- | --- |
| `mcp__neo4j__write_cypher` | Create/update nodes and relationships |
| `mcp__neo4j__read_cypher` | Query the graph — returns structured results |
| `mcp__neo4j__get_schema` | Inspect current labels, relationship types, property keys |

## Recording Findings

When you discover something, write Cypher immediately. Every finding is a MERGE — never skip, never batch "for later." Unrecorded findings are permanently lost on compaction.

## Schema

Use ONLY the node labels and relationship types defined below. Do NOT invent new labels or relationship types. If a finding doesn't fit the schema, store it as properties on existing nodes rather than creating new types.

### Node Labels

| Label | Key Property | Key Format | Other Properties |
| ----- | ------------ | ---------- | ---------------- |
| target | name | `BoxName` | platform, notes, domain |
| ip | addr | `10.0.0.1` | |
| port | key | `10.0.0.1:22/tcp` | port, proto |
| service | key | `10.0.0.1:22:ssh` | service, version |
| credential | key | `admin:P@ssw0rd` | username, secret, secret_type |
| user | name | `admin` | domain, groups |
| vulnerability | key | `CVE-2024-1234` or `vuln:sqli@/login` | name, cve, endpoint, param, tool, exploitation_method, prerequisites, payload_format, confidence, wrong_approaches |
| shell | key | `BoxName:www-data:webshell` | user, method |
| flag | key | `HTB{...}` or `flag:user.txt` | value, location |
| file | key | `/etc/config.ini` | content_hash |
| endpoint | key | `/api/login` | method, params |
| strategy | key | `strat:ssh-brute-admin` | method, category, status, result, target_component |
| attempt | key | `att:<technique>:<tool>@<target_component>` | technique, tool, command, outcome, output_summary, error_signature, created_at |
| task | key | `task:<role>:<subject>` | description, status, depth, role, assignee, target, parent_key, findings_summary, spawned_at, completed_at |
| attack_class | key | `class:<type>@<component>` | status, reason, blocked_techniques, evidence_basis, disproven_at |

### Relationship Types

| Relationship | From | To | Properties | Meaning |
| ------------ | ---- | -- | ---------- | ------- |
| HAS_IP | target | ip | | Target resolves to this IP |
| HAS_PORT | target | port | | Port is open on target |
| RUNS_SERVICE | port | service | | Service identified on port |
| AUTHENTICATES_TO | credential | service | status: untested/confirmed/failed | Credential tested against service |
| BELONGS_TO | credential | user | | Credential belongs to this user |
| FOUND_IN | credential, flag | file, endpoint | | Where the finding was discovered |
| FOUND_ON | credential, vuln | target | | Associated with this target |
| AFFECTS | vulnerability | service, endpoint | | Vulnerability affects this component |
| RUNS_AS | shell | user | | Shell executes as this user |
| ON_TARGET | shell, vuln, strategy | target | | Exists on this target |
| LED_TO | vulnerability | shell | | Exploitation of vuln gave shell |
| TARGETS | strategy | target, service, endpoint | | Strategy aims at this component |
| TRIED_ON | attempt | service, endpoint, target | | Attempt targeted this component |
| HAS_ATTEMPT | strategy | attempt | | Strategy spawned this attempt |
| DISCOVERED | command_log, task | credential, service, vulnerability, shell, flag, attack_class | | Work unit produced this finding (auto-created by hook for credentials/services; model creates for vulns/shells/flags/attack_classes) |
| SPAWNED | task | task | | Parent task created child task for deeper investigation |

### Schema Rules

1. **Closed vocabulary** — only use the 15 node labels and 16 relationship types above
2. **Properties over new types** — if a nuance doesn't fit, add it as a property on the relationship (e.g., `AUTHENTICATES_TO {status: "confirmed", method: "pass-the-hash"}`)
3. **MERGE not CREATE** — idempotent writes prevent duplicates
4. **target.name is the anchor** — box name like "Pirate", not the IP. IPs are separate nodes linked via HAS_IP
5. **Relationship properties carry status** — `untested`, `confirmed`, `failed` for tracking what's been tried

## Example — Port Scan to Credential Chain

One example showing the pattern. Derive other scenarios from the schema tables above.

```cypher
MERGE (t:target {name: "BoxName"})
MERGE (p:port {key: "10.0.0.1:22/tcp"})
SET p.port = 22, p.proto = "tcp"
MERGE (t)-[:HAS_PORT]->(p)
MERGE (s:service {key: "10.0.0.1:22:ssh"})
SET s.service = "ssh", s.version = "OpenSSH 8.9p1"
MERGE (p)-[:RUNS_SERVICE]->(s)
MERGE (c:credential {key: "admin:P@ssw0rd"})
SET c.username = "admin", c.secret = "P@ssw0rd", c.secret_type = "password"
MERGE (c)-[:AUTHENTICATES_TO {status: "untested"}]->(s)
```

## Attempt Tracking — Version Control for Adversary Actions

Every adversary action (exploit, spray, brute-force, injection, scan) MUST be recorded as an `attempt` node. This prevents repeating failed techniques after context compaction.

### Attempt Key Format

`att:<technique>:<tool>@<target_component>` — the key includes the tool so different tools create separate nodes, but they share the same `technique` value for similarity matching via `STARTS WITH`.

### Technique Naming

Freeform dot-notation. Use your judgment. Convention: `<category>.<specifics>`.

Examples: `spray.password`, `inject.sqli.blind`, `exploit.cve`, `privesc.sudo`, `enum.dirbust`, `lateral.credreuse`

Create deeper keys freely: `exploit.deserialization.java`, `privesc.service.race`. Prefix queries via `STARTS WITH` catch all sub-techniques automatically.

### Automated Enforcement

A PreToolUse hook (`trace.sh`) fires BEFORE kali MCP tool calls. It queries Neo4j for prior attempts, known credentials, and strategies on the target IP and presents the raw graph context as `additionalContext`. Review this context — if the same technique already failed and nothing has materially changed, abort and choose a different approach.

## Reading the Graph

### Untested edges — what hasn't been tried yet

```cypher
MATCH (c:credential)-[r:AUTHENTICATES_TO {status: "untested"}]->(s:service)
RETURN c.key AS credential, s.key AS service
```

## Attack Class Tracking — Category-Level Kill Switch

An `attack_class` represents an entire CATEGORY of attack against a specific component. When one technique fails for a CLASS-LEVEL reason (the underlying mechanism is impossible, not just one payload variant), mark the whole class dead.

**Class-level failure** = the mechanism itself is blocked (parser doesn't support DTDs, regex blocks required characters, subprocess uses list args not shell=True).

**Instance-level failure** = the mechanism works but this specific payload/parameter was wrong (wrong path format, wrong injection point, wrong encoding). Instance-level failures do NOT kill the class.

### When to Write attack_class Nodes

```cypher
// Class-level disproof (kills entire attack category)
MERGE (ac:attack_class {key: 'class:xml_injection@variatype:80'})
SET ac.status = 'disproven',
    ac.reason = 'ElementTree parser (expat-based), no DTD/entity support',
    ac.blocked_techniques = 'xxe, oob_xxe, xinclude, parameter_entities, svg_xxe',
    ac.evidence_basis = 'fonttools uses xml.etree.ElementTree — confirmed in source',
    ac.disproven_at = datetime()
MERGE (tgt:target {name: 'VariaType'})
MERGE (ac)-[:ON_TARGET]->(tgt)

// Class remains viable (specific variant failed, class still open)
MERGE (ac:attack_class {key: 'class:path_traversal@variatype:80'})
SET ac.status = 'viable',
    ac.reason = 'os.path.join() is exploitable — relative paths failed but absolute paths not yet tested'
```

### Class Naming Convention

`class:<attack_type>@<component>` — component is the target service or endpoint.

Examples: `class:xml_injection@web:80`, `class:ssti@flask:80`, `class:path_traversal@portal:80/view.php`, `class:command_injection@cron:fontforge`

## Vulnerability — Enhanced Properties for Exploitation

When recording a vulnerability with a known exploitation method, include these properties:

```cypher
MERGE (v:vulnerability {key: 'CVE-2025-66034'})
SET v.name = 'fonttools varLib arbitrary file write',
    v.cve = 'CVE-2025-66034',
    v.exploitation_method = 'absolute path in <variable-font filename="/path"> — os.path.join ignores base when second arg is absolute',
    v.prerequisites = 'fonttools <= 4.48, upload .designspace + .ttf to /tools/variable-font-generator/process',
    v.payload_format = 'filename="/var/www/.../shell.php" with PHP in <labelname> CDATA',
    v.confidence = 'high',
    v.wrong_approaches = 'relative paths ../../ fail because os.path.join resolves within temp dir'
```

**confidence levels**: `high` (version match + method validated + payload format confirmed), `medium` (CVE found + general method known), `low` (possible CVE match, method unvalidated).

## Task Management — Orchestrator Work Units

`task` nodes track work assignments in the orchestrator's task tree. The lead agent creates them when spawning teammates; teammates update them on completion.

```cypher
// Create task
MERGE (t:task {key: 'task:cve_scout:fonttools-4.38.0'})
SET t.description = 'Research CVEs for fonttools 4.38.0',
    t.status = 'in_progress', t.depth = 1,
    t.role = 'cve_scout', t.assignee = 'teammate-1',
    t.target = 'VariaType', t.spawned_at = datetime()

// Link to parent
MERGE (parent:task {key: 'task:root:VariaType'})
MERGE (parent)-[:SPAWNED]->(t)

// On completion
MATCH (t:task {key: 'task:cve_scout:fonttools-4.38.0'})
SET t.status = 'completed',
    t.findings_summary = 'CVE-2025-66034: file write via absolute path in designspace. High confidence.',
    t.completed_at = datetime()
```

**Status values**: `pending`, `in_progress`, `completed`, `dead` (killed by class disproof or branch abandonment).

## Reactive Planning

When a finding is recorded, think about what it unlocks:

- **After credential**: create AUTHENTICATES_TO edges with status "untested" to every known auth-capable service (SSH, FTP, SMB, RDP, WinRM, DB, web login)
- **After open port**: identify the service, link creds if any exist, create strategy nodes for enumeration
- **After vulnerability**: create a strategy for exploitation
- **After shell**: new identity = new enumeration. Check sudo, SUID, cron, internal network, config files, databases
- **After attack_class disproof**: check if any in-progress tasks or strategies target techniques within this class — mark them dead
- **Before any attack action**: query for disproven attack classes AND prior attempts. If the class is dead, don't try any variant. If the technique failed and nothing changed, don't retry
