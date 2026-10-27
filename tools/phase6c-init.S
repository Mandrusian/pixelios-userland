#define SYS_exit     1
#define SYS_fork     2
#define SYS_write    4
#define SYS_open     5
#define SYS_wait4    7
#define SYS_getpid   20
#define SYS_getppid  39
#define SYS_select   93
#define O_RDWR       2
#define WNOHANG      1

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
    b.cs identity_failure
    mov x20, x0
    SAY parent_prefix
    mov x0, x20
    bl print_number
    SAY newline
    mov x24, #0
    mov x25, #1

spawn_next:
    SAY spawning
    mov x0, x25
    bl print_number
    SAY newline
    mov x16, #SYS_fork
    svc #0x80
    b.cs fork_failure
    mov x22, x0
    mov x16, #SYS_getpid
    svc #0x80
    b.cs identity_failure
    cmp x0, x20
    b.ne child_path
    cbz x22, fork_failure

parent_path:
    SAY forked_prefix
    mov x0, x22
    bl print_number
    SAY newline
    sub sp, sp, #32
    str wzr, [sp]
    mov x23, #0

poll_child:
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
    cmp x23, #20
    b.hs wait_timeout
    mov x0, #0
    mov x1, #0
    mov x2, #0
    mov x3, #0
    adr x4, one_second
    mov x16, #SYS_select
    svc #0x80
    b poll_child

check_status:
    ldr w10, [sp]
    add sp, sp, #32
    tst w10, #0x7f
    b.ne bad_exit_status
    ubfx w10, w10, #8, #8
    cmp w10, #42
    b.ne bad_exit_status
    SAY child_reaped
    mov x0, x25
    bl print_number
    SAY newline
    add x24, x24, #1
    add x25, x25, #1
    cmp x25, #3
    b.lo spawn_next
    SAY summary
    mov x0, x24
    bl print_number
    SAY newline
    b heartbeat

child_path:
    SAY child_index
    mov x0, x25
    bl print_number
    SAY newline
    SAY child_pid
    mov x16, #SYS_getpid
    svc #0x80
    bl print_number
    SAY newline
    SAY child_ppid
    mov x16, #SYS_getppid
    svc #0x80
    bl print_number
    SAY newline
    SAY child_exiting
    mov x0, #42
    mov x16, #SYS_exit
    svc #0x80
    b hang

wait_failure:
    add sp, sp, #32
    SAY wait_failed
    b heartbeat
wait_timeout:
    add sp, sp, #32
    SAY wait_timed_out
    b heartbeat
bad_exit_status:
    SAY bad_status
    b heartbeat
fork_failure:
    SAY fork_failed
    b heartbeat
identity_failure:
    SAY pid_failed

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
banner:
    .ascii "\nPIXELIOS PHASE 6C: DARWIN FORK + WAIT4\n"
banner_end:
parent_prefix:
    .ascii "P6C PARENT PID="
parent_prefix_end:
spawning:
    .ascii "P6C SPAWN CHILD #"
spawning_end:
forked_prefix:
    .ascii "P6C FORK RETURNED PID="
forked_prefix_end:
child_index:
    .ascii "P6C CHILD INDEX="
child_index_end:
child_pid:
    .ascii "P6C CHILD PID="
child_pid_end:
child_ppid:
    .ascii "P6C CHILD PPID="
child_ppid_end:
child_exiting:
    .ascii "P6C CHILD EXITING 42\n"
child_exiting_end:
child_reaped:
    .ascii "P6C WAIT4 PASS CHILD #"
child_reaped_end:
summary:
    .ascii "P6C REAPED CHILDREN="
summary_end:
fork_failed:
    .ascii "P6C FORK FAILED\n"
fork_failed_end:
wait_failed:
    .ascii "P6C WAIT4 FAILED\n"
wait_failed_end:
wait_timed_out:
    .ascii "P6C WAIT4 TIMEOUT (20s)\n"
wait_timed_out_end:
bad_status:
    .ascii "P6C CHILD EXIT STATUS FAIL\n"
bad_status_end:
pid_failed:
    .ascii "P6C GETPID FAILED\n"
pid_failed_end:
newline:
    .ascii "\n"
newline_end:
alive:
    .ascii "P6C HEARTBEAT: PID 1 ALIVE\n"
alive_end:
