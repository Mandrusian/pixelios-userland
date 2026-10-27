#define SYS_write       4
#define SYS_open        5
#define SYS_getpid      20
#define SYS_getuid      24
#define SYS_getppid     39
#define SYS_getgid      47
#define SYS_munmap      73
#define SYS_select      93
#define SYS_mmap        197
#define O_RDWR          2
#define PROT_READ_WRITE 3
#define MAP_PRIVATE_ANON 0x1002

.text
.globl _start
.p2align 2

.macro SAY name
    adr x1, \name
    adr x2, \name\()_end
    sub x2, x2, x1
    bl write_console
.endm

.macro REPORT_ID number, name
    mov x16, #\number
    svc #0x80
    mov x21, x0
    b.cs 9f
    SAY \name
    mov x0, x21
    bl print_number
    SAY newline
    b 8f
9:
    SAY id_failure
8:
.endm

_start:
    mov x9, sp
    and x9, x9, #~15
    mov sp, x9

    adr x0, console_path
    mov x1, #O_RDWR
    mov x2, #0
    mov x16, #SYS_open
    svc #0x80
    b.cs hang
    mov x19, x0

    SAY banner
    REPORT_ID SYS_getpid, pid_prefix
    REPORT_ID SYS_getppid, ppid_prefix
    REPORT_ID SYS_getuid, uid_prefix
    REPORT_ID SYS_getgid, gid_prefix

    sub sp, sp, #32
    mov x10, #0x1234
    movk x10, #0x5678, lsl #16
    movk x10, #0x9abc, lsl #32
    movk x10, #0xdef0, lsl #48
    mvn x11, x10
    str x10, [sp]
    str x11, [sp, #8]
    ldr x12, [sp]
    ldr x13, [sp, #8]
    cmp x10, x12
    b.ne stack_failure
    cmp x11, x13
    b.ne stack_failure
    add sp, sp, #32
    SAY stack_ok
    b test_mmap
stack_failure:
    add sp, sp, #32
    SAY stack_bad

test_mmap:
    mov x0, #0
    mov x1, #16384
    mov x2, #PROT_READ_WRITE
    mov x3, #MAP_PRIVATE_ANON
    mov x4, #-1
    mov x5, #0
    mov x16, #SYS_mmap
    svc #0x80
    b.cs mmap_failure
    cbz x0, mmap_failure
    mov x20, x0

    mov x10, #0xabcd
    movk x10, #0x1234, lsl #16
    movk x10, #0x5678, lsl #32
    movk x10, #0x9abc, lsl #48
    str x10, [x20]
    str x10, [x20, #8192]
    ldr x11, [x20]
    cmp x11, x10
    b.ne mmap_corruption
    ldr x11, [x20, #8192]
    cmp x11, x10
    b.ne mmap_corruption

    mov x0, x20
    mov x1, #16384
    mov x16, #SYS_munmap
    svc #0x80
    b.cs munmap_failure
    SAY mmap_ok
    b heartbeat
mmap_corruption:
    SAY mmap_bad
    b heartbeat
mmap_failure:
    SAY mmap_unavailable
    b heartbeat
munmap_failure:
    SAY munmap_bad

heartbeat:
    mov x0, #0
    mov x1, #0
    mov x2, #0
    mov x3, #0
    adr x4, five_seconds
    mov x16, #SYS_select
    svc #0x80
    SAY alive
    b heartbeat

print_number:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    mov x11, x0
    add x10, sp, #63
    mov x12, #10
1:
    udiv x13, x11, x12
    msub x14, x13, x12, x11
    add w14, w14, #'0'
    strb w14, [x10, #-1]!
    mov x11, x13
    cbnz x11, 1b
    mov x1, x10
    add x2, sp, #63
    sub x2, x2, x10
    bl write_console
    ldp x29, x30, [sp], #64
    ret

write_console:
    mov x0, x19
    mov x16, #SYS_write
    svc #0x80
    ret

hang:
    b hang

.p2align 3
five_seconds:
    .quad 5
    .quad 0
console_path:
    .asciz "/dev/console"
banner:
    .ascii "\nPIXELIOS PHASE 6B: NATIVE DARWIN DIAGNOSTICS\n"
banner_end:
pid_prefix:
    .ascii "P6B PID="
pid_prefix_end:
ppid_prefix:
    .ascii "P6B PPID="
ppid_prefix_end:
uid_prefix:
    .ascii "P6B UID="
uid_prefix_end:
gid_prefix:
    .ascii "P6B GID="
gid_prefix_end:
newline:
    .ascii "\n"
newline_end:
id_failure:
    .ascii "P6B ID SYSCALL FAILED\n"
id_failure_end:
stack_ok:
    .ascii "P6B STACK PASS\n"
stack_ok_end:
stack_bad:
    .ascii "P6B STACK FAIL\n"
stack_bad_end:
mmap_ok:
    .ascii "P6B MMAP PASS (16K RW anonymous, verified, unmapped)\n"
mmap_ok_end:
mmap_bad:
    .ascii "P6B MMAP CORRUPTION\n"
mmap_bad_end:
mmap_unavailable:
    .ascii "P6B MMAP UNAVAILABLE\n"
mmap_unavailable_end:
munmap_bad:
    .ascii "P6B MUNMAP FAILED\n"
munmap_bad_end:
alive:
    .ascii "P6B HEARTBEAT: PID 1 ALIVE\n"
alive_end:
