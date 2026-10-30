#!/bin/bash
# Reproducible local checks. Run from anywhere: tests/run.sh
set -euo pipefail

cd "$(dirname "$0")/.."

echo "== store model tests =="
node --test tests/*.test.mjs

echo
echo "== shell syntax =="
bash -n install.sh uninstall.sh tests/run.sh scripts/screenshots.sh

echo
echo "== manifest validation =="
if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin validate .
else
  echo "omarchy not found; skipped plugin validation"
fi

echo
echo "OK. A graphical acceptance run still requires a real Omarchy session; see README.md."
