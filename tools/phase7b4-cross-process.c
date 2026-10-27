#include <fcntl.h>
#include <mach/mach.h>
#include <mach/task_special_ports.h>
#include <spawn.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/wait.h>
#include <unistd.h>

extern int posix_spawnattr_set_platform_np(posix_spawnattr_t *attr,
                                            int platform, uint32_t flags);
extern int posix_spawnattr_setspecialport_np(posix_spawnattr_t *attr,
                                             mach_port_t port, int which);

#define PIXELIOS_IOS_PLATFORM 2
#define PIXELIOS_IPC_ID 0x7B040001
#define PIXELIOS_IPC_COOKIE 0x7B041643
#define PIXELIOS_BUFFER_BYTES 256

typedef struct {
    mach_msg_header_t header;
    uint32_t cookie;
    uint32_t sender_pid;
} pixelios_ipc_packet;

typedef union {
    pixelios_ipc_packet packet;
    uint8_t bytes[PIXELIOS_BUFFER_BYTES];
} pixelios_ipc_receive;

_Static_assert(PIXELIOS_BUFFER_BYTES >= sizeof(pixelios_ipc_packet) + 128,
               "Receive capacity must include Mach trailer");

static void output(int fd, const char *s, size_t n) {
    while (n) {
        ssize_t step = write(fd, s, n);
        if (step <= 0) return;
        s += step;
        n -= (size_t)step;
    }
}
#define SAY(fd, text) output(fd, text, sizeof(text)-1)

static void number(int fd, uint32_t v) {
    char s[16];
    size_t p = sizeof(s);
    do {
        s[--p] = (char)('0' + (v % 10u));
        v /= 10u;
    } while (v);
    output(fd, s + p, sizeof(s) - p);
}

static int failure(int fd, const char *where, size_t n, uint32_t status, int rc) {
    SAY(fd, "P7B4 FAIL ");
    output(fd, where, n);
    SAY(fd, " CODE=");
    number(fd, status);
    SAY(fd, "\n");
    return rc;
}
#define FAIL(fd, name, status, rc) failure(fd, name, sizeof(name)-1, (uint32_t)(status), rc)

static int worker(int fd) {
    SAY(fd, "P7B4 WORKER DYNAMIC PROCESS START\n");
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &port);
    if (kr != KERN_SUCCESS || port == MACH_PORT_NULL)
        return FAIL(fd, "task_get_special_port", kr, 61);
    SAY(fd, "P7B4 WORKER INHERITED BOOTSTRAP SEND RIGHT\n");

    pixelios_ipc_packet msg = {0};
    msg.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    msg.header.msgh_size = (mach_msg_size_t)sizeof(msg);
    msg.header.msgh_remote_port = port;
    msg.header.msgh_local_port = MACH_PORT_NULL;
    msg.header.msgh_id = PIXELIOS_IPC_ID;
    msg.cookie = PIXELIOS_IPC_COOKIE;
    msg.sender_pid = (uint32_t)getpid();

    kr = mach_msg(&msg.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                  msg.header.msgh_size, 0, MACH_PORT_NULL, 5000, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS)
        return FAIL(fd, "worker_mach_send", kr, 62);
    SAY(fd, "P7B4 WORKER SEND PASS PID=");
    number(fd, (uint32_t)getpid());
    SAY(fd, "\n");
    (void)mach_port_deallocate(mach_task_self(), port);
    SAY(fd, "P7B4 WORKER EXIT=42\n");
    return 42;
}

