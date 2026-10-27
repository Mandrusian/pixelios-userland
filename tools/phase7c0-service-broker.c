#include <fcntl.h>
#include <mach/mach.h>
#include <mach/task_special_ports.h>
#include <spawn.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern int posix_spawnattr_set_platform_np(posix_spawnattr_t *, int, uint32_t);
extern int posix_spawnattr_setspecialport_np(posix_spawnattr_t *, mach_port_t, int);

#define P7C_PLATFORM_IOS 2
#define P7C_TIMEOUT_MS 60000u
#define P7C_COOKIE 0x7c005eedu
#define P7C_REGISTER 0x7c000001
#define P7C_LOOKUP 0x7c000002
#define P7C_LOOKUP_REPLY 0x7c000003
#define P7C_PING 0x7c000004
#define P7C_PONG 0x7c000005

typedef struct {
    mach_msg_header_t h;
    uint32_t cookie;
    uint32_t pid;
} simple_message;

typedef struct {
    mach_msg_header_t h;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t desc;
    uint32_t cookie;
    uint32_t pid;
} port_message;

typedef union {
    mach_msg_header_t h;
    simple_message plain;
    port_message with_port;
    uint8_t bytes[512];
} receive_buffer;

_Static_assert(sizeof(receive_buffer) >= sizeof(port_message) + 128u,
               "Mach trailers need additional receive space");

static void out(int fd, const char *p, size_t n) {
    while (n > 0) {
        ssize_t sent = write(fd, p, n);
        if (sent <= 0) return;
        p += (size_t)sent;
        n -= (size_t)sent;
    }
}
#define SAY(fd, m) out(fd, m, sizeof(m) - 1)

static void num(int fd, uint32_t n) {
    char b[16];
    size_t i = sizeof(b);
    do {
        b[--i] = (char)('0' + (n % 10));
        n /= 10;
    } while (n);
    out(fd, b + i, sizeof(b) - i);
}

static int fail(int fd, const char *where, unsigned code, int status) {
    SAY(fd, "P7C0 FAIL ");
    out(fd, where, strlen(where));
    SAY(fd, " CODE=");
    num(fd, code);
    SAY(fd, "\n");
    return status;
}

static kern_return_t recv_msg(receive_buffer *b, mach_port_t p, unsigned timeout_ms) {
    memset(b, 0, sizeof(*b));
    return mach_msg(&b->h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0,
                    sizeof(b->bytes), p, timeout_ms, MACH_PORT_NULL);
}

static kern_return_t send_msg(mach_msg_header_t *h) {
    return mach_msg(h, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                    h->msgh_size, 0, MACH_PORT_NULL, 5000, MACH_PORT_NULL);
}

static int port_for_worker(int fd, mach_port_t *result) {
    kern_return_t kr = task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, result);
    if (kr != KERN_SUCCESS || *result == MACH_PORT_NULL) {
        return fail(fd, "task_get_bootstrap_port", (unsigned)kr, 61);
    }
    return 0;
}

