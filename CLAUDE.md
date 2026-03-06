# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Docker and orchestration toolkit for deploying vLLM on NVIDIA DGX Spark clusters. Includes multi-node Ray orchestration, InfiniBand/RDMA support, model recipes for one-click deployments, and a mod/patch system for model-specific fixes.

**Primary languages**: Bash (scripts), Python 3.10+ (recipe engine), YAML (recipes)
**Core stack**: vLLM, Ray, FlashInfer, NCCL, Docker (multi-stage builds)

## Common Commands

```bash
# Build Docker image
./build-and-copy.sh

# Build and copy to cluster nodes
./build-and-copy.sh -c 192.168.177.12

# Force rebuild vLLM wheel
./build-and-copy.sh --rebuild-vllm

# List available recipes
./run-recipe.sh --list

# Run a recipe (solo mode, with build+download)
./run-recipe.sh qwen3-coder-next-fp8 --solo --setup

# Run a recipe (cluster mode)
./run-recipe.sh glm-4.7-flash-awq -n 192.168.177.11,192.168.177.12 --setup

# Dry-run (no execution)
./run-recipe.sh minimax-m2-awq --solo --dry-run

# Run integration tests
./tests/test_recipes.sh -v

# Image artifact helpers
make image-status
make image-all
```

## Architecture

```
Recipe YAML → run-recipe.py → build-and-copy.sh (Docker build)
                             → hf-download.sh (model download + rsync)
                             → launch-cluster.sh (container orchestration)
                                 → run-cluster-node.sh (container entrypoint: Ray, NCCL, RDMA)
```

**Recipes** (`recipes/*.yaml`): Declarative model configs with container settings, command templates using `{placeholder}` substitution, default parameters, mod lists, and build args. Required fields: `name`, `recipe_version`, `container`, `command`.

**Mods** (`mods/*/`): Runtime patches applied before launch. Each mod has a `run.sh` script and optional `.patch`/`.diff` files. Applied via `--apply-mod` in `launch-cluster.sh` or `mods` list in recipes.

**Cluster modes**: Solo (single node, no Ray) and Cluster (multi-node with Ray head/worker, RDMA/InfiniBand).

**Build pipeline**: Multi-stage Dockerfile (base → FlashInfer builder → vLLM builder → runtime). Smart caching: downloads prebuilt wheels when available, falls back to local compilation. Ccache enabled.

**Network auto-detection**: `launch-cluster.sh` auto-detects Ethernet/InfiniBand interfaces and node IPs for DGX Spark ConnectX 7.

## Conventions

- Bash: `set -e`, long-form flags (`--gpu-arch` not `-g`), uppercase env vars
- Python: type hints on all functions, snake_case, 4-space indent
- Recipe filenames: lowercase kebab-case (e.g., `qwen3-coder-next-fp8.yaml`)
- Mod directories: named to describe the fix (e.g., `fix-qwen3-coder-next/`)

## Testing

Tests use `--dry-run` mode for integration validation without actual execution. Run `./tests/test_recipes.sh -v` before PRs. Test expectations are in `tests/expected_commands.sh`.

## Adding New Models

1. Create `recipes/yourmodel.yaml` following existing recipe structure
2. If model-specific patches needed, create `mods/yourfix/run.sh` with patches
3. Test with `./run-recipe.sh yourmodel --solo --dry-run`
