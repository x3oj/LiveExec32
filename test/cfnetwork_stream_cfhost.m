#import <CFNetwork/CFNetwork.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

#include <arpa/inet.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#ifndef LC32_CFHOST_STREAM_NATIVE_CHECK
_Static_assert(sizeof(CFReadStreamRef) == 4, "guest stream pointers are ARM32");
_Static_assert(sizeof(CFWriteStreamRef) == 4, "guest stream pointers are ARM32");
#endif

typedef struct {
    uint32_t before;
    CFReadStreamRef stream;
    uint32_t after;
} ReadGuard;

typedef struct {
    uint32_t before;
    CFWriteStreamRef stream;
    uint32_t after;
} WriteGuard;

_Static_assert(offsetof(ReadGuard, after) ==
    offsetof(ReadGuard, stream) + sizeof(CFReadStreamRef),
    "read canary immediately follows output");
_Static_assert(offsetof(WriteGuard, after) ==
    offsetof(WriteGuard, stream) + sizeof(CFWriteStreamRef),
    "write canary immediately follows output");

static const uint32_t beforeCanary = UINT32_C(0x13579bdf);
static const uint32_t afterCanary = UINT32_C(0xfedcba98);
static int failures;

static void check(const char *name, BOOL condition) {
    printf("%s: %s\n", name, condition ? "PASS" : "FAIL");
    failures += !condition;
}

static void testPair(CFHostRef host, const char *name) {
    check(name, host != NULL);
    if(!host) return;

    ReadGuard read = {beforeCanary, NULL, afterCanary};
    WriteGuard write = {beforeCanary, NULL, afterCanary};
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    CFStreamCreatePairWithSocketToCFHost(kCFAllocatorDefault,
        host, 443, &read.stream, &write.stream);
    CFRelease(host);
    [pool drain];

    check("cfhost-stream-read-canaries", read.before == beforeCanary &&
        read.after == afterCanary);
    check("cfhost-stream-write-canaries", write.before == beforeCanary &&
        write.after == afterCanary);
    // Create-rule results must survive releasing the host and draining the
    // autorelease pool. Neither stream is opened, so no network is contacted.
    check("cfhost-stream-read-owned", read.stream != NULL);
    check("cfhost-stream-write-owned", write.stream != NULL);
    if(read.stream) {
        check("cfhost-stream-read-type", CFGetTypeID(read.stream) ==
            CFReadStreamGetTypeID());
        check("cfhost-stream-read-not-open", CFReadStreamGetStatus(read.stream)
            == kCFStreamStatusNotOpen);
        CFRelease(read.stream);
    }
    if(write.stream) {
        check("cfhost-stream-write-type", CFGetTypeID(write.stream) ==
            CFWriteStreamGetTypeID());
        check("cfhost-stream-write-not-open", CFWriteStreamGetStatus(write.stream)
            == kCFStreamStatusNotOpen);
        CFRelease(write.stream);
    }
}

static void testOptionalOutputs(void) {
    CFHostRef host = CFHostCreateWithName(kCFAllocatorDefault,
        CFSTR("127.0.0.1"));
    check("cfhost-stream-optional-host", host != NULL);
    if(!host) return;

    ReadGuard read = {beforeCanary, NULL, afterCanary};
    CFStreamCreatePairWithSocketToCFHost(kCFAllocatorDefault,
        host, 443, &read.stream, NULL);
    check("cfhost-stream-read-only", read.stream != NULL &&
        read.before == beforeCanary && read.after == afterCanary);
    if(read.stream) CFRelease(read.stream);

    WriteGuard write = {beforeCanary, NULL, afterCanary};
    CFStreamCreatePairWithSocketToCFHost(kCFAllocatorDefault,
        host, 443, NULL, &write.stream);
    check("cfhost-stream-write-only", write.stream != NULL &&
        write.before == beforeCanary && write.after == afterCanary);
    if(write.stream) CFRelease(write.stream);

#ifndef LC32_CFHOST_STREAM_NATIVE_CHECK
    // Defensive shim behavior for invalid input is not a native API contract.
    CFStreamCreatePairWithSocketToCFHost(kCFAllocatorDefault,
        host, 443, NULL, NULL);
    check("cfhost-stream-no-outputs", YES);

    read.stream = (CFReadStreamRef)(uintptr_t)1;
    write.stream = (CFWriteStreamRef)(uintptr_t)1;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    CFStreamCreatePairWithSocketToCFHost(kCFAllocatorDefault,
        NULL, 443, &read.stream, &write.stream);
#pragma clang diagnostic pop
    check("cfhost-stream-null-host-clears-outputs", !read.stream &&
        !write.stream && read.before == beforeCanary &&
        read.after == afterCanary && write.before == beforeCanary &&
        write.after == afterCanary);

    read.stream = (CFReadStreamRef)(uintptr_t)1;
    CFStreamCreatePairWithSocketToCFHost(kCFAllocatorDefault,
        host, 443, &read.stream, (CFWriteStreamRef *)&read.stream);
    check("cfhost-stream-aliased-outputs-rejected", !read.stream &&
        read.before == beforeCanary && read.after == afterCanary);
#endif
    CFRelease(host);
}

int main(void) {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    testPair(CFHostCreateWithName(kCFAllocatorDefault, CFSTR("127.0.0.1")),
        "cfhost-stream-numeric-name");
    testPair(CFHostCreateWithName(kCFAllocatorDefault, CFSTR("localhost")),
        "cfhost-stream-unresolved-name");

    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    CFDataRef data = CFDataCreate(kCFAllocatorDefault,
        (const UInt8 *)&address, sizeof(address));
    CFHostRef host = data ? CFHostCreateWithAddress(kCFAllocatorDefault, data)
        : NULL;
    if(data) CFRelease(data);
    testPair(host, "cfhost-stream-address-object");
    testOptionalOutputs();
    [pool drain];
    return failures != 0;
}
