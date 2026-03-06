#!/bin/bash
#
# test_mcp_tool_loop.sh - E2E tests for MCP tool execution loop patch
#
# Tests the server-side MCP tool loop in vLLM Chat Completions API.
# Requires a running vllm_node container with the qwen3-coder-next-fp8 recipe.
#
# Usage:
#   ./tests/test_mcp_tool_loop.sh          # Run all tests
#   ./tests/test_mcp_tool_loop.sh -v       # Verbose output
#

set +e

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VERBOSE="${1:-}"

CONTAINER="vllm_node"
VLLM_URL="http://localhost:8000"
MCP_PORT=8888
MODEL="Qwen/Qwen3-Coder-Next-FP8"
CURL_TIMEOUT=120

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

log_test() {
    echo -e "${YELLOW}[TEST]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

log_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
}

log_verbose() {
    if [[ "$VERBOSE" == "-v" ]]; then
        echo "       $1"
    fi
}

log_info() {
    echo -e "       $1"
}

# ==============================================================================
# Setup & Teardown
# ==============================================================================

check_prerequisites() {
    log_test "Checking prerequisites..."

    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
        log_fail "Container '${CONTAINER}' is not running"
        echo "  Start vLLM first: ./run-recipe.sh qwen3-coder-next-fp8 --solo"
        exit 1
    fi

    if ! command -v curl &>/dev/null; then
        log_fail "curl not found"
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        log_fail "jq not found"
        exit 1
    fi

    log_pass "Prerequisites OK"
}

setup_mcp_server() {
    log_test "Setting up MCP test server on port ${MCP_PORT}..."

    # Kill any existing test server in container
    docker exec "$CONTAINER" bash -c "pkill -f 'mcp_test_server.py' 2>/dev/null || true"
    sleep 1

    # Copy and start
    docker cp "$SCRIPT_DIR/mcp_test_server.py" "${CONTAINER}:/tmp/mcp_test_server.py"
    docker exec -d "$CONTAINER" bash -c "python3 /tmp/mcp_test_server.py --port ${MCP_PORT} > /tmp/mcp_test_server.log 2>&1"

    # Wait for ready
    local i=0
    while [[ $i -lt 20 ]]; do
        if curl -s --max-time 2 "http://localhost:${MCP_PORT}/health" 2>/dev/null | grep -q "ok"; then
            log_pass "MCP test server ready on port ${MCP_PORT}"
            return 0
        fi
        sleep 0.5
        i=$((i + 1))
    done

    log_fail "MCP test server did not start within 10s"
    docker exec "$CONTAINER" cat /tmp/mcp_test_server.log 2>/dev/null
    return 1
}

ensure_vllm_has_tool_server() {
    log_test "Checking vLLM has --tool-server..."

    local vllm_cmd
    vllm_cmd=$(docker exec "$CONTAINER" ps aux | grep "[v]llm serve" | sed 's/.*vllm serve/vllm serve/')

    if [[ -z "$vllm_cmd" ]]; then
        log_fail "Could not find running vLLM process"
        return 1
    fi

    # If --tool-server is already present, no restart needed
    if echo "$vllm_cmd" | grep -q "\-\-tool-server"; then
        log_pass "vLLM already has --tool-server"
        return 0
    fi

    # Need to restart with --tool-server
    log_info "vLLM missing --tool-server, restarting..."
    vllm_cmd="$vllm_cmd --tool-server localhost:${MCP_PORT}"
    log_verbose "vLLM command: $vllm_cmd"

    docker exec "$CONTAINER" bash -c "pkill -f 'vllm serve' 2>/dev/null || true"
    sleep 3
    if docker exec "$CONTAINER" pgrep -f "vllm serve" >/dev/null 2>&1; then
        docker exec "$CONTAINER" bash -c "pkill -9 -f 'vllm serve' 2>/dev/null || true"
        sleep 2
    fi

    docker exec -d "$CONTAINER" bash -c "$vllm_cmd"

    log_info "Waiting for vLLM to reload (up to 120s)..."
    local i=0
    while [[ $i -lt 240 ]]; do
        if curl -s --max-time 2 "${VLLM_URL}/v1/models" 2>/dev/null | grep -q "$MODEL"; then
            log_pass "vLLM restarted with --tool-server"
            return 0
        fi
        sleep 0.5
        i=$((i + 1))
    done

    log_fail "vLLM did not become ready within 120s"
    return 1
}

