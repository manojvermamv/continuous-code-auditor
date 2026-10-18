#!/usr/bin/env bash
# scripts/commands/alignment.sh — /continuous-code-auditor-alignment
#
# Reports the project's trajectory: baseline checkpoint -> latest, with the
# derived signals that indicate whether the audit is still converging on what
# the charter says this project is for.
#
# Read-only. Reports; never judges the charter and never edits it.
#
# The division of labour here is deliberate:
#   - scripts/checkpoint.sh (hourly, no model) collects the numbers.
#   - THIS script derives direction from them, deterministically.
#   - The MODEL interprets the result against the charter's prose, on demand
#     (see SKILL.md "Alignment review").
# Keeping measurement out of the model's hands is what makes the measurement
# worth anything — a model grading its own alignment reports alignment.
#
# Exit codes:
#   0  trajectory computed (drift indicators may still be present — read them)
#   1  cannot compute (no checkpoints yet, or no config)

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

CP_DIR="$PROJECT/work/checkpoints"
TIMELINE="$CP_DIR/timeline.jsonl"
BASELINE="$CP_DIR/baseline.json"
CHARTER="${CHARTER_FILE:-$SKILL_DIR/config/charter.md}"

echo "== continuous-code-auditor alignment =="
echo "project: $PROJECT"
echo

if [[ ! -f "$BASELINE" || ! -s "$TIMELINE" ]]; then
  echo "No checkpoints yet."
  echo
  echo "Alignment needs a timeline to measure against. Start collecting:"
  echo "  $SKILL_DIR/scripts/checkpoint.sh              # once, manually"
  echo "  systemctl enable --now continuous-code-auditor-checkpoint.timer   # hourly"
  echo
  echo "And write the charter it measures against:"
  echo "  cp $SKILL_DIR/config/charter.md.example $SKILL_DIR/config/charter.md"
  exit 1
fi

# --- charter status ------------------------------------------------------
echo "-- charter --"
if [[ -f "$CHARTER" ]]; then
  now_hash="$(sha256sum "$CHARTER" | cut -c1-16)"
  base_hash="$(python3 -c "
import json; print(json.load(open('$BASELINE')).get('charter_hash','none'))" 2>/dev/null)"
  echo "  present: $CHARTER"
  if [[ "$base_hash" == "none" ]]; then
    echo "  note:    charter was added AFTER the baseline checkpoint — the earliest"
    echo "           part of this timeline predates any stated intent."
  elif [[ "$now_hash" != "$base_hash" ]]; then
    echo "  CHANGED: the charter differs from the first checkpoint ($base_hash -> $now_hash)."
    echo "           Trajectory is compared only within a checkpoint epoch with this hash."
    echo "           Confirm the revision is recorded in the charter's revision log."
  else
    echo "  stable:  unchanged since baseline ($base_hash)"
  fi
else
  echo "  MISSING: no charter at $CHARTER"
  echo "           Trajectory below is still measured, but nothing can be judged"
  echo "           aligned or misaligned without a stated intent to measure against."
  echo "           Start from: $SKILL_DIR/config/charter.md.example"
fi

# --- trajectory ----------------------------------------------------------
echo
echo "-- trajectory: current charter epoch --"
CURRENT_CHARTER_HASH="none"
[[ -f "$CHARTER" ]] && CURRENT_CHARTER_HASH="$(sha256sum "$CHARTER" | cut -c1-16)"
EPOCH_BASELINE="$CP_DIR/baseline_${CURRENT_CHARTER_HASH}.json"
[[ -f "$EPOCH_BASELINE" ]] || EPOCH_BASELINE="$BASELINE"
python3 - "$EPOCH_BASELINE" "$TIMELINE" "$CURRENT_CHARTER_HASH" <<'PY' || exit $?
import json, sys
from datetime import datetime

try:
    epoch_baseline = json.load(open(sys.argv[1], encoding="utf-8"))
    all_rows = [json.loads(l) for l in open(sys.argv[2], encoding="utf-8") if l.strip()]
except (OSError, json.JSONDecodeError) as exc:
    print(f"alignment: invalid checkpoint data: {exc}", file=sys.stderr)
    sys.exit(1)
if not all_rows:
    print("alignment: checkpoint timeline is empty", file=sys.stderr)
    sys.exit(1)

current_hash = sys.argv[3]
if current_hash != "none":
    if all_rows[-1].get("charter_hash", "none") != current_hash:
        print("  No checkpoint has been recorded for the current charter revision.")
        print("  Run scripts/checkpoint.sh and review again; no direction is inferred.")
        sys.exit(0)
    if epoch_baseline.get("charter_hash", "none") == current_hash:
        baseline = epoch_baseline
        rows = [row for row in all_rows if row.get("charter_hash", "none") == current_hash]
    else:
        # Upgrade from a timeline collected before per-charter baselines were
        # added: use the earliest retained checkpoint with the current hash.
        rows = []
        for row in all_rows:
            if row.get("charter_hash", "none") == current_hash:
                rows.append(row)
        baseline = rows[0]
