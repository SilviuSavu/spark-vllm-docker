#!/bin/bash
set -e

# Default values
IMAGE_TAG="vllm-node"
REBUILD_DEPS=false
REBUILD_VLLM=false
COPY_HOST=""
SSH_USER="$USER"

# Help function
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "  -t, --tag <tag>           : Image tag (default: 'vllm-node')"
    echo "  --rebuild-deps            : Set cache bust for dependencies"
    echo "  --rebuild-vllm            : Set cache bust for vllm"
    echo "  -h, --copy-to-host <host> : Host address to copy the image to (if not set, don't copy)"
    echo "  -u, --user <user>         : Username for ssh command (default: \$USER)"
    echo "  --help                    : Show this help message"
    exit 1
}

# Argument parsing
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -t|--tag) IMAGE_TAG="$2"; shift ;;
        --rebuild-deps) REBUILD_DEPS=true ;;
        --rebuild-vllm) REBUILD_VLLM=true ;;
        -h|--copy-to-host) COPY_HOST="$2"; shift ;;
        -u|--user) SSH_USER="$2"; shift ;;
        --help) usage ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# Construct build command
CMD=("docker" "build" "-t" "$IMAGE_TAG")

if [ "$REBUILD_DEPS" = true ]; then
    echo "Setting CACHEBUST_DEPS..."
    CMD+=("--build-arg" "CACHEBUST_DEPS=$(date +%s)")
fi

if [ "$REBUILD_VLLM" = true ]; then
    echo "Setting CACHEBUST_VLLM..."
    CMD+=("--build-arg" "CACHEBUST_VLLM=$(date +%s)")
fi

# Add build context
CMD+=(".")

# Execute build
echo "Building image with command: ${CMD[*]}"
"${CMD[@]}"

# Copy to host if requested
if [ -n "$COPY_HOST" ]; then
    echo "Copying image '$IMAGE_TAG' to ${SSH_USER}@${COPY_HOST}..."
    # Using the pipe method from README.md
    docker save "$IMAGE_TAG" | ssh "${SSH_USER}@${COPY_HOST}" "docker load"
    echo "Copy complete."
else
    echo "No host specified, skipping copy."
fi

echo "Done."
