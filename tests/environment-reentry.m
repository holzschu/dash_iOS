// Reuse the real Dash entry with an environment whose lifetime ends after each run.
#import <Foundation/Foundation.h>
#import <ios_system/ios_system.h>
#include <dlfcn.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static int (*shellMain)(int, char **);
static char **(*runtimeEnvironment)(pid_t);
static __thread BOOL inShell;
static char *commandEnvironment[3];

// Link the tested Dash image with -flat_namespace so this executable supplies
// its environment boundary. Other runtime calls retain their real environment.
char **environmentVariables(pid_t pid) {
    return inShell ? commandEnvironment : runtimeEnvironment(pid);
}

int environment_reentry_main(int argc, char **argv) {
    inShell = YES;
    return shellMain(argc, argv);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        alarm(15);
        void *runtime = dlopen("@rpath/ios_system.framework/ios_system", RTLD_NOW | RTLD_LOCAL);
        if (!runtime || !(runtimeEnvironment = dlsym(runtime, "environmentVariables"))) return 2;
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!library || !(shellMain = dlsym(library, "main"))) {
            dprintf(2, "load Dash: %s\n", dlerror());
            return 2;
        }
        NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *files = NSFileManager.defaultManager;
        if (![files createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:NULL]) return 2;
        NSString *marker = [home stringByAppendingPathComponent:@"reentry-marker"];
        if (![@"#!/bin/sh\n" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:NULL] ||
            chmod(marker.fileSystemRepresentation, 0700)) return 2;
        initializeEnvironment();
        ios_switchSession("environment-reentry");
        ios_setenv("HOME", home.fileSystemRepresentation, 1);
        FILE *input = tmpfile(), *output = tmpfile(), *error = tmpfile();
        void *owner = NULL;
        if (!input || !output || !error || ashell_register_owned_streams(input, output, error, &owner)) return 2;
        ios_setStreams(input, output, error);
        replaceCommand(@"reentry-dash", @"environment_reentry_main", false);
        joinMainThread = false;
        const size_t pageSize = (size_t)getpagesize();
        void *pages[3];
        BOOL passed = YES;
        int completed = 0;
        for (int run = 0; run < 3; ++run) {
            pages[run] = mmap(NULL, pageSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
            if (pages[run] == MAP_FAILED) return 2;
            char *path = pages[run];
            int length = snprintf(path, pageSize, "PATH=%s", home.fileSystemRepresentation);
            if (length < 0 || (size_t)length + 32 >= pageSize) return 2;
            char *term = path + length + 1;
            snprintf(term, pageSize - length - 1, "TERM=reentry-%d", run);
            commandEnvironment[0] = path;
            commandEnvironment[1] = term;
            pid_t child = ios_fork();
            int status = ios_system("reentry-dash -c 'printf \"%s|%s|\" \"$PATH\" \"$TERM\"; command -v reentry-marker'");
            ios_waitpid(child);
            ashell_wait_owned_streams(owner);
            fflush(output);
            fflush(error);
            if (status || ios_getCommandStatus() || ftell(error)) { passed = NO; break; }
            ++completed;
            dprintf(2, "environment reentry: completed run %d\n", completed);
            // The next invocation must not access the completed command's strings.
            if (mprotect(pages[run], pageSize, PROT_NONE)) return 2;
        }
        rewind(output);
        char actual[8192] = {0};
        size_t bytes = fread(actual, 1, sizeof actual - 1, output);
        NSMutableString *expected = NSMutableString.string;
        for (int run = 0; run < 3; ++run)
            [expected appendFormat:@"%@|reentry-%d|%@\n", home, run, marker];
        passed = passed && completed == 3 && !strcmp(actual, expected.UTF8String);
        if (!passed) {
            dprintf(2, "actual stdout: %s\n", actual);
            rewind(error);
            char diagnostic[2048] = {0};
            fread(diagnostic, 1, sizeof diagnostic - 1, error);
            dprintf(2, "actual stderr: %s\n", diagnostic);
        }
        ashell_unregister_owned_streams(&owner);
        ios_setStreams(stdin, stdout, stderr);
        int inputClose = fclose(input), outputClose = fclose(output), errorClose = fclose(error);
        passed = passed && !inputClose && !outputClose && !errorClose;
        for (int run = 0; run < completed; ++run) munmap(pages[run], pageSize);
        [files removeItemAtPath:home error:NULL];
        alarm(0);
        dprintf(2, "environment reentry: completed=%d bytes=%zu %s\n", completed, bytes, passed ? "PASS" : "FAIL");
        return passed ? 0 : 1;
    }
}
