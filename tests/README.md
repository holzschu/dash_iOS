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

# Nested login profile

`login-profile.m` runs real commands through ios_system with six Dash frameworks. Its disposable `HOME/Documents/.profile` invokes a child Dash. Eight root invocations must each read the profile once, capture exactly `CHILD_OKROOT_OK` per invocation, produce no stderr and leave the caller streams open until the fixture closes them. The eight roots also exercise reuse beyond the six interpreter slots. The fixture applies and checks the stock `alias sh dash` command to match the embedding app's dispatch configuration. The twenty-second alarm bounds recursion or a stalled wait.

Prepare a probe bundle directory with `Frameworks/ios_system.framework`, all six same-source `dash`, `dashA` through `dashE` frameworks, and ios_system's `Resources/commandDictionary.plist` beside the executable. Use the caller-owned stream prerequisite described above. Build and run with the selected Simulator:

```sh
xcrun --sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -fobjc-arc -DNDEBUG -Wall -Wextra -Wno-unused-parameter -F "$PROBE/Frameworks" -framework ios_system -framework Foundation -Wl,-rpath,@executable_path/Frameworks tests/login-profile.m -o "$PROBE/login-profile"
for framework in "$PROBE"/Frameworks/*.framework; do codesign --force --sign - "$framework"; done
codesign --force --sign - "$PROBE/login-profile"
xcrun simctl spawn "$SIMULATOR_UDID" "$PROBE/login-profile"
```

Before the fix, the marker exists only in ios_system's environment after Dash has imported its variables. A nested exec replaces that environment and drops the marker, so each child rereads the profile until all six slots are occupied: `completed=0 bytes=47 visits=6 FAIL`, exit 1. With the exported Dash variable, the same fixture prints `completed=8 bytes=120 visits=8 PASS`, exit 0. This checks noninteractive startup on arm64 Simulator; physical-device startup remains a separate check.
