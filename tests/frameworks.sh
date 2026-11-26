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
	xcframework="$work/$name.xcframework"
	binary="$zip"
	unzip -q "$zip" -d "$work"
	swift package compute-checksum "$zip"
	plutil -extract AvailableLibraries json -o - "$xcframework/Info.plist" > "$work/libraries.json" ||
		fail "cannot read AvailableLibraries"
	jq -e --arg name "$name" '
		map([.LibraryIdentifier, .SupportedPlatform, .SupportedPlatformVariant,
		    (.SupportedArchitectures | sort), .LibraryPath, .BinaryPath]) | sort ==
		[
		  ["ios-arm64", "ios", null, ["arm64"], ($name + ".framework"), ($name + ".framework/" + $name)],
		  ["ios-arm64_x86_64-simulator", "ios", "simulator", ["arm64", "x86_64"],
		   ($name + ".framework"), ($name + ".framework/" + $name)]
		]' "$work/libraries.json" >/dev/null || fail "unexpected AvailableLibraries"

	for slice in ios-arm64 ios-arm64_x86_64-simulator; do
		case "$slice" in
			ios-arm64) arches=arm64; platform=IOS; supported=iPhoneOS ;;
			ios-arm64_x86_64-simulator) arches='arm64 x86_64'; platform=IOSSIMULATOR; supported=iPhoneSimulator ;;
		esac
		framework="$xcframework/$slice/$name.framework"
		binary="$framework/$name"
		plutil -convert json -o - "$framework/Info.plist" > "$work/framework.json" ||
			fail "cannot read framework Info.plist"
		jq -e --arg name "$name" --arg platform "$supported" '
			.CFBundleExecutable == $name and .CFBundlePackageType == "FMWK" and
			.CFBundleIdentifier == ("Nicolas-Holzschuch." + $name) and
			.CFBundleSupportedPlatforms == [$platform] and .MinimumOSVersion == "15.0" and
			($platform != "iPhoneSimulator" or (has("UIRequiredDeviceCapabilities") | not))
		' "$work/framework.json" >/dev/null || fail "unexpected framework Info.plist"
		actual=$(xcrun lipo -archs "$binary")
		if [ "$arches" = arm64 ]; then
			[ "$actual" = arm64 ] || fail "expected a thin device binary"
		else
			[ "$actual" = 'arm64 x86_64' ] || [ "$actual" = 'x86_64 arm64' ] || fail "expected only arm64 and x86_64"
		fi
		for arch in $arches; do
			if [ "$slice" = ios-arm64_x86_64-simulator ]; then
				xcrun lipo -thin "$arch" "$binary" -output "$work/thin"
				image="$work/thin"
			else
				image="$binary"
			fi
			xcrun vtool -show-build "$image" > "$work/platform"
			grep -Eq "^[[:space:]]*platform $platform$" "$work/platform" || fail "expected $platform for $arch"
			grep -Eq '^[[:space:]]*minos 15\.0$' "$work/platform" || fail "expected deployment target 15.0"

			xcrun otool -L "$image" > "$work/libraries"
			xcrun otool -D "$image" > "$work/install-name"
			grep -Fxq "@rpath/$name.framework/$name" "$work/install-name" || fail "wrong install name"
			grep -Fq '@rpath/ios_system.framework/ios_system' "$work/libraries" || fail "missing ios_system dependency"
			if grep -Eq 'lib(ncurses|curses|termcap|tinfo|edit)[.0-9w]' "$work/libraries"; then
				fail "dynamic terminal or editor library"
			fi
			xcrun nm -um "$image" > "$work/imports"
			xcrun nm -m "$image" > "$work/symbols"
			xcrun dyld_info -exports "$image" > "$work/exports"
			xcrun nm -u "$image" > "$work/undefined"
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
			printf '%s %s %s: PASS\n' "$name" "$slice" "$arch"
		done
	done
done
