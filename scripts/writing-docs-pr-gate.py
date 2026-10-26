#!/usr/bin/env python3
"""PreToolUse hook on Bash: refuses to publish a branch that changes
documentation until this session has run the writing-docs skill over it.

Runs on `but pr ... new <branch>`, `gh pr create`, `but push <branch>`, and
`git push <remote> <branch>`, so pushes after a pull request is open are
checked too. When the branch changes
documentation since it left origin/main, the session's transcript must show the
steps of the skill that leave a record:

  - the skill's references/style.md and references/audiences.md were read
    (a Read call, or a Bash command naming them);
  - a review ran after this session first edited those files (an Agent call
    whose prompt names review.md). Fixing what it reports doesn't call for
    another. When the session never edited them, the review must come after
    they last changed on disk;
  - the closing summary (Audience, Pass 1-4, and Review lines, each filled in)
    was written in message text after that review and after the session last
    edited those files, so it covers the fixes. A rebase that rewrites them
    with the same content doesn't count as an edit.

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
# The closing summary from the skill's SKILL.md, shown when the summary is missing.
SUMMARY_TEMPLATE = """\
Audience: <audience>   Kind: <kind>
Pass 1: <what the headings read like as a table of contents, or "no headings changed">
Pass 2: <each setting, option, or term the change introduces, and where it is explained or linked>
Pass 3: <each paragraph you shortened, or why none could be shorter>
Pass 4: <each `;` or `—` you rewrote, or "none in the changed text">
Review: <findings, and what you fixed>
Left alone: <existing problems on the page outside your change>
Filed: <beads issues for code problems found, or none>"""
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
REFERENCES = ("style.md", "audiences.md")


class Marks:
    """What the session did, from its transcript: when its own agent last wrote a
    summary, an exemption (with its reason), and started a review, which skill
    references it read, and when the session first and last changed one of
    `files`. A rebase that leaves a file's content alone isn't a change."""

    def __init__(self):
        self.summary = self.exemption = self.review = self.first_edit = self.last_edit = None
        self.read = set()


def changed_paths(result):
    """Files a tool result says it changed: an Edit or Write, or a Bash command
    whose changes Claude Code recorded."""
    if not isinstance(result, dict):
        return []
    diff = result.get("bashEditDiff") or {}
    return [result.get("filePath") or "", *diff.get("changedFiles", [])]


def last_marks(transcript, files=()):
    marks = Marks()
    try:
        lines = open(transcript, encoding="utf-8")
    except OSError:
        return marks
    with lines:
        for line in lines:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if entry.get("type") == "user":
                paths = changed_paths(entry.get("toolUseResult"))
                if any(path.endswith("/" + f) for path in paths if path for f in files):
                    marks.last_edit = datetime.fromisoformat(entry["timestamp"].replace("Z", "+00:00"))
                    marks.first_edit = marks.first_edit or marks.last_edit
            if entry.get("type") != "assistant" or entry.get("isSidechain"):
                continue
            at = datetime.fromisoformat(entry["timestamp"].replace("Z", "+00:00"))
            for part in (entry.get("message") or {}).get("content") or []:
                if not isinstance(part, dict):
                    continue
                if part.get("type") == "tool_use":
                    tool, given = part.get("name"), json.dumps(part.get("input") or {})
                    if tool in ("Agent", "Task") and "review.md" in given:
                        marks.review = at
                    elif tool in ("Read", "Bash"):
                        marks.read |= {name for name in REFERENCES if name in given}
                    continue
                text = part.get("text", "")
                if all(re.search(r"^\W*" + label + r"[ \t]*\S", text, re.M) for label in SUMMARY):
                    marks.summary = at
                reason = EXEMPTION.search(text)
                if reason:
                    marks.exemption = (at, reason.group(1).strip())
    return marks


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

    marks = last_marks(data.get("transcript_path", ""), files)
    # The session's own last edit, so a rebase that rewrites the files with the
    # same content doesn't count. A branch the session never edited falls back
    # to when the files last changed on disk.
    changed = marks.last_edit or max(
        (datetime.fromtimestamp(os.path.getmtime(f), timezone.utc) for f in files if os.path.exists(f)),
        default=None,
    )
    fresh = lambda at: at is not None and (changed is None or at >= changed)
    # One review per round of work: it must see the session's edits, and fixes
    # made after it are covered by the summary instead of another review.
    anchor = marks.first_edit or changed
    reviewed = marks.review is not None and (anchor is None or marks.review >= anchor)
    when = "after this session first edited them" if marks.first_edit else "after they last changed"
    summarized = fresh(marks.summary) and reviewed and marks.summary >= marks.review
    missing = [
        *(f"read references/{name}" for name in REFERENCES if name not in marks.read),
        *([] if reviewed else [f"a review (an Agent call naming review.md) {when}"]),
        *([] if summarized
           else ["the closing summary in your message text after that review and after the last docs change"]),
    ]
    if not missing:
        return
    exemption = marks.exemption
    if exemption and fresh(exemption[0]):
        print(json.dumps({
            "systemMessage": (
                f"writing-docs gate: {branch} was published without the writing-docs process. "
                f"Agent's reason: {exemption[1]} Files: {', '.join(files)}."
            )
        }))
        return

    deny(
        f"{branch} changes public docs ({', '.join(files)}). Remember to use the full "
        "/writing-docs process for public docs changes. Not done yet in this session: "
        + "; ".join(missing)
        + ". The summary counts only as visible text in a message you've already sent, "
        "not in your reasoning, a tool call, or a file. "
        + ("" if summarized else "Write each of its lines, filled in with evidence:\n" + SUMMARY_TEMPLATE + "\n")
        + "Then run this command again. "
        "If these files aren't public docs, write a line "
        "`writing-docs exemption: <reason>` instead. The operator sees that reason."
    )


if __name__ == "__main__":
    main()
