#! /bin/sh
set -eu

packages=${1:-.}
work=$(mktemp -d "${TMPDIR:-/tmp}/dash-frameworks.XXXXXX")
trap 'rm -rf "$work"' EXIT

fail() {
	echo "$binary: $*" >&2
	exit 1
}

for name in dash dashA dashB dashC dashD dashE; do
	zip="$packages/$name.xcframework.zip"
	unzip -q "$zip" -d "$work"
	swift package compute-checksum "$zip"

	for slice in ios-arm64 ios-x86_64-simulator; do
		case "$slice" in
			ios-arm64) arch=arm64; platform=IOS ;;
			ios-x86_64-simulator) arch=x86_64; platform=IOSSIMULATOR ;;
		esac
		binary="$work/$name.xcframework/$slice/$name.framework/$name"
		[ "$(xcrun lipo -archs "$binary")" = "$arch" ] || fail "expected $arch"
		xcrun vtool -show-build "$binary" > "$work/platform"
		grep -Eq "^[[:space:]]*platform $platform$" "$work/platform" || fail "expected $platform"
		grep -Eq '^[[:space:]]*minos 15\.0$' "$work/platform" || fail "expected deployment target 15.0"

		xcrun otool -L "$binary" > "$work/libraries"
		xcrun otool -D "$binary" > "$work/install-name"
		grep -Fxq "@rpath/$name.framework/$name" "$work/install-name" || fail "wrong install name"
		grep -Fq '@rpath/ios_system.framework/ios_system' "$work/libraries" || fail "missing ios_system dependency"
		if grep -Eq 'lib(ncurses|curses|termcap|tinfo|edit)[.0-9w]' "$work/libraries"; then
			fail "dynamic terminal or editor library"
		fi
		xcrun nm -um "$binary" > "$work/imports"
		xcrun nm -m "$binary" > "$work/symbols"
		xcrun dyld_info -exports "$binary" > "$work/exports"
		xcrun nm -u "$binary" > "$work/undefined"
		for symbol in tgetent tgetflag tgetnum tgetstr tgoto tputs strchrnul; do
			if grep -Eq "(^|[[:space:]])_${symbol}([[:space:]]|$)" "$work/undefined"; then
				fail "imports _$symbol"
			fi
		done
		for symbol in tgetent tgetflag tgetnum tgetstr tgoto tputs; do
			if grep -Eq "[[:space:]]_${symbol}([[:space:]]|$)" "$work/symbols"; then
				fail "contains unnamespaced _$symbol"
			fi
		done
		for symbol in dash_tgetent dash_tgetflag dash_tgetnum dash_tgetstr dash_tgoto dash_tputs cur_term el_cursor; do
			if grep -Eq "[[:space:]]_${symbol}([[:space:]]|$)" "$work/imports" "$work/exports"; then
				fail "_$symbol crosses the image boundary"
			fi
			grep -Eq "\\([^)]*\\) (non-external|private external).* _${symbol}$" "$work/symbols" ||
				fail "_$symbol has no private definition"
		done
		grep -Eq '[[:space:]]_main$' "$work/exports" || fail "missing Dash entry point"
		printf '%s %s: PASS\n' "$name" "$slice"
	done
done
