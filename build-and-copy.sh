#!/bin/bash
set -e

# Start total time tracking
START_TIME=$(date +%s)

# Default values
IMAGE_TAG="vllm-node"
REBUILD_FLASHINFER=false
REBUILD_VLLM=false
COPY_HOSTS=()
SSH_USER="$USER"
NO_BUILD=false
VLLM_REF="main"
TMP_IMAGE=""
PARALLEL_COPY=false
EXP_MXFP4=false
VLLM_REF_SET=false
VLLM_PRS=""
PRE_TRANSFORMERS=false
FULL_LOG=false
BUILD_JOBS="16"
GPU_ARCH_LIST="12.1a"

cleanup() {
    if [ -n "$TMP_IMAGE" ] && [ -f "$TMP_IMAGE" ]; then
        echo "Cleaning up temporary image $TMP_IMAGE"
        rm -f "$TMP_IMAGE"
    fi
}

trap cleanup EXIT

add_copy_hosts() {
    local token part
    for token in "$@"; do
        IFS=',' read -ra PARTS <<< "$token"
        for part in "${PARTS[@]}"; do
            part="${part//[[:space:]]/}"
            if [ -n "$part" ]; then
                COPY_HOSTS+=("$part")
            fi
        done
    done
}

copy_to_host() {
    local host="$1"
    echo "Loading image into ${SSH_USER}@${host}..."
    local host_copy_start host_copy_end host_copy_time
    host_copy_start=$(date +%s)
    if cat "$TMP_IMAGE" | ssh "${SSH_USER}@${host}" "docker load"; then
        host_copy_end=$(date +%s)
        host_copy_time=$((host_copy_end - host_copy_start))
        printf "Copy to %s completed in %02d:%02d:%02d\n" "$host" $((host_copy_time/3600)) $((host_copy_time%3600/60)) $((host_copy_time%60))
    else
        echo "Copy to $host failed."
        return 1
    fi
}

# Help function
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "  -t, --tag <tag>               : Image tag (default: 'vllm-node')"
    echo "  --gpu-arch <arch>             : GPU architecture (default: '12.1a')"
    echo "  --rebuild-flashinfer          : Force rebuild of FlashInfer wheels (ignore cached wheels)"
    echo "  --rebuild-vllm                : Force rebuild of vLLM wheels (ignore cached wheels)"
    echo "  --vllm-ref <ref>              : vLLM commit SHA, branch or tag (default: 'main')"
    echo "  -c, --copy-to <hosts>         : Host(s) to copy the image to. Accepts comma or space-delimited lists."
    echo "      --copy-to-host            : Alias for --copy-to (backwards compatibility)."
    echo "      --copy-parallel           : Copy to all hosts in parallel instead of serially."
    echo "  -j, --build-jobs <jobs>       : Number of concurrent build jobs (default: ${BUILD_JOBS})"
    echo "  -u, --user <user>             : Username for ssh command (default: \$USER)"
    echo "  --pre-tf, --pre-transformers  : Install transformers 5.0.0rc0 or higher"
    echo "  --exp-mxfp4, --experimental-mxfp4 : Build with experimental native MXFP4 support"
    echo "  --apply-vllm-pr <pr-num>      : Apply a specific PR patch to vLLM source. Can be specified multiple times."
    echo "  --full-log                    : Enable full build logging (--progress=plain)"
    echo "  --no-build                    : Skip building, only copy image (requires --copy-to)"
    echo "  -h, --help                    : Show this help message"
    exit 1
}

