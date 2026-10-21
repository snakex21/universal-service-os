# Coverage fixture completion and UART input loss

The first RTM r13 attempt never entered USOS. Its preparation log shows
`mkfs.fat -F 32 -n USOS_ESda1`, an input line truncated by the UART, followed
by a kernel panic. The old low-RAM harness classified the echoed command
`echo LOWRAM-RESULT=PASS` as success. The resulting stick contained a GPT
but no formatted filesystems, and OVMF entered its firmware shell.

Fixture commands now run as a PID-1 script appended to the private initrd,
with no serial command upload. Failures print a failure marker and power
off. Before success, the script compares the EFI boot application,
initramfs, complete ISO and prerequisite media, then syncs and unmounts the
writable partitions. An independent exact completion line, successful
child exit, no deadline and no kernel panic are all required. Historical
metadata without this proof cannot start a coverage VM. Firmware-shell
output before USOS is a terminal runner error, rather than a long wait.

The shared low-RAM worktree and production installer are unchanged. Seven
host regression cases cover echoed success, panic, child failure, deadline,
clean completion, historical metadata and firmware fallback. A fresh RTM
fixture in QEMU completed all comparisons, sync and unmount in 47.034 s;
`commands_sent=false`, clean child exit and the independent marker were
verified. This checks the disposable installation media, not Windows.
The subsequent normal menu/install test is pending. No Windows runtime
PASS is claimed.
