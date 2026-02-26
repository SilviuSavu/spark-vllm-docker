#!/bin/bash
set -e

# vLLM startup script for Qwen3-Coder-Next-FP8 (solo mode)
# Counterpart to shutdown-vllm.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECIPE="${RECIPE:-qwen3-coder-next-fp8}"
CONTAINER_NAME="${CONTAINER_NAME:-vllm_node}"
VLLM_PORT="${VLLM_PORT:-8000}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"

echo "=== vLLM Startup ==="

# Check if already running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container '${CONTAINER_NAME}' is already running."
    echo "Run ./shutdown-vllm.sh first if you want to restart."
    exit 1
fi

# Launch via run-recipe.sh (solo mode, with build+download)
echo "Starting recipe '${RECIPE}' in solo mode..."
"${SCRIPT_DIR}/run-recipe.sh" "$RECIPE" --solo --setup

# Wait for the API to become healthy
echo "Waiting for vLLM API to become healthy (up to ${HEALTH_TIMEOUT}s)..."
SECONDS_WAITED=0
while [ "$SECONDS_WAITED" -lt "$HEALTH_TIMEOUT" ]; do
    if curl -sf --max-time 5 "http://localhost:${VLLM_PORT}/health" >/dev/null 2>&1; then
        echo "API is healthy."
        break
    fi
    sleep 5
    SECONDS_WAITED=$((SECONDS_WAITED + 5))
    echo "  Not ready yet... (${SECONDS_WAITED}s/${HEALTH_TIMEOUT}s)"
done

if [ "$SECONDS_WAITED" -ge "$HEALTH_TIMEOUT" ]; then
    echo "WARNING: API did not become healthy within ${HEALTH_TIMEOUT}s."
    echo "Check logs: docker logs ${CONTAINER_NAME}"
    exit 1
fi

# Show loaded models
echo "Loaded models:"
curl -sf --max-time 10 "http://localhost:${VLLM_PORT}/v1/models" | python3 -m json.tool 2>/dev/null || echo "  (could not list models)"

echo "=== vLLM is up and serving on port ${VLLM_PORT} ==="