static int service(int fd) {
    SAY(fd, "P7C0 SERVICE PROCESS START\n");
    mach_port_t broker = MACH_PORT_NULL;
    int err = port_for_worker(fd, &broker);
    if (err) return err;

    mach_port_t local = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &local);
    if (kr != KERN_SUCCESS || local == MACH_PORT_NULL)
        return fail(fd, "service_receive_allocate", (unsigned)kr, 62);
    kr = mach_port_insert_right(mach_task_self(), local, local, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS)
        return fail(fd, "service_make_send", (unsigned)kr, 63);

    port_message reg = {0};
    reg.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    reg.h.msgh_size = sizeof(reg);
    reg.h.msgh_remote_port = broker;
    reg.h.msgh_id = P7C_REGISTER;
    reg.body.msgh_descriptor_count = 1;
    reg.desc.name = local;
    reg.desc.disposition = MACH_MSG_TYPE_COPY_SEND;
    reg.desc.type = MACH_MSG_PORT_DESCRIPTOR;
    reg.cookie = P7C_COOKIE;
    reg.pid = (uint32_t)getpid();
    kr = send_msg(&reg.h);
    if (kr != KERN_SUCCESS)
        return fail(fd, "service_register_send", (unsigned)kr, 64);
    SAY(fd, "P7C0 SERVICE REGISTERED PORT VIA MACH DESCRIPTOR\n");

    receive_buffer rx;
    kr = recv_msg(&rx, local, P7C_TIMEOUT_MS);
    if (kr != KERN_SUCCESS)
        return fail(fd, "service_receive_ping", (unsigned)kr, 65);
    if (rx.plain.h.msgh_id != P7C_PING ||
        rx.plain.h.msgh_size != sizeof(simple_message) ||
        rx.plain.cookie != P7C_COOKIE ||
        rx.plain.h.msgh_remote_port == MACH_PORT_NULL)
        return fail(fd, "service_ping_invalid", 1, 66);

    simple_message pong = {0};
    pong.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    pong.h.msgh_size = sizeof(pong);
    pong.h.msgh_remote_port = rx.plain.h.msgh_remote_port;
    pong.h.msgh_id = P7C_PONG;
    pong.cookie = P7C_COOKIE;
    pong.pid = (uint32_t)getpid();
    kr = send_msg(&pong.h);
    if (kr != KERN_SUCCESS)
        return fail(fd, "service_send_pong", (unsigned)kr, 67);
    SAY(fd, "P7C0 SERVICE RECEIVED PING AND REPLIED PONG\n");

    (void)mach_port_destruct(mach_task_self(), local, -1, 0);
    (void)mach_port_deallocate(mach_task_self(), broker);
    SAY(fd, "P7C0 SERVICE EXIT=42\n");
    return 42;
}

static int client(int fd) {
    SAY(fd, "P7C0 CLIENT PROCESS START\n");
    mach_port_t broker = MACH_PORT_NULL;
    int err = port_for_worker(fd, &broker);
    if (err) return err;

    mach_port_t reply = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply);
    if (kr != KERN_SUCCESS || reply == MACH_PORT_NULL)
        return fail(fd, "client_reply_allocate", (unsigned)kr, 71);

    simple_message lookup = {0};
    lookup.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    lookup.h.msgh_size = sizeof(lookup);
    lookup.h.msgh_remote_port = broker;
    lookup.h.msgh_local_port = reply;
    lookup.h.msgh_id = P7C_LOOKUP;
    lookup.cookie = P7C_COOKIE;
    lookup.pid = (uint32_t)getpid();
    kr = send_msg(&lookup.h);
    if (kr != KERN_SUCCESS)
        return fail(fd, "client_send_lookup", (unsigned)kr, 72);
    SAY(fd, "P7C0 CLIENT SENT SERVICE LOOKUP\n");

    receive_buffer found;
    kr = recv_msg(&found, reply, P7C_TIMEOUT_MS);
    if (kr != KERN_SUCCESS)
        return fail(fd, "client_receive_lookup_reply", (unsigned)kr, 73);
    if (found.with_port.h.msgh_id != P7C_LOOKUP_REPLY ||
        found.with_port.h.msgh_size != sizeof(port_message) ||
        !(found.with_port.h.msgh_bits & MACH_MSGH_BITS_COMPLEX) ||
        found.with_port.body.msgh_descriptor_count != 1 ||
        found.with_port.desc.type != MACH_MSG_PORT_DESCRIPTOR ||
        found.with_port.desc.name == MACH_PORT_NULL ||
        found.with_port.cookie != P7C_COOKIE)
        return fail(fd, "client_lookup_reply_invalid", 1, 74);

    mach_port_t service_port = found.with_port.desc.name;
    SAY(fd, "P7C0 CLIENT LOOKUP RECEIVED REGISTERED SEND RIGHT\n");

    simple_message ping = {0};
    ping.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    ping.h.msgh_size = sizeof(ping);
    ping.h.msgh_remote_port = service_port;
    ping.h.msgh_local_port = reply;
    ping.h.msgh_id = P7C_PING;
    ping.cookie = P7C_COOKIE;
    ping.pid = (uint32_t)getpid();
    kr = send_msg(&ping.h);
    if (kr != KERN_SUCCESS)
        return fail(fd, "client_send_ping", (unsigned)kr, 75);
    SAY(fd, "P7C0 CLIENT DIRECT SERVICE PING SENT\n");

    receive_buffer pong;
    kr = recv_msg(&pong, reply, P7C_TIMEOUT_MS);
    if (kr != KERN_SUCCESS)
        return fail(fd, "client_receive_pong", (unsigned)kr, 76);
    if (pong.plain.h.msgh_id != P7C_PONG ||
        pong.plain.h.msgh_size != sizeof(simple_message) ||
        pong.plain.cookie != P7C_COOKIE ||
        pong.plain.pid != found.with_port.pid)
        return fail(fd, "client_pong_invalid", 1, 77);
    SAY(fd, "P7C0 CLIENT RECEIVED VALID SERVICE PONG\n");

    (void)mach_port_deallocate(mach_task_self(), service_port);
    (void)mach_port_deallocate(mach_task_self(), broker);
    (void)mach_port_destruct(mach_task_self(), reply, 0, 0);
    SAY(fd, "P7C0 CLIENT EXIT=42\n");
    return 42;
}

