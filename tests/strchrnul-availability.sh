#!/bin/sh
# Run against the build/ directory staged by build_dash.sh on macOS.
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: sh $0 BUILD_DIRECTORY" >&2
    exit 2
fi

failed=0
for platform in iphoneos iphonesimulator; do
    for slot in dash dashA dashB dashC dashD dashE; do
        binary="$1/Release-$platform/$slot.framework/$slot"
        imports=$(xcrun nm -arch all -u "$binary") || exit 2
        if printf '%s\n' "$imports" | grep -Eq '(^|[[:space:]])_strchrnul$'; then
            printf 'FAIL %s/%s: imports strchrnul (requires iOS 18.4)\n' "$platform" "$slot" >&2
            failed=1
        else
            printf 'PASS %s/%s\n' "$platform" "$slot"
        fi
    done
done
exit "$failed"
