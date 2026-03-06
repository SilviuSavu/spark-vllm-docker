# Repository Guidelines

## Project Structure & Module Organization
This repo is a script-first toolkit for building and launching vLLM containers on DGX Spark.

- `run-recipe.py` and `run-recipe.sh`: recipe-driven entrypoint for build/download/run workflows.
- `launch-cluster.sh`, `run-cluster-node.sh`, `autodiscover.sh`, `hf-download.sh`: cluster orchestration and model distribution.
- `recipes/*.yaml`: declarative model recipes (container, command template, defaults, mods).
- `mods/*`: optional runtime/build patches applied by recipes or launch scripts.
- `tests/`: integration-style dry-run tests (`test_recipes.sh`) and expected argument fixtures.
- `docs/` and `examples/`: networking guidance and runnable command examples.
- `wheels/`: cached or downloaded wheel artifacts used by build scripts.

## Build, Test, and Development Commands
- `./build-and-copy.sh`: build the default Docker image locally.
- `./build-and-copy.sh -c`: build and copy image to autodiscovered cluster peers.
- `./run-recipe.sh --list`: list available recipes.
- `./run-recipe.sh <recipe> --solo --dry-run`: validate generated launch command without running containers.
- `./run-recipe.sh <recipe> --solo --setup`: full setup (build/download/run) on one node.
- `./tests/test_recipes.sh -v`: run integration checks used by CI.

## Coding Style & Naming Conventions
- Shell scripts: Bash with `set -e` where appropriate, long-form flags, uppercase env/config vars, and clear helper functions.
- Python (`run-recipe.py`): Python 3.10+, 4-space indentation, type hints, snake_case for functions/variables.
- YAML recipes: lowercase kebab-case filenames (for example `qwen3-coder-next-fp8.yaml`) and explicit `recipe_version`.
- Keep scripts executable when intended (`chmod +x`), matching existing repository conventions.

## Testing Guidelines
- Primary validation is dry-run integration testing, not unit tests.
- Run `./tests/test_recipes.sh -v` before opening a PR.
- For recipe changes, also run `./run-recipe.py <name> --dry-run --solo`.
- Keep `tests/expected_commands.sh` and README command examples synchronized with recipe behavior.

## Commit & Pull Request Guidelines
- Follow existing history style: short, imperative, descriptive subjects (for example, `Handle failed downloads properly`).
- Keep commits focused by concern (recipe, launcher, build, docs, tests).
- PRs should include:
  - What changed and why.
  - Affected recipes/scripts.
  - Validation performed (commands and outcomes).
  - Relevant logs or dry-run output when behavior changes.
