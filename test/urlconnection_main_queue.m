#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <unistd.h>

// Match the legacy client's Foundation completion -> dispatch_sync(main)
// handoff. No credentials or requests to a real login service are used.
int main(int argc, char **argv) {
    if(argc != 2) return 2;
    setvbuf(stdout, NULL, _IONBF, 0);
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:argv[1]]];
    NSURLRequest *request = [NSURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:5.0];
    NSOperationQueue *queue = [NSOperationQueue new];
    __block volatile BOOL completionCalled = NO;
    __block volatile BOOL mainCalled = NO;
    __block BOOL mainIdentity = NO;
    __block BOOL workerIdentity = NO;
    __block BOOL responseOK = NO;
    [NSURLConnection sendAsynchronousRequest:request queue:queue
        completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
            workerIdentity = ![NSThread isMainThread];
            completionCalled = YES;
            responseOK = !error && [(NSHTTPURLResponse *)response statusCode] == 200 &&
                [[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease]
                    containsString:@"LC32-CFHOST-IO-OK"];
            printf("urlconnection-completion: response=%ld bytes=%lu error=%s/%ld worker=%d\n",
                (long)[(NSHTTPURLResponse *)response statusCode], (unsigned long)data.length,
                error.domain.UTF8String ?: "none", (long)error.code, workerIdentity);
            dispatch_sync(dispatch_get_main_queue(), ^{
                mainIdentity = [NSThread isMainThread];
                mainCalled = YES;
                printf("urlconnection-main-handoff: main=%d\n", mainIdentity);
            });
        }];
    [queue release];
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 10;
    while(!mainCalled && CFAbsoluteTimeGetCurrent() < deadline) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    }
    BOOL passed = completionCalled && mainCalled && mainIdentity && workerIdentity && responseOK;
    printf("urlconnection-main-queue: %s completion=%d main=%d response=%d\n",
        passed ? "PASS" : "FAIL", completionCalled, mainCalled, responseOK);
    if(!passed) _exit(1);
    [pool drain];
    return 0;
}
