#!/usr/bin/env bash
# cleanup.sh — Tear down the pownie stack and optionally remove generated files/volumes
#
# Usage:
#   ./cleanup.sh              # stop containers, keep volumes and generated files
#   ./cleanup.sh --volumes    # also remove Docker volumes (neo4j data, workspace, etc.)
#   ./cleanup.sh --full       # remove everything: containers, volumes, generated files
#   ./cleanup.sh --generated  # only remove generated files (no Docker changes)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
MCP_JSON="$SCRIPT_DIR/.mcp.json"

if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    SETTINGS_LOCAL="$CLAUDE_PROJECT_DIR/.claude/settings.local.json"
else
    SETTINGS_LOCAL="$SCRIPT_DIR/.claude/settings.local.json"
fi

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

# ── Parse flags ──────────────────────────────────────────────────────────

REMOVE_VOLUMES=false
REMOVE_GENERATED=false
SKIP_DOCKER=false

for arg in "$@"; do
    case "$arg" in
        --volumes)
            REMOVE_VOLUMES=true
            ;;
        --full)
            REMOVE_VOLUMES=true
            REMOVE_GENERATED=true
            ;;
        --generated)
            REMOVE_GENERATED=true
            SKIP_DOCKER=true
            ;;
        --help|-h)
            echo "Usage: ./cleanup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  (none)        Stop containers, keep volumes and generated files"
            echo "  --volumes     Also remove Docker volumes (neo4j data, workspace)"
            echo "  --full        Remove everything: containers, volumes, generated files"
            echo "  --generated   Only remove generated files (no Docker changes)"
            echo ""
            exit 0
            ;;
        *)
            err "Unknown option: $arg"
            echo "Run ./cleanup.sh --help for usage"
            exit 1
            ;;
    esac
done

# ── Stop containers ──────────────────────────────────────────────────────

if ! $SKIP_DOCKER; then
    if [ -f "$COMPOSE_FILE" ]; then
        # Show what's running
        local running
        running=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}}\t{{.Status}}' 2>/dev/null || true)
        if [ -n "$running" ]; then
            info "Running containers:"
            echo "$running" | while IFS=$'\t' read -r name status; do
                printf "  ${YELLOW}%-30s${NC} %s\n" "$name" "$status"
            done
            echo ""
        fi

        if $REMOVE_VOLUMES; then
            read -rp "$(printf "${CYAN}?${NC} Stop containers and DELETE all volumes (neo4j data, workspace)? [y/N] ")" ans
            if [[ ! "$ans" =~ ^[Yy] ]]; then
                ok "Aborted"
                exit 0
            fi
            docker compose -f "$COMPOSE_FILE" down --remove-orphans --volumes
            ok "Containers stopped and volumes removed"
        else
            read -rp "$(printf "${CYAN}?${NC} Stop and remove these containers? [y/N] ")" ans
            if [[ ! "$ans" =~ ^[Yy] ]]; then
                ok "Aborted"
                exit 0
            fi
            docker compose -f "$COMPOSE_FILE" down --remove-orphans
            ok "Containers stopped"
        fi
    else
        warn "No docker-compose.yml found — skipping container teardown"

        # Try to find and stop orphaned containers by common prefixes
        local prefix="${POWNIE_PREFIX:-pownie}"
        local orphans
        orphans=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${prefix}-(kali|neo4j|playwright|tempo|grafana)$" || true)
        if [ -n "$orphans" ]; then
            warn "Found containers matching prefix '${prefix}' without a compose file:"
            echo "$orphans" | while read -r name; do
                printf "  ${YELLOW}%s${NC}\n" "$name"
            done
            echo ""
            read -rp "$(printf "${CYAN}?${NC} Stop and remove these containers? [y/N] ")" ans
            if [[ "$ans" =~ ^[Yy] ]]; then
                echo "$orphans" | xargs docker rm -f 2>/dev/null
                ok "Orphaned containers removed"
            fi
        fi
    fi
fi

# ── Remove generated files ───────────────────────────────────────────────

if $REMOVE_GENERATED; then
    info "Removing generated files..."

    local hooks_file="$SCRIPT_DIR/hooks/hooks.json"
    for f in "$COMPOSE_FILE" "$MCP_JSON" "$hooks_file"; do
        if [ -f "$f" ]; then
            rm "$f"
            ok "Removed $(basename "$f")"
        fi
    done

    if [ -f "$SETTINGS_LOCAL" ]; then
        warn "Found $SETTINGS_LOCAL"
        read -rp "$(printf "${CYAN}?${NC} Remove settings.local.json? This includes your permissions. [y/N] ")" ans
        if [[ "$ans" =~ ^[Yy] ]]; then
            rm "$SETTINGS_LOCAL"
            ok "Removed settings.local.json"
        else
            ok "Kept settings.local.json"
        fi
    fi
else
    if ! $SKIP_DOCKER; then
        echo ""
        echo "Generated files kept:"
        [ -f "$COMPOSE_FILE" ] && echo "  docker-compose.yml"
        [ -f "$MCP_JSON" ] && echo "  .mcp.json"
        [ -f "$SETTINGS_LOCAL" ] && echo "  .claude/settings.local.json"
        echo ""
        echo "To also remove these: ./cleanup.sh --full"
    fi
fi

echo ""
ok "Cleanup complete."
