#!/usr/bin/env bash
# scripts/commands/uninstall.sh — /continuous-code-auditor-uninstall
#
# Removes this skill's presence: stops/removes scheduling (systemd timer, or
# the matching cron line), and removes the skill-directory symlinks/copies
# installer/install.sh created for whichever agent CLIs use native skill
# discovery (Claude Code, Gemini CLI, Codex CLI, Hermes — see adapters/).
#
# Does NOT touch work/, archives/, backups/, or logs/ by default — audit
# history survives an uninstall unless you explicitly ask otherwise. Run
# scripts/commands/backup-everything.sh first if you want a safety copy
# regardless.
#
# Usage: uninstall.sh [--purge-data]
#   --purge-data   also delete PROJECT/work, PROJECT/archives, PROJECT/backups,
#                  and LOG_DIR. Irreversible. Off by default.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

PURGE=false
[[ "${1:-}" == "--purge-data" ]] && PURGE=true

echo "== uninstalling continuous-code-auditor =="

if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files 2>/dev/null | grep -q "^continuous-code-auditor.timer"; then
    systemctl disable --now continuous-code-auditor.timer 2>/dev/null \
      && echo "disabled and stopped continuous-code-auditor.timer" \
      || echo "note: could not disable continuous-code-auditor.timer (permissions? try with sudo)"
    if [[ -w /etc/systemd/system ]]; then
      rm -f /etc/systemd/system/continuous-code-auditor.service /etc/systemd/system/continuous-code-auditor.timer
      systemctl daemon-reload 2>/dev/null || true
      echo "removed the systemd unit files"
    fi
  fi
  if systemctl list-unit-files 2>/dev/null | grep -q "^continuous-code-auditor-watchdog.timer"; then
    systemctl disable --now continuous-code-auditor-watchdog.timer 2>/dev/null \
      && echo "disabled and stopped continuous-code-auditor-watchdog.timer" \
      || echo "note: could not disable continuous-code-auditor-watchdog.timer (permissions? try with sudo)"
    if [[ -w /etc/systemd/system ]]; then
      rm -f /etc/systemd/system/continuous-code-auditor-watchdog.service /etc/systemd/system/continuous-code-auditor-watchdog.timer
      systemctl daemon-reload 2>/dev/null || true
      echo "removed the watchdog's systemd unit files"
    fi
  fi
fi

if command -v crontab >/dev/null 2>&1; then
  if crontab -l 2>/dev/null | grep -qE "$SKILL_DIR/scripts/(run_auditor|watchdog)\.sh"; then
    ( crontab -l 2>/dev/null | grep -vE "$SKILL_DIR/scripts/(run_auditor|watchdog)\.sh" ) | crontab -
    echo "removed the cron entries for this installation (main auditor and watchdog)"
  fi
fi

for skills_dir_name in .claude/skills .gemini/skills .codex/skills .hermes/skills; do
  for base in "$HOME" "$PROJECT"; do
    candidate="$base/${skills_dir_name}/${SKILL_NAME}"
    if [[ -L "$candidate" || -e "$candidate" ]]; then
      rm -rf "$candidate"
      echo "removed $candidate"
    fi
  done
done

# Slash-command files installed by installer/install.sh. Without this, the
# eight /continuous-code-auditor-* commands stay visible in the CLI after an
# uninstall and fail when invoked, because the script they point at is gone.
removed_cmds=0
for cmd_dir in .claude/commands .gemini/commands; do
  for base in "$HOME" "$PROJECT"; do
    for f in "$base/${cmd_dir}/${SKILL_NAME}-"*; do
      if [[ -e "$f" ]]; then
        rm -f "$f"
        removed_cmds=$((removed_cmds + 1))
      fi
    done
  done
done
[[ "$removed_cmds" -gt 0 ]] && echo "removed $removed_cmds installed slash-command file(s)"

if [[ "$PURGE" == true ]]; then
  echo
  echo "-- --purge-data was given: removing audit data too --"
  rm -rf "$PROJECT/work" "$PROJECT/archives" "$PROJECT/backups" "$LOG_DIR"
  echo "removed $PROJECT/work, $PROJECT/archives, $PROJECT/backups, $LOG_DIR"
else
  echo
  echo "audit data left untouched: $PROJECT/work, $PROJECT/archives, $PROJECT/backups, $LOG_DIR"
  echo "(re-run with --purge-data to also remove these — irreversible, consider"
  echo " scripts/commands/backup-everything.sh first)"
fi

echo
echo "done. The skill package itself at $SKILL_DIR was not deleted — remove that"
echo "directory yourself if you're done with it entirely."
