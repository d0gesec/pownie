#!/usr/bin/env bash
# setup.sh — Interactive setup for the pownie offensive security plugin
#
# Generates docker-compose.yml, .mcp.json, and .claude/settings.local.json
# based on selected profiles, then builds and starts the stack.
#
# Profiles:
#   core        kali + neo4j (always included)
#   browser     playwright-based browser MCP server + noVNC
#   telemetry   tempo + grafana (OTLP tracing for hook/skill development)
#
# Usage:
#   ./setup.sh              # interactive
#   ./setup.sh --all        # everything
#   ./setup.sh --core-only  # minimal
#   ./setup.sh --down       # stop and remove containers
#   ./setup.sh --bare       # bare Kali/Linux mode (no mcp-kali container)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_DIR="$SCRIPT_DIR/docker"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
MCP_JSON="$SCRIPT_DIR/.mcp.json"

# Detect if running as a plugin or standalone
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    SETTINGS_DIR="$CLAUDE_PROJECT_DIR/.claude"
else
    SETTINGS_DIR="$SCRIPT_DIR/.claude"
fi
SETTINGS_LOCAL="$SETTINGS_DIR/settings.local.json"

# ── Defaults ─────────────────────────────────────────────────────────────

PREFIX="${POWNIE_PREFIX:-pownie}"
ENABLE_BROWSER=false
ENABLE_TELEMETRY=false
EXEC_MODE="mcp"  # "mcp" = mcp-kali container, "bare" = bare Kali/Linux

# Port defaults
PORT_MCP="${PORT_MCP:-3888}"
PORT_VNC="${PORT_VNC:-6080}"
PORT_NEO4J_HTTP="${PORT_NEO4J_HTTP:-7474}"
PORT_NEO4J_BOLT="${PORT_NEO4J_BOLT:-7687}"
PORT_OTLP_GRPC="${PORT_OTLP_GRPC:-4317}"
PORT_OTLP_HTTP="${PORT_OTLP_HTTP:-4318}"
PORT_TEMPO="${PORT_TEMPO:-3200}"
PORT_GRAFANA="${PORT_GRAFANA:-3000}"

# ── Colors ───────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${CYAN}▶${NC} %s\n" "$1"; }
ok()    { printf "${GREEN}✓${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}!${NC} %s\n" "$1"; }
err()   { printf "${RED}✗${NC} %s\n" "$1"; }

# ── Prereq checks ───────────────────────────────────────────────────────

check_prereqs() {
    local missing=0

    if ! command -v docker &>/dev/null; then
        err "docker not found — install Docker Desktop or Docker Engine"
        missing=1
    fi

    if ! command -v claude &>/dev/null; then
        warn "claude CLI not found — install from https://docs.anthropic.com/en/docs/claude-code"
        warn "setup will continue but you won't be able to run sessions"
    fi

    if ! docker info &>/dev/null 2>&1; then
        err "Docker daemon not running — start Docker Desktop or dockerd"
        missing=1
    fi

    if [ $missing -eq 1 ]; then
        exit 1
    fi
}

# ── Name conflict detection ──────────────────────────────────────────────

check_name_conflict() {
    # Collect running/stopped containers that match the prefix
    local conflicts
    conflicts=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${PREFIX}-(kali|neo4j|playwright|tempo|grafana)$" || true)

    if [ -z "$conflicts" ]; then
        return
    fi

    # Check if these containers belong to OUR compose project
    # If a docker-compose.yml already exists and matches, this is a re-run — no conflict
    if [ -f "$COMPOSE_FILE" ]; then
        local existing_project
        existing_project=$(grep -oP '^name:\s*\K\S+' "$COMPOSE_FILE" 2>/dev/null || true)
        if [ "$existing_project" = "$PREFIX" ]; then
            # Same project re-run — compose will handle it
            return
        fi
    fi

    echo ""
    warn "Existing containers found using prefix '${PREFIX}':"
    echo ""
    echo "$conflicts" | while read -r name; do
        local state
        state=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "unknown")
        printf "  ${YELLOW}%-30s${NC} %s\n" "$name" "($state)"
    done
    echo ""
    warn "These containers are NOT managed by this pownie setup."
    echo ""

    read -rp "$(printf "${CYAN}?${NC} Choose a different prefix (or press Enter to use '${PREFIX}' anyway): ")" new_prefix

    if [ -n "$new_prefix" ]; then
        PREFIX="$new_prefix"
        ok "Using prefix: ${PREFIX}"
    else
        warn "Continuing with '${PREFIX}' — docker compose will replace conflicting containers"
    fi
    echo ""
}

