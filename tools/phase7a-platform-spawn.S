#define SYS_open        5
#define SYS_write       4
#define SYS_getpid     20
#define SYS_wait4       7
#define SYS_select     93
#define SYS_posix_spawn 244
#define O_RDWR          2
#define WNOHANG         1
#define PLATFORM_IOS    2
#define SPAWN_ATTR_SIZE 184
#define SPAWN_PLATFORM_OFFSET 108

.text
.globl _start
.p2align 2

.macro SAY name
    adr x1, \name
    adr x2, \name\()_end
    sub x2, x2, x1
    bl write_console
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

    sub sp, sp, #512
    mov x26, sp
    add x27, x26, #256
    add x28, x26, #384
    mov x10, x26
    mov x11, #32
clear_structures:
    stp xzr, xzr, [x10], #16
    subs x11, x11, #1
    b.ne clear_structures

    mov w10, #PLATFORM_IOS
    str w10, [x26, #SPAWN_PLATFORM_OFFSET]
    mov x10, #SPAWN_ATTR_SIZE
    str x10, [x27]
    str x26, [x27, #8]

    adr x10, child_path
    str x10, [x28]
    str xzr, [x28, #8]
    str xzr, [x28, #16]

    SAY banner
    mov x16, #SYS_getpid
    svc #0x80
    b.cs pid_failed
    mov x20, x0
    SAY parent_prefix
    mov x0, x20
    bl print_number
    SAY newline

    mov x24, #0
    mov x25, #1

spawn_next:
    SAY launching
    mov x0, x25
    bl print_number
    SAY newline

    add x0, x28, #32
    str wzr, [x0]
    adr x1, child_path
    mov x2, x27
    mov x3, x28
    add x4, x28, #16
    mov x16, #SYS_posix_spawn
    svc #0x80
    b.cs spawn_failed
    ldr w22, [x28, #32]
    cbz x22, spawn_failed

    SAY spawned_prefix
    mov x0, x22
    bl print_number
    SAY newline

    sub sp, sp, #32
    str wzr, [sp]
    mov x23, #0

wait_child:
    mov x0, x22
    mov x1, sp
    mov x2, #WNOHANG
    mov x3, #0
    mov x16, #SYS_wait4
    svc #0x80
    b.cs wait_failed
    cmp x0, x22
    b.eq check_status
    cbnz x0, wait_failed
    add x23, x23, #1
    cmp x23, #30
    b.hs wait_timeout

    mov x0, #0
    mov x1, #0
    mov x2, #0
    mov x3, #0
    adr x4, one_second
    mov x16, #SYS_select
    svc #0x80
    b wait_child

check_status:
    ldr w10, [sp]
    add sp, sp, #32
    tst w10, #0x7f
    b.ne bad_status
    ubfx w10, w10, #8, #8
    cmp w10, #42
    b.ne bad_status
    SAY reaped_prefix
    mov x0, x25
    bl print_number
    SAY newline
    add x24, x24, #1
    add x25, x25, #1
    cmp x25, #3
    b.lo spawn_next
    SAY total_reaped
    mov x0, x24
    bl print_number
    SAY newline
    SAY success
    b heartbeat

spawn_failed:
    SAY spawn_failure
    b heartbeat
wait_failed:
    add sp, sp, #32
    SAY wait_failure
    b heartbeat
wait_timeout:
    add sp, sp, #32
    SAY wait_timeout_msg
    b heartbeat
bad_status:
    SAY status_failure
    b heartbeat
pid_failed:
    SAY pid_failure

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
one_second:
    .quad 1
    .quad 0
five_seconds:
    .quad 5
    .quad 0
console_path:
    .asciz "/dev/console"
child_path:
    .asciz "/bin/pixelios-dynamic"
banner:
    .ascii "\nPIXELIOS PHASE 7A: IOS PLATFORM POSIX_SPAWN\n"
banner_end:
parent_prefix:
    .ascii "P7A INIT PID="
parent_prefix_end:
launching:
    .ascii "P7A POSIX_SPAWN PLATFORM_IOS CHILD #"
launching_end:
spawned_prefix:
    .ascii "P7A SPAWN CHILD PID="
spawned_prefix_end:
reaped_prefix:
    .ascii "P7A DYNAMIC EXEC+WAIT PASS CHILD #"
reaped_prefix_end:
total_reaped:
    .ascii "P7A REAPED CHILDREN="
total_reaped_end:
success:
    .ascii "P7A DYNAMIC LIBSYSTEM MULTIPROCESS PASS\n"
success_end:
spawn_failure:
    .ascii "P7A POSIX_SPAWN FAILED\n"
spawn_failure_end:
wait_failure:
    .ascii "P7A WAIT4 FAILED\n"
wait_failure_end:
wait_timeout_msg:
    .ascii "P7A WAIT4 TIMEOUT (30s)\n"
wait_timeout_msg_end:
status_failure:
    .ascii "P7A DYNAMIC CHILD EXIT STATUS FAIL\n"
status_failure_end:
pid_failure:
    .ascii "P7A GETPID FAILED\n"
pid_failure_end:
newline:
    .ascii "\n"
newline_end:
alive:
    .ascii "P7A HEARTBEAT: PID 1 ALIVE\n"
alive_end:
