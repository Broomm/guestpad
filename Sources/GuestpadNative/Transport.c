#include "GuestpadNative.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>

static void socket_address(const char *directory, struct sockaddr_un *address) {
    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    snprintf(address->sun_path, sizeof(address->sun_path), "%s/input", directory);
}

int gp_listen(int *lock_fd) {
    char directory[GP_PATH_SIZE], lock_path[GP_PATH_SIZE];
    gp_endpoint_directory(directory);
    if (mkdir(directory, 0700) != 0 && errno != EEXIST) return -1;

    struct stat info;
    if (lstat(directory, &info) != 0 || !S_ISDIR(info.st_mode) ||
        info.st_uid != getuid() || (info.st_mode & 077) != 0) {
        errno = EACCES;
        return -1;
    }

    snprintf(lock_path, sizeof(lock_path), "%s/lock", directory);
    int lock = open(lock_path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (lock < 0) return -1;
    int fd = -1;
    if (flock(lock, LOCK_EX | LOCK_NB) != 0) goto fail;

    struct sockaddr_un address;
    socket_address(directory, &address);
    if (lstat(address.sun_path, &info) == 0) {
        if (!S_ISSOCK(info.st_mode) || info.st_uid != getuid()) {
            errno = EACCES;
            goto fail;
        }
        if (unlink(address.sun_path) != 0) goto fail;
    } else if (errno != ENOENT) {
        goto fail;
    }

    fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 || fcntl(fd, F_SETFL, O_NONBLOCK) < 0) goto fail;
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) goto fail;
    if (chmod(address.sun_path, 0600) != 0) {
        int error = errno;
        unlink(address.sun_path);
        errno = error;
        goto fail;
    }
    *lock_fd = lock;
    return fd;

fail: {
    int error = errno;
    if (fd >= 0) close(fd);
    close(lock);
    errno = error;
    return -1;
}
}

int gp_read(int fd, GPMessage *message) {
    unsigned char bytes[sizeof(GPMessage) + 1];
    ssize_t length = recv(fd, bytes, sizeof(bytes), 0);
    if (length < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
    if (length < 0) return -1;
    if (length != sizeof(GPMessage)) return 2;
    memcpy(message, bytes, sizeof(*message));
    if (message->magic != 0x47504144 || message->version != GP_PROTOCOL_VERSION || message->kind > 3) return 2;
    return 1;
}

void gp_close(int fd, int lock_fd) {
    if (fd >= 0) {
        char directory[GP_PATH_SIZE];
        gp_endpoint_directory(directory);
        struct sockaddr_un address;
        socket_address(directory, &address);
        unlink(address.sun_path);
        close(fd);
    }
    if (lock_fd >= 0) close(lock_fd);
}