static int spawn_worker(int fd, const char *role, mach_port_t bootstrap, pid_t *out_pid) {
    posix_spawnattr_t attr = NULL;
    int rc = posix_spawnattr_init(&attr);
    if (rc) return fail(fd, "spawnattr_init", (unsigned)rc, 81);
    rc = posix_spawnattr_set_platform_np(&attr, P7C_PLATFORM_IOS, 0);
    if (rc) {
        (void)posix_spawnattr_destroy(&attr);
        return fail(fd, "spawnattr_set_platform_ios", (unsigned)rc, 82);
    }
    rc = posix_spawnattr_setspecialport_np(&attr, bootstrap, TASK_BOOTSTRAP_PORT);
    if (rc) {
        (void)posix_spawnattr_destroy(&attr);
        return fail(fd, "spawnattr_setspecialport", (unsigned)rc, 83);
    }
    char *const argv[] = {"/bin/pixelios-dynamic", (char *)role, NULL};
    char *const envp[] = {NULL};
    *out_pid = -1;
    rc = posix_spawn(out_pid, argv[0], NULL, &attr, argv, envp);
    (void)posix_spawnattr_destroy(&attr);
    if (rc || *out_pid <= 0) return fail(fd, "spawn_worker", (unsigned)rc, 84);
    return 0;
}

static int reap_worker(int fd, pid_t pid, const char *tag) {
    int status = 0;
    for (unsigned i = 0; i < 900; ++i) {
        pid_t rc = waitpid(pid, &status, WNOHANG);
        if (rc == pid) {
            if (!WIFEXITED(status) || WEXITSTATUS(status) != 42)
                return fail(fd, tag, (unsigned)status, 91);
            return 0;
        }
        if (rc < 0) return fail(fd, "waitpid_failed", 1, 92);
        (void)usleep(100000);
    }
    return fail(fd, "waitpid_timeout", (unsigned)pid, 93);
}