static int server(int fd) {
    SAY(fd, "\nP7B4 CROSS-PROCESS MACH IPC THROUGH DYLD\n");
    SAY(fd, "P7B4 SERVER PID=");
    number(fd, (uint32_t)getpid());
    SAY(fd, "\n");

    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
    if (kr != KERN_SUCCESS || port == MACH_PORT_NULL)
        return FAIL(fd, "mach_port_allocate", kr, 51);

    kr = mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        (void)mach_port_destruct(mach_task_self(), port, 0, 0);
        return FAIL(fd, "mach_port_insert_right", kr, 52);
    }

    posix_spawnattr_t attr = NULL;
    int err = posix_spawnattr_init(&attr);
    if (err) {
        (void)mach_port_destruct(mach_task_self(), port, -1, 0);
        return FAIL(fd, "spawnattr_init", err, 53);
    }

    err = posix_spawnattr_set_platform_np(&attr, PIXELIOS_IOS_PLATFORM, 0);
    if (err) {
        (void)posix_spawnattr_destroy(&attr);
        (void)mach_port_destruct(mach_task_self(), port, -1, 0);
        return FAIL(fd, "spawnattr_set_platform_ios", err, 54);
    }
    err = posix_spawnattr_setspecialport_np(&attr, port, TASK_BOOTSTRAP_PORT);
    if (err) {
        (void)posix_spawnattr_destroy(&attr);
        (void)mach_port_destruct(mach_task_self(), port, -1, 0);
        return FAIL(fd, "spawnattr_set_bootstrap_port", err, 55);
    }
    SAY(fd, "P7B4 SERVER REGISTERED BOOTSTRAP PORT FOR SPAWN\n");

    char *const argv[] = {"/bin/pixelios-dynamic", "--worker", NULL};
    char *const envp[] = {NULL};
    pid_t pid = -1;
    err = posix_spawn(&pid, argv[0], NULL, &attr, argv, envp);
    (void)posix_spawnattr_destroy(&attr);
    if (err || pid <= 0) {
        (void)mach_port_destruct(mach_task_self(), port, -1, 0);
        return FAIL(fd, "posix_spawn_worker", err ? err : 1, 56);
    }
    SAY(fd, "P7B4 SERVER SPAWNED WORKER PID=");
    number(fd, (uint32_t)pid);
    SAY(fd, "\n");

    pixelios_ipc_receive incoming = {0};
    kr = mach_msg(&incoming.packet.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                  0, sizeof(incoming.bytes), port, 300000, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) {
        (void)mach_port_destruct(mach_task_self(), port, -1, 0);
        return FAIL(fd, "server_mach_receive", kr, 57);
    }

    if (incoming.packet.header.msgh_id != PIXELIOS_IPC_ID ||
        incoming.packet.header.msgh_size != sizeof(pixelios_ipc_packet) ||
        incoming.packet.header.msgh_local_port != port ||
        incoming.packet.cookie != PIXELIOS_IPC_COOKIE ||
        incoming.packet.sender_pid != (uint32_t)pid) {
        SAY(fd, "P7B4 FAIL INTERPROCESS HEADER/COOKIE/PID MISMATCH\n");
        (void)mach_port_destruct(mach_task_self(), port, -1, 0);
        return 58;
    }
    SAY(fd, "P7B4 SERVER RECEIVED AND VERIFIED CROSS-TASK MACH MESSAGE\n");

    int status = 0, reaped = 0;
    for (unsigned round = 0; round < 600; ++round) {
        pid_t result = waitpid(pid, &status, WNOHANG);
        if (result == pid) {
            reaped = 1;
            break;
        }
        if (result < 0) break;
        (void)usleep(100000);
    }
    kr = mach_port_destruct(mach_task_self(), port, -1, 0);
    if (kr != KERN_SUCCESS)
        return FAIL(fd, "server_port_cleanup", kr, 59);
    if (!reaped || !WIFEXITED(status) || WEXITSTATUS(status) != 42) {
        SAY(fd, "P7B4 FAIL WORKER REAP/EXIT=42 CHECK\n");
        return 60;
    }
    SAY(fd, "P7B4 SERVER REAPED WORKER EXIT=42\n");
    SAY(fd, "P7B4 CROSS-PROCESS MACH IPC PASS; EXIT=42\n");
    return 42;
}

int main(int argc, char **argv) {
    int fd = open("/dev/console", O_RDWR);
    if (fd < 0) return 90;
    int result;
    if (argc == 2 && argv[1] &&
        argv[1][0] == '-' && argv[1][1] == '-' &&
        argv[1][2] == 'w' && argv[1][3] == 'o' &&
        argv[1][4] == 'r' && argv[1][5] == 'k' &&
        argv[1][6] == 'e' && argv[1][7] == 'r' &&
        argv[1][8] == '\0') {
        result = worker(fd);
    } else {
        result = server(fd);
    }
    close(fd);
    return result;
}
