#!/usr/bin/env bash
# PostToolUse hook for Edit and Write: when the edited file is documentation
# (as scripts/docs-final-read.sh defines it), reminds the agent that the edit is
# docs writing and reports `;` and `—` in that file's added prose.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
file="$(python3 -c 'import json, sys; i = json.load(sys.stdin).get("tool_input", {}); print(i.get("file_path", ""))')"

[ -n "$file" ] || exit 0
"$root/scripts/docs-final-read.sh" --touches-docs "$file" || exit 0

relative="${file#"$root"/}"
violations="$("$root/scripts/docs-final-read.sh" --no-links "$file" | sed -n '/^Pass 4/,$p' | tail -n +2)"

message="Docs edit: $relative. This is docs writing, so the writing-docs skill applies \
(.agents/skills/writing-docs/SKILL.md): load it if this session hasn't, and read style.md, \
audiences.md, and the reference for the page's kind. Before finishing: run \
scripts/docs-final-read.sh and paste its output into the closing summary, do passes 2 and 3 \
with the evidence the summary template asks for, and get a fresh review.
Pass 4 for this file:
$violations"

MESSAGE="$message" python3 -c '
import json, os
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": os.environ["MESSAGE"]}}))'