# ── Teardown ─────────────────────────────────────────────────────────────

teardown() {
    if [ -f "$COMPOSE_FILE" ]; then
        local running
        running=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}}\t{{.Status}}' 2>/dev/null || true)
        if [ -n "$running" ]; then
            info "Running containers:"
            echo "$running" | while IFS=$'\t' read -r name status; do
                printf "  ${YELLOW}%-30s${NC} %s\n" "$name" "$status"
            done
            echo ""
        fi
        read -rp "$(printf "${CYAN}?${NC} Stop and remove these containers? [y/N] ")" ans
        if [[ ! "$ans" =~ ^[Yy] ]]; then
            ok "Aborted"
            exit 0
        fi
        docker compose -f "$COMPOSE_FILE" down --remove-orphans
        ok "Stack stopped"
    else
        warn "No docker-compose.yml found — nothing to stop"
    fi
    exit 0
}

# ── Profile selection ────────────────────────────────────────────────────

select_profiles() {
    case "${1:-}" in
        --all)
            ENABLE_BROWSER=true
            ENABLE_TELEMETRY=true
            return
            ;;
        --core-only)
            return
            ;;
        --bare)
            EXEC_MODE="bare"
            return
            ;;
        --down)
            teardown
            ;;
    esac

    echo ""
    printf "${BOLD}pownie setup${NC}\n"
    echo ""

    echo "Execution mode:"
    echo "  1) mcp-kali  — Docker containers with mcp-kali server (recommended)"
    echo "  2) bare      — Running directly on Kali/Linux (hooks fire on Bash tool)"
    echo ""
    read -rp "$(printf "${CYAN}?${NC} Choose mode [1/2]: ")" mode_ans
    [[ "$mode_ans" = "2" ]] && EXEC_MODE="bare"

    echo ""
    if [ "$EXEC_MODE" = "mcp" ]; then
        echo "Core stack (kali + neo4j) is always installed."
        echo ""

        read -rp "$(printf "${CYAN}?${NC} Enable browser MCP server (playwright + noVNC)? [y/N] ")" ans
        [[ "$ans" =~ ^[Yy] ]] && ENABLE_BROWSER=true
    else
        echo "Bare mode — no Docker containers for kali. Neo4j is still required."
        echo ""
    fi

    echo ""
    read -rp "$(printf "${CYAN}?${NC} Enable trace viewer (tempo + grafana)? Useful for debugging skills/hooks. [y/N] ")" ans
    [[ "$ans" =~ ^[Yy] ]] && ENABLE_TELEMETRY=true

    echo ""
}

# ── Generate hooks/hooks.json ────────────────────────────────────────────

generate_hooks() {
    info "Generating hooks/hooks.json"

    local hooks_file="$SCRIPT_DIR/hooks/hooks.json"
    mkdir -p "$SCRIPT_DIR/hooks"

    local matcher
    if [ "$EXEC_MODE" = "bare" ]; then
        matcher="Bash"
    else
        matcher="mcp__kali__execute_command|mcp__kali__session_send|mcp__kali__session_create"
    fi

    cat > "$hooks_file" << HOOKSEOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "${matcher}",
        "hooks": [
          {
            "type": "command",
            "command": "\${CLAUDE_PLUGIN_ROOT}/skills/offsec-intel-graph/preToolUse/pre-exec.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "${matcher}",
        "hooks": [
          {
            "type": "command",
            "command": "\${CLAUDE_PLUGIN_ROOT}/skills/offsec-intel-graph/postToolUse/post-exec.sh"
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "\${CLAUDE_PLUGIN_ROOT}/skills/strategy-compact/pre-compact-save.sh"
          }
        ]
      }
    ]
  }
}
HOOKSEOF

    ok "hooks.json generated (mode: ${EXEC_MODE})"
}

