#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

#include <cstdlib>
#include <cstring>

namespace {
int instanceLock = -1;

void setError(char* output, unsigned int capacity, NSString* message) {
    if (!output || capacity == 0) return;
    const char* value = message.UTF8String ?: "Unknown web request failure";
    std::strncpy(output, value, capacity - 1);
    output[capacity - 1] = '\0';
}
}

extern "C" int mcdWebRequest(const char* methodUtf8, const char* urlUtf8,
    const char* headersUtf8, const unsigned char* body,
    unsigned int bodyLength, int* status, unsigned char** response,
    unsigned int* responseLength, char* error, unsigned int errorCapacity) {
    if (!methodUtf8 || !urlUtf8 || !status || !response || !responseLength) {
        setError(error, errorCapacity, @"Invalid web request arguments");
        return 0;
    }
    *status = 0;
    *response = nullptr;
    *responseLength = 0;
    NSString* method = [NSString stringWithUTF8String:methodUtf8];
    NSString* urlString = [NSString stringWithUTF8String:urlUtf8];
    NSURL* url = [NSURL URLWithString:urlString];
    if (!method || !url || ![url.scheme.lowercaseString isEqualToString:@"https"]) {
        setError(error, errorCapacity, @"Only HTTPS account URLs are allowed");
        return 0;
    }
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method;
    request.timeoutInterval = 15.0;
    if (headersUtf8 && *headersUtf8) {
        NSString* headerText = [NSString stringWithUTF8String:headersUtf8];
        for (NSString* line in [headerText componentsSeparatedByString:@"\r\n"]) {
            NSRange separator = [line rangeOfString:@":"];
            if (separator.location == NSNotFound) continue;
            NSString* name = [line substringToIndex:separator.location];
            NSString* value = [[line substringFromIndex:separator.location + 1]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            [request setValue:value forHTTPHeaderField:name];
        }
    }
    if (bodyLength) request.HTTPBody = [NSData dataWithBytes:body length:bodyLength];

    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block NSData* received = nil;
    __block NSHTTPURLResponse* http = nil;
    __block NSError* requestError = nil;
    NSURLSessionDataTask* task = [NSURLSession.sharedSession
        dataTaskWithRequest:request completionHandler:^(NSData* data,
            NSURLResponse* result, NSError* failure) {
            received = data;
            http = (NSHTTPURLResponse*)result;
            requestError = failure;
            dispatch_semaphore_signal(completed);
        }];
    [task resume];
    dispatch_semaphore_wait(completed,
        dispatch_time(DISPATCH_TIME_NOW, 20LL * NSEC_PER_SEC));
    if (!http || requestError) {
        [task cancel];
        setError(error, errorCapacity,
            requestError.localizedDescription ?: @"The secure account request timed out");
        return 0;
    }
    *status = static_cast<int>(http.statusCode);
    if (received.length) {
        auto* copy = static_cast<unsigned char*>(std::malloc(received.length));
        if (!copy) {
            setError(error, errorCapacity, @"The account response was too large");
            return 0;
        }
        std::memcpy(copy, received.bytes, received.length);
        *response = copy;
        *responseLength = static_cast<unsigned int>(received.length);
    }
    return 1;
}

extern "C" void mcdWebFree(void* memory) { std::free(memory); }

extern "C" int mcdOpenExternalUrl(const char* urlUtf8) {
    NSString* value = urlUtf8 ? [NSString stringWithUTF8String:urlUtf8] : nil;
    NSURL* url = value ? [NSURL URLWithString:value] : nil;
    if (!url) return 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSWorkspace.sharedWorkspace openURL:url];
    });
    return 1;
}

extern "C" unsigned int mcdChooseSkinPng(char* output, unsigned int capacity) {
    if (![NSThread isMainThread]) return 0;
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.title = @"Choose a 64 x 64 Minecraft skin";
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedFileTypes = @[@"png"];
    if ([panel runModal] != NSModalResponseOK) return 0;
    const char* path = panel.URL.path.UTF8String;
    const size_t length = path ? std::strlen(path) : 0;
    if (!length || !output || length + 1 > capacity) return 0;
    std::memcpy(output, path, length + 1);
    return static_cast<unsigned int>(length);
}

extern "C" int mcdAcquireSingleInstance(const char* lockPath) {
    if (!lockPath || !*lockPath) return 1;
    instanceLock = open(lockPath, O_CREAT | O_RDWR, 0600);
    if (instanceLock < 0 || flock(instanceLock, LOCK_EX | LOCK_NB) == 0)
        return 1;
    NSArray<NSRunningApplication*>* running =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:
            @"com.minecraftdedition.game"];
    for (NSRunningApplication* application in running) {
        if (application.processIdentifier != NSProcessInfo.processInfo.processIdentifier) {
            [application activateWithOptions:NSApplicationActivateIgnoringOtherApps];
            break;
        }
    }
    close(instanceLock);
    instanceLock = -1;
    return 0;
}
