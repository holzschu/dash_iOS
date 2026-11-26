#!/bin/bash
set -euo pipefail
export LC_ALL=C

ncurses_host_tool() {
    local tool=$1 path version
    if ! path=$(type -P "$tool"); then
        printf 'ncurses 6.6 host tool %s was not found in PATH.\n' "$tool" >&2
        return 1
    fi
    [[ $path = /* ]] || path="$PWD/$path"
    if ! version=$("$path" -V 2>&1); then
        printf 'Could not read the ncurses version from %s: %s\n' "$path" "$version" >&2
        return 1
    fi
    if [[ ! $version =~ ^ncurses[[:blank:]]+6\.6(\.[0-9]+)?$ ]]; then
        printf 'Expected ncurses 6.6 from %s (%s), got "%s". Put the 6.6 host tools first in PATH.\n' \
            "$tool" "$path" "$version" >&2
        return 1
    fi
    printf '%s\n' "$path"
}

tic=$(ncurses_host_tool tic)
infocmp=$(ncurses_host_tool infocmp)
command -v jq >/dev/null || { echo 'jq is required to audit the XCFramework plists.' >&2; exit 1; }
repo=$(cd "$(dirname "$0")" && pwd)
work="$repo/.build/dash-xcframeworks"
inputs="$work/inputs"
ios_system=f187d27373865977db4705b38d3a35eec13415ec
mkdir -p "$inputs"

fetch() {
    local url=$1 sha=$2 path="$inputs/$3"
    if [[ ! -f $path ]]; then
        curl -fLsS --retry 3 "$url" -o "$path.part"
        printf '%s  %s\n' "$sha" "$path.part" | shasum -a 256 -c -
        mv "$path.part" "$path"
    fi
    printf '%s  %s\n' "$sha" "$path" | shasum -a 256 -c -
}

# The released ios_system framework does not export Dash's owned-stream API.
fetch "https://codeload.github.com/holzschu/ios_system/tar.gz/$ios_system" a7b8881369549973ae46bd362702b92980abafdbd2537befa3c339b94029d38b ios_system.tar.gz
fetch https://thrysoee.dk/editline/libedit-20260512-3.1.tar.gz 432d5e7ea8b0116dd39f2eca7bc11d0eed77faa6b77ea526ace89907c23ea4a0 libedit.tar.gz
fetch https://ftp.gnu.org/gnu/ncurses/ncurses-6.6.tar.gz 355b4cbbed880b0381a04c46617b7656e362585d52e9cf84a67e2009b749ff11 ncurses.tar.gz
fetch https://ftp.gnu.org/gnu/automake/automake-1.19.tar.xz e3e2c2e3abf37898138db5b6c1d1dc35c9160c5978be7947d2c741705251d445 automake.tar.xz

stage=$work
# Autotools splits source paths and flags when the checkout contains whitespace.
if [[ $work == *[[:space:]]* ]]; then
    stage=$(mktemp -d /tmp/dash-xcframeworks.XXXXXX)
    trap 'rm -rf "$stage"' EXIT
fi
src="$stage/source"
for dir in "$src" "$stage/slices" "$work/dist"; do
    rm -rf "$dir"
    mkdir -p "$dir"
done
for dependency in ios_system libedit ncurses automake; do
    mkdir -p "$src/$dependency"
    if [[ $dependency == automake ]]; then
        tar -xJf "$inputs/$dependency.tar.xz" --strip-components 1 -C "$src/$dependency"
    else
        tar -xzf "$inputs/$dependency.tar.gz" --strip-components 1 -C "$src/$dependency"
    fi
done
patch -F 0 -p1 -d "$src/libedit" < "$repo/libedit-socket.patch"
mkdir "$src/dash"
cp -R "$repo"/{src,COPYING,ChangeLog,ChangeLog.O,Makefile.in,Makefile.am,aclocal.m4,config.h.in,configure,configure.ac,histedit.h,ios_error.h} "$src/dash/"
cp "$src/automake/lib/"{compile,depcomp,install-sh,missing} "$src/dash/"
# Use the checkout's generated Autotools files without regenerating them.
find "$src/dash" -type f -exec touch -t 202001010000 {} +

host=$(sh "$src/ncurses/config.guess")
host_sdk=$(xcrun --sdk macosx --show-sdk-path)
namespace='-Dtgetent=dash_tgetent -Dtgetflag=dash_tgetflag -Dtgetnum=dash_tgetnum -Dtgetstr=dash_tgetstr -Dtgoto=dash_tgoto -Dtputs=dash_tputs'

build_slice() (
    local sdk=$1 arch=$2 out=$3
    local target="$arch-apple-ios15.0" sysroot flags settings tinfo edit core
    if [[ $sdk == iphonesimulator ]]; then target+=-simulator; fi
    sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
    flags="-target $target -isysroot $sysroot"
    tinfo="$out/tinfo"
    edit="$out/libedit"
    core="$out/core"
    mkdir -p "$tinfo" "$edit" "$core" "$out/dash"
    xcodebuild -project "$src/ios_system/ios_system.xcodeproj" -target ios_system -configuration Release \
        -sdk "$sdk" -arch "$arch" -jobs 2 CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=15.0 \
        CONFIGURATION_BUILD_DIR="$core" OBJROOT="$core/objects" SYMROOT="$core/products"
    (
        cd "$tinfo"
        "$src/ncurses/configure" --build="$host" --host="$arch-apple-darwin" \
            --with-build-cc=clang --with-termlib --with-ospeed=speed_t --disable-widec --disable-mixed-case \
            --disable-database --with-fallbacks=xterm-256color,xterm,vt100 \
            --with-tic-path="$tic" --with-infocmp-path="$infocmp" \
            --without-shared --without-debug --without-ada --without-cxx --without-cxx-binding \
            --without-manpages --without-progs --without-tests --disable-db-install \
            CC=clang CFLAGS="$flags -O2 $namespace" CPPFLAGS="$flags" LDFLAGS="$flags" LIBS=
        make -C include -j4
        make -C ncurses -j4 ../lib/libtinfo.a
    )
    (
        cd "$edit"
        ac_cv_lib_ncurses_tgetent=no ac_cv_lib_curses_tgetent=no ac_cv_lib_termcap_tgetent=no ac_cv_lib_tinfo_tgetent=yes \
            "$src/libedit/configure" --build="$host" --host="$arch-apple-darwin" \
            --disable-shared --enable-static --disable-examples CC=clang CFLAGS="$flags -O2" \
            CPPFLAGS="$flags -I$tinfo/include $namespace" LDFLAGS="$flags -L$tinfo/lib" LIBS=
        make -C src -j4
    )
    cd "$out/dash"
    settings="$flags -DJOBS=0 -Dstat64=stat -Dlstat64=lstat -Dfstat64=fstat -DUSE_GLIBC_STDIO=1 -DFLUSHERR=1 -I$src/dash"
    ac_cv_func_strchrnul=no "$src/dash/configure" --build="$host" --host="$arch-apple-darwin" cross_compiling=yes \
        --with-libedit CC=clang CXX=clang++ CC_FOR_BUILD="clang -isysroot $host_sdk -DJOBS=0" \
        CFLAGS="-std=gnu17 $settings" CPPFLAGS="$settings" CXXFLAGS="$settings" \
        LDFLAGS="$flags -dynamiclib -F$core -framework ios_system -L$edit/src/.libs" \
        LIBS="-Wl,-load_hidden,$edit/src/.libs/libedit.a -Wl,-load_hidden,$tinfo/lib/libtinfo.a"
    make -j4
)

for target in iphoneos:arm64 iphonesimulator:arm64 iphonesimulator:x86_64; do
    sdk=${target%:*}
    arch=${target#*:}
    log="$work/$sdk-$arch.log"
    printf 'Building %s/%s\n' "$sdk" "$arch"
    set +e
    (set -e; build_slice "$sdk" "$arch" "$stage/slices/$sdk-$arch") > "$log" 2>&1
    status=$?
    set -e
    if (( status != 0 )); then
        tail -80 "$log" >&2
        exit "$status"
    fi
done

out="$work/dist"
for name in dash dashA dashB dashC dashD dashE; do
    device="$stage/slices/Release-iphoneos/$name.framework"
    simulator="$stage/slices/Release-iphonesimulator/$name.framework"
    mkdir -p "$device" "$simulator"
    cp "$stage/slices/iphoneos-arm64/dash/src/dash" "$device/$name"
    xcrun lipo -create "$stage/slices/iphonesimulator-arm64/dash/src/dash" \
        "$stage/slices/iphonesimulator-x86_64/dash/src/dash" -output "$simulator/$name"
    cp "$repo/basic_Info.plist" "$device/Info.plist"
    cp "$repo/basic_Info_Simulator.plist" "$simulator/Info.plist"
    # The Simulator framework must not declare an arm64-only capability.
    plutil -remove UIRequiredDeviceCapabilities "$simulator/Info.plist"
    for framework in "$device" "$simulator"; do
        plutil -replace CFBundleExecutable -string "$name" "$framework/Info.plist"
        plutil -replace CFBundleName -string "$name" "$framework/Info.plist"
        plutil -replace CFBundleIdentifier -string "Nicolas-Holzschuch.$name" "$framework/Info.plist"
        xcrun install_name_tool -id "@rpath/$name.framework/$name" "$framework/$name"
    done
    xcodebuild -create-xcframework -framework "$device" -framework "$simulator" -output "$out/$name.xcframework"
    (cd "$out" && zip -qry "$name.xcframework.zip" "$name.xcframework")
    printf '%s  %s\n' "$(swift package compute-checksum "$out/$name.xcframework.zip")" "$name.xcframework.zip" >> "$out/checksums.txt"
done
sh "$repo/tests/strchrnul-availability.sh" "$stage/slices"
sh "$repo/tests/frameworks.sh" "$out" | tee "$out/frameworks-audit.txt"
sh "$repo/tests/frameworks-negative.sh" "$out" | tee -a "$out/frameworks-audit.txt"
if [[ $stage != "$work" ]]; then
    rm -rf "$work/slices"
    mv "$stage/slices" "$work/"
fi
