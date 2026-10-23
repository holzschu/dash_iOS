// Verify borrowed command input and owned script cleanup through ios_system.
#import <Foundation/Foundation.h>
#import <ios_system/ios_system.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

static int (*shellMain)(int, char **);
int input_shell_main(int argc, char **argv) { return shellMain(argc, argv); }

static int descriptorCount(void) {
    int count = 0;
    for (int fd = 0; fd < getdtablesize(); ++fd)
        if (fcntl(fd, F_GETFD) >= 0) ++count;
    return count;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        alarm(5);
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!library || !(shellMain = dlsym(library, "main"))) return 2;
        BOOL scriptMode = !strcmp(argv[2], "script");
        if (!scriptMode && strcmp(argv[2], "borrowed")) return 2;
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *script = @"read value; printf 'INPUT=%s\\n' \"$value\"";
        if (scriptMode && ![script writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]) return 2;
        initializeEnvironment();
        ios_switchSession("input-lifetime");
        FILE *input = tmpfile(), *output = tmpfile(), *error = tmpfile();
        void *registration = NULL;
        if (!input || !output || !error) return 2;
        fputs("caller-input\n", input);
        rewind(input);
        if (ashell_register_owned_streams(input, output, error, &registration)) return 2;
        ios_setStreams(input, output, error);
        replaceCommand(@"dash", @"input_shell_main", false);
        NSString *command = scriptMode ? [NSString stringWithFormat:@"dash '%@'", path] : [NSString stringWithFormat:@"dash -c '%@'", [script stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
        int before = descriptorCount();
        joinMainThread = false;
        pid_t root = ios_fork();
        ios_system(command.UTF8String);
        ios_waitpid(root);
        ashell_wait_owned_streams(registration);
        int status = ios_getCommandStatus();
        int after = descriptorCount();
        rewind(output);
        char actual[64] = {0};
        size_t bytes = fread(actual, 1, sizeof actual - 1, output);
        rewind(error);
        BOOL passed = status == 0 && bytes == 19 && !strcmp(actual, "INPUT=caller-input\n") && fgetc(error) == EOF && before == after;
        rewind(input);
        passed = passed && fgetc(input) == 'c';
        ashell_unregister_owned_streams(&registration);
        ios_setStreams(stdin, stdout, stderr);
        int inputClose = fclose(input), outputClose = fclose(output), errorClose = fclose(error);
        passed = passed && !inputClose && !outputClose && !errorClose;
        if (scriptMode) unlink(path.fileSystemRepresentation);
        dlclose(library);
        alarm(0);
        dprintf(STDERR_FILENO, "input %s: status=%d descriptors=%d/%d close=%d/%d/%d %s\n", argv[2], status, before, after, inputClose, outputClose, errorClose, passed ? "PASS" : "FAIL");
        return passed ? 0 : 1;
    }
}
