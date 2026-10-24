// Exercise the real Dash command entry with caller-owned streams.
#import <Foundation/Foundation.h>
#import <ios_system/ios_system.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <signal.h>
#include <sys/stat.h>
#include <limits.h>
#include <unistd.h>

static int (*shellMain)(int, char **);

// The embedding application owns this optional callback contract.
static int foregroundPID;
int ashell_pane_exchange_foreground_pid(int pid) {
    int previous = foregroundPID;
    foregroundPID = pid;
    return previous;
}

int pipeline_shell_main(int argc, char **argv) {
    return shellMain(argc, argv);
}

int pipeline_first_main(int argc, char **argv) {
    char *line = NULL;
    size_t capacity = 0;
    ssize_t length = getline(&line, &capacity, thread_stdin);
    int status = length > 0 && fwrite(line, 1, length, thread_stdout) == (size_t)length ? 0 : 1;
    free(line);
    return status;
}

int pipeline_envprobe_main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "valid")) {
        char **env = environmentVariables(ios_currentPid());
        for (; env && *env; env++) {
            const char *equals = strchr(*env, '=');
            if (!equals || equals == *env) return 7;
        }
        fprintf(thread_stdout, "valid\n");
        return 0;
    }
    const char *value = ios_getenv("FOO");
    fprintf(thread_stdout, "%s\n", value ? value : "missing");
    return 0;
}

// Stand-in for a-Shell's synchronous WebAssembly queue: each `wasm` command is stacked and
// blocks until the caller's wait runs the stack, producer first. The first argument
// picks the behaviour: emit writes a block, fail writes nothing, drain counts its input and
// skip ignores it. A skipping consumer runs before the producer, which then meets a closed pipe.
static struct {
    FILE *input, *output;
    dispatch_semaphore_t done;
    char kind;
} queued[2];
static int queuedCount;
static pthread_mutex_t queueLock = PTHREAD_MUTEX_INITIALIZER;
#define WASM_BYTES 4096

int pipeline_wasm_main(int argc, char **argv) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    pthread_mutex_lock(&queueLock);
    int slot = queuedCount++;
    queued[slot].input = thread_stdin;
    queued[slot].output = thread_stdout;
    queued[slot].done = done;
    queued[slot].kind = argc > 1 ? argv[1][0] : 0;
    pthread_mutex_unlock(&queueLock);
    finishedPreparingWebAssemblyCommand();
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return 0;
}

static void runQueued(int slot) {
    char block[WASM_BYTES];
    size_t total = 0, got;
    switch (queued[slot].kind) {
    case 'e':
        memset(block, 'x', sizeof(block));
        fwrite(block, 1, sizeof(block), queued[slot].output);
        fflush(queued[slot].output);
        break;
    case 'd':
        while ((got = fread(block, 1, sizeof(block), queued[slot].input)) > 0) total += got;
        fprintf(queued[slot].output, "%zu\n", total);
        fflush(queued[slot].output);
        break;
    }
    dispatch_semaphore_signal(queued[slot].done);
}

void executeWebAssemblyCommands(void) {
    if (queuedCount != 2) return;
    // Dash starts the consumer first, so find the producer by what it does.
    int producer = queued[0].kind == 'e' || queued[0].kind == 'f' ? 0 : 1;
    int consumer = 1 - producer;
    bool consumerSkips = queued[consumer].kind == 's';
    runQueued(consumerSkips ? consumer : producer);
    if (consumerSkips) usleep(200000);
    runQueued(consumerSkips ? producer : consumer);
    queuedCount = 0;
}

