// Exercise profile inheritance through real ios_system and six Dash frameworks.
#import <Foundation/Foundation.h>
#import <ios_system/ios_system.h>
#include <signal.h>
#include <unistd.h>

int main(void) {
    @autoreleasepool {
        alarm(20);
        NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *documents = [home stringByAppendingPathComponent:@"Documents"];
        NSFileManager *files = NSFileManager.defaultManager;
        if (![files createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:NULL]) return 2;
        NSString *bin = [home stringByAppendingPathComponent:@"bin"];
        if (![files createDirectoryAtPath:bin withIntermediateDirectories:NO attributes:nil error:NULL] ||
            ![files createFileAtPath:[bin stringByAppendingPathComponent:@"dash"] contents:NSData.data attributes:nil]) return 2;
        NSString *profile = @"printf 'PROFILE\\n' >> \"$HOME/profile-count\"\ndash -c 'printf CHILD_OK'\n";
        if (![profile writeToFile:[documents stringByAppendingPathComponent:@".profile"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]) return 2;
        NSString *script = [home stringByAppendingPathComponent:@"command.sh"];
        if (![@"printf SCRIPT_OK" writeToFile:script atomically:YES encoding:NSUTF8StringEncoding error:NULL]) return 2;
        initializeEnvironment();
        ios_switchSession("login-profile");
        ios_setenv("HOME", home.fileSystemRepresentation, 1);
        ios_setenv("PATH", bin.fileSystemRepresentation, 1);
        ios_unsetenv("_DASH_LOGIN_SHELL");
        FILE *input = tmpfile(), *output = tmpfile(), *error = tmpfile();
        void *owner = NULL;
        if (!input || !output || !error || ashell_register_owned_streams(input, output, error, &owner)) return 2;
        ios_setStreams(input, output, error);
        if (ios_system("alias sh dash")) return 2;
        joinMainThread = false;
        BOOL passed = YES;
        NSArray<NSString *> *nonlogin = @[@"dash -c 'printf COMMAND_OK'", [@"dash " stringByAppendingString:script]];
        for (NSString *command in nonlogin) {
            pid_t child = ios_fork();
            int status = ios_system(command.UTF8String);
            ios_waitpid(child);
            ashell_wait_owned_streams(owner);
            fflush(error);
            if (status || ios_getCommandStatus() || ftell(error)) passed = NO;
        }
        passed = passed && ![files fileExistsAtPath:[home stringByAppendingPathComponent:@"profile-count"]];
        int completed = 0;
        for (; completed < 8; ++completed) {
            pid_t child = ios_fork();
            int status = ios_system(completed == 7 ? "dash -ic 'printf ROOT_OK'" : "dash -lc 'printf ROOT_OK'");
            ios_waitpid(child);
            ashell_wait_owned_streams(owner);
            fflush(error);
            if (status || ios_getCommandStatus() || ftell(error)) { passed = NO; break; }
        }
        fflush(output);
        rewind(output);
        char actual[256] = {0};
        size_t count = fread(actual, 1, sizeof actual - 1, output);
        NSString *expected = [@"COMMAND_OKSCRIPT_OK" stringByAppendingString:[@"CHILD_OKROOT_OK" stringByPaddingToLength:8 * 15 withString:@"CHILD_OKROOT_OK" startingAtIndex:0]];
        NSString *visits = [NSString stringWithContentsOfFile:[home stringByAppendingPathComponent:@"profile-count"] encoding:NSUTF8StringEncoding error:NULL];
        NSString *expectedVisits = [@"PROFILE\n" stringByPaddingToLength:8 * 8 withString:@"PROFILE\n" startingAtIndex:0];
        passed = passed && count == strlen(expected.UTF8String) && !strcmp(actual, expected.UTF8String) && [visits isEqualToString:expectedVisits];
        ashell_unregister_owned_streams(&owner);
        ios_setStreams(stdin, stdout, stderr);
        int inputClose = fclose(input), outputClose = fclose(output), errorClose = fclose(error);
        passed = passed && !inputClose && !outputClose && !errorClose;
        [files removeItemAtPath:home error:NULL];
        alarm(0);
        dprintf(STDOUT_FILENO, "profile inheritance: completed=%d bytes=%zu visits=%lu %s\n", completed, count, (unsigned long)(visits.length / 8), passed ? "PASS" : "FAIL");
        return passed ? 0 : 1;
    }
}
