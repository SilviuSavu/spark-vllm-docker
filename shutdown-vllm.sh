#!/bin/bash
set -e

# Graceful vLLM shutdown script
# Unloads the model via the API, then stops the container.

CONTAINER_NAME="${CONTAINER_NAME:-vllm_node}"
VLLM_HOST="${VLLM_HOST:-localhost}"
VLLM_PORT="${VLLM_PORT:-8000}"
BASE_URL="http://${VLLM_HOST}:${VLLM_PORT}"
TIMEOUT="${TIMEOUT:-120}"

echo "=== vLLM Graceful Shutdown ==="

# Check if the container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container '${CONTAINER_NAME}' is not running. Nothing to do."
    exit 0
fi

# Step 1: Check if the API is responsive
echo "Checking vLLM API at ${BASE_URL}..."
if curl -sf --max-time 5 "${BASE_URL}/health" >/dev/null 2>&1; then
    echo "API is up."

    # Step 2: List loaded models
    echo "Loaded models:"
    curl -sf --max-time 10 "${BASE_URL}/v1/models" | python3 -m json.tool 2>/dev/null || echo "  (could not list models)"

    # Step 3: Unload model(s) via /unload_lora_adapter or let shutdown handle it
    # vLLM doesn't have a dedicated "unload" endpoint for base models.
    # The graceful approach is to: drain requests, then stop.

    # Step 4: Wait for in-flight requests to drain
    echo "Waiting for in-flight requests to complete..."
    SECONDS_WAITED=0
    while [ "$SECONDS_WAITED" -lt "$TIMEOUT" ]; do
        # Check running requests via /metrics
        RUNNING=$(curl -sf --max-time 5 "${BASE_URL}/metrics" 2>/dev/null \
            | grep '^vllm:num_requests_running' \
            | awk '{print $2}' \
            | head -1)

        if [ -z "$RUNNING" ]; then
            # Metrics may use different format, try alternate pattern
            RUNNING=$(curl -sf --max-time 5 "${BASE_URL}/metrics" 2>/dev/null \
                | grep 'num_requests_running' \
                | grep -oP '[0-9]+\.?[0-9]*' \
                | tail -1)
        fi

        if [ -z "$RUNNING" ]; then
            echo "  Could not read metrics. Proceeding with shutdown."
            break
        fi

        # Convert float to int for comparison
        RUNNING_INT=$(printf '%.0f' "$RUNNING" 2>/dev/null || echo "0")

        if [ "$RUNNING_INT" -eq 0 ]; then
            echo "  No in-flight requests. Ready to stop."
            break
        fi

        echo "  ${RUNNING_INT} request(s) still running... (${SECONDS_WAITED}s/${TIMEOUT}s)"
        sleep 2
        SECONDS_WAITED=$((SECONDS_WAITED + 2))
    done

    if [ "$SECONDS_WAITED" -ge "$TIMEOUT" ]; then
        echo "  WARNING: Timed out waiting for requests to drain after ${TIMEOUT}s."
    fi
else
    echo "API is not responding (container may be starting up or already unhealthy). Proceeding to stop container."
fi

# Step 5: Stop the container gracefully (sends SIGTERM, waits for shutdown)
echo "Stopping container '${CONTAINER_NAME}' (SIGTERM, ${TIMEOUT}s grace period)..."
docker stop --timeout "$TIMEOUT" "$CONTAINER_NAME"

echo "Container stopped."

# Step 6: Verify
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "ERROR: Container is still running!"
    exit 1
fi

echo "=== vLLM shutdown complete. Safe to proceed with system update. ==="
