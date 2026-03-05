#!/bin/bash
set -e

echo "--- Applying MCP tool execution loop patch to Chat Completions API..."
python3 patch_chat_tool_loop.py
echo "--- Installing MCP server dependencies..."
pip install mcp starlette uvicorn --quiet 2>&1 | tail -1
echo "--- Copying MCP server to /workspace..."
cp mcp_server.py /workspace/mcp_server.py
echo "=== OK"
