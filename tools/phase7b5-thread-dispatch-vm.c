#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_map.h>
#include <pthread.h>
#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <unistd.h>
#include <fcntl.h>

#define P7B5_VM_BYTES 16384
#define P7B5_THREAD_VALUE 0x7b051234u
#define P7B5_DISPATCH_VALUE 0x7b055678u

static void say(int fd, const char *msg, size_t n) {
    while (n) {
        ssize_t sent = write(fd, msg, n);
        if (sent <= 0) return;
        msg += sent;
        n -= (size_t)sent;
    }
}
#define SAY(fd, msg) say(fd, msg, sizeof(msg) - 1)

static void print_number(int fd, unsigned v) {
    char b[16];
    size_t pos = sizeof(b);
    do {
        b[--pos] = (char)('0' + v % 10u);
        v /= 10u;
    } while (v);
    say(fd, b + pos, sizeof(b) - pos);
}

static int fail(int fd, const char *which, size_t count, unsigned code, int status) {
    SAY(fd, "P7B5 FAIL ");
    say(fd, which, count);
    SAY(fd, " CODE=");
    print_number(fd, code);
    SAY(fd, "\n");
    return status;
}
#define FAIL(fd, name, code, status) fail(fd, name, sizeof(name) - 1, (unsigned)(code), status)

typedef struct {
    _Atomic unsigned finished;
    uint32_t result;
    pthread_mutex_t mutex;
} thread_test;

static void *thread_main(void *arg) {
    thread_test *test = (thread_test *)arg;
    if (pthread_mutex_lock(&test->mutex) == 0) {
        test->result = P7B5_THREAD_VALUE;
        (void)pthread_mutex_unlock(&test->mutex);
    }
    atomic_store_explicit(&test->finished, 1u, memory_order_release);
    return (void *)(uintptr_t)P7B5_THREAD_VALUE;
}

typedef struct {
    _Atomic unsigned finished;
    uint32_t result;
    dispatch_semaphore_t semaphore;
} dispatch_test;

static void dispatch_main(void *arg) {
    dispatch_test *test = (dispatch_test *)arg;
    test->result = P7B5_DISPATCH_VALUE;
    atomic_store_explicit(&test->finished, 1u, memory_order_release);
    dispatch_semaphore_signal(test->semaphore);
}

int main(void) {
    int fd = open("/dev/console", O_RDWR);
    if (fd < 0) return 90;

    SAY(fd, "\nP7B5 PTHREAD DISPATCH AND MACH VM THROUGH DYLD\n");
    SAY(fd, "P7B5 DYNAMIC PID=");
    print_number(fd, (unsigned)getpid());
    SAY(fd, "\n");

    thread_test t = {0};
    int status = pthread_mutex_init(&t.mutex, NULL);
    if (status != 0) return FAIL(fd, "pthread_mutex_init", status, 51);

    pthread_t tid;
    status = pthread_create(&tid, NULL, thread_main, &t);
    if (status != 0) return FAIL(fd, "pthread_create", status, 52);
    SAY(fd, "P7B5 PTHREAD CREATE PASS\n");

    unsigned i = 0;
    for (; i < 800; ++i) {
        if (atomic_load_explicit(&t.finished, memory_order_acquire)) break;
        (void)usleep(10000);
    }
    if (i == 800) return FAIL(fd, "pthread_worker_timeout", 800, 53);

    void *ret = NULL;
    status = pthread_join(tid, &ret);
    if (status != 0) return FAIL(fd, "pthread_join", status, 54);
    if ((uintptr_t)ret != (uintptr_t)P7B5_THREAD_VALUE ||
        t.result != P7B5_THREAD_VALUE)
        return FAIL(fd, "pthread_result_mismatch", t.result, 55);
    (void)pthread_mutex_destroy(&t.mutex);
    SAY(fd, "P7B5 PTHREAD JOIN AND MUTEX PASS\n");

    dispatch_test dt = {0};
    dt.semaphore = dispatch_semaphore_create(0);
    if (!dt.semaphore) return FAIL(fd, "dispatch_semaphore_create", 0, 56);

    dispatch_queue_t queue = dispatch_queue_create("tech.mandrusia.pixelios.phase7b5", DISPATCH_QUEUE_SERIAL);
    if (!queue) return FAIL(fd, "dispatch_queue_create", 0, 57);
    SAY(fd, "P7B5 DISPATCH QUEUE CREATED\n");

    dispatch_async_f(queue, &dt, dispatch_main);
    long wait_error = dispatch_semaphore_wait(dt.semaphore,
            dispatch_time(DISPATCH_TIME_NOW, 8LL * NSEC_PER_SEC));
    if (wait_error != 0)
        return FAIL(fd, "dispatch_semaphore_timed_out", (unsigned)wait_error, 58);
    if (atomic_load_explicit(&dt.finished, memory_order_acquire) != 1u ||
        dt.result != P7B5_DISPATCH_VALUE)
        return FAIL(fd, "dispatch_payload_mismatch", dt.result, 59);

    dispatch_release(queue);
    dispatch_release(dt.semaphore);
    SAY(fd, "P7B5 DISPATCH ASYNC AND SEMAPHORE PASS\n");

    mach_vm_address_t addr = 0;
    kern_return_t kr = mach_vm_allocate(mach_task_self(), &addr,
                                        P7B5_VM_BYTES, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS || addr == 0)
        return FAIL(fd, "mach_vm_allocate", kr, 60);
    SAY(fd, "P7B5 MACH VM ALLOCATE PASS\n");

    volatile uint32_t *value = (volatile uint32_t *)(uintptr_t)addr;
    value[0] = 0x7b05aabb;
    value[64] = 0x11223344;
    if (value[0] != 0x7b05aabb || value[64] != 0x11223344)
        return FAIL(fd, "mach_vm_read_write_mismatch", 0, 61);

    kr = mach_vm_deallocate(mach_task_self(), addr, P7B5_VM_BYTES);
    if (kr != KERN_SUCCESS)
        return FAIL(fd, "mach_vm_deallocate", kr, 62);
    SAY(fd, "P7B5 MACH VM WRITE READ AND DEALLOCATE PASS\n");

    void *mapping = mmap(NULL, P7B5_VM_BYTES,
                         PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANON, -1, 0);
    if (mapping == MAP_FAILED)
        return FAIL(fd, "mmap", 0, 63);
    ((volatile uint8_t *)mapping)[123] = 0x5a;
    if (((volatile uint8_t *)mapping)[123] != 0x5a)
        return FAIL(fd, "mmap_payload", 0, 64);
    if (munmap(mapping, P7B5_VM_BYTES) != 0)
        return FAIL(fd, "munmap", 0, 65);
    SAY(fd, "P7B5 MMAP AND MUNMAP PASS\n");

    SAY(fd, "P7B5 PTHREAD DISPATCH MACH VM PASS; EXIT=42\n");
    close(fd);
    return 42;
}
