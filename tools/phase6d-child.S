#define SYS_exit     1
#define SYS_write    4
#define SYS_open     5
#define SYS_getpid  20
#define SYS_getppid 39
#define O_RDWR       2

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
    b.cs exit_error
    mov x19, x0
    SAY banner

    mov x16, #SYS_getpid
    svc #0x80
    b.cs exit_error
    SAY pid_prefix
    bl print_number
    SAY newline

    mov x16, #SYS_getppid
    svc #0x80
    b.cs exit_error
    mov x20, x0
    SAY ppid_prefix
    mov x0, x20
    bl print_number
    SAY newline

    cmp x20, #1
    b.ne ppid_error
    SAY pass
    mov x0, #42
    b exit_now

ppid_error:
    SAY ppid_bad
exit_error:
    mov x0, #96

exit_now:
    mov x16, #SYS_exit
    svc #0x80
hang:
    b hang

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

.p2align 3
console_path:
    .asciz "/dev/console"
banner:
    .ascii "P6D EXTERNAL MACH-O CHILD LOADED FROM HFS+\n"
banner_end:
pid_prefix:
    .ascii "P6D EXEC CHILD PID="
pid_prefix_end:
ppid_prefix:
    .ascii "P6D EXEC CHILD PPID="
ppid_prefix_end:
pass:
    .ascii "P6D EXEC CHILD EXIT=42\n"
pass_end:
ppid_bad:
    .ascii "P6D EXEC CHILD WRONG PARENT\n"
ppid_bad_end:
newline:
    .ascii "\n"
newline_end:
