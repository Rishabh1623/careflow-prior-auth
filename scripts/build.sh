#!/usr/bin/env bash
# Packages each Lambda into a zip for Terraform deployment.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"

mkdir -p "$BUILD_DIR"

build_lambda() {
  local name=$1
  local src_dir="$REPO_ROOT/src/$name"
  local tmp_dir
  tmp_dir=$(mktemp -d)

  echo "Building $name..."
  python3 -m pip install \
    -r "$src_dir/requirements.txt" \
    -t "$tmp_dir" \
    -q \
    --python-version 3.13 \
    --platform manylinux2014_x86_64 \
    --only-binary=:all:

  cp "$src_dir/handler.py" "$tmp_dir/"
  (cd "$tmp_dir" && zip -r9 "$BUILD_DIR/${name}.zip" . -q)
  rm -rf "$tmp_dir"
  echo "  -> $BUILD_DIR/${name}.zip ($(du -sh "$BUILD_DIR/${name}.zip" | cut -f1))"
}

build_lambda "submission"
build_lambda "reviewer_callback"
build_lambda "orchestrator"

echo ""
echo "All Lambda packages built in $BUILD_DIR/"
ls -lh "$BUILD_DIR/"
