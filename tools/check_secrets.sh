#!/usr/bin/env bash
# Refuse to commit a known secret.
#
# Counts matches rather than relying on grep's exit status through xargs:
# `xargs grep -l` reports the status of the LAST invocation only, so a match
# in an earlier batch is reported as success. That is how a live API key
# reached a public repository once already.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1

PATTERNS='sk-[A-Za-z0-9_-]{16,}|AIza[0-9A-Za-z_-]{30,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH|EC|PGP) PRIVATE KEY'
FILES=$(git diff --cached --name-only --diff-filter=ACM)
[ -z "$FILES" ] && exit 0

HITS=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  case "$f" in *dart_defines.example.json|tools/check_secrets.sh) continue;; esac
  # Deliberate test fixtures say so in the value itself. Anything that does
  # not carry such a marker is treated as real.
  if out=$(grep -nIE "$PATTERNS" "$f" 2>/dev/null | grep -viE 'FAKE|EXAMPLE|PLACEHOLDER|REDACTED|your-'); then
    echo "SECRET in $f"
    echo "$out" | head -3
    HITS=$((HITS+1))
  fi
done <<< "$FILES"

if [ "$HITS" -gt 0 ]; then
  echo "Refusing to commit: $HITS file(s) contain what looks like a live credential."
  exit 1
fi
echo "secret scan: clean"
