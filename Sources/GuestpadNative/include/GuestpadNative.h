#ifndef GUESTPAD_NATIVE_H
#define GUESTPAD_NATIVE_H

#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

#define GP_PATH_SIZE 104
#define GP_PROTOCOL_VERSION 2

static inline void gp_endpoint_directory(char path[GP_PATH_SIZE]) {
    snprintf(path, GP_PATH_SIZE, "/tmp/guestpad-%u", (unsigned)getuid());
}

// Private, local-only datagram format. No keyboard, clipboard or account data.
typedef struct {
    uint32_t magic; uint16_t version; uint16_t kind;
    uint64_t peer; uint64_t sequence;
    uint32_t controller; uint16_t buttons; int16_t axes[4];
    uint8_t triggers[2]; uint8_t allowed; uint8_t reserved;
    uint32_t status;
} GPMessage;
int gp_listen(int *lock_fd);
int gp_read(int fd, GPMessage *message);
void gp_close(int fd, int lock_fd);

#endif
