#!/usr/bin/env bash
# Runs the mechanical passes of the writing-docs final read on documentation
# changed since a base ref, and fails on a violation. The base defaults to
# where HEAD left origin/main, so commits on main since then don't count.
#
# Documentation is product markdown (docs, READMEs, changelogs, not
# docs/plans/ or test fixtures) and the @moduledoc and @doc text in lib/.
# Only lines added since the base are checked, so existing text never fails.
#
#   Pass 1: for a page whose headings changed, prints its headings in order,
#           marking the added ones with +, to read on their own.
#   Pass 4: flags `;` and `—` outside code blocks and inline code.
#   Links:  runs `mix docs` in image_pipe/ and fails on its warnings.
#
# Usage: docs-final-read.sh [--base REF] [--no-links] [FILE...]
#
# Without FILEs, checks every documentation file changed since the base,
# committed or not.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

base=""
links=true
files=()

while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    --no-links) links=false; shift ;;
    *) files+=("${1#"$root"/}"); shift ;;
  esac
done

[ -n "$base" ] || base="$(git merge-base origin/main HEAD)"

doc_file() {
  case "$1" in
    */docs/plans/* | */test/* | */deps/* | */_build/* | */node_modules/*) return 1 ;;
    image_pipe*/*.md) return 0 ;;
    image_pipe*/lib/*.ex) return 0 ;;
    *) return 1 ;;
  esac
}

# Line numbers added since the base, one per line. An untracked file is all new.
added_lines() {
  if ! git ls-files --error-unmatch "$1" > /dev/null 2>&1; then
    awk '{ print NR }' "$1"
    return
  fi

  git diff -U0 --no-color "$base" -- "$1" |
    awk '/^@@ / {
      split($3, range, ",")
      start = substr(range[1], 2)
      count = (2 in range) ? range[2] : 1
      for (i = 0; i < count; i++) print start + i
    }'
}

# Prints `file:line: text` for each added documentation line outside code
# blocks. In an .ex file that is the text of @moduledoc and @doc heredocs.
doc_added_lines() {
  local file="$1" kind="md"
  case "$file" in *.ex) kind="ex" ;; esac

  added_lines "$file" |
    awk -v file="$file" -v kind="$kind" '
      NR == FNR { added[$1] = 1; next }
      {
        if (kind == "ex") {
          if (!indoc && $0 ~ /^[ \t]*@(moduledoc|doc)[ \t]+(~[sS])?"""/) { indoc = 1; next }
          if (indoc && $0 ~ /^[ \t]*"""/) { indoc = 0; fence = 0; next }
          if (!indoc) next
          # Indented code inside a doc heredoc.
          if ($0 ~ /^[ \t]{6,}[^ \t|*-]/) next
        }
        if ($0 ~ /^[ \t]*(```|~~~)/) { fence = !fence; next }
        if (!fence && (FNR in added)) printf "%s:%d: %s\n", file, FNR, $0
      }
    ' - "$file"
}

# Added documentation lines with `;` or `—` outside inline code and HTML entities.
pass4() {
  doc_added_lines "$1" |
    awk '{
      text = $0
      sub(/^[^:]*:[0-9]+: /, "", text)
      gsub(/`[^`]*`/, "", text)
      gsub(/&[#a-zA-Z0-9]+;/, "", text)
      if (text ~ /;|—/) print
    }'
}

if [ ${#files[@]} -eq 0 ]; then
  while IFS= read -r file; do
    doc_file "$file" && [ -f "$file" ] && files+=("$file")
  done < <({ git diff --name-only "$base"; git ls-files --others --exclude-standard; } | sort -u)
fi

failed=false

echo "Pass 1: headings of pages whose headings changed"
headings_changed=0
for file in ${files[@]+"${files[@]}"}; do
  case "$file" in *.md) ;; *) continue ;; esac
  outline="$(added_lines "$file" |
    awk 'NR == FNR { added[$1] = 1; next }
      /^[ \t]*(```|~~~)/ { fence = !fence; next }
      !fence && /^#{1,6} / { printf "    %s %s\n", (FNR in added) ? "+" : " ", $0; if (FNR in added) changed = 1 }
      END { exit !changed }' - "$file")" || continue
  headings_changed=$((headings_changed + 1))
  echo "  $file"
  printf '%s\n' "$outline"
done
[ "$headings_changed" -gt 0 ] || echo "  no headings changed"

echo "Pass 4: \`;\` and \`—\` in added prose"
violations=""
for file in ${files[@]+"${files[@]}"}; do
  violations+="$(pass4 "$file")"$'\n'
done
violations="$(printf '%s' "$violations" | sed '/^$/d')"
if [ -n "$violations" ]; then
  printf '%s\n' "$violations" | sed 's/^/  /'
  failed=true
else
  echo "  0 found in ${#files[@]} file(s)"
fi

if $links; then
  echo "Links: mix docs"
  warnings="$(cd image_pipe && mix docs 2>&1 | grep -iE 'warning' || true)"
  if [ -n "$warnings" ]; then
    printf '%s\n' "$warnings" | sed 's/^/  /'
    failed=true
  else
    echo "  no warnings"
  fi
fi

if $failed; then exit 1; fi