else:
    rows = all_rows
    baseline = epoch_baseline
latest = rows[-1]

def f(rec, k): return rec.get("findings", {}).get(k, 0)

def span(a, b):
    try:
        d = datetime.fromisoformat(b["ts"]) - datetime.fromisoformat(a["ts"])
        h = d.total_seconds() / 3600
        return f"{h:.1f} hours" if h < 48 else f"{h/24:.1f} days"
    except Exception:
        return "unknown"

print(f"  window:      {baseline['ts']}")
print(f"           ->  {latest['ts']}   ({span(baseline, latest)}, {len(rows)} checkpoints)")
print(f"  executions:  {baseline.get('executions',0)} -> {latest.get('executions',0)}")
print(f"  auditor:     v{baseline.get('auditor_version','?')} -> v{latest.get('auditor_version','?')}")
print(f"  target size: {baseline.get('target_files',0)} files / {baseline.get('target_bytes',0)}B"
      f"  ->  {latest.get('target_files',0)} files / {latest.get('target_bytes',0)}B")
print()

keys = [("open","Open"), ("verified_in_code","Verified-in-code"),
        ("verified_runtime","Verified-runtime"), ("closed_intentional","Closed-as-intentional"),
        ("contradiction_flagged","Contradiction-Flagged"), ("deferred","Deferred-Human-Review")]
print("  findings          baseline   latest   delta")
for k, label in keys:
    b, l = f(baseline, k), f(latest, k)
    d = l - b
    print(f"    {label:<24}{b:>4}  {l:>6}   {d:+d}")

# --- derived direction ---------------------------------------------------
print()
print("-- direction --")
signals = []

b_open, l_open = f(baseline,"open"), f(latest,"open")
b_closed = f(baseline,"verified_in_code")+f(baseline,"verified_runtime")+f(baseline,"closed_intentional")
l_closed = f(latest,"verified_in_code")+f(latest,"verified_runtime")+f(latest,"closed_intentional")
opened, closed = l_open - b_open, l_closed - b_closed

if closed > opened and opened <= 0:
    print("  CONVERGING: open findings fell while resolutions rose.")
elif closed >= opened and closed > 0:
    print("  CONVERGING: resolving at least as fast as discovering.")
elif opened > 0 and closed == 0:
    signals.append("Findings are accumulating with none resolved. Either nobody is acting "
                   "on them, or the auditor is reporting things this project does not "
                   "consider worth fixing — the charter's 'acceptable trade-offs' section "
                   "is what tells you which.")
    print("  DIVERGING:  discovering without resolving.")
elif opened > closed:
    signals.append("Open findings are growing faster than they are being resolved.")
    print("  DIVERGING:  net open count rising.")
else:
    print("  STEADY:     no material change in finding balance.")

if f(latest,"contradiction_flagged") > f(baseline,"contradiction_flagged"):
    signals.append("New Contradiction-Flagged findings: the auditor reached different "
                   "conclusions about unchanged code. That is reasoning drift and needs "
                   "human review — see references/consistency-and-safeguards.md §4.")

if f(latest,"deferred") > max(3, f(baseline,"deferred")):
    signals.append("Deferred-Human-Review items are accumulating. Work is being parked "
                   "rather than decided; each one is a question nobody has answered.")

if latest.get("executions",0) == baseline.get("executions",0) and len(rows) > 3:
    signals.append("Execution count has not moved across the window. Checkpoints are "
                   "being collected but audits are not running — check the scheduler, "
                   "pause flag, and circuit breaker.")

bt, lt = baseline.get("target_bytes",0), latest.get("target_bytes",0)
if bt > 0 and lt > bt * 1.5:
    signals.append(f"The audit target has grown {lt/bt:.1f}x since baseline. Scope "
                   "expansion is legitimate, but it should be a decision — check it "
                   "against the charter's non-goals and stated direction.")

if signals:
    print()
    print("-- drift indicators --")
    for s in signals:
        print(f"  * {s}")
else:
    print()
    print("  No drift indicators.")
PY

echo
echo "-- interpretation --"
if [[ -f "$CHARTER" ]]; then
  echo "  The numbers above are mechanical. Whether they represent alignment"
  echo "  depends on what this project is FOR, which only the charter states."
  echo "  For a judged read, ask your agent: \"review alignment against the charter\""
  echo "  (see SKILL.md \"Alignment review\")."
else
  echo "  Write a charter to make this judgable rather than merely observable."
fi
exit 0
