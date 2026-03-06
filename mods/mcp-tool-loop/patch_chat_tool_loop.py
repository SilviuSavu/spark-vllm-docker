#!/usr/bin/env python3
"""
Patch vLLM Chat Completions to add server-side MCP tool execution loop.

When tool_server is configured, non-streaming chat completions that return
tool_calls will automatically execute those tools via MCP and loop until
the model produces a final text response (or max rounds is reached).

Includes context management to prevent conversation history from exceeding
the model's context window.
"""

import sys

ROUTER_FILE = "/usr/local/lib/python3.12/dist-packages/vllm/entrypoints/openai/generate/api_router.py"
SERVING_FILE = "/usr/local/lib/python3.12/dist-packages/vllm/entrypoints/openai/chat_completion/serving.py"


def patch_api_router():
    """Add tool_server=tool_server to OpenAIServingChat constructor."""
    with open(ROUTER_FILE) as f:
        content = f.read()

    if "tool_server=tool_server" in content and "OpenAIServingChat" in content:
        # Check it's in the OpenAIServingChat section specifically
        chat_section = content[content.index("OpenAIServingChat("):]
        chat_section = chat_section[:chat_section.index(")")]
        if "tool_server=tool_server" in chat_section:
            print("  api_router.py: already patched, skipping")
            return

    # Insert tool_server=tool_server after log_error_stack line in OpenAIServingChat
    old = """            log_error_stack=args.log_error_stack,
        )
        if "generate" in supported_tasks
        else None
    )
    # Warm up chat template processing"""

    new = """            log_error_stack=args.log_error_stack,
            tool_server=tool_server,
        )
        if "generate" in supported_tasks
        else None
    )
    # Warm up chat template processing"""

    if old not in content:
        print(f"  ERROR: Could not find expected pattern in {ROUTER_FILE}", file=sys.stderr)
        sys.exit(1)

    content = content.replace(old, new)
    with open(ROUTER_FILE, "w") as f:
        f.write(content)
    print("  api_router.py: patched OK")


