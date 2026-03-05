#!/bin/bash
set -e

echo "--- Applying MCP tool execution loop patch to Chat Completions API..."
python3 patch_chat_tool_loop.py
echo "=== OK"
