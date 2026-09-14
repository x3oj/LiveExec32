#import "bridge.h"
#import <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <stdio.h>

namespace {

void DrainGuestMainQueue(CFMachPortRef, void *, CFIndex, void *info) {
    // libdispatch-703's 4CF callback ignores its message argument. Never
    // expose a native Mach message buffer as an ARM32 address.
    u32 arguments[] = {0};
    LC32InvokeGuestC(static_cast<u32>(reinterpret_cast<uintptr_t>(info)),
        false, 1, arguments);
}

} // namespace

void LC32InstallGuestMainQueueRunLoop(void) {
    // The source must execute on the registered guest main thread, not on
    // the generic callback worker. UIKit and the CFRunLoop shims enter here
    // only after guest libdispatch has finished loading.
    static bool installed = false;
    if(installed || !pthread_main_np() ||
       !Dynarmic_guest_thread_is_registered()) return;

    const u32 getPort = guest_dlsym("_dispatch_get_main_queue_port_4CF");
    const u32 drain = guest_dlsym("_dispatch_main_queue_callback_4CF");
    if(!getPort || !drain) {
        fprintf(stderr, "LC32: guest libdispatch main-queue hooks unavailable\n");
        return;
    }
    const mach_port_t port = static_cast<mach_port_t>(
        LC32InvokeGuestC(getPort, false, 0, nullptr));
    if(port == MACH_PORT_NULL) return;

    CFMachPortContext context = {};
    context.info = reinterpret_cast<void *>(static_cast<uintptr_t>(drain));
    CFMachPortRef wrapper = CFMachPortCreateWithPort(kCFAllocatorDefault,
        port, DrainGuestMainQueue, &context, nullptr);
    if(!wrapper) return;
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(
        kCFAllocatorDefault, wrapper, 0);
    if(source) {
        // The native run loop already services native libdispatch. Add the
        // separate ARM32 queue's wakeup port to the same common modes.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
        installed = true;
        CFRelease(source);
    }
    CFRelease(wrapper);
}
