#!/bin/bash
set -e

echo "Patching Qwen3-Coder-Next crashing on start"
patch -p1 -d /usr/local/lib/python3.12/dist-packages < fix_crash.diff || echo "Patch is not applicable, skipping"

echo "Reverting PR #34279 that causes slowness"
patch -p1 -R -d /usr/local/lib/python3.12/dist-packages < fix_slowness.diff || echo "Reversing PR #34279 failed, skipping"

echo "Fixing Triton allocator bug"
cp _triton* /usr/local/lib/python3.12/dist-packages/
