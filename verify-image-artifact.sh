#!/usr/bin/env bash
set -euo pipefail

MANIFEST_PATH="${1:-artifacts/build-manifest.json}"

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "ERROR: manifest not found: $MANIFEST_PATH" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required to parse $MANIFEST_PATH" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is required" >&2
  exit 1
fi

image_tar="$(jq -r '.artifacts.image_tar' "$MANIFEST_PATH")"
expected_sha="$(jq -r '.artifacts.image_tar_sha256' "$MANIFEST_PATH")"
expected_id="$(jq -r '.image.id' "$MANIFEST_PATH")"
trace_tag="$(jq -r '.image.trace_tag' "$MANIFEST_PATH")"
primary_tag="$(jq -r '.image.primary_tag' "$MANIFEST_PATH")"

if [[ -z "$image_tar" || "$image_tar" == "null" ]]; then
  echo "ERROR: artifacts.image_tar missing in manifest" >&2
  exit 1
fi
if [[ ! -f "$image_tar" ]]; then
  echo "ERROR: image tar not found: $image_tar" >&2
  exit 1
fi
if [[ -z "$expected_sha" || "$expected_sha" == "null" ]]; then
  echo "ERROR: artifacts.image_tar_sha256 missing in manifest" >&2
  exit 1
fi
if [[ -z "$expected_id" || "$expected_id" == "null" ]]; then
  echo "ERROR: image.id missing in manifest" >&2
  exit 1
fi
if [[ -z "$trace_tag" || "$trace_tag" == "null" ]]; then
  echo "ERROR: image.trace_tag missing in manifest" >&2
  exit 1
fi

echo "[1/4] Verifying tar checksum: $image_tar"
actual_sha="$(sha256sum "$image_tar" | awk '{print $1}')"
if [[ "$actual_sha" != "$expected_sha" ]]; then
  echo "ERROR: tar checksum mismatch" >&2
  echo "  expected: $expected_sha" >&2
  echo "  actual:   $actual_sha" >&2
  exit 1
fi
echo "  OK"

echo "[2/4] Verifying trace tag exists: $trace_tag"
if ! docker image inspect "$trace_tag" >/dev/null 2>&1; then
  echo "ERROR: image tag not found locally: $trace_tag" >&2
  exit 1
fi
echo "  OK"

echo "[3/4] Verifying image ID for trace tag"
trace_id="$(docker image inspect "$trace_tag" --format '{{.Id}}')"
if [[ "$trace_id" != "$expected_id" ]]; then
  echo "ERROR: image ID mismatch for $trace_tag" >&2
  echo "  expected: $expected_id" >&2
  echo "  actual:   $trace_id" >&2
  exit 1
fi
echo "  OK"

if [[ -n "$primary_tag" && "$primary_tag" != "null" ]]; then
  echo "[4/4] Verifying primary tag points to same image: $primary_tag"
  if ! docker image inspect "$primary_tag" >/dev/null 2>&1; then
    echo "ERROR: primary tag not found locally: $primary_tag" >&2
    exit 1
  fi
  primary_id="$(docker image inspect "$primary_tag" --format '{{.Id}}')"
  if [[ "$primary_id" != "$expected_id" ]]; then
    echo "ERROR: image ID mismatch for $primary_tag" >&2
    echo "  expected: $expected_id" >&2
    echo "  actual:   $primary_id" >&2
    exit 1
  fi
  echo "  OK"
fi

echo
echo "Verification passed."
echo "  Manifest: $MANIFEST_PATH"
echo "  Trace tag: $trace_tag"
echo "  Image ID: $expected_id"
