#!/bin/sh
# Check the public ZIP audit with intact binaries and invalid selection metadata.
set -eu

packages=${1:?usage: sh tests/frameworks-negative.sh PACKAGE_DIRECTORY}
audit=$(cd "$(dirname "$0")" && pwd)/frameworks.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/dash-frameworks-negative.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$packages/"*.xcframework.zip "$work/"
(
	cd "$work"
	unzip -q dash.xcframework.zip
	plist=dash.xcframework/Info.plist
	index=$(plutil -extract AvailableLibraries json -o - "$plist" |
		jq -er 'map(.SupportedPlatformVariant == "simulator") | index(true)')
	plutil -remove "AvailableLibraries.$index.SupportedPlatformVariant" "$plist"
	zip -q dash.xcframework.zip "$plist"
)
status=0
sh "$audit" "$work" > "$work/audit.log" 2>&1 || status=$?
if [ "$status" -ne 1 ] || ! grep -Fq 'unexpected AvailableLibraries' "$work/audit.log"; then
	tail -30 "$work/audit.log" >&2
	echo 'The ZIP audit did not reject the invalid Simulator variant.' >&2
	exit 1
fi
printf '%s\n' 'PASS: ZIP audit rejected invalid Simulator metadata'