# ── Generate docker-compose.yml ──────────────────────────────────────────

generate_compose() {
    info "Generating docker-compose.yml"

    cat > "$COMPOSE_FILE" << COMPOSEEOF
# Generated by pownie setup.sh — do not edit manually
# Re-run ./setup.sh to regenerate

name: ${PREFIX}

services:
COMPOSEEOF

    # Kali service (mcp mode only)
    if [ "$EXEC_MODE" = "mcp" ]; then
        cat >> "$COMPOSE_FILE" << KALIEOF
  kali:
    build:
      context: .
      dockerfile: docker/Dockerfile.kali
    container_name: ${PREFIX}-kali
    hostname: ${PREFIX}-kali
    privileged: true
    ports:
      - "${PORT_MCP}:${PORT_MCP}"
      - "${PORT_VNC}:6080"
    networks:
      - pownie-net
    working_dir: /workspace
    command: ["sh", "-c", "mkdir -p /var/log/mcp && touch /var/log/mcp/server.log && tail -f /var/log/mcp/server.log"]
    volumes:
      - workspace:/workspace

KALIEOF
    fi

    cat >> "$COMPOSE_FILE" << NEO4JEOF
  neo4j:
    build:
      context: docker
      dockerfile: Dockerfile.neo4j
    container_name: ${PREFIX}-neo4j
    hostname: ${PREFIX}-neo4j
    ports:
      - "${PORT_NEO4J_HTTP}:7474"
      - "${PORT_NEO4J_BOLT}:7687"
    environment:
      - NEO4J_AUTH=neo4j/pownie-graph
      - NEO4J_PLUGINS=["apoc"]
    volumes:
      - neo4j_data:/data
    networks:
      - pownie-net
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "cypher-shell", "-u", "neo4j", "-p", "pownie-graph", "RETURN 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
NEO4JEOF

    # Playwright service (mcp mode + browser enabled)
    if [ "$EXEC_MODE" = "mcp" ] && $ENABLE_BROWSER; then
        cat >> "$COMPOSE_FILE" << PLAYWRIGHTEOF

  playwright:
    build:
      context: docker
      dockerfile: Dockerfile.playwright
    container_name: ${PREFIX}-playwright
    network_mode: "container:${PREFIX}-kali"
    environment:
      - SCREEN_WIDTH=1920
      - SCREEN_HEIGHT=1080
      - SCREEN_DEPTH=24
      - MCP_PORT=${PORT_MCP}
      - MCP_BROWSER=chrome
    shm_size: "2gb"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:6080"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
PLAYWRIGHTEOF
    fi

    # Telemetry services (optional)
    if $ENABLE_TELEMETRY; then
        cat >> "$COMPOSE_FILE" << TELEMETRYEOF

  tempo:
    image: grafana/tempo:2.7.2
    container_name: ${PREFIX}-tempo
    hostname: ${PREFIX}-tempo
    command: ["-config.file=/etc/tempo.yaml"]
    volumes:
      - ./docker/tempo.yaml:/etc/tempo.yaml
      - tempo_data:/var/tempo
    ports:
      - "${PORT_OTLP_GRPC}:4317"
      - "${PORT_OTLP_HTTP}:4318"
      - "${PORT_TEMPO}:3200"
    networks:
      - pownie-net
    restart: unless-stopped

  grafana:
    image: grafana/grafana:11.5.2
    container_name: ${PREFIX}-grafana
    hostname: ${PREFIX}-grafana
    ports:
      - "${PORT_GRAFANA}:3000"
    environment:
      - GF_AUTH_ANONYMOUS_ENABLED=true
      - GF_AUTH_ANONYMOUS_ORG_ROLE=Admin
      - GF_LIVE_ALLOWED_ORIGINS=*
    volumes:
      - grafana_data:/var/lib/grafana
      - ./docker/grafana/provisioning:/etc/grafana/provisioning
    networks:
      - pownie-net
    restart: unless-stopped
TELEMETRYEOF
    fi

    # Networks and volumes
    cat >> "$COMPOSE_FILE" << FOOTEREOF

networks:
  pownie-net:
    driver: bridge

volumes:
  neo4j_data: {}
FOOTEREOF

    if [ "$EXEC_MODE" = "mcp" ]; then
        cat >> "$COMPOSE_FILE" << WVOLEOF
  workspace: {}
WVOLEOF
    fi

    if $ENABLE_TELEMETRY; then
        cat >> "$COMPOSE_FILE" << TVOLEOF
  tempo_data: {}
  grafana_data: {}
TVOLEOF
    fi

    ok "docker-compose.yml generated"
}

