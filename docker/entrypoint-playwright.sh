#!/bin/bash
set -e

export SCREEN_WIDTH=${SCREEN_WIDTH:-1920}
export SCREEN_HEIGHT=${SCREEN_HEIGHT:-1080}
export SCREEN_DEPTH=${SCREEN_DEPTH:-24}
export MCP_PORT=${MCP_PORT:-3000}
export MCP_HOST=${MCP_HOST:-0.0.0.0}
export MCP_BROWSER=${MCP_BROWSER:-chrome}
export DISPLAY=${DISPLAY:-:99}

VIEWPORT_WIDTH=$((SCREEN_WIDTH - 20))
VIEWPORT_HEIGHT=$((SCREEN_HEIGHT - 80))

echo "============================================="
echo "  Playwright MCP + noVNC Container"
echo "============================================="
echo "  Display:    ${DISPLAY} (${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH})"
echo "  noVNC:      http://localhost:6080"
echo "  MCP SSE:    http://localhost:${MCP_PORT}/sse"
echo "  Browser:    ${MCP_BROWSER}"
echo "  Viewport:   ${VIEWPORT_WIDTH}x${VIEWPORT_HEIGHT}"
echo "============================================="

/usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf &
SUPERVISOR_PID=$!

echo "Waiting for Xvfb to start..."
for i in $(seq 1 30); do
    if xdpyinfo -display :99 > /dev/null 2>&1; then
        echo "Xvfb is ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: Xvfb failed to start within 30 seconds."
        exit 1
    fi
    sleep 1
done

CHROMIUM_PATH=${CHROMIUM_PATH:-$(find /ms-playwright -name "chrome" -type f 2>/dev/null | grep chrome-linux | head -1)}
if [ -n "${CHROMIUM_PATH}" ]; then
    echo "  Chromium:   ${CHROMIUM_PATH}"
fi

MCP_ARGS=(
    "--port" "${MCP_PORT}"
    "--host" "${MCP_HOST}"
    "--browser" "${MCP_BROWSER}"
    "--no-sandbox"
    "--viewport-size" "${VIEWPORT_WIDTH}x${VIEWPORT_HEIGHT}"
)

if [ -n "${CHROMIUM_PATH}" ]; then
    MCP_ARGS+=("--executable-path" "${CHROMIUM_PATH}")
fi

if [ -n "${PROXY_SERVER:-}" ]; then
    echo "  Proxy:      ${PROXY_SERVER}"
    MCP_ARGS+=("--proxy-server" "${PROXY_SERVER}")
fi

if [ -n "${PROXY_BYPASS:-}" ]; then
    MCP_ARGS+=("--proxy-bypass" "${PROXY_BYPASS}")
fi

echo "Starting Playwright MCP server..."
echo "  Command: npx @playwright/mcp ${MCP_ARGS[*]}"

trap "kill $SUPERVISOR_PID 2>/dev/null; exit 0" SIGTERM SIGINT

exec npx @playwright/mcp "${MCP_ARGS[@]}"