# Argument parsing
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -t|--tag) IMAGE_TAG="$2"; shift ;;
        --gpu-arch) GPU_ARCH_LIST="$2"; shift ;;
        --rebuild-flashinfer) REBUILD_FLASHINFER=true ;;
        --rebuild-vllm) REBUILD_VLLM=true ;;
        --vllm-ref) VLLM_REF="$2"; VLLM_REF_SET=true; shift ;;
        -c|--copy-to|--copy-to-host|--copy-to-hosts)
            shift
            while [[ "$#" -gt 0 && "$1" != -* ]]; do
                add_copy_hosts "$1"
                shift
            done

            if [ "${#COPY_HOSTS[@]}" -eq 0 ]; then
                echo "No hosts specified. Using autodiscovery..."
                source "$(dirname "$0")/autodiscover.sh"

                detect_nodes
                if [ $? -ne 0 ]; then
                    echo "Error: Autodiscovery failed."
                    exit 1
                fi

                if [ ${#PEER_NODES[@]} -gt 0 ]; then
                    COPY_HOSTS=("${PEER_NODES[@]}")
                fi

                if [ "${#COPY_HOSTS[@]}" -eq 0 ]; then
                     echo "Error: Autodiscovery found no other nodes."
                     exit 1
                fi
                echo "Autodiscovered hosts: ${COPY_HOSTS[*]}"
            fi
            continue
            ;;
        -j|--build-jobs) BUILD_JOBS="$2"; shift ;;
        -u|--user) SSH_USER="$2"; shift ;;
        --copy-parallel) PARALLEL_COPY=true ;;
        --pre-tf|--pre-transformers) PRE_TRANSFORMERS=true ;;
        --exp-mxfp4|--experimental-mxfp4) EXP_MXFP4=true ;;
        --apply-vllm-pr)
            if [ -n "$2" ] && [[ "$2" != -* ]]; then
               if [ -n "$VLLM_PRS" ]; then
                   VLLM_PRS="$VLLM_PRS $2"
               else
                   VLLM_PRS="$2"
               fi
               shift
            else
               echo "Error: --apply-vllm-pr requires a PR number."
               exit 1
            fi
            ;;
        --full-log) FULL_LOG=true ;;
        --no-build) NO_BUILD=true ;;
        -h|--help) usage ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# Validate flag combinations
if [ -n "$VLLM_PRS" ]; then
    if [ "$EXP_MXFP4" = true ]; then echo "Error: --apply-vllm-pr is incompatible with --exp-mxfp4"; exit 1; fi
fi

if [ "$EXP_MXFP4" = true ]; then
    if [ "$VLLM_REF_SET" = true ]; then echo "Error: --exp-mxfp4 is incompatible with --vllm-ref"; exit 1; fi
    if [ "$PRE_TRANSFORMERS" = true ]; then echo "Error: --exp-mxfp4 is incompatible with --pre-transformers"; exit 1; fi
    if [ "$REBUILD_FLASHINFER" = true ]; then echo "Error: --exp-mxfp4 is incompatible with --rebuild-flashinfer"; exit 1; fi
    if [ "$REBUILD_VLLM" = true ]; then echo "Error: --exp-mxfp4 is incompatible with --rebuild-vllm"; exit 1; fi
fi

# Validate --no-build usage
if [ "$NO_BUILD" = true ] && [ "${#COPY_HOSTS[@]}" -eq 0 ]; then
    echo "Error: --no-build requires --copy-to to be specified"
    exit 1
fi

# Ensure wheels directory exists
mkdir -p ./wheels

# Common build flags used across all non-mxfp4 sub-builds
COMMON_BUILD_FLAGS=()
if [ "$FULL_LOG" = true ]; then
    COMMON_BUILD_FLAGS+=("--progress=plain")
fi
COMMON_BUILD_FLAGS+=("--build-arg" "BUILD_JOBS=$BUILD_JOBS")
COMMON_BUILD_FLAGS+=("--build-arg" "TORCH_CUDA_ARCH_LIST=$GPU_ARCH_LIST")
COMMON_BUILD_FLAGS+=("--build-arg" "FLASHINFER_CUDA_ARCH_LIST=$GPU_ARCH_LIST")

# =====================================================
# Build image (unless --no-build or --exp-mxfp4)
# =====================================================
FLASHINFER_BUILD_TIME=0
VLLM_BUILD_TIME=0
RUNNER_BUILD_TIME=0

