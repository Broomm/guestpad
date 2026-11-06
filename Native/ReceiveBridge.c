// Guestpad's version-guarded, ARM64 receive tap. No third-party hook library.
#include "GuestpadNative.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <CommonCrypto/CommonDigest.h>
#include <libkern/OSCacheControl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdbool.h>
static int channel = -1;
static char directory[GP_PATH_SIZE];
static struct sockaddr_un endpoint;
static _Atomic bool has_listener = false;
static _Atomic uint32_t status=0;
static _Atomic uint64_t sequence=0;
void *gp_return_address;
extern void gp_hook_entry(void);
static bool emit(GPMessage *message) {
    message->magic = 0x47504144;
    message->version = GP_PROTOCOL_VERSION;
    message->sequence = atomic_fetch_add(&sequence, 1);
    // Sending by name lets a new Guestpad instance bind the same endpoint.
    return sendto(channel, message, sizeof(*message), MSG_DONTWAIT | MSG_NOSIGNAL,
                  (struct sockaddr *)&endpoint, sizeof(endpoint)) == sizeof(*message);
}
static uint16_t be16(const unsigned char *p) { return ((uint16_t)p[0]<<8)|p[1]; }
void gp_capture(uint64_t *registers) {
    if (!atomic_load(&has_listener)) return;
    const uintptr_t original_sp=registers[31];
    const uintptr_t peer=registers[20];
    const unsigned type=(unsigned)registers[25];
    if(!peer) return;
    GPMessage m={.kind=2,.peer=peer,.allowed=*(unsigned char*)(peer+0x178)};
    if(type==23) {
        uint32_t size; uintptr_t payload;
        memcpy(&size,(void*)(original_sp+0xd4),4);
        memcpy(&payload,(void*)(original_sp+0xb8),8);
        if(size!=28 || !payload)return;
        const unsigned char *p=(const unsigned char*)payload;
        m.kind=1; m.controller=((uint32_t)be16(p)<<16)|be16(p+2);
        m.buttons=be16(p+16);
        for(int i=0;i<4;i++)m.axes[i]=(int16_t)be16(p+18+2*i);
        m.triggers[0]=p[26]; m.triggers[1]=p[27];
    }
    emit(&m);
}
static int known_core(const char *path) {
    static const unsigned char expected[32]={0x26,0xa0,0xfe,0x52,0xfd,0x70,0x1e,0xe1,0xa7,0x5f,0x1f,0x90,0xbc,0xc0,0xb0,0xeb,0x67,0x8e,0x6b,0x13,0x3d,0xf3,0x7b,0x77,0x32,0xb0,0xd2,0x20,0x38,0x8d,0xa0,0xea};
    FILE *f=fopen(path,"rb"); if(!f)return 0;
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx);
    unsigned char buffer[16384],hash[32]; size_t n;
    while((n=fread(buffer,1,sizeof(buffer),f)))CC_SHA256_Update(&ctx,buffer,(CC_LONG)n);
    int ok=!ferror(f); fclose(f); CC_SHA256_Final(hash,&ctx);
    return ok && !memcmp(hash,expected,32);
}
static uint32_t branch(uintptr_t from,uintptr_t to) { return 0x14000000 | (((int64_t)to-(int64_t)from)>>2 & 0x03ffffff); }
static void added(const struct mach_header *header,intptr_t slide) {
    (void)slide;
    if(atomic_load(&status)!=0)return;
    const char *path=NULL;
    for(uint32_t i=0;i<_dyld_image_count();i++)if(_dyld_get_image_header(i)==header)path=_dyld_get_image_name(i);
    if(!path || !strstr(path,"/parsecd-") || !strstr(path,".dylib"))return;
    if(!known_core(path)) { atomic_store(&status,2); return; }
    uintptr_t site=(uintptr_t)header+0x14222c;
    if(*(uint32_t*)site!=0x7100933f) { atomic_store(&status,3); return; }
    // A single aligned branch instruction is installed while dyld loads the core,
    // before Parsec can execute it. The nearby stub preserves x16/x17.
    mach_vm_address_t stub=0;
    const size_t page=(size_t)getpagesize();
    for(uint64_t delta=page;delta<0x07f00000;delta+=page) {
        stub=(site & ~(page-1))+delta;
        if(mach_vm_allocate(mach_task_self(),&stub,page,VM_FLAGS_FIXED)==KERN_SUCCESS)break;
        stub=0;
    }
    if(!stub) { atomic_store(&status,4); return; }
    uint32_t *code=(uint32_t*)stub;
    code[0]=0xa9bf47f0; // stp x16,x17,[sp,#-16]!
    code[1]=0x580000b0; // ldr x16, literal at +24
    code[2]=0xd61f0200; // br x16
    code[3]=0xa8c147f0; // ldp x16,x17,[sp],#16
    code[4]=0x7100933f; // displaced cmp w25,#36
    code[5]=branch(stub+20,site+4);
    *(uintptr_t*)(stub+24)=(uintptr_t)&gp_hook_entry;
    gp_return_address=(void*)(stub+12);
    sys_icache_invalidate((void*)stub,32);
    if(mach_vm_protect(mach_task_self(),stub,page,FALSE,VM_PROT_READ|VM_PROT_EXECUTE)!=KERN_SUCCESS) { atomic_store(&status,5); return; }
    mach_vm_address_t target_page=site & ~(page-1);
    if(mach_vm_protect(mach_task_self(),target_page,page,FALSE,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)!=KERN_SUCCESS) { atomic_store(&status,6); return; }
    *(uint32_t*)site=branch(site,stub);
    sys_icache_invalidate((void*)site,4);
    if(mach_vm_protect(mach_task_self(),target_page,page,FALSE,VM_PROT_READ|VM_PROT_EXECUTE)!=KERN_SUCCESS) _exit(78);
    atomic_store(&status,1);
}
static bool listener_is_private(void) {
    struct stat info;
    if (lstat(directory, &info) != 0 || !S_ISDIR(info.st_mode) ||
        info.st_uid != getuid() || (info.st_mode & 077) != 0) return false;
    return lstat(endpoint.sun_path, &info) == 0 && S_ISSOCK(info.st_mode) &&
           info.st_uid == getuid() && (info.st_mode & 077) == 0;
}

static void *heartbeat(void *unused) {
    (void)unused;
    for (;;) {
        GPMessage message = {.kind = 0, .status = atomic_load(&status)};
        atomic_store(&has_listener, listener_is_private() && emit(&message));
        usleep(250000);
    }
}

__attribute__((constructor)) static void start(void) {
    gp_endpoint_directory(directory);
    endpoint.sun_family = AF_UNIX;
    snprintf(endpoint.sun_path, sizeof(endpoint.sun_path), "%s/input", directory);
    channel = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (channel < 0) return;
    fcntl(channel, F_SETFL, O_NONBLOCK);
    fcntl(channel, F_SETFD, FD_CLOEXEC);
    _dyld_register_func_for_add_image(added);
    pthread_t thread;
    if (pthread_create(&thread, NULL, heartbeat, NULL) == 0) pthread_detach(thread);
}
