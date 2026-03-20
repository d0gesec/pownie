---
name: offsec-debrief
description: Post-challenge debrief — generates writeup with structured failure analysis. Outputs to writeup/ directory and updates MEMORY.md with key lessons.
user-invocable: true
---

# Offsec Debrief & Writeup

Generate a structured writeup documenting the full challenge including both the successful attack path and every failure with structured analysis. Update MEMORY.md with generalized lessons.

---

## Phase 1: Generate the Writeup

### When to Use

- After completing a CTF challenge (HackTheBox, CTF competitions, etc.)
- When documenting penetration testing exercises
- For educational walkthroughs of security challenges

### Data Collection (First Step)

Before writing anything, reconstruct the attack history from conversation context, workspace files, and any saved notes.

### Writeup Structure

#### 1. Header

```markdown
# [Platform] - [Box Name] Writeup

**Difficulty:** [Easy/Medium/Hard]
**OS:** [Linux/Windows/Other]
**Category:** [Web/PWN/Wireless/Network/etc.]
**Target IP:** [IP Address]
```

#### 2. Overview

- Brief challenge description
- High-level attack path summary
- Key vulnerabilities exploited
- Network architecture (if applicable)

#### 3. Flags

```markdown
| Flag | Value |
|------|-------|
| User | `[hash]` |
| Root | `[hash]` |
```

#### 4. Attack Chain Summary

Visual representation of the successful path:
```markdown
1. Initial Access Method → Result
2. Exploitation Step → Outcome
3. Privilege Escalation → Final Goal
```

#### 5. Failure Track (REQUIRED — The Most Important Section)

**This section is where learning happens.** Every failed strategy must be documented with enough structure to extract patterns from.

Review all failed approaches from conversation context and workspace notes. For each failure, document:

```markdown
## Failure Track

### F1: [Short description of what was attempted]
- **Strategy:** What technique/tool/CVE was tried
- **Target component:** What service/port/endpoint was targeted
- **Trigger signal:** What observation led you to try this (version number, error message, open port, etc.)
- **Result:** What actually happened (error messages, no output, wrong response, etc.)
- **Root cause:** Why it failed (wrong CVE for this config, network isolation, wrong layer, etc.)
- **Time spent:** How long before pivoting
- **Stop signal missed?** Was there an early indicator this wouldn't work that was ignored?
- **Rabbit hole type:** [Wrong CVE | Wrong exploitation method | Wrong layer | String filter | Session limitation | Other]
- **Rule for next time:** One-sentence decision rule to avoid this in the future

### F2: [Next failure...]
```

**Rabbit hole types:**
- **Wrong CVE, Right Service** — CVE exists but vulnerable component/module isn't present
- **Correct Vuln, Wrong Method** — vulnerability is real but exploitation blocked by environment
- **Wrong Layer** — attacking app layer when it's infra, or vice versa
- **String Filter Bypass** — filter blocks direct approach, needs encoding/traversal
- **Session Limitation** — tool/technique doesn't work in current session type
- **Premature Complexity** — tried advanced technique when simple one existed
- **Unverified Assumption** — proceeded based on something assumed but not confirmed

**Why this structure matters:**
- "Stop signal missed" teaches us to recognize early exits faster
- "Rabbit hole type" helps classify failure patterns
- "Rule for next time" becomes a candidate for MEMORY.md lessons
- "Trigger signal" helps us understand what false signals look like

#### 6. Success Path (Phase-by-Phase Walkthrough)

For each phase of the successful attack:
- Clear phase title (e.g., "Phase 1: Initial Access — SNMP Enumeration")
- Step-by-step technical details
- All commands used (in code blocks with syntax highlighting)
- Command output (formatted)
- Explanation of what each step accomplishes
- **What signal triggered this approach** (version number, error output, config leak, etc.)

```bash
# Include comments explaining purpose
command --flags argument
```

```
Clearly formatted command output
```

#### 7. Key Takeaways