# ── Generate .mcp.json ──────────────────────────────────────────────────

generate_mcp_json() {
    info "Generating .mcp.json"

    local servers=""

    if [ "$EXEC_MODE" = "mcp" ]; then
        servers=$(cat << MCPKALI
    "kali": {
      "type": "stdio",
      "command": "docker",
      "args": ["exec", "-i", "${PREFIX}-kali", "python3", "/opt/mcp_server.py"]
    },
MCPKALI
)
    fi

    servers="${servers}
    \"neo4j\": {
      \"type\": \"stdio\",
      \"command\": \"docker\",
      \"args\": [\"exec\", \"-i\", \"-e\", \"NEO4J_URI=bolt://localhost:7687\", \"-e\", \"NEO4J_USERNAME=neo4j\", \"-e\", \"NEO4J_PASSWORD=pownie-graph\", \"${PREFIX}-neo4j\", \"neo4j-mcp\"]
    }"

    if [ "$EXEC_MODE" = "mcp" ] && $ENABLE_BROWSER; then
        servers="${servers},
    \"playwright\": {
      \"type\": \"http\",
      \"url\": \"http://localhost:${PORT_MCP}/mcp\"
    }"
    fi

    cat > "$MCP_JSON" << MCPEOF
{
  "mcpServers": {
${servers}
  }
}
MCPEOF

    ok ".mcp.json generated"
}

# ── Generate .claude/settings.local.json ─────────────────────────────────

generate_settings_local() {
    if [ -f "$SETTINGS_LOCAL" ]; then
        ok "settings.local.json already exists (not overwriting)"
        return
    fi

    info "Generating .claude/settings.local.json"
    mkdir -p "$SETTINGS_DIR"

    local mcp_permissions=""

    if [ "$EXEC_MODE" = "mcp" ]; then
        mcp_permissions='"mcp__kali__execute_command",
      "mcp__kali__session_send",
      "mcp__kali__session_close",
      "mcp__kali__session_create",
      "mcp__kali__session_list",
      "mcp__kali__system_install_package",
      "mcp__kali__system_find_tool",
      "mcp__kali__task_get_output",
      "mcp__kali__task_stop",
      "mcp__kali__task_list",
      "mcp__kali__list_files",
      "mcp__kali__proxy_start",
      "mcp__kali__proxy_get_flows",
      "mcp__kali__proxy_export",
      "mcp__kali__proxy_replay",
      "mcp__neo4j__read-cypher",
      "mcp__neo4j__write-cypher",
      "mcp__neo4j__get-schema",
      "WebFetch(domain:*)",
      "WebSearch"'
    else
        mcp_permissions='"mcp__neo4j__read-cypher",
      "mcp__neo4j__write-cypher",
      "mcp__neo4j__get-schema",
      "Bash(nmap:*)",
      "Bash(gobuster:*)",
      "Bash(nikto:*)",
      "Bash(sqlmap:*)",
      "Bash(hydra:*)",
      "Bash(john:*)",
      "Bash(hashcat:*)",
      "WebFetch(domain:*)",
      "WebSearch"'
    fi

    if [ "$EXEC_MODE" = "mcp" ] && $ENABLE_BROWSER; then
        mcp_permissions="${mcp_permissions},
      \"mcp__playwright__*\""
    fi

    cat > "$SETTINGS_LOCAL" << SETTINGSEOF
{
  "env": {
    "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "70",
    "POWNIE_PREFIX": "${PREFIX}"
  },
  "permissions": {
    "allow": [
      ${mcp_permissions}
    ]
  },
  "enableAllProjectMcpServers": true
}
SETTINGSEOF

    ok "settings.local.json created"
}