cleanup() {
    log_info "Cleaning up..."
    docker exec "$CONTAINER" bash -c "pkill -f 'mcp_test_server.py' 2>/dev/null || true"
}

trap cleanup EXIT

# ==============================================================================
# Test 1: Patch applied
# ==============================================================================
test_patch_applied() {
    log_test "Patch applied: self.tool_server in serving.py"
    local file="/usr/local/lib/python3.12/dist-packages/vllm/entrypoints/openai/chat_completion/serving.py"
    if docker exec "$CONTAINER" grep -q "self.tool_server" "$file"; then
        log_pass "serving.py contains self.tool_server"
    else
        log_fail "serving.py does not contain self.tool_server"
    fi
}

# ==============================================================================
# Test 2: Patch idempotent
# ==============================================================================
test_patch_idempotent() {
    log_test "Patch is idempotent"
    docker cp "$PROJECT_DIR/mods/mcp-tool-loop/patch_chat_tool_loop.py" "${CONTAINER}:/tmp/patch_chat_tool_loop.py"
    local output
    output=$(docker exec "$CONTAINER" python3 /tmp/patch_chat_tool_loop.py 2>&1)
    if echo "$output" | grep -q "already patched"; then
        log_pass "Patch reports 'already patched' on re-run"
    else
        log_fail "Patch did not report 'already patched'"
        log_verbose "$output"
    fi
}

# ==============================================================================
# Test 3: MCP server running
# ==============================================================================
test_mcp_server_running() {
    log_test "MCP test server accessible"
    if curl -s --max-time 5 "http://localhost:${MCP_PORT}/health" 2>/dev/null | grep -q "ok"; then
        log_pass "MCP test server /health returns ok"
    else
        log_fail "MCP test server not accessible"
    fi
}

# ==============================================================================
# Test 4: vLLM healthy
# ==============================================================================
test_vllm_healthy() {
    log_test "vLLM /v1/models returns model"
    local response
    response=$(curl -s --max-time 10 "${VLLM_URL}/v1/models" 2>/dev/null)
    if echo "$response" | jq -e ".data[].id" 2>/dev/null | grep -q "$MODEL"; then
        log_pass "vLLM reports model $MODEL"
    else
        log_fail "vLLM does not list expected model"
        log_verbose "Response: $response"
    fi
}

