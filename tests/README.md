# Native pipeline regressions

`pipelines.m` runs the real Dash entry through the public ios_system command boundary. It registers a native first-line reader, creates its executable PATH marker and captures caller-owned output. The root and pipeline commands use detached ios_system dispatch and the caller waits for final cleanup. Each case runs in a fresh process, as the stock interpreter loader resets each library between invocations. An alarm bounds hangs at five seconds.

Use an arm64 Simulator ios_system framework with the caller-owned command-tree API from holzschu/ios_system#181. Build Dash with its stock autotools route; the following commands exercise noninteractive evaluation without libedit. They use a disposable build directory so generated files stay out of the source tree:

```sh
mkdir -p .build/dash .build/probe/Frameworks
cp -R "$IOS_SYSTEM_FRAMEWORK_ROOT/ios_system.framework" .build/probe/Frameworks/
rsync -a --exclude .git --exclude .build --exclude tests --exclude '*.zip' ./ .build/dash/
source_root="$PWD"
simulator_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
host_sdk=$(xcrun --sdk macosx --show-sdk-path)
```

Run the configure/build commands from `.build/dash`:

```sh
autoreconf -fi
flags="-std=gnu11 -target arm64-apple-ios15.0-simulator -isysroot $simulator_sdk -DJOBS=0 -Dstat64=stat -Dlstat64=lstat -Dfstat64=fstat -DUSE_GLIBC_STDIO=1 -DFLUSHERR=1 -I$PWD"
./configure CC=clang CXX=clang++ CC_FOR_BUILD="clang -std=gnu11 -isysroot $host_sdk -DJOBS=0" CFLAGS="$flags" CPPFLAGS="$flags" CXXFLAGS="$flags" LDFLAGS="-target arm64-apple-ios15.0-simulator -isysroot $simulator_sdk -dynamiclib -F$source_root/.build/probe/Frameworks -framework ios_system" --build=x86_64-apple-darwin --host=armv8-apple-darwin cross_compiling=yes
make -j2
```

Return to the repository root, copy the prerequisite's `Resources/commandDictionary.plist` beside the probe executable, then compile and run:

```sh
xcrun --sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -isysroot "$simulator_sdk" -fobjc-arc -Wall -Wextra -Wno-unused-parameter -F .build/probe/Frameworks -framework ios_system -framework Foundation -Wl,-rpath,@executable_path/Frameworks -Wl,-export_dynamic tests/pipelines.m -o .build/probe/pipelines
for scenario in group early-reader heredoc subshell-next subshell-status wasm-producer-eof wasm-producer-fails wasm-consumer-skips; do
    xcrun simctl spawn "$SIMULATOR_UDID" "$PWD/.build/probe/pipelines" "$PWD/.build/dash/src/dash" "$scenario"
done
```

The baseline leaks a grouped producer's second line into the caller output, times out after an infinite builtin producer loses its reader, and exits the enclosing shell after `(exit 7)` instead of running the next command. The patched results are `group: status=0 bytes=4`, `early-reader: status=0 bytes=2`, `heredoc: status=0 bytes=4`, `subshell-next: status=0 bytes=5`, and `subshell-status: status=7 bytes=0`, `wasm-producer-eof: status=0 bytes=5`, `wasm-producer-fails: status=0 bytes=7` and `wasm-consumer-skips: status=0 bytes=5`, each with `PASS`. The same executable tests both libraries. These checks do not qualify interactive libedit hooks or physical-device behavior.

The `wasm-*` cases register a stand-in `wasm` command that stacks its call and blocks, as a-Shell does, until the caller's wait runs the stack, producer first. `wasm-producer-eof` runs `wasm emit | wasm drain`: the consumer prints the number of bytes it read, `4096`, so the output is `4096` and a newline (5 bytes). Without ios_system owning a simple external producer's pipe in `eval_pipeline_producer`, the producer's write end stays open, the consumer never sees EOF and the alarm fires. `wasm-producer-fails` (`wasm fail | wasm drain; printf next`) and `wasm-consumer-skips` (a consumer that exits without reading, so the producer writes into a closed pipe) check that the enclosing shell survives and runs the next command.

# Input lifetime

`input-lifetime.m` runs Dash through the public ios_system entry with real caller-owned input/output/error streams. The `borrowed` case runs a command string; `script` runs an owned temporary script. Both read caller input, check exact output and empty stderr, compare open descriptor counts, then rewind and read the original input again before closing all three streams.

Build as for `pipelines.m`, replacing the source and executable name with `input-lifetime.m` and `input-lifetime`. Run each case in a fresh process:

```sh
for scenario in borrowed script; do
    xcrun simctl spawn "$SIMULATOR_UDID" "$PWD/.build/probe/input-lifetime" "$PWD/.build/dash/src/dash" "$scenario"
done
```

Before the borrowed-input fix, `borrowed` exits 1 with descriptors `8/7` and input close `-1`; `script` remains green with `8/8`. With the fix, both exit 0 with descriptors `8/8`, successful stream closes and `PASS`.