Numbered list of lessons learned:
```markdown
## Key Takeaways

1. **Vulnerability Type** — Brief explanation of the security issue
2. **Attack Technique** — How it was exploited
3. **Detection/Prevention** — How to defend against it
```

#### 8. Tools Used

```markdown
## Tools Used

- `tool-name` — Purpose/usage
- `another-tool` — Purpose/usage
```

#### 9. Additional Sections (as needed)

- **Vulnerabilities Exploited** — CVE details, CVSS scores, affected versions
- **Timeline** — Timestamps showing progression
- **References** — Links to CVE databases, advisories, documentation

### Output

Save to `writeup/[BoxName].md`.

### Writing Style

- Include exact commands used
- Show actual output
- Use GitHub-flavored Markdown with syntax highlighting
- Technical but accessible — explain acronyms on first use
- Focus on methodology and reasoning, not just outcomes

### Completeness Checklist

Before finalizing, ensure the writeup includes:
- [ ] Title with difficulty, OS, category, target IP
- [ ] Overview paragraph
- [ ] Both flags clearly displayed
- [ ] Attack chain summary
- [ ] **Failure track with full structure** (trigger, root cause, stop signal, rabbit hole type, rule)
- [ ] Complete phase-by-phase walkthrough of the successful path
- [ ] All commands with proper formatting
- [ ] Key takeaways section
- [ ] Tools used section

---

## Phase 2: Update MEMORY.md

**After the writeup is saved**, extract generalized lessons and update MEMORY.md.

### What to capture

**From failures:**
- New rabbit hole patterns worth remembering
- Decision rules that would have saved time
- False signal patterns (what looked promising but wasn't)

**From successes:**
- New attack patterns or technique combinations
- Recon methods that proved critical
- Tool usage insights

### How to generalize

- BAD: "On Browsed, Flask on :5000 was the path from git → larry"
- GOOD: "Localhost-only web services are frequently the bridge between a service account and a real user"
- BAD: "Soulmate had Erlang SSH on 127.0.0.1:2222"
- GOOD: "Non-standard SSH variants on localhost ports are common privesc paths"

### Rules

- Keep MEMORY.md under 200 lines — consolidate older entries or move details to topic-specific files if approaching the limit
- Machine-specific details ARE allowed in MEMORY.md (it's a personal journal, not a playbook)
- Don't add generic advice ("always be thorough") — only specific, actionable rules
- If unsure whether a pattern is generalizable, record it and wait for confirmation from a second challenge

---

## Workflow Summary

When this skill is invoked:

```
1. Pull attack history
   └─ Review conversation history and workspace files

2. Write the report
   ├─ Header, overview, flags, attack chain
   ├─ FAILURE TRACK (every failed strategy with full analysis)
   ├─ Success path (phase-by-phase)
   └─ Save to writeup/[BoxName].md

3. Update MEMORY.md
   ├─ Extract generalized lessons from failures and successes
   ├─ Add new decision rules and patterns
   └─ Keep under 200 lines
```

---

## Common Patterns by Category

### Web Exploitation
- Recon (port scan, directory enumeration)
- Application fingerprinting
- Vulnerability identification (SQLi, XSS, LFI, etc.)
- Exploitation and initial access
- Credential extraction
- Privilege escalation

### Wireless Security
- Interface setup and monitor mode
- Network discovery
- Traffic capture
- Credential interception
- Hash cracking
- Network access
- Lateral movement

### PWN/Binary
- Binary analysis
- Vulnerability discovery
- Exploit development
- Payload crafting
- Privilege escalation

### Network/Infrastructure
- Service enumeration
- Version fingerprinting
- Credential attacks
- Lateral movement
- Persistence

## Quality Standards

A complete writeup should:
- Be reproducible by following the steps
- Explain not just what was done, but why
- Include defensive considerations
- Serve as both documentation and learning resource
- Maintain professional technical writing standards
- Credit tools, researchers, and references appropriately
