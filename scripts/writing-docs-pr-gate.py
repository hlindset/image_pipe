#!/usr/bin/env python3
"""PreToolUse hook on Bash: refuses to publish a branch that changes
documentation until this session has run the writing-docs skill over it.

Runs on `but pr ... new <branch>`, `gh pr create`, `but push <branch>`, and
`git push <remote> <branch>`, so pushes after a pull request is open are
checked too. When the branch changes
documentation since it left origin/main, the session's transcript must hold the
skill's closing summary (Audience, Pass 1-4, and Review lines, each filled in),
written after the branch's documentation files last changed on disk.

For a false positive, the agent can instead write a line
`writing-docs exemption: <reason>` after those files changed. The command then
goes through, and a system message shows the operator the branch, the files,
and the reason.

Documentation is product markdown (under image_pipe*/, and the root README.md;
not plans, tests, benchmarks, generated docs, licenses, or priv/) and the
@moduledoc, @doc, and @typedoc text of lib/ modules.
"""

import json
import os
import re
import shlex
import subprocess
import sys
from datetime import datetime, timezone

SUMMARY = [r"Audience:", r"Pass 1:", r"Pass 2:", r"Pass 3:", r"Pass 4:", r"Review:"]
EXCLUDED = ("/docs/plans/", "/test/", "/deps/", "/_build/", "/doc/", "/bench/", "/priv/", "/native/")
DOC_ATTR = re.compile(r'^\s*@(?:moduledoc|doc|typedoc)\s+(?:~[sS])?("""|")')
HEREDOC_END = re.compile(r'^\s*"""')


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=False).stdout


def first_argument(words, takes_value=()):
    """The first positional word, skipping options and their values."""
    skip = False
    for token in words:
        if skip:
            skip = False
        elif token in takes_value:
            skip = True
        elif token in ("&&", ";", "|", "||"):
            break
        elif not token.startswith("-") and not re.search(r"[<>]", token):
            return token
    return None


def branch_of(command):
    """The branch a command publishes, '' when it publishes none, None when unknown."""
    try:
        words = shlex.split(command)
    except ValueError:
        return ""
    if {"-h", "--help"} & set(words):
        return ""
    for i, word in enumerate(words):
        if word == "but" and words[i + 1 : i + 2] == ["pr"]:
            rest = words[i + 2 :]
            if "new" not in rest:
                return ""
            return first_argument(rest[rest.index("new") + 1 :], ("-m", "--message", "-F", "--file"))
        if word == "but" and words[i + 1 : i + 2] == ["push"]:
            rest = words[i + 2 :]
            return "" if {"-d", "--dry-run"} & set(rest) else first_argument(rest)
        if word == "git" and words[i + 1 : i + 2] == ["push"]:
            rest = words[i + 2 :]
            remote = first_argument(rest)
            branch = first_argument(rest[rest.index(remote) + 1 :]) if remote else None
            return branch.split(":")[0].removeprefix("+") if branch else None
        if word == "gh" and words[i + 1 : i + 3] == ["pr", "create"]:
            rest = words[i + 3 :]
            if "--head" in rest:
                return rest[rest.index("--head") + 1]
            current = git("rev-parse", "--abbrev-ref", "HEAD").strip()
            return None if current.startswith("gitbutler/") else current
    return ""


def doc_ranges(text):
    """1-based (first, last) line ranges of doc attributes in Elixir source."""
    ranges, start = [], None
    for number, line in enumerate(text.splitlines(), 1):
        if start is not None:
            if HEREDOC_END.match(line):
                ranges.append((start, number))
                start = None
            continue
        match = DOC_ATTR.match(line)
        if match and match.group(1) == '"""':
            start = number
        elif match:
            ranges.append((number, number))
    return ranges


def docs_changed(base, branch):
    files = []
    for path in git("diff", "--name-only", base, branch).splitlines():
        rel = "/" + path
        if any(part in rel for part in EXCLUDED) or path.endswith("LICENSE.md"):
            continue
        if path == "README.md" or (path.startswith("image_pipe") and path.endswith(".md")):
            files.append(path)
        elif path.startswith("image_pipe") and "/lib/" in rel and path.endswith(".ex"):
            ranges = doc_ranges(git("show", f"{branch}:{path}"))
            for header in re.findall(r"^@@ .* \+(\d+)(?:,(\d+))? @@", git("diff", "-U0", base, branch, "--", path), re.M):
                first = int(header[0])
                last = first + max(int(header[1] or 1), 1) - 1
                if any(first <= end and last >= start for start, end in ranges):
                    files.append(path)
                    break
    return files


EXEMPTION = re.compile(r"^\W*writing-docs exemption:[ \t]*(\S.*)$", re.M | re.I)


def last_marks(transcript):
    """(time, None) of the latest complete summary and (time, reason) of the
    latest exemption the session's agent wrote, each None when absent."""
    summary, exemption = None, None
    try:
        lines = open(transcript, encoding="utf-8")
    except OSError:
        return None, None
    with lines:
        for line in lines:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if entry.get("type") != "assistant" or entry.get("isSidechain"):
                continue
            for part in (entry.get("message") or {}).get("content") or []:
                text = part.get("text", "") if isinstance(part, dict) else ""
                at = datetime.fromisoformat(entry["timestamp"].replace("Z", "+00:00"))
                if all(re.search(r"^\W*" + label + r"[ \t]*\S", text, re.M) for label in SUMMARY):
                    summary = at
                reason = EXEMPTION.search(text)
                if reason:
                    exemption = (at, reason.group(1).strip())
    return summary, exemption


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))


def main():
    data = json.load(sys.stdin)
    os.chdir(os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or ".")
    branch = branch_of((data.get("tool_input") or {}).get("command", ""))
    if branch == "":
        return
    if branch is None:
        deny("Name the branch by its full name, so its documentation changes can be checked.")
        return

    ref = branch if branch.startswith("refs/") else f"refs/heads/{branch}"
    if not git("rev-parse", "--verify", "--quiet", ref).strip():
        deny(f"No branch named {branch}. Name the branch by its full name, so its documentation changes can be checked.")
        return
    base = git("merge-base", "origin/main", ref).strip()
    files = docs_changed(base, ref)
    if not files:
        return

    summary, exemption = last_marks(data.get("transcript_path", ""))
    changed = max(
        (datetime.fromtimestamp(os.path.getmtime(f), timezone.utc) for f in files if os.path.exists(f)),
        default=None,
    )
    fresh = lambda at: at is not None and (changed is None or at >= changed)
    if fresh(summary):
        return
    if exemption and fresh(exemption[0]):
        print(json.dumps({
            "systemMessage": (
                f"writing-docs gate: {branch} was published without the writing-docs process. "
                f"Agent's reason: {exemption[1]} Files: {', '.join(files)}."
            )
        }))
        return

    stale = " Those files changed after this session's last summary." if summary else ""
    deny(
        f"{branch} changes public docs ({', '.join(files)}).{stale} Remember to use the full "
        "/writing-docs process for public docs changes, ending with its closing summary "
        "in your message text (a summary inside a tool call or a file doesn't count), "
        "then run this command again. If these files aren't public docs, write a line "
        "`writing-docs exemption: <reason>` instead. The operator sees that reason."
    )


if __name__ == "__main__":
    main()
