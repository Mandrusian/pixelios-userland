#include <fcntl.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stddef.h>
#include <unistd.h>

typedef struct {
    mach_msg_header_t header;
    uint32_t value;
} pixelios_ipc_message;

#define PIXELIOS_MESSAGE_ID 0x7B030001
#define PIXELIOS_MESSAGE_VALUE 0x5A17C032

static void out(int fd, const char *s, size_t n) {
    while (n != 0) {
        ssize_t count = write(fd, s, n);
        if (count <= 0) return;
        s += count;
        n -= (size_t)count;
    }
}
#define SAY(fd, s) out(fd, (s), sizeof(s)-1)

static void integer(int fd, unsigned number) {
    char data[16];
    unsigned i = sizeof(data);
    do {
        data[--i] = (char)('0' + number % 10u);
        number /= 10u;
    } while (number);
    out(fd, data + i, sizeof(data) - i);
}

static int problem(int fd, const char *label, size_t len, kern_return_t kr, int rc) {
    SAY(fd, "P7B3 FAIL ");
    out(fd, label, len);
    SAY(fd, " KERN_RETURN=");
    integer(fd, (unsigned)kr);
    SAY(fd, "\n");
    return rc;
}
#define PROBLEM(fd, label, kr, rc) problem(fd, label, sizeof(label)-1, kr, rc)

int main(void) {
    int fd = open("/dev/console", O_RDWR);
    if (fd < 0) return 90;

    SAY(fd, "\nP7B3 MACH IPC START THROUGH DYLD\n");
    SAY(fd, "P7B3 PID=");
    integer(fd, (unsigned)getpid());
    SAY(fd, " P7B3 PPID=");
    integer(fd, (unsigned)getppid());
    SAY(fd, "\n");

    mach_port_t receive = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &receive);
    if (kr != KERN_SUCCESS || receive == MACH_PORT_NULL) {
        int rc = PROBLEM(fd, "mach_port_allocate", kr, 51);
        close(fd);
        return rc;
    }
    SAY(fd, "P7B3 MACH RECEIVE PORT ALLOCATED\n");

    kr = mach_port_insert_right(mach_task_self(), receive, receive, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        int rc = PROBLEM(fd, "mach_port_insert_right", kr, 52);
        (void)mach_port_destruct(mach_task_self(), receive, -1, 0);
        close(fd);
        return rc;
    }
    SAY(fd, "P7B3 MACH SEND RIGHT INSERTED\n");

    pixelios_ipc_message tx = {0};
    tx.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    tx.header.msgh_size = (mach_msg_size_t)sizeof(tx);
    tx.header.msgh_remote_port = receive;
    tx.header.msgh_local_port = MACH_PORT_NULL;
    tx.header.msgh_id = PIXELIOS_MESSAGE_ID;
    tx.value = PIXELIOS_MESSAGE_VALUE;

    kr = mach_msg(&tx.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                  tx.header.msgh_size, 0, MACH_PORT_NULL, 5000, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) {
        int rc = PROBLEM(fd, "mach_msg_send", kr, 53);
        (void)mach_port_destruct(mach_task_self(), receive, -1, 0);
        close(fd);
        return rc;
    }
    SAY(fd, "P7B3 MACH MSG SEND PASS\n");

    pixelios_ipc_message rx = {0};
    rx.header.msgh_size = (mach_msg_size_t)sizeof(rx);
    kr = mach_msg(&rx.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                  0, (mach_msg_size_t)sizeof(rx), receive, 5000, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) {
        int rc = PROBLEM(fd, "mach_msg_receive", kr, 54);
        (void)mach_port_destruct(mach_task_self(), receive, -1, 0);
        close(fd);
        return rc;
    }
    if (rx.header.msgh_id != PIXELIOS_MESSAGE_ID ||
        rx.header.msgh_size != sizeof(rx) ||
        rx.value != PIXELIOS_MESSAGE_VALUE ||
        rx.header.msgh_local_port != receive) {
        SAY(fd, "P7B3 FAIL MACH PAYLOAD/HEADER MISMATCH\n");
        (void)mach_port_destruct(mach_task_self(), receive, -1, 0);
        close(fd);
        return 55;
    }
    SAY(fd, "P7B3 MACH MSG RECEIVE+PAYLOAD PASS\n");

    kr = mach_port_destruct(mach_task_self(), receive, -1, 0);
    if (kr != KERN_SUCCESS) {
        int rc = PROBLEM(fd, "mach_port_destroy", kr, 56);
        close(fd);
        return rc;
    }
    SAY(fd, "P7B3 MACH PORT CLEANUP PASS\n");
    SAY(fd, "P7B3 MACH IPC PASS; EXIT=42\n");
    close(fd);
    return 42;
}