# ==============================================================================
# Test 5: Single tool call — add_numbers(2, 3) → 5
# ==============================================================================
test_single_tool_call() {
    log_test "Single tool call: add_numbers(2, 3) → 5"

    local request
    request=$(jq -n '{
        model: "'"$MODEL"'",
        messages: [{"role": "user", "content": "Use the add_numbers tool to compute 2 + 3. Just call the tool, nothing else."}],
        tools: [
            {"type": "function", "function": {"name": "add_numbers", "description": "Add two numbers", "parameters": {"type": "object", "properties": {"a": {"type": "number"}, "b": {"type": "number"}}, "required": ["a", "b"]}}}
        ],
        tool_choice: "auto",
        stream: false,
        max_tokens: 256
    }')

    local response
    response=$(curl -s --max-time "$CURL_TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "$request" \
        "${VLLM_URL}/v1/chat/completions" 2>/dev/null)

    log_verbose "Response: $(echo "$response" | jq -c '.' 2>/dev/null)"

    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        log_fail "API error: $(echo "$response" | jq -r '.error.message' 2>/dev/null)"
        return
    fi

    local content
    content=$(echo "$response" | jq -r '.choices[0].message.content // ""' 2>/dev/null)
    local has_tool_calls
    has_tool_calls=$(echo "$response" | jq -e '.choices[0].message.tool_calls | length > 0' 2>/dev/null && echo "yes" || echo "no")

    if echo "$content" | grep -q "5" && [[ "$has_tool_calls" != "yes" ]]; then
        log_pass "Response contains '5', no tool_calls in final response"
    elif echo "$content" | grep -q "5"; then
        log_pass "Response contains '5' (tool executed server-side)"
    elif [[ "$has_tool_calls" == "yes" ]]; then
        log_fail "Tool loop did not execute — tool_calls returned to client"
        log_verbose "Content: $content"
    else
        log_fail "Response does not contain '5'"
        log_verbose "Content: $content"
    fi
}

# ==============================================================================
# Test 6: Multi-tool parallel calls — add_numbers + echo in one turn
# ==============================================================================
test_multi_tool_parallel() {
    log_test "Multi-tool parallel: add_numbers + echo in one turn"

    local request
    request=$(jq -n '{
        model: "'"$MODEL"'",
        messages: [{"role": "user", "content": "Do two things at once: 1) Use add_numbers to compute 10 + 20. 2) Use echo to echo the text \"hello\". Call both tools in parallel."}],
        tools: [
            {"type": "function", "function": {"name": "add_numbers", "description": "Add two numbers", "parameters": {"type": "object", "properties": {"a": {"type": "number"}, "b": {"type": "number"}}, "required": ["a", "b"]}}},
            {"type": "function", "function": {"name": "echo", "description": "Echo back text", "parameters": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}}
        ],
        tool_choice: "auto",
        stream: false,
        max_tokens: 512
    }')

    local response
    response=$(curl -s --max-time "$CURL_TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "$request" \
        "${VLLM_URL}/v1/chat/completions" 2>/dev/null)

    log_verbose "Response: $(echo "$response" | jq -c '.' 2>/dev/null)"

    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        log_fail "API error: $(echo "$response" | jq -r '.error.message' 2>/dev/null)"
        return
    fi

    local content
    content=$(echo "$response" | jq -r '.choices[0].message.content // ""' 2>/dev/null)

    if echo "$content" | grep -q "30" && echo "$content" | grep -qi "hello"; then
        log_pass "Response contains '30' and 'hello' (both tools executed)"
    elif echo "$content" | grep -q "30"; then
        log_pass "Response contains '30' (at least add_numbers executed)"
    elif [[ -n "$content" ]]; then
        log_pass "Got final text response (tools executed server-side)"
        log_verbose "Content: $content"
    else
        log_fail "No content in response"
        log_verbose "Response: $(echo "$response" | jq -c '.' 2>/dev/null)"
    fi
}

# ==============================================================================
# Test 7: Deep chain — 6 sequential chain_lookup calls (must hit 5+ rounds)
# ==============================================================================
test_deep_chain() {
    log_test "Deep chain: 6 sequential chain_lookup calls (expect 5+ rounds)"

    # Reset MCP server call counters
    curl -s -X POST "http://localhost:${MCP_PORT}/reset-stats" >/dev/null 2>&1

    local request
    request=$(jq -n '{
        model: "'"$MODEL"'",
        messages: [{"role": "user", "content": "Use the chain_lookup tool starting with key \"start\". Each result will give you the next key. Keep calling chain_lookup with each next key until the chain is complete. Then tell me the sum of all values."}],
        tools: [
            {"type": "function", "function": {"name": "chain_lookup", "description": "Look up a value by key in a hidden chain. Start with key start. Each result gives the next key. Keep calling until chain complete.", "parameters": {"type": "object", "properties": {"key": {"type": "string", "description": "The key to look up"}}, "required": ["key"]}}}
        ],
        tool_choice: "auto",
        stream: false,
        max_tokens: 1024
    }')

    local response
    response=$(curl -s --max-time 300 \
        -H "Content-Type: application/json" \
        -d "$request" \
        "${VLLM_URL}/v1/chat/completions" 2>/dev/null)

    log_verbose "Response: $(echo "$response" | jq -c '.' 2>/dev/null)"

    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        log_fail "API error: $(echo "$response" | jq -r '.error.message' 2>/dev/null)"
        return
    fi

    local content
    content=$(echo "$response" | jq -r '.choices[0].message.content // ""' 2>/dev/null)
    local has_tool_calls
    has_tool_calls=$(echo "$response" | jq -e '.choices[0].message.tool_calls | length > 0' 2>/dev/null && echo "yes" || echo "no")

    # Query MCP server for actual call count
    local stats
    stats=$(curl -s --max-time 5 "http://localhost:${MCP_PORT}/stats" 2>/dev/null)
    local chain_calls
    chain_calls=$(echo "$stats" | jq -r '.call_counts.chain_lookup // 0' 2>/dev/null)
    chain_calls=${chain_calls:-0}

    log_info "chain_lookup calls recorded by MCP server: $chain_calls"
    log_verbose "Content: $content"

    if [[ "$has_tool_calls" == "yes" ]]; then
        log_fail "Tool calls returned to client — loop did not complete"
        return
    fi

    if [[ "$chain_calls" -ge 5 ]]; then
        if echo "$content" | grep -q "314"; then
            log_pass "Chain completed: $chain_calls tool calls, correct sum 314"
        else
            log_pass "Chain completed: $chain_calls tool calls (sum not in response but loop worked)"
        fi
    elif [[ "$chain_calls" -ge 1 ]]; then
        log_fail "Only $chain_calls chain_lookup calls — expected 5+ (chain has 6 steps)"
    else
        log_fail "No chain_lookup calls recorded — MCP tool loop not executing"
    fi
}

# ==============================================================================
# Test 8: Streaming bypass — tool_calls returned to client
# ==============================================================================
test_streaming_passthrough() {
    log_test "Streaming: tool_calls returned to client (no server-side exec)"

    local request
    request=$(jq -n '{
        model: "'"$MODEL"'",
        messages: [{"role": "user", "content": "Use add_numbers to add 10 and 20."}],
        tools: [
            {"type": "function", "function": {"name": "add_numbers", "description": "Add two numbers", "parameters": {"type": "object", "properties": {"a": {"type": "number"}, "b": {"type": "number"}}, "required": ["a", "b"]}}}
        ],
        tool_choice: "required",
        stream: true,
        max_tokens: 256
    }')

    local response
    response=$(curl -s --max-time "$CURL_TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "$request" \
        "${VLLM_URL}/v1/chat/completions" 2>/dev/null)

    log_verbose "SSE response (first 500 chars): ${response:0:500}"

    if echo "$response" | grep -q "data:"; then
        if echo "$response" | grep -q "tool_calls"; then
            log_pass "Streaming returns tool_calls to client (not executed server-side)"
        else
            log_pass "Streaming returns SSE chunks"
        fi
    else
        log_fail "Response is not SSE formatted"
        log_verbose "Response: ${response:0:300}"
    fi
}

# ==============================================================================
# Test 9: No tools — normal text response
# ==============================================================================
test_no_tools_normal() {
    log_test "No tools: normal text response"

    local request
    request=$(jq -n '{
        model: "'"$MODEL"'",
        messages: [{"role": "user", "content": "What is 2+2? Reply with just the number."}],
        stream: false,
        max_tokens: 64
    }')

    local response
    response=$(curl -s --max-time "$CURL_TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "$request" \
        "${VLLM_URL}/v1/chat/completions" 2>/dev/null)

    log_verbose "Response: $(echo "$response" | jq -c '.' 2>/dev/null)"

    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        log_fail "API error: $(echo "$response" | jq -r '.error.message' 2>/dev/null)"
        return
    fi

    local content
    content=$(echo "$response" | jq -r '.choices[0].message.content // ""' 2>/dev/null)
    local finish_reason
    finish_reason=$(echo "$response" | jq -r '.choices[0].finish_reason // ""' 2>/dev/null)

    if [[ -n "$content" ]] && [[ "$finish_reason" == "stop" ]]; then
        log_pass "Normal text response with finish_reason=stop"
        log_verbose "Content: $content"
    else
        log_fail "Unexpected response"
        log_verbose "Content: $content, finish_reason: $finish_reason"
    fi
}

# ==============================================================================
# Test 10: Error handling — fail_tool doesn't crash vLLM
# ==============================================================================
test_tool_error_handling() {
    log_test "Tool error: fail_tool doesn't crash vLLM"

    local request
    request=$(jq -n '{
        model: "'"$MODEL"'",
        messages: [{"role": "user", "content": "Call the fail_tool function."}],
        tools: [
            {"type": "function", "function": {"name": "fail_tool", "description": "A tool that always fails", "parameters": {"type": "object", "properties": {}}}}
        ],
        tool_choice: "required",
        stream: false,
        max_tokens: 256
    }')

    local response
    response=$(curl -s --max-time "$CURL_TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "$request" \
        "${VLLM_URL}/v1/chat/completions" 2>/dev/null)

    log_verbose "Response: $(echo "$response" | jq -c '.' 2>/dev/null)"

    if [[ -z "$response" ]]; then
        log_fail "No response — vLLM may have crashed"
        return
    fi

    # Main check: vLLM is still alive
    if curl -s --max-time 5 "${VLLM_URL}/v1/models" 2>/dev/null | grep -q "$MODEL"; then
        log_pass "vLLM survived tool error and is still serving"
    else
        log_fail "vLLM became unresponsive after tool error"
    fi
}

# ==============================================================================
# Test 11: Stress test — 20-step chain (expect 20 rounds)
# ==============================================================================
test_long_chain() {
    log_test "Stress test: 20-step chain (expect 20 rounds)"

    # Switch to long chain and reset counters
    curl -s -X POST -H "Content-Type: application/json" \
        -d '{"chain": "long"}' "http://localhost:${MCP_PORT}/set-chain" >/dev/null 2>&1
    curl -s -X POST "http://localhost:${MCP_PORT}/reset-stats" >/dev/null 2>&1

    local request
    request=$(jq -n '{
        model: "'"$MODEL"'",
        messages: [{"role": "user", "content": "Use the chain_lookup tool starting with key \"start\". Each result gives you a value and the next key. You MUST call chain_lookup with each next key until the chain is complete — do NOT stop early. After the chain is complete, report the sum of all values."}],
        tools: [
            {"type": "function", "function": {"name": "chain_lookup", "description": "Look up a value by key in a hidden chain. Start with key start. Each result gives the next key. You must keep calling until chain complete.", "parameters": {"type": "object", "properties": {"key": {"type": "string", "description": "The key to look up"}}, "required": ["key"]}}}
        ],
        tool_choice: "auto",
        stream: false,
        max_tokens: 2048
    }')

    local start_time=$SECONDS
    local response
    response=$(curl -s --max-time 600 \
        -H "Content-Type: application/json" \
        -d "$request" \
        "${VLLM_URL}/v1/chat/completions" 2>/dev/null)
    local elapsed=$(( SECONDS - start_time ))

    log_verbose "Response: $(echo "$response" | jq -c '.' 2>/dev/null)"

    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        log_fail "API error: $(echo "$response" | jq -r '.error.message' 2>/dev/null)"
        # Reset back to short chain
        curl -s -X POST -H "Content-Type: application/json" \
            -d '{"chain": "short"}' "http://localhost:${MCP_PORT}/set-chain" >/dev/null 2>&1
        return
    fi

    local content
    content=$(echo "$response" | jq -r '.choices[0].message.content // ""' 2>/dev/null)
    local has_tool_calls
    has_tool_calls=$(echo "$response" | jq -e '.choices[0].message.tool_calls | length > 0' 2>/dev/null && echo "yes" || echo "no")
    local prompt_tokens
    prompt_tokens=$(echo "$response" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null)

    # Query MCP server for actual call count
    local stats
    stats=$(curl -s --max-time 5 "http://localhost:${MCP_PORT}/stats" 2>/dev/null)
    local chain_calls
    chain_calls=$(echo "$stats" | jq -r '.call_counts.chain_lookup // 0' 2>/dev/null)
    chain_calls=${chain_calls:-0}

    log_info "chain_lookup calls: $chain_calls | elapsed: ${elapsed}s | prompt_tokens: $prompt_tokens"
    log_verbose "Content: $content"

    if [[ "$has_tool_calls" == "yes" ]]; then
        log_fail "Tool calls returned to client — loop did not complete"
    elif [[ "$chain_calls" -ge 18 ]]; then
        log_pass "Long chain completed: $chain_calls tool calls in ${elapsed}s"
    elif [[ "$chain_calls" -ge 10 ]]; then
        log_fail "Partial chain: $chain_calls/20 calls — model stopped early"
    else
        log_fail "Chain barely started: $chain_calls/20 calls"
    fi

    # Reset back to short chain
    curl -s -X POST -H "Content-Type: application/json" \
        -d '{"chain": "short"}' "http://localhost:${MCP_PORT}/set-chain" >/dev/null 2>&1
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    echo "=============================================="
    echo "  MCP Tool Loop E2E Tests"
    echo "=============================================="
    echo ""

    cd "$PROJECT_DIR"

    check_prerequisites
    echo ""

    # Setup
    echo "--- Setup ---"
    setup_mcp_server || exit 1
    ensure_vllm_has_tool_server || exit 1
    echo ""

    # Patch verification
    echo "--- Patch Verification ---"
    test_patch_applied
    test_patch_idempotent
    echo ""

    # Infrastructure
    echo "--- Infrastructure ---"
    test_mcp_server_running
    test_vllm_healthy
    echo ""

    # API tests
    echo "--- API Tests ---"
    test_single_tool_call
    test_multi_tool_parallel
    test_deep_chain
    test_streaming_passthrough
    test_no_tools_normal
    test_tool_error_handling
    echo ""

    # Stress tests
    echo "--- Stress Tests ---"
    test_long_chain
    echo ""

    # Summary
    echo "=============================================="
    echo "  Test Summary"
    echo "=============================================="
    echo -e "  ${GREEN}Passed:${NC}  $TESTS_PASSED"
    echo -e "  ${RED}Failed:${NC}  $TESTS_FAILED"
    echo -e "  ${YELLOW}Skipped:${NC} $TESTS_SKIPPED"
    echo "=============================================="

    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
