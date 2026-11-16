// A real embedding consumer supplies socket IO and optional foreground-input hooks.
#import <Foundation/Foundation.h>
#import <ios_system/ios_system.h>
#include <dlfcn.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <limits.h>
#include <unistd.h>
#include <time.h>
#include <stdatomic.h>
#include <pthread.h>

static int (*shellMain)(int, char **);
static FILE *editorInput;
static const char *scenario;
static _Atomic int foregroundPid;
static _Atomic int resizeHandled;
static int resizeEvent[2];

int ashell_pane_exchange_foreground_pid(int pid) {
    return atomic_exchange(&foregroundPid, pid);
}

int ashell_pane_wait_editor_input(FILE *input) {
    struct pollfd events[2] = {{.fd = fileno(input), .events = POLLIN}, {.fd = resizeEvent[0], .events = POLLIN}};
    int result;
    do { result = poll(events, 2, -1); } while (result < 0 && errno == EINTR);
    if (result < 0) return -errno;
    if (events[1].revents & POLLIN) {
        char event;
        if (read(resizeEvent[0], &event, 1) != 1) return -EIO;
        atomic_fetch_add(&resizeHandled, 1);
        ios_setenv("COLUMNS", "40", 1);
        ios_setenv("LINES", "12", 1);
        return events[0].revents & POLLIN ? 1 : 2;
    }
    return 0;
}

struct inputLease { FILE *stream; void *registration; int writer; };

int ashell_pane_begin_foreground_input(FILE **input, void **leaseHandle) {
    int descriptors[2];
    if (pipe(descriptors)) return errno;
    const char *payload = !strcmp(scenario, "raw") ? "RAW=\r\004\033[A\n" : "CAT_PAYLOAD\n";
    BOOL cancellable = strstr(scenario, "cancel") != NULL;
    if (!cancellable) {
        size_t length = strlen(payload);
        if (write(descriptors[1], payload, length) != (ssize_t)length) {
            close(descriptors[0]); close(descriptors[1]); return EIO;
        }
        close(descriptors[1]);
    }
    struct inputLease *lease = calloc(1, sizeof(*lease));
    if (!lease) { close(descriptors[0]); if (cancellable) close(descriptors[1]); return ENOMEM; }
    lease->writer = cancellable ? descriptors[1] : -1;
    lease->stream = fdopen(descriptors[0], "r");
    if (!lease->stream) { int error = errno; close(descriptors[0]); if (lease->writer >= 0) close(lease->writer); free(lease); return error; }
    int error = ashell_register_command_input(lease->stream, &lease->registration);
    if (error) { fclose(lease->stream); if (lease->writer >= 0) close(lease->writer); free(lease); return error; }
    ios_settty(lease->stream);
    *input = lease->stream;
    *leaseHandle = lease;
    return 0;
}

int ashell_pane_end_foreground_input(void *leaseHandle) {
    struct inputLease *lease = leaseHandle;
    ashell_wait_owned_streams(lease->registration);
    ashell_unregister_owned_streams(&lease->registration);
    if (lease->writer >= 0) close(lease->writer);
    ios_settty(editorInput);
    int error = fclose(lease->stream) ? errno : 0;
    free(lease);
    return error;
}

int socket_shell_main(int argc, char **argv) { return shellMain(argc, argv); }

int socket_cat_main(int argc, char **argv) {
    if (strstr(scenario, "cancel")) fputs("INPUT_READY\n", thread_stdout);
    char buffer[256];
    ssize_t count;
    while ((count = read(fileno(thread_stdin), buffer, sizeof(buffer))) > 0)
        if (fwrite(buffer, 1, count, thread_stdout) != (size_t)count) return 1;
    return count < 0 ? 1 : 0;
}

static BOOL receiveUntil(int descriptor, const char *expected) {
    char capture[32768] = {0};
    size_t used = 0;
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - start.tv_sec >= 5) break;
        struct pollfd ready = { .fd = descriptor, .events = POLLIN };
        int result = poll(&ready, 1, 250);
        if (result < 0) return NO;
        if (!result) continue;
        ssize_t count = read(descriptor, capture + used, sizeof(capture) - used - 1);
        if (count <= 0) return NO;
        used += count;
        capture[used] = 0;
        if (strstr(capture, expected)) return YES;
        if (used == sizeof(capture) - 1) return NO;
    }
    dprintf(STDERR_FILENO, "Expected %s; received %zu bytes: %s\n", expected, used, capture);
    return NO;
}

static BOOL sendText(int descriptor, const char *text) {
    size_t length = strlen(text);
    return write(descriptor, text, length) == (ssize_t)length;
}

static void timedOut(int signal) {
    const char message[] = "socket editor timed out\n";
    write(STDERR_FILENO, message, sizeof(message) - 1);
    _Exit(124);
}

