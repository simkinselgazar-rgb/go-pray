#include <unistd.h>
#include <dlfcn.h>
#include <stdio.h>
#include <dispatch/dispatch.h>
#include <CoreFoundation/CoreFoundation.h>
// Loaded into /usr/bin/perl via DynaLoader; called as an XSUB (cv argument ignored).
typedef void (*GetPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef Boolean (*SendCmd)(uint32_t, CFDictionaryRef);
void mr_probe(void *cv) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    GetPlaying gp = (GetPlaying)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    SendCmd sc = (SendCmd)dlsym(h, "MRMediaRemoteSendCommand");
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    __block int playing = -1;
    gp(dispatch_get_global_queue(0, 0), ^(Boolean p) { playing = p; dispatch_semaphore_signal(s); });
    dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    printf("perl-hosted: isPlaying=%d\n", playing);
    if (getenv("MR_PAUSE")) { printf("perl-hosted: send(pause)=%d\n", sc(1, NULL)); usleep(800000); }
    fflush(stdout);
}
