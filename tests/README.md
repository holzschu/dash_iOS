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
for scenario in group early-reader heredoc subshell-next subshell-status wasm-producer-eof wasm-producer-fails wasm-consumer-skips pipeline-environment pipeline-error-unwind; do
    xcrun simctl spawn "$SIMULATOR_UDID" "$PWD/.build/probe/pipelines" "$PWD/.build/dash/src/dash" "$scenario"
done
```

The baseline leaks a grouped producer's second line into the caller output, times out after an infinite builtin producer loses its reader, and exits the enclosing shell after `(exit 7)` instead of running the next command. The patched results are `group: status=0 bytes=4`, `early-reader: status=0 bytes=2`, `heredoc: status=0 bytes=4`, `subshell-next: status=0 bytes=5`, and `subshell-status: status=7 bytes=0`, `wasm-producer-eof: status=0 bytes=5`, `wasm-producer-fails: status=0 bytes=7` and `wasm-consumer-skips: status=0 bytes=5`, each with `PASS`. The environment and unwind cases report `pipeline-environment: status=0 bytes=51` and `pipeline-error-unwind: status=1 bytes=0`, also with `PASS`. The same executable tests both libraries. These checks do not qualify interactive libedit hooks or physical-device behavior.

The `pipeline-environment` case registers a native envprobe command. Direct dispatch reads exported FOO=outer, an inline assignment reads inner, and the following command still reads outer. Pipeline consumers must read outer or their own inline pipe assignment, then leave the caller at outer. The expected output is `outer`, `inner`, `outer`, `outer`, `pipe`, `outer`, each followed by a newline. The pre-correction EV_NOFORK consumer omits the shell environment; the same fixture fails against it. This uses the real Dash/ios_system command boundary and checks status and output, without changing fork or pipe ownership.

The `wasm-*` cases register a stand-in `wasm` command that stacks its call and blocks, as a-Shell does, until the caller's wait runs the stack, producer first. `wasm-producer-eof` runs `wasm emit | wasm drain`: the consumer prints the number of bytes it read, `4096`, so the output is `4096` and a newline (5 bytes). Without ios_system owning a simple external producer's pipe in `eval_pipeline_producer`, the producer's write end stays open, the consumer never sees EOF and the alarm fires. `wasm-producer-fails` (`wasm fail | wasm drain; printf next`) and `wasm-consumer-skips` (a consumer that exits without reading, so the producer writes into a closed pipe) check that the enclosing shell survives and runs the next command.

# Socket command input

`socket-input.m` is an embedding consumer of Dash's real entry and the public ios_system APIs. It supplies caller-owned socket streams and optional foreground-input callbacks. The registered `socket-cat` command reads an actual pipe; its CR, Ctrl-D and escape bytes bypass the line editor. Cancellation uses the published foreground PID to cancel that reader, including inside `eval`, and then runs another command. It does not qualify nested interpreter loading or a complete TUI.

Build with the input-lease API from holzschu/ios_system#183, session preservation from #184, native descriptor detection from #182, and the pipeline prerequisite from holzschu/dash_iOS#1. The native framework used for these checks also includes ios_system#179. Use a framework built from those commits, its matching command dictionary, and a Simulator you own. The libedit dependency must include `libedit-socket.patch`: upstream libedit's NO_TTY path otherwise bypasses editing even with a custom reader.

Download `https://thrysoee.dk/editline/libedit-20260512-3.1.tar.gz` and verify SHA256 `432d5e7ea8b0116dd39f2eca7bc11d0eed77faa6b77ea526ace89907c23ea4a0`. Extract it into `.build/libedit`, apply the patch with `patch -p1`, and build from that directory:

```sh
mkdir -p local
cp "$host_sdk/usr/include/termcap.h" "$host_sdk/usr/include/ncurses_dll.h" local/
./configure --build=x86_64-apple-darwin --host=armv8-apple-darwin --disable-shared --enable-static --disable-readline CC=clang CFLAGS="-target arm64-apple-ios15.0-simulator -isysroot $simulator_sdk -I$PWD/local" CPPFLAGS="-I$PWD/local" LDFLAGS="-target arm64-apple-ios15.0-simulator -isysroot $simulator_sdk"
make -C src -j2
```

Make a fresh disposable Dash source copy as above. Copy `.build/libedit/src/histedit.h` into its `src/` directory so the bundled older header cannot shadow the matching dependency header. Add `--with-libedit` to Dash's configure command and `-L$source_root/.build/libedit/src/.libs` to its LDFLAGS; set `LIBS=-lncurses`. Compile and run from the repository root:

```sh
xcrun --sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -fobjc-arc -Wall -Wextra -Wno-unused-parameter -F .build/probe/Frameworks -framework ios_system -framework Foundation -Wl,-rpath,@executable_path/Frameworks -Wl,-export_dynamic tests/socket-input.m -o .build/probe/socket-input
for scenario in line context foreground delete raw cancel nested-cancel resize repeat; do
    xcrun simctl spawn "$SIMULATOR_UDID" "$PWD/.build/probe/socket-input" "$PWD/.build/dash/src/dash" "$scenario"
done
```

The `line` case checks UTF-8 input and Return; `context` checks the command-session environment. `foreground` checks reader EOF, `delete` keeps the idle shell alive after Ctrl-D, and `raw` checks exact control bytes. Both cancellation cases keep the reader's input writer open until cancellation completes. `resize` delivers a real event while input is pending, verifies event consumption and completes that line. `repeat` loads, runs and closes Dash eight times in one process. Every case requires the same shell to print `NEXT_OK` before exiting. An alarm bounds a run at twelve seconds. The identical executable fails on the pipeline-only baseline and passes on this branch; the ten pipeline regression cases also remain green. Device behavior and terminal-cell reflow need app-level qualification.

Socket consumers opt in with `ASHELL_IOS_SOCKET_INPUT=1`. They may export these optional functions in the embedding process:

```c
int ashell_pane_begin_foreground_input(FILE **input, void **lease);
int ashell_pane_end_foreground_input(void *lease);
int ashell_pane_exchange_foreground_pid(int pid);
int ashell_pane_wait_editor_input(FILE *input);
```

Begin installs a borrowed command stream and returns a lease; end waits for its users before closing it. Both return zero on success or an errno value. Dash restores its editor input and retires the lease when evaluation raises a shell exception. Background evaluation does not acquire foreground input. PID exchange returns the previous PID; negative PIDs identify shell waiters and must never be cancellation targets. The editor wait callback returns 0 for ready input, 1 for resize plus ready input, 2 for resize only, or a negative errno. Update the command thread's COLUMNS/LINES before returning a resize event. The callback runs before the builtin Unicode reader, so it must account for the consumer's input buffering. Without the optional exports, Dash retains its regular evaluation path.

The `pipeline-error-unwind` case enables socket mode and supplies the application's optional foreground-PID exchange callback. A producer builtin rejects an invalid export name, unwinds the pipeline and lets its first-line consumer finish without input. The real Dash command returns status 1 with empty output, and the application callback must be back at its initial idle value. The pre-correction pipeline leaves a stale cancellation target. This checks the optional embedding callback contract without asserting the order of internal calls.

Foreground PID exchange is available without socket opt-in so an embedding terminal can target its active command. Direct and pipeline dispatch pass exported variables and command-prefix assignments; unexported shell variables stay inside Dash. The environment case also checks that an unexported value is absent from both command paths, for 51 bytes of exact output.
