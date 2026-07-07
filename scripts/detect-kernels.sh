#!/bin/bash
set -e

INPUT_TAGS=$(cat)
BUILT_VERSIONS=$(ls packages/axcl-driver-*.tgz 2>/dev/null | sed 's|packages/axcl-driver-||' | sed 's|\.tgz||' || true)

NEW_KERNELS=()
while IFS= read -r tag; do
  [ -z "$tag" ] && continue
  if echo "${BUILT_VERSIONS}" | grep -qF "${tag}"; then
    echo "  [SKIP] ${tag} - already built"
  else
    echo "  [NEW]  ${tag} - will build"
    NEW_KERNELS+=("$tag")
  fi
done <<< "$INPUT_TAGS"

if [ ${#NEW_KERNELS[@]} -eq 0 ]; then
  echo "No new kernel versions found. Nothing to build."
  echo "[]"
else
  printf '%s\n' "${NEW_KERNELS[@]:0:3}" | python3 -c "import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))"
fi
