#!/usr/bin/env python3
"""
Minimal MCP SSE server with test tools for E2E testing of the MCP tool loop patch.

Runs on 0.0.0.0:8888 using SSE transport. vLLM connects via --tool-server localhost:8888.

Tools:
  - get_current_time(timezone): Returns current UTC time
  - add_numbers(a, b): Adds two numbers (deterministic)
  - echo(text): Echoes input back
  - fail_tool(): Always raises an error
"""

import asyncio
import datetime

from mcp.server import Server
from mcp.server.sse import SseServerTransport
from mcp.types import TextContent, Tool

from starlette.applications import Starlette
from starlette.routing import Mount, Route
from starlette.responses import JSONResponse

import uvicorn


server = Server("mcp-test-server")

# Call counter for test verification
call_counts: dict[str, int] = {}


TOOLS = [
    Tool(
        name="get_current_time",
        description="Get the current time in a given timezone (returns UTC)",
        inputSchema={
            "type": "object",
            "properties": {
                "timezone": {
                    "type": "string",
                    "description": "Timezone name (ignored, always returns UTC)",
                },
            },
            "required": ["timezone"],
        },
    ),
    Tool(
        name="add_numbers",
        description="Add two numbers together and return the result",
        inputSchema={
            "type": "object",
            "properties": {
                "a": {"type": "number", "description": "First number"},
                "b": {"type": "number", "description": "Second number"},
            },
            "required": ["a", "b"],
        },
    ),
    Tool(
        name="echo",
        description="Echo back the input text exactly as provided",
        inputSchema={
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "Text to echo back"},
            },
            "required": ["text"],
        },
    ),
    Tool(
        name="fail_tool",
        description="A tool that always fails with an error (for testing error handling)",
        inputSchema={
            "type": "object",
            "properties": {},
        },
    ),
    Tool(
        name="chain_lookup",
        description="Look up a value by key in a hidden chain. Start with key 'start'. Each result gives you the next key to look up. You MUST call this tool with each next_key until you reach the end.",
        inputSchema={
            "type": "object",
            "properties": {
                "key": {
                    "type": "string",
                    "description": "The key to look up. Start with 'start'.",
                },
            },
            "required": ["key"],
        },
    ),
]

# Chain data — forces sequential tool calls (each step reveals the next key)
# Short chain (6 steps) for basic test
CHAIN_SHORT = {
    "start": {"value": "42", "next_key": "alpha"},
    "alpha": {"value": "17", "next_key": "beta"},
    "beta":  {"value": "83", "next_key": "gamma"},
    "gamma": {"value": "56", "next_key": "delta"},
    "delta": {"value": "91", "next_key": "epsilon"},
    "epsilon": {"value": "25", "next_key": "DONE"},
}

# Long chain (20 steps) for stress testing — sum = 1052
_LONG_KEYS = [
    "start", "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta",
    "theta", "iota", "kappa", "lambda", "mu", "nu", "xi", "omicron",
    "pi", "rho", "sigma", "tau",
]
_LONG_VALUES = [42, 17, 83, 56, 91, 25, 64, 38, 72, 19, 55, 47, 33, 88, 11, 76, 29, 63, 44, 99]
CHAIN_LONG = {}
for i, key in enumerate(_LONG_KEYS):
    next_key = _LONG_KEYS[i + 1] if i + 1 < len(_LONG_KEYS) else "DONE"
    CHAIN_LONG[key] = {"value": str(_LONG_VALUES[i]), "next_key": next_key}

# Active chain (toggled by /set-chain endpoint)
ACTIVE_CHAIN = {"name": "short", "data": CHAIN_SHORT, "sum": 314}


@server.list_tools()
async def list_tools():
    return TOOLS


@server.call_tool()
async def call_tool(name: str, arguments: dict):
    call_counts[name] = call_counts.get(name, 0) + 1
    if name == "get_current_time":
        now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
        return [TextContent(type="text", text=now)]

    elif name == "add_numbers":
        a = arguments.get("a", 0)
        b = arguments.get("b", 0)
        result = a + b
        # Return integer if possible for clean output
        if isinstance(result, float) and result == int(result):
            result = int(result)
        return [TextContent(type="text", text=str(result))]

    elif name == "echo":
        text = arguments.get("text", "")
        return [TextContent(type="text", text=text)]

    elif name == "chain_lookup":
        key = arguments.get("key", "")
        chain = ACTIVE_CHAIN["data"]
        if key in chain:
            entry = chain[key]
            if entry["next_key"] == "DONE":
                return [TextContent(type="text", text=f"Value: {entry['value']}. CHAIN COMPLETE. Sum of all values = {ACTIVE_CHAIN['sum']}.")]
            return [TextContent(type="text", text=f"Value: {entry['value']}. Next key to look up: {entry['next_key']}")]
        return [TextContent(type="text", text=f"Unknown key: '{key}'. You must start with key 'start'.")]

    elif name == "fail_tool":
        raise RuntimeError("This tool always fails (intentional test error)")

    else:
        raise ValueError(f"Unknown tool: {name}")


async def health(request):
    return JSONResponse({"status": "ok"})


async def stats(request):
    return JSONResponse({"call_counts": call_counts, "total": sum(call_counts.values())})


async def reset_stats(request):
    call_counts.clear()
    return JSONResponse({"status": "reset"})


async def set_chain(request):
    body = await request.json()
    name = body.get("chain", "short")
    if name == "long":
        ACTIVE_CHAIN["name"] = "long"
        ACTIVE_CHAIN["data"] = CHAIN_LONG
        ACTIVE_CHAIN["sum"] = sum(_LONG_VALUES)
    else:
        ACTIVE_CHAIN["name"] = "short"
        ACTIVE_CHAIN["data"] = CHAIN_SHORT
        ACTIVE_CHAIN["sum"] = 314
    return JSONResponse({"status": "ok", "chain": ACTIVE_CHAIN["name"],
                         "steps": len(ACTIVE_CHAIN["data"]),
                         "expected_sum": ACTIVE_CHAIN["sum"]})


def create_app():
    sse = SseServerTransport("/messages/")

    async def handle_sse(request):
        async with sse.connect_sse(
            request.scope, request.receive, request._send
        ) as streams:
            await server.run(
                streams[0], streams[1], server.create_initialization_options()
            )

    app = Starlette(
        routes=[
            Route("/health", health),
            Route("/stats", stats),
            Route("/reset-stats", reset_stats, methods=["POST"]),
            Route("/set-chain", set_chain, methods=["POST"]),
            Route("/sse", endpoint=handle_sse),
            Mount("/messages/", app=sse.handle_post_message),
        ],
    )
    return app


if __name__ == "__main__":
    app = create_app()
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8888)
    args = parser.parse_args()
    uvicorn.run(app, host="0.0.0.0", port=args.port)