# ── Docker build + start ─────────────────────────────────────────────────

start_stack() {
    info "Building and starting containers..."

    docker compose -f "$COMPOSE_FILE" up --build -d

    echo ""
    if [ "$EXEC_MODE" = "mcp" ]; then
        ok "Core stack running (kali + neo4j)"
        $ENABLE_BROWSER && ok "Browser MCP server running (playwright + noVNC)"
    else
        ok "Neo4j container running (bare mode — no kali container)"
    fi
    $ENABLE_TELEMETRY && ok "Telemetry stack running (tempo + grafana)"
}

# ── Wait for health ──────────────────────────────────────────────────────

wait_for_health() {
    info "Waiting for Neo4j to be ready..."
    local retries=30
    while [ $retries -gt 0 ]; do
        if docker exec "${PREFIX}-neo4j" cypher-shell -u neo4j -p pownie-graph "RETURN 1" &>/dev/null; then
            ok "Neo4j is ready"
            break
        fi
        retries=$((retries - 1))
        sleep 2
    done

    if [ $retries -eq 0 ]; then
        warn "Neo4j didn't become ready in time — it may still be starting"
    fi

    if [ "$EXEC_MODE" = "mcp" ]; then
        if docker ps --format '{{.Names}}' | grep -q "${PREFIX}-kali"; then
            ok "Kali container is running"
        else
            warn "Kali container may not be running — check: docker logs ${PREFIX}-kali"
        fi

        if $ENABLE_BROWSER; then
            if docker ps --format '{{.Names}}' | grep -q "${PREFIX}-playwright"; then
                ok "Playwright container is running"
            else
                warn "Playwright container may not be running — check: docker logs ${PREFIX}-playwright"
            fi
        fi
    fi
}

# ── Summary ──────────────────────────────────────────────────────────────

print_summary() {
    echo ""
    printf "${BOLD}Setup complete.${NC}\n"
    echo ""
    echo "Mode: ${EXEC_MODE}"
    echo ""
    echo "Services:"
    if [ "$EXEC_MODE" = "mcp" ]; then
        echo "  kali       docker exec -it ${PREFIX}-kali bash"
    fi
    echo "  neo4j      http://localhost:${PORT_NEO4J_HTTP}  (neo4j/pownie-graph)"
    if [ "$EXEC_MODE" = "mcp" ] && $ENABLE_BROWSER; then
        echo "  playwright http://localhost:${PORT_MCP}/mcp"
        echo "  vnc        http://localhost:${PORT_VNC}"
    fi
    if $ENABLE_TELEMETRY; then
        echo "  grafana    http://localhost:${PORT_GRAFANA}"
        echo "  tempo      http://localhost:${PORT_TEMPO}"
    fi
    echo ""
    echo "Generated files:"
    echo "  docker-compose.yml           — container orchestration"
    echo "  hooks/hooks.json             — hook matchers (${EXEC_MODE} mode)"
    echo "  .mcp.json                    — MCP server configs for Claude Code"
    echo "  .claude/settings.local.json  — permissions and env vars"
    echo ""

    if [ -d "$SCRIPT_DIR/.claude-plugin" ]; then
        echo "Plugin usage:"
        echo "  claude --plugin-dir ${SCRIPT_DIR}"
        echo ""
    else
        echo "Start a session:"
        echo "  claude"
        echo ""
    fi

    if $ENABLE_TELEMETRY; then
        echo "Trace viewer:"
        echo "  Grafana -> Explore -> Tempo -> service.name = pownie-pre-hook"
        echo ""
    fi

    echo "Management:"
    echo "  ./cleanup.sh              stop containers, keep data"
    echo "  ./cleanup.sh --volumes    also wipe neo4j + workspace volumes"
    echo "  ./cleanup.sh --full       remove everything (containers, volumes, generated files)"
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────

main() {
    check_prereqs
    select_profiles "${1:-}" "${2:-}"
    check_name_conflict
    generate_hooks
    generate_compose
    generate_mcp_json
    generate_settings_local
    start_stack
    wait_for_health
    print_summary
}

main "$@"