static int broker(int fd) {
    SAY(fd, "\nP7C0 MACH BOOTSTRAP SERVICE BROKER THROUGH DYLD\n");
    SAY(fd, "P7C0 BROKER PID=");
    num(fd, (uint32_t)getpid());
    SAY(fd, "\n");

    mach_port_t root_port = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &root_port);
    if (kr != KERN_SUCCESS || root_port == MACH_PORT_NULL)
        return fail(fd, "broker_port_allocate", (unsigned)kr, 51);
    kr = mach_port_insert_right(mach_task_self(), root_port, root_port, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS)
        return fail(fd, "broker_make_send", (unsigned)kr, 52);

    pid_t service_pid = -1, client_pid = -1;
    int rc = spawn_worker(fd, "--service", root_port, &service_pid);
    if (rc) return rc;
    SAY(fd, "P7C0 BROKER SPAWNED SERVICE PID=");
    num(fd, (uint32_t)service_pid);
    SAY(fd, "\n");

    receive_buffer registration;
    kr = recv_msg(&registration, root_port, P7C_TIMEOUT_MS);
    if (kr != KERN_SUCCESS)
        return fail(fd, "broker_receive_registration", (unsigned)kr, 53);
    if (registration.with_port.h.msgh_id != P7C_REGISTER ||
        registration.with_port.h.msgh_size != sizeof(port_message) ||
        !(registration.with_port.h.msgh_bits & MACH_MSGH_BITS_COMPLEX) ||
        registration.with_port.body.msgh_descriptor_count != 1 ||
        registration.with_port.desc.type != MACH_MSG_PORT_DESCRIPTOR ||
        registration.with_port.desc.name == MACH_PORT_NULL ||
        registration.with_port.cookie != P7C_COOKIE ||
        registration.with_port.pid != (uint32_t)service_pid)
        return fail(fd, "broker_registration_invalid", 1, 54);
    mach_port_t service_port = registration.with_port.desc.name;
    SAY(fd, "P7C0 BROKER REGISTERED SERVICE PORT NAME\n");

    rc = spawn_worker(fd, "--client", root_port, &client_pid);
    if (rc) return rc;
    SAY(fd, "P7C0 BROKER SPAWNED CLIENT PID=");
    num(fd, (uint32_t)client_pid);
    SAY(fd, "\n");

    receive_buffer lookup;
    kr = recv_msg(&lookup, root_port, P7C_TIMEOUT_MS);
    if (kr != KERN_SUCCESS)
        return fail(fd, "broker_receive_lookup", (unsigned)kr, 55);
    if (lookup.plain.h.msgh_id != P7C_LOOKUP ||
        lookup.plain.h.msgh_size != sizeof(simple_message) ||
        lookup.plain.cookie != P7C_COOKIE ||
        lookup.plain.pid != (uint32_t)client_pid ||
        lookup.plain.h.msgh_remote_port == MACH_PORT_NULL)
        return fail(fd, "broker_lookup_invalid", 1, 56);

    port_message answer = {0};
    answer.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0) | MACH_MSGH_BITS_COMPLEX;
    answer.h.msgh_size = sizeof(answer);
    answer.h.msgh_remote_port = lookup.plain.h.msgh_remote_port;
    answer.h.msgh_id = P7C_LOOKUP_REPLY;
    answer.body.msgh_descriptor_count = 1;
    answer.desc.name = service_port;
    answer.desc.type = MACH_MSG_PORT_DESCRIPTOR;
    answer.desc.disposition = MACH_MSG_TYPE_COPY_SEND;
    answer.cookie = P7C_COOKIE;
    answer.pid = (uint32_t)service_pid;
    kr = send_msg(&answer.h);
    if (kr != KERN_SUCCESS)
        return fail(fd, "broker_lookup_reply", (unsigned)kr, 57);
    SAY(fd, "P7C0 BROKER SENT SERVICE RIGHT TO CLIENT\n");

    rc = reap_worker(fd, client_pid, "client_exit_not_42");
    if (rc) return rc;
    SAY(fd, "P7C0 BROKER REAPED CLIENT EXIT=42\n");
    rc = reap_worker(fd, service_pid, "service_exit_not_42");
    if (rc) return rc;
    SAY(fd, "P7C0 BROKER REAPED SERVICE EXIT=42\n");

    kr = mach_port_deallocate(mach_task_self(), service_port);
    if (kr != KERN_SUCCESS)
        return fail(fd, "broker_service_port_release", (unsigned)kr, 58);
    kr = mach_port_destruct(mach_task_self(), root_port, -1, 0);
    if (kr != KERN_SUCCESS)
        return fail(fd, "broker_bootstrap_port_cleanup", (unsigned)kr, 59);

    SAY(fd, "P7C0 SERVICE REGISTER LOOKUP PING PONG PASS; EXIT=42\n");
    return 42;
}

int main(int argc, char **argv) {
    int fd = open("/dev/console", O_RDWR);
    if (fd < 0) return 99;
    int rc;
    if (argc == 2 && strcmp(argv[1], "--service") == 0) rc = service(fd);
    else if (argc == 2 && strcmp(argv[1], "--client") == 0) rc = client(fd);
    else rc = broker(fd);
    close(fd);
    return rc;
}