def patch_serving():
    """Add tool_server param to __init__ and agentic loop to create_chat_completion."""
    with open(SERVING_FILE) as f:
        content = f.read()

    if "self.tool_server" in content:
        print("  serving.py: already patched, skipping")
        return

    # 1. Add tool_server parameter to __init__
    old_init = """        default_chat_template_kwargs: dict[str, Any] | None = None,
    ) -> None:"""
    new_init = """        default_chat_template_kwargs: dict[str, Any] | None = None,
        tool_server: Any | None = None,
    ) -> None:"""

    if old_init not in content:
        print(f"  ERROR: Could not find __init__ pattern in {SERVING_FILE}", file=sys.stderr)
        sys.exit(1)
    content = content.replace(old_init, new_init, 1)

    # 2. Store tool_server after self.response_role
    old_store = """        self.response_role = response_role"""
    new_store = """        self.response_role = response_role
        self.tool_server = tool_server"""

    if old_store not in content:
        print(f"  ERROR: Could not find response_role pattern in {SERVING_FILE}", file=sys.stderr)
        sys.exit(1)
    content = content.replace(old_store, new_store, 1)

    # 3. Add the agentic loop import at top of file (after existing json import)
    old_import = "import json"
    new_import = "import json\nfrom contextlib import AsyncExitStack"
    if "from contextlib import AsyncExitStack" not in content:
        content = content.replace(old_import, new_import, 1)

    # 4. Wrap the non-streaming return in an agentic loop
    old_return = """        try:
            return await self.chat_completion_full_generator(
                request,
                result_generator,
                request_id,
                model_name,
                conversation,
                tokenizer,
                request_metadata,
                reasoning_parser,
            )
        except GenerationError as e:
            return self._convert_generation_error_to_response(e)
        except ValueError as e:
            return self.create_error_response(e)

    def get_chat_request_role"""

    new_return = """        try:
            response = await self.chat_completion_full_generator(
                request,
                result_generator,
                request_id,
                model_name,
                conversation,
                tokenizer,
                request_metadata,
                reasoning_parser,
            )
        except GenerationError as e:
            return self._convert_generation_error_to_response(e)
        except ValueError as e:
            return self.create_error_response(e)

        # --- MCP Tool Execution Loop (non-streaming only) ---
        # Context management constants
        max_rounds = 300
        MAX_TOOL_OUTPUT_CHARS = 6000    # truncate individual tool results
        MAX_HISTORY_ROUNDS = 20         # keep last N rounds of tool interaction
        round_num = 0
        total_compacted_calls = 0       # cumulative tool calls removed by compaction

        def _truncate_tool_output(text, max_chars=MAX_TOOL_OUTPUT_CHARS):
            \"\"\"Truncate tool output, keeping head and tail for context.\"\"\"
            if not isinstance(text, str) or len(text) <= max_chars:
                return text
            head = max_chars * 2 // 3
            tail = max_chars // 3
            return (text[:head]
                    + f"\\n\\n... [{len(text) - head - tail} chars truncated] ...\\n\\n"
                    + text[-tail:])

        def _count_round_messages(messages):
            \"\"\"Count assistant+tool message groups after the initial system+user messages.\"\"\"
            rounds = 0
            i = 0
            for msg in messages:
                if msg.get("role") == "assistant" and msg.get("tool_calls"):
                    rounds += 1
            return rounds

        def _compact_history(messages, keep_rounds, current_round):
            \"\"\"Sliding window: keep system+user prompt and last keep_rounds of tool interaction.\"\"\"
            # Split into: original preamble (system+user only) and everything after
            preamble_end = 0
            for i, msg in enumerate(messages):
                if msg.get("role") in ("system", "user"):
                    preamble_end = i + 1
                else:
                    break
            preamble = messages[:preamble_end]
            rest = messages[preamble_end:]

            # Group rest into tool rounds: each starts with assistant(tool_calls)
            # Skip any non-tool-call messages (like previous summaries)
            rounds = []
            current_group = []
            for msg in rest:
                if msg.get("role") == "assistant" and msg.get("tool_calls"):
                    if current_group:
                        rounds.append(current_group)
                    current_group = [msg]
                elif current_group:
                    current_group.append(msg)
                # else: skip orphaned messages (old summaries etc)
            if current_group:
                rounds.append(current_group)

            if len(rounds) <= keep_rounds:
                return messages  # nothing to compact

            # Split into old (to summarize) and recent (to keep)
            old_rounds = rounds[:-keep_rounds]
            keep = rounds[-keep_rounds:]

            # Count tool calls in removed rounds
            total_removed = 0
            tool_counts = {}
            for rnd in old_rounds:
                for msg in rnd:
                    if msg.get("tool_calls"):
                        for tc in msg["tool_calls"]:
                            name = tc.get("function", {}).get("name", "?")
                            tool_counts[name] = tool_counts.get(name, 0) + 1
                            total_removed += 1

            tool_summary = ", ".join(f"{n}x{c}" for n, c in tool_counts.items())
            # Use nonlocal to accumulate across compactions
            nonlocal total_compacted_calls
            total_compacted_calls += total_removed
            summary_text = (
                f"[Context compressed: rounds 1-{current_round - keep_rounds} "
                f"removed ({total_compacted_calls} total tool calls). "
                f"Continuing from round {current_round - keep_rounds + 1}.]"
            )

            # Reconstruct: preamble + single summary + recent rounds
            recent = [msg for rnd in keep for msg in rnd]
            return preamble + [{"role": "assistant", "content": summary_text}] + recent

        while (isinstance(response, ChatCompletionResponse)
               and self.tool_server is not None
               and response.choices
               and response.choices[0].message.tool_calls
               and round_num < max_rounds):
            round_num += 1
            tool_calls = response.choices[0].message.tool_calls

            logger.info("MCP tool loop round %d: executing %d tool call(s)",
                        round_num, len(tool_calls))

            # Append assistant message with tool_calls
            # Compact arguments JSON to single line to avoid chat template parsing issues
            assistant_msg = {"role": "assistant", "tool_calls": [
                {"id": tc.id, "type": "function",
                 "function": {"name": tc.function.name,
                              "arguments": json.dumps(json.loads(tc.function.arguments))
                              if tc.function.arguments else "{}"}}
                for tc in tool_calls
            ]}
            request.messages.append(assistant_msg)

            # Execute each tool call via MCP
            server_label = next(iter(self.tool_server.urls.keys()))
            async with AsyncExitStack() as stack:
                session = await stack.enter_async_context(
                    self.tool_server.new_session(server_label, request_id))
                for tc in tool_calls:
                    try:
                        args = json.loads(tc.function.arguments)
                    except json.JSONDecodeError:
                        args = {}
                    try:
                        mcp_result = await session.call_tool(
                            tc.function.name, args)
                        result_text = (mcp_result.content[0].text
                                       if mcp_result.content else "")
                    except Exception as e:
                        logger.warning("MCP tool call %s failed: %s",
                                       tc.function.name, e)
                        result_text = f"Error: {e}"

                    # Layer 1: Truncate large tool outputs
                    result_text = _truncate_tool_output(result_text)

                    request.messages.append({
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": result_text,
                    })

            # Layer 2: Sliding window - compact old rounds
            n_rounds = _count_round_messages(request.messages)
            if n_rounds > MAX_HISTORY_ROUNDS:
                old_len = len(request.messages)
                request.messages = _compact_history(
                    request.messages, MAX_HISTORY_ROUNDS, round_num)
                logger.info("MCP context compacted: %d -> %d messages "
                            "(%d rounds kept)",
                            old_len, len(request.messages),
                            MAX_HISTORY_ROUNDS)

            # Re-render the request with updated messages
            result = await self.render_chat_request(request)
            if isinstance(result, ErrorResponse):
                logger.warning("MCP loop render failed round %d: %s",
                               round_num, result)
                return result
            conversation, engine_prompts = result
            prompt_len = self._extract_prompt_len(engine_prompts[0])
            logger.info("MCP loop round %d: %d messages, prompt_len=%d",
                        round_num, len(request.messages), prompt_len)

            # Rebuild generator and regenerate
            try:
                generators = []
                for i, engine_prompt in enumerate(engine_prompts):
                    sub_request_id = (
                        request_id if len(engine_prompts) == 1
                        else f"{request_id}_{i}"
                    )
                    max_tokens = get_max_tokens(
                        self.model_config.max_model_len,
                        request.max_completion_tokens
                        if request.max_completion_tokens is not None
                        else request.max_tokens,
                        self._extract_prompt_len(engine_prompt),
                        self.default_sampling_params,
                        self.override_max_tokens,
                    )
                    sampling_params = request.to_sampling_params(
                        max_tokens, self.default_sampling_params)
                    generator = self.engine_client.generate(
                        engine_prompt, sampling_params, sub_request_id,
                        priority=request.priority,
                        data_parallel_rank=data_parallel_rank,
                    )
                    generators.append(generator)
                assert len(generators) == 1
                (result_generator,) = generators
                response = await self.chat_completion_full_generator(
                    request, result_generator, request_id, model_name,
                    conversation, tokenizer, request_metadata,
                    reasoning_parser)
            except (GenerationError, ValueError) as e:
                logger.warning("MCP loop generation failed round %d: %s",
                               round_num, e)
                break

        if round_num > 0:
            logger.info("MCP tool loop completed after %d round(s)", round_num)

        return response

    def get_chat_request_role"""

    if old_return not in content:
        print(f"  ERROR: Could not find non-streaming return pattern in {SERVING_FILE}", file=sys.stderr)
        sys.exit(1)
    content = content.replace(old_return, new_return, 1)

    with open(SERVING_FILE, "w") as f:
        f.write(content)
    print("  serving.py: patched OK")


if __name__ == "__main__":
    print("Patching vLLM Chat Completions for MCP tool execution loop...")
    patch_api_router()
    patch_serving()
    print("Done.")