if [ "$NO_BUILD" = false ]; then
    if [ "$EXP_MXFP4" = true ]; then
        echo "Building with experimental MXFP4 support..."
        CMD=("docker" "build" "-t" "$IMAGE_TAG" "${COMMON_BUILD_FLAGS[@]}" "-f" "Dockerfile.mxfp4" ".")
        echo "Building image with command: ${CMD[*]}"
        BUILD_START=$(date +%s)
        "${CMD[@]}"
        BUILD_END=$(date +%s)
        RUNNER_BUILD_TIME=$((BUILD_END - BUILD_START))
    else
        # ----------------------------------------------------------
        # Phase 1: FlashInfer wheels
        # ----------------------------------------------------------
        FLASHINFER_WHEELS_EXIST=false
        if compgen -G "./wheels/flashinfer*.whl" > /dev/null 2>&1; then
            FLASHINFER_WHEELS_EXIST=true
        fi

        if [ "$REBUILD_FLASHINFER" = true ] || [ "$FLASHINFER_WHEELS_EXIST" = false ]; then
            if [ "$REBUILD_FLASHINFER" = true ]; then
                echo "Rebuilding FlashInfer wheels (--rebuild-flashinfer specified)..."
            else
                echo "No FlashInfer wheels found in ./wheels/ — building..."
            fi

            FI_CMD=("docker" "build"
                "--target" "flashinfer-export"
                "--output" "type=local,dest=./wheels"
                "${COMMON_BUILD_FLAGS[@]}")

            if [ "$REBUILD_FLASHINFER" = true ]; then
                FI_CMD+=("--build-arg" "CACHEBUST_FLASHINFER=$(date +%s)")
            fi

            FI_CMD+=(".")

            echo "FlashInfer build command: ${FI_CMD[*]}"
            FI_START=$(date +%s)
            "${FI_CMD[@]}"
            FI_END=$(date +%s)
            FLASHINFER_BUILD_TIME=$((FI_END - FI_START))
        else
            echo "FlashInfer wheels already present in ./wheels/ — skipping build."
        fi

        # ----------------------------------------------------------
        # Phase 2: vLLM wheels
        # ----------------------------------------------------------
        VLLM_WHEELS_EXIST=false
        if compgen -G "./wheels/vllm*.whl" > /dev/null 2>&1; then
            VLLM_WHEELS_EXIST=true
        fi

        if [ "$REBUILD_VLLM" = true ] || [ "$VLLM_WHEELS_EXIST" = false ]; then
            if [ "$REBUILD_VLLM" = true ]; then
                echo "Rebuilding vLLM wheels (--rebuild-vllm specified)..."
            else
                echo "No vLLM wheels found in ./wheels/ — building..."
            fi

            VLLM_CMD=("docker" "build"
                "--target" "vllm-export"
                "--output" "type=local,dest=./wheels"
                "${COMMON_BUILD_FLAGS[@]}"
                "--build-arg" "VLLM_REF=$VLLM_REF")

            if [ "$REBUILD_VLLM" = true ]; then
                VLLM_CMD+=("--build-arg" "CACHEBUST_VLLM=$(date +%s)")
            fi

            if [ -n "$VLLM_PRS" ]; then
                echo "Applying vLLM PRs: $VLLM_PRS"
                VLLM_CMD+=("--build-arg" "VLLM_PRS=$VLLM_PRS")
            fi

            if [ "$PRE_TRANSFORMERS" = true ]; then
                echo "Using transformers>=5.0.0..."
                VLLM_CMD+=("--build-arg" "PRE_TRANSFORMERS=1")
            fi

            VLLM_CMD+=(".")

            echo "vLLM build command: ${VLLM_CMD[*]}"
            VLLM_START=$(date +%s)
            "${VLLM_CMD[@]}"
            VLLM_END=$(date +%s)
            VLLM_BUILD_TIME=$((VLLM_END - VLLM_START))
        else
            echo "vLLM wheels already present in ./wheels/ — skipping build."
        fi

        # ----------------------------------------------------------
        # Phase 3: Runner image
        # ----------------------------------------------------------
        if ! compgen -G "./wheels/*.whl" > /dev/null 2>&1; then
            echo "Error: No wheel files found in ./wheels/ — cannot build runner image."
            exit 1
        fi

        RUNNER_CMD=("docker" "build"
            "-t" "$IMAGE_TAG"
            "${COMMON_BUILD_FLAGS[@]}")

        if [ "$PRE_TRANSFORMERS" = true ]; then
            RUNNER_CMD+=("--build-arg" "PRE_TRANSFORMERS=1")
        fi

        RUNNER_CMD+=(".")

        echo "Building runner image with command: ${RUNNER_CMD[*]}"
        RUNNER_START=$(date +%s)
        "${RUNNER_CMD[@]}"
        RUNNER_END=$(date +%s)
        RUNNER_BUILD_TIME=$((RUNNER_END - RUNNER_START))
    fi
