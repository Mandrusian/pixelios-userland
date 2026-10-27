#define SYS_exit    1
#define SYS_fork    2
#define SYS_write   4
#define SYS_open    5
#define SYS_wait4   7
#define SYS_getpid  20
#define SYS_select  93
#define SYS_execve  59
#define O_RDWR      2
#define WNOHANG     1

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

    SAY banner
    mov x16, #SYS_getpid
    svc #0x80
    b.cs pid_failure
    mov x20, x0
    SAY init_pid
    mov x0, x20
    bl print_number
    SAY newline

    mov x24, #0
    mov x25, #1

spawn_next:
    SAY launch_prefix
    mov x0, x25
    bl print_number
    SAY newline
    mov x16, #SYS_fork
    svc #0x80
    b.cs fork_failure
    mov x22, x0

    mov x16, #SYS_getpid
    svc #0x80
    b.cs pid_failure
    cmp x0, x20
    b.ne child_fork
    cbz x22, fork_failure

parent:
    SAY forked_prefix
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
    b.cs wait_failure
    cmp x0, x22
    b.eq check_status
    cbnz x0, wait_failure
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
    b.ne bad_exit
    ubfx w10, w10, #8, #8
    cmp w10, #42
    b.ne bad_exit
    SAY reaped_prefix
    mov x0, x25
    bl print_number
    SAY newline
    add x24, x24, #1
    add x25, x25, #1
    cmp x25, #3
    b.lo spawn_next
    SAY reaped_total
    mov x0, x24
    bl print_number
    SAY newline
    SAY pass
    b heartbeat

child_fork:
    SAY child_attempt
    sub sp, sp, #32
    adr x9, child_path
    str x9, [sp]
    str xzr, [sp, #8]
    str xzr, [sp, #16]
    adr x0, child_path
    mov x1, sp
    add x2, sp, #16
    mov x16, #SYS_execve
    svc #0x80
    b.cs exec_failed
    SAY exec_returned
    mov x0, #98
    b exit_child

exec_failed:
    SAY exec_failed_msg
    mov x0, #97
exit_child:
    mov x16, #SYS_exit
    svc #0x80
    b hang

fork_failure:
    SAY fork_failed_msg
    b heartbeat
pid_failure:
    SAY pid_failed_msg
    b heartbeat
wait_failure:
    add sp, sp, #32
    SAY wait_failed_msg
    b heartbeat
wait_timeout:
    add sp, sp, #32
    SAY wait_timeout_msg
    b heartbeat
bad_exit:
    SAY bad_status_msg

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
    .asciz "/bin/pixelios-child"
banner:
    .ascii "\nPIXELIOS PHASE 6D: FORK + EXECVE + WAIT4\n"
banner_end:
init_pid:
    .ascii "P6D INIT PID="
init_pid_end:
newline:
    .ascii "\n"
newline_end:
launch_prefix:
    .ascii "P6D LAUNCH CHILD #"
launch_prefix_end:
forked_prefix:
    .ascii "P6D FORK CHILD PID="
forked_prefix_end:
child_attempt:
    .ascii "P6D CHILD CALLING EXECVE /bin/pixelios-child\n"
child_attempt_end:
reaped_prefix:
    .ascii "P6D EXEC+WAIT PASS CHILD #"
reaped_prefix_end:
reaped_total:
    .ascii "P6D REAPED CHILDREN="
reaped_total_end:
pass:
    .ascii "P6D MULTIPROCESS EXEC PASS\n"
pass_end:
exec_failed_msg:
    .ascii "P6D EXECVE FAILED\n"
exec_failed_msg_end:
exec_returned:
    .ascii "P6D EXECVE UNEXPECTED RETURN\n"
exec_returned_end:
fork_failed_msg:
    .ascii "P6D FORK FAILED\n"
fork_failed_msg_end:
pid_failed_msg:
    .ascii "P6D GETPID FAILED\n"
pid_failed_msg_end:
wait_failed_msg:
    .ascii "P6D WAIT4 FAILED\n"
wait_failed_msg_end:
wait_timeout_msg:
    .ascii "P6D WAIT4 TIMEOUT (30s)\n"
wait_timeout_msg_end:
bad_status_msg:
    .ascii "P6D CHILD EXIT STATUS FAIL\n"
bad_status_msg_end:
alive:
    .ascii "P6D HEARTBEAT: PID 1 ALIVE\n"
alive_end:
