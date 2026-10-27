#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <unistd.h>

static void out(int fd, const char *text, size_t len) {
    while (len != 0) {
        ssize_t done = write(fd, text, len);
        if (done <= 0) return;
        text += done;
        len -= (size_t)done;
    }
}

#define SAY(fd, text) out((fd), (text), sizeof(text)-1)

static void number(int fd, unsigned n) {
    char buffer[16];
    unsigned i = sizeof(buffer);
    do {
        buffer[--i] = (char)('0' + n % 10);
        n /= 10;
    } while (n);
    out(fd, buffer + i, sizeof(buffer) - i);
}

int main(void) {
    int fd = open("/dev/console", O_RDWR);
    if (fd < 0) return 96;

    SAY(fd, "P7A DYNAMIC MACH-O STARTED THROUGH DYLD\n");

    pid_t pid = getpid();
    pid_t parent = getppid();

    SAY(fd, "P7A DYNAMIC PID=");
    number(fd, (unsigned)pid);
    SAY(fd, "\nP7A DYNAMIC PPID=");
    number(fd, (unsigned)parent);
    SAY(fd, "\n");

    if (pid <= 1 || parent != 1) {
        SAY(fd, "P7A DYNAMIC PROCESS IDENTITY FAIL\n");
        close(fd);
        return 95;
    }

    SAY(fd, "P7A DYNAMIC LIBSYSTEM PASS; EXIT=42\n");
    close(fd);
    return 42;
}
