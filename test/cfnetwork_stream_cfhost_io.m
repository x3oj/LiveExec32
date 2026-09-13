#import <CFNetwork/CFNetwork.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    CFReadStreamRef read;
    CFWriteStreamRef write;
    const char *request;
    CFIndex length, sent, received;
    char response[8192];
    CFOptionFlags readEvents, writeEvents;
    Boolean failed, ended, identityOK;
} Transfer;

static void sendRequest(Transfer *t) {
    if(t->sent == t->length || !CFWriteStreamCanAcceptBytes(t->write)) return;
    CFIndex n = CFWriteStreamWrite(t->write,
        (const UInt8 *)t->request + t->sent, t->length - t->sent);
    if(n < 0) t->failed = true;
    else t->sent += n;
}

static void receiveResponse(Transfer *t) {
    if(!CFReadStreamHasBytesAvailable(t->read)) return;
    CFIndex available = sizeof(t->response) - 1 - t->received;
    if(available <= 0) { t->failed = true; return; }
    CFIndex n = CFReadStreamRead(t->read,
        (UInt8 *)t->response + t->received, available);
    if(n < 0) t->failed = true;
    else if(n == 0) t->ended = true;
    else {
        t->received += n;
        t->response[t->received] = '\0';
    }
}

static void readEvent(CFReadStreamRef stream, CFStreamEventType event, void *info) {
    Transfer *t = info;
    t->identityOK &= stream == t->read;
    t->readEvents |= event;
    if(event == kCFStreamEventHasBytesAvailable) receiveResponse(t);
    if(event == kCFStreamEventErrorOccurred) t->failed = true;
    if(event == kCFStreamEventEndEncountered) t->ended = true;
}

static void writeEvent(CFWriteStreamRef stream, CFStreamEventType event, void *info) {
    Transfer *t = info;
    t->identityOK &= stream == t->write;
    t->writeEvents |= event;
    if(event == kCFStreamEventCanAcceptBytes) sendRequest(t);
    if(event == kCFStreamEventErrorOccurred) t->failed = true;
}

int main(int argc, char **argv) {
    if(argc != 7) {
        fprintf(stderr, "usage: %s host port plain|tls callbacks|poll marker|http deferred|resolved\n", argv[0]);
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    long port = strtol(argv[2], NULL, 10);
    Boolean tls = strcmp(argv[3], "tls") == 0;
    Boolean callbacks = strcmp(argv[4], "callbacks") == 0;
    Boolean marker = strcmp(argv[5], "marker") == 0;
    CFStringRef name = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
    CFHostRef host = name ? CFHostCreateWithName(NULL, name) : NULL;
    if(name) CFRelease(name);
    if(!host || port <= 0 || port > 65535) return 2;
    if(strcmp(argv[6], "resolved") == 0) {
        CFStreamError error = {0, 0};
        if(!CFHostStartInfoResolution(host, kCFHostAddresses, &error)) {
            printf("resolve failed: domain=%ld error=%d\n", (long)error.domain, (int)error.error);
            CFRelease(host);
            [pool drain];
            return 1;
        }
    }
    Transfer t = {0};
    t.identityOK = true;
    CFStreamCreatePairWithSocketToCFHost(NULL, host, (SInt32)port, &t.read, &t.write);
    CFRelease(host);
    if(!t.read || !t.write) return 1;
    char request[1024];
    int length = snprintf(request, sizeof(request),
        "GET / HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n", argv[1]);
    if(length <= 0 || (size_t)length >= sizeof(request)) return 2;
    t.request = request;
    t.length = length;
    if(tls) {
        // Keep native certificate and hostname verification enabled.
        t.failed = !CFReadStreamSetProperty(t.read,
            kCFStreamPropertySocketSecurityLevel, kCFStreamSocketSecurityLevelNegotiatedSSL) ||
            !CFWriteStreamSetProperty(t.write,
            kCFStreamPropertySocketSecurityLevel, kCFStreamSocketSecurityLevelNegotiatedSSL);
    }
    CFRunLoopRef loop = CFRunLoopGetCurrent();
    if(callbacks && !t.failed) {
        CFStreamClientContext context = {0, &t, NULL, NULL, NULL};
        t.failed = !CFReadStreamSetClient(t.read,
            kCFStreamEventOpenCompleted | kCFStreamEventHasBytesAvailable |
            kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered, readEvent, &context) ||
            !CFWriteStreamSetClient(t.write,
            kCFStreamEventOpenCompleted | kCFStreamEventCanAcceptBytes |
            kCFStreamEventErrorOccurred, writeEvent, &context);
        CFReadStreamScheduleWithRunLoop(t.read, loop, kCFRunLoopDefaultMode);
        CFWriteStreamScheduleWithRunLoop(t.write, loop, kCFRunLoopDefaultMode);
    }
    if(!t.failed) t.failed = !CFReadStreamOpen(t.read) || !CFWriteStreamOpen(t.write);
    const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 15.0;
    Boolean complete = false;
    while(!t.failed && !t.ended && CFAbsoluteTimeGetCurrent() < deadline) {
        if(callbacks) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
        else { sendRequest(&t); receiveResponse(&t); }
        if(CFReadStreamGetStatus(t.read) == kCFStreamStatusError ||
           CFWriteStreamGetStatus(t.write) == kCFStreamStatusError) t.failed = true;
        complete = t.sent == t.length && strncmp(t.response, "HTTP/", 5) == 0 &&
            strstr(t.response, "\r\n\r\n") != NULL &&
            (!marker || strstr(t.response, "LC32-CFHOST-IO-OK") != NULL);
        if(complete) break;
    }
    CFStreamError readError = CFReadStreamGetError(t.read);
    CFStreamError writeError = CFWriteStreamGetError(t.write);
    Boolean passed = complete && !t.failed && t.identityOK &&
        (!callbacks || ((t.readEvents & kCFStreamEventHasBytesAvailable) &&
                        (t.writeEvents & kCFStreamEventCanAcceptBytes)));
    printf("CFHost I/O %s:%ld %s %s %s: %s sent=%ld received=%ld read-events=%lu write-events=%lu read-error=%ld/%d write-error=%ld/%d\n",
        argv[1], port, argv[3], argv[4], argv[6], passed ? "PASS" : "FAIL",
        (long)t.sent, (long)t.received, (unsigned long)t.readEvents, (unsigned long)t.writeEvents,
        (long)readError.domain, (int)readError.error, (long)writeError.domain, (int)writeError.error);
    char *lineEnd = strstr(t.response, "\r\n");
    if(lineEnd) { *lineEnd = '\0'; printf("Response: %.120s\n", t.response); }
    if(callbacks) {
        CFReadStreamUnscheduleFromRunLoop(t.read, loop, kCFRunLoopDefaultMode);
        CFWriteStreamUnscheduleFromRunLoop(t.write, loop, kCFRunLoopDefaultMode);
        CFReadStreamSetClient(t.read, 0, NULL, NULL);
        CFWriteStreamSetClient(t.write, 0, NULL, NULL);
    }
    CFReadStreamClose(t.read);
    CFWriteStreamClose(t.write);
    CFRelease(t.read);
    CFRelease(t.write);
    [pool drain];
    return passed ? 0 : 1;
}