static int runProbe(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        scenario = argv[2];
        atomic_store(&resizeHandled, 0);
        if (pipe(resizeEvent)) return 2;
        signal(SIGALRM, timedOut);
        signal(SIGPIPE, SIG_IGN);
        alarm(12);
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!library || !(shellMain = dlsym(library, "main"))) {
            dprintf(STDERR_FILENO, "Cannot load Dash: %s\n", dlerror());
            return 2;
        }
        char directory[PATH_MAX], markerPath[PATH_MAX];
        snprintf(directory, sizeof(directory), "%ssocket-commands.XXXXXX", NSTemporaryDirectory().fileSystemRepresentation);
        if (!mkdtemp(directory)) return 2;
        snprintf(markerPath, sizeof(markerPath), "%s/socket-cat", directory);
        FILE *marker = fopen(markerPath, "w");
        if (!marker || fclose(marker) || chmod(markerPath, 0755)) return 2;
        setenv("PATH", directory, 1);
        setenv("PS1", "probe> ", 1);
        setenv("TERM", "xterm-256color", 1);
        setenv("LC_ALL", "en_US.UTF-8", 1);
        setenv("ENV", "", 1);
        initializeEnvironment();
        ios_switchSession("socket-input-probe");
        ios_setenv("ASHELL_IOS_SOCKET_INPUT", "1", 1);
        ios_setenv("SOCKET_CONTEXT", "session-value", 1);
        ios_setenv("COLUMNS", "80", 1);
        ios_setenv("LINES", "24", 1);
        int sockets[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets)) return 2;
        FILE *input = fdopen(dup(sockets[0]), "r");
        FILE *output = fdopen(dup(sockets[0]), "w");
        FILE *error = fdopen(dup(sockets[0]), "w");
        close(sockets[0]);
        if (!input || !output || !error) return 2;
        setvbuf(output, NULL, _IONBF, 0);
        setvbuf(error, NULL, _IONBF, 0);
        editorInput = input;
        void *registration = NULL;
        if (ashell_register_owned_streams(input, output, error, &registration)) return 2;
        ios_setStreams(input, output, error);
        ios_settty(input);
        ios_useNativeTTY(true);
        replaceCommand(@"dash", @"socket_shell_main", false);
        replaceCommand(@"socket-cat", @"socket_cat_main", false);
        joinMainThread = false;
        pid_t root = ios_fork();
        ios_system("dash -i");
        BOOL passed = receiveUntil(sockets[1], "probe> ");
        if (passed && !strcmp(argv[2], "line"))
            passed = sendText(sockets[1], "printf 'UNICODE=é\\n'\r") && receiveUntil(sockets[1], "UNICODE=é\n");
        else if (passed && !strcmp(argv[2], "context"))
            passed = sendText(sockets[1], "printf 'CONTEXT=%s\\n' \"$SOCKET_CONTEXT\"\n") && receiveUntil(sockets[1], "CONTEXT=session-value\n");
        else if (passed && !strcmp(argv[2], "foreground"))
            passed = sendText(sockets[1], "socket-cat\n") && receiveUntil(sockets[1], "CAT_PAYLOAD\n");
        else if (passed && !strcmp(argv[2], "delete"))
            passed = sendText(sockets[1], "\004printf 'DELETE_OK\\n'\n") && receiveUntil(sockets[1], "DELETE_OK\n");
        else if (strcmp(argv[2], "raw") && strcmp(argv[2], "cancel") && strcmp(argv[2], "resize") && strcmp(argv[2], "nested-cancel")) passed = NO;
        if (passed && !strcmp(argv[2], "raw"))
            passed = sendText(sockets[1], "socket-cat\n") && receiveUntil(sockets[1], "RAW=\r\004\033[A\n");
        if (passed && strstr(argv[2], "cancel")) {
            passed = sendText(sockets[1], !strcmp(argv[2], "nested-cancel") ? "eval 'socket-cat'\n" : "socket-cat\n") && receiveUntil(sockets[1], "INPUT_READY\n");
            int pid = atomic_load(&foregroundPid);
            pthread_t target = pid > 0 ? ios_getThreadId(pid) : NULL;
            passed = passed && target && target != (pthread_t)-1 && !pthread_cancel(target);
            if (passed) passed = receiveUntil(sockets[1], "probe> ");
        }
        if (passed && !strcmp(argv[2], "resize")) {
            passed = sendText(sockets[1], "printf 'RESIZE_OK");
            if (passed) passed = receiveUntil(sockets[1], "RESIZE_OK");
            if (passed) passed = write(resizeEvent[1], "r", 1) == 1;
            if (passed) passed = sendText(sockets[1], "\\n'\n") && receiveUntil(sockets[1], "RESIZE_OK\n");
            passed = passed && atomic_load(&resizeHandled) == 1;
        }
        if (passed)
            passed = sendText(sockets[1], "printf 'NEXT_OK\\n'\n") && receiveUntil(sockets[1], "NEXT_OK\n");
        if (!passed) {
            dprintf(STDERR_FILENO, "socket %s and next command: FAIL\n", argv[2]);
            return 1;
        }
        if (!sendText(sockets[1], "exit\n")) return 1;
        ios_waitpid(root);
        ashell_wait_owned_streams(registration);
        ashell_unregister_owned_streams(&registration);
        ios_setStreams(stdin, stdout, stderr);
        if (fclose(input) || fclose(output) || fclose(error)) return 1;
        close(sockets[1]);
        dlclose(library);
        shellMain = NULL;
        close(resizeEvent[0]); close(resizeEvent[1]);
        ios_closeSession("socket-input-probe");
        unlink(markerPath);
        rmdir(directory);
        alarm(0);
        dprintf(STDERR_FILENO, "socket %s and next command: PASS\n", argv[2]);
        return 0;
    }
}

int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[2], "repeat")) {
        char *arguments[] = {argv[0], argv[1], "context", NULL};
        for (int index = 0; index < 8; index++) {
            int status = runProbe(3, arguments);
            if (status) return status;
        }
        dprintf(STDERR_FILENO, "eight Dash load/run/close cycles: PASS\n");
        return 0;
    }
    return runProbe(argc, argv);
}