else
    echo "Skipping build (--no-build specified)"
fi

# =====================================================
# Copy to host(s) if requested
# =====================================================
COPY_TIME=0
if [ "${#COPY_HOSTS[@]}" -gt 0 ]; then
    echo "Copying image '$IMAGE_TAG' to ${#COPY_HOSTS[@]} host(s): ${COPY_HOSTS[*]}"
    if [ "$PARALLEL_COPY" = true ]; then
        echo "Parallel copy enabled."
    fi
    COPY_START=$(date +%s)

    TMP_IMAGE=$(mktemp -t vllm_image.XXXXXX)
    echo "Saving image locally to $TMP_IMAGE..."
    docker save -o "$TMP_IMAGE" "$IMAGE_TAG"

    if [ "$PARALLEL_COPY" = true ]; then
        PIDS=()
        for host in "${COPY_HOSTS[@]}"; do
            copy_to_host "$host" &
            PIDS+=($!)
        done
        COPY_FAILURE=0
        for pid in "${PIDS[@]}"; do
            if ! wait "$pid"; then
                COPY_FAILURE=1
            fi
        done
        if [ "$COPY_FAILURE" -ne 0 ]; then
            echo "One or more copies failed."
            exit 1
        fi
    else
        for host in "${COPY_HOSTS[@]}"; do
            copy_to_host "$host"
        done
    fi

    COPY_END=$(date +%s)
    COPY_TIME=$((COPY_END - COPY_START))
    echo "Copy complete."
else
    echo "No host specified, skipping copy."
fi

# Calculate total time
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

# Display timing statistics
echo ""
echo "========================================="
echo "         TIMING STATISTICS"
echo "========================================="
if [ "$FLASHINFER_BUILD_TIME" -gt 0 ]; then
    echo "FlashInfer Build: $(printf '%02d:%02d:%02d' $((FLASHINFER_BUILD_TIME/3600)) $((FLASHINFER_BUILD_TIME%3600/60)) $((FLASHINFER_BUILD_TIME%60)))"
fi
if [ "$VLLM_BUILD_TIME" -gt 0 ]; then
    echo "vLLM Build:       $(printf '%02d:%02d:%02d' $((VLLM_BUILD_TIME/3600)) $((VLLM_BUILD_TIME%3600/60)) $((VLLM_BUILD_TIME%60)))"
fi
if [ "$RUNNER_BUILD_TIME" -gt 0 ]; then
    echo "Runner Build:     $(printf '%02d:%02d:%02d' $((RUNNER_BUILD_TIME/3600)) $((RUNNER_BUILD_TIME%3600/60)) $((RUNNER_BUILD_TIME%60)))"
fi
if [ "$COPY_TIME" -gt 0 ]; then
    echo "Image Copy:       $(printf '%02d:%02d:%02d' $((COPY_TIME/3600)) $((COPY_TIME%3600/60)) $((COPY_TIME%60)))"
fi
echo "Total Time:       $(printf '%02d:%02d:%02d' $((TOTAL_TIME/3600)) $((TOTAL_TIME%3600/60)) $((TOTAL_TIME%60)))"
echo "========================================="
echo "Done building $IMAGE_TAG."