static void timedOut(int signal) {
    const char message[] = "pipeline regression timed out\n";
    write(STDERR_FILENO, message, sizeof(message) - 1);
    _Exit(124);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        signal(SIGALRM, timedOut);
        signal(SIGPIPE, SIG_IGN);
        alarm(5);
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!library || !(shellMain = dlsym(library, "main"))) {
            dprintf(STDERR_FILENO, "Cannot load Dash: %s\n", dlerror());
            return 2;
        }
        const char *script, *expected;
        int expectedStatus = 0;
        if (!strcmp(argv[2], "group")) {
            script = "{ printf 'one\\n'; printf 'two\\n'; } | first-line";
            expected = "one\n";
        } else if (!strcmp(argv[2], "early-reader")) {
            script = "{ while :; do printf 'x\\n'; done; } | first-line";
            expected = "x\n";
        } else if (!strcmp(argv[2], "heredoc")) {
            script = "first-line <<EOF | first-line\none\ntwo\nEOF\n";
            expected = "one\n";
        } else if (!strcmp(argv[2], "subshell-next")) {
            script = "(exit 7); printf 'next\\n'";
            expected = "next\n";
        } else if (!strcmp(argv[2], "subshell-status")) {
            script = "(exit 7)";
            expected = "";
            expectedStatus = 7;
        } else if (!strcmp(argv[2], "wasm-producer-eof")) {
            script = "wasm emit | wasm drain";
            expected = "4096\n";
        } else if (!strcmp(argv[2], "wasm-producer-fails")) {
            script = "wasm fail | wasm drain; printf 'next\\n'";
            expected = "0\nnext\n";
        } else if (!strcmp(argv[2], "wasm-consumer-skips")) {
            script = "wasm emit | wasm skip; printf 'next\\n'";
            expected = "next\n";
        } else if (!strcmp(argv[2], "unset-semantics")) {
            script = "export FOO=outer; unset FOO; envprobe; printf x | envprobe; exec envprobe";
            expected = "missing\nmissing\nmissing\n";
        } else if (!strcmp(argv[2], "unset-environment")) {
            script = "unset ASHELL_ABSENT; envprobe valid; printf x | envprobe valid; exec envprobe valid";
            expected = "valid\nvalid\nvalid\n";
        } else if (!strcmp(argv[2], "pipeline-environment")) {
            script = "FOO=private; envprobe; printf x | envprobe; export FOO=outer; envprobe; FOO=inner envprobe; envprobe; printf x | envprobe; printf x | FOO=pipe envprobe; envprobe";
            expected = "private\nprivate\nouter\ninner\nouter\nouter\npipe\nouter\n";
        } else if (!strcmp(argv[2], "pipeline-error-unwind")) {
            script = "export 1bad=value | first-line";
            expected = "";
            expectedStatus = 2;
        } else return 2;
        initializeEnvironment();
        ios_switchSession("pipeline-regression");
        // Dash resolves external commands through PATH before ios_system dispatch.
        char markerDirectory[PATH_MAX];
        snprintf(markerDirectory, sizeof(markerDirectory), "%spipeline-markers.XXXXXX", NSTemporaryDirectory().fileSystemRepresentation);
        if (!mkdtemp(markerDirectory)) return 2;
        char markerPath[PATH_MAX];
        snprintf(markerPath, sizeof(markerPath), "%s/first-line", markerDirectory);
        FILE *marker = fopen(markerPath, "w");
        if (!marker || fclose(marker) || chmod(markerPath, 0755)) return 2;
        snprintf(markerPath, sizeof(markerPath), "%s/wasm", markerDirectory);
        marker = fopen(markerPath, "w");
        if (!marker || fclose(marker) || chmod(markerPath, 0755)) return 2;
        snprintf(markerPath, sizeof(markerPath), "%s/envprobe", markerDirectory);
        marker = fopen(markerPath, "w");
        if (!marker || fclose(marker) || chmod(markerPath, 0755)) return 2;
        ios_setenv("PATH", markerDirectory, 1);
        FILE *input = tmpfile(), *output = tmpfile(), *error = tmpfile();
        if (!input || !output || !error) return 2;
        void *registration = NULL;
        if (ashell_register_owned_streams(input, output, error, &registration)) return 2;
        ios_setStreams(input, output, error);
        replaceCommand(@"dash", @"pipeline_shell_main", false);
        replaceCommand(@"first-line", @"pipeline_first_main", false);
        replaceCommand(@"wasm", @"pipeline_wasm_main", false);
        replaceCommand(@"envprobe", @"pipeline_envprobe_main", false);
        // Quote embedded apostrophes for the outer ios_system command parser.
        NSString *quoted = [[NSString stringWithUTF8String:script] stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
        NSString *command = [NSString stringWithFormat:@"dash -c '%@'", quoted];
        joinMainThread = false;
        pid_t root = ios_fork();
        ios_system(command.UTF8String);
        ios_waitpid(root);
        ashell_wait_owned_streams(registration);
        int status = ios_getCommandStatus();
        ashell_unregister_owned_streams(&registration);
        rewind(output);
        char actual[64] = {0};
        size_t length = fread(actual, 1, sizeof(actual) - 1, output);
        BOOL passed = length == strlen(expected) && !strcmp(actual, expected) && status == expectedStatus && foregroundPID == 0;
        ios_setStreams(stdin, stdout, stderr);
        if (fclose(input) || fclose(output) || fclose(error)) return 1;
        alarm(0);
        dprintf(STDERR_FILENO, "Dash %s: status=%d bytes=%zu %s\n", argv[2], status, length, passed ? "PASS" : "FAIL");
        if (!strcmp(argv[2], "pipeline-error-unwind"))
            dprintf(STDERR_FILENO, "Foreground idle after pipeline error: %s\n", foregroundPID == 0 ? "PASS" : "FAIL");
        dlclose(library);
        unlink(markerPath);
        snprintf(markerPath, sizeof(markerPath), "%s/wasm", markerDirectory);
        unlink(markerPath);
        snprintf(markerPath, sizeof(markerPath), "%s/first-line", markerDirectory);
        unlink(markerPath);
        rmdir(markerDirectory);
        return passed ? 0 : 1;
    }
}
