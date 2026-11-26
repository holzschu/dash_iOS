#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cp "$repo/build_dash.sh" "$work/"
mkdir "$work/first" "$work/later"

version_tool() {
    printf '#!/bin/bash\nprintf "%%s\\n" "ncurses %s"\n' "$2" > "$1"
    chmod +x "$1"
}

for tool in tic infocmp; do
    version_tool "$work/later/$tool" 6.6.20251230
done

# No downloads should be attempted during host validation.
printf '#!/bin/bash\necho "unexpected fetch" >&2\nexit 77\n' > "$work/later/curl"
chmod +x "$work/later/curl"

reject() {
    local search_path=$1 diagnostic=$2 status=0
    PATH="$search_path" /bin/bash "$work/build_dash.sh" > "$work/check.log" 2>&1 || status=$?
    if [[ $status != 1 || -e $work/.build ]] || ! grep -Fq "$diagnostic" "$work/check.log"; then
        printf 'FAIL: expected exit 1 before build setup and diagnostic: %s\n' "$diagnostic" >&2
        tail -20 "$work/check.log" >&2
        return 1
    fi
}

reject "$work/missing" 'ncurses 6.6 host tool tic was not found in PATH.'
version_tool "$work/first/tic" 6.60.20251230
reject "$work/first:$work/later:$PATH" 'Expected ncurses 6.6 from tic'
version_tool "$work/first/tic" 6.6.20251230
reject "$work/first" 'ncurses 6.6 host tool infocmp was not found in PATH.'
version_tool "$work/first/infocmp" 6.5.20251230
reject "$work/first:$work/later:$PATH" 'Expected ncurses 6.6 from infocmp'
printf '%s\n' 'PASS: host ncurses preflight rejects missing tic or infocmp, lookalike, and mismatched PATH tools before build setup'
