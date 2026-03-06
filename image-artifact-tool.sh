#!/usr/bin/env bash
set -euo pipefail

MANIFEST_PATH="${MANIFEST_PATH:-artifacts/build-manifest.json}"
CMD="${1:-help}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1" >&2
    exit 1
  fi
}

need_cmd jq
need_cmd docker

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "ERROR: manifest not found: $MANIFEST_PATH" >&2
  exit 1
fi

image_tar="$(jq -r '.artifacts.image_tar' "$MANIFEST_PATH")"
trace_tag="$(jq -r '.image.trace_tag' "$MANIFEST_PATH")"
primary_tag="$(jq -r '.image.primary_tag' "$MANIFEST_PATH")"
image_id="$(jq -r '.image.id' "$MANIFEST_PATH")"
commit="$(jq -r '.git.commit' "$MANIFEST_PATH")"
tar_sha="$(jq -r '.artifacts.image_tar_sha256' "$MANIFEST_PATH")"

show_help() {
  cat <<EOF
Human-friendly image helper

Usage:
  ./image-artifact-tool.sh status
  ./image-artifact-tool.sh verify
  ./image-artifact-tool.sh load
  ./image-artifact-tool.sh all

Optional:
  MANIFEST_PATH=artifacts/build-manifest.json ./image-artifact-tool.sh status
EOF
}

show_status() {
  echo "Build commit: $commit"
  echo "Expected image ID: $image_id"
  echo "Trace tag: $trace_tag"
  echo "Primary tag: $primary_tag"
  echo "Tar file: $image_tar"
  echo "Tar SHA256: $tar_sha"
  echo
  if [[ -f "$image_tar" ]]; then
    size="$(stat -c '%s' "$image_tar")"
    echo "Tar present: yes (${size} bytes)"
  else
    echo "Tar present: no"
  fi
  if docker image inspect "$trace_tag" >/dev/null 2>&1; then
    local_id="$(docker image inspect "$trace_tag" --format '{{.Id}}')"
    echo "Trace tag loaded: yes ($local_id)"
  else
    echo "Trace tag loaded: no"
  fi
}

run_verify() {
  ./verify-image-artifact.sh "$MANIFEST_PATH"
}

run_load() {
  if [[ ! -f "$image_tar" ]]; then
    echo "ERROR: tar file not found: $image_tar" >&2
    exit 1
  fi
  echo "Loading image tar into Docker..."
  docker load -i "$image_tar" >/dev/null
  echo "Load complete. Ensuring expected tags exist..."
  if ! docker image inspect "$trace_tag" >/dev/null 2>&1; then
    if docker image inspect "$image_id" >/dev/null 2>&1; then
      docker tag "$image_id" "$trace_tag"
    else
      echo "ERROR: could not find loaded image ID $image_id" >&2
      exit 1
    fi
  fi
  if [[ -n "$primary_tag" && "$primary_tag" != "null" ]]; then
    docker tag "$trace_tag" "$primary_tag"
  fi
  echo "Load + tag complete."
}

case "$CMD" in
  status)
    show_status
    ;;
  verify)
    run_verify
    ;;
  load)
    run_load
    ;;
  all)
    show_status
    echo
    run_verify
    echo
    run_load
    echo
    run_verify
    ;;
  help|-h|--help)
    show_help
    ;;
  *)
    echo "ERROR: unknown command: $CMD" >&2
    show_help
    exit 1
    ;;
esac
