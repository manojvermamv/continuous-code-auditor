#!/usr/bin/env bash
# scripts/commands/archive.sh — /continuous-code-auditor-archive
#
# Non-destructive checkpoint: COPIES (not moves) the current contents of
# work/ into a timestamped folder under work/archives/, without clearing or
# resetting anything. The auditor keeps running normally afterward — this is
# for "snapshot the current findings before I do something risky," not for
# starting over. For that, see scripts/commands/reset.sh.
#
# Usage: archive.sh [label]
#   label   optional short tag appended to the snapshot folder name

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

LABEL="$(sanitize_label "${1:-}")"
if [[ -n "${1:-}" && -z "$LABEL" ]]; then
  echo "note: the given label had no safe characters (alphanumeric/hyphen/underscore only) — proceeding without one"
fi
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST_NAME="$TIMESTAMP"
[[ -n "$LABEL" ]] && DEST_NAME="${TIMESTAMP}-${LABEL}"
DEST="$PROJECT/work/archives/$DEST_NAME"

mkdir -p "$DEST"

# Copy everything directly inside work/ EXCEPT the archives/ directory
# itself — never recurse a snapshot of work/archives into itself.
shopt -s nullglob dotglob
for entry in "$PROJECT"/work/*; do
  base="$(basename "$entry")"
  [[ "$base" == "archives" ]] && continue
  cp -r "$entry" "$DEST/"
done
shopt -u nullglob dotglob

echo "checkpointed work/ (excluding work/archives/) into: $DEST"
echo "the active workspace was NOT modified — this is a copy, not a reset."
