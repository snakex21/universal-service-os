<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Bootfiles test limits

The bootfiles runner uses fixed raw containers below QCOW2. The target
container is 128 MiB and the utility overlay is 8 MiB. QEMU image creation
and the `bootfiles` internal snapshot use the same bounded block graph;
ordinary `qemu-img create` or `snapshot` would bypass its bound.

The utility FAT image is 65 MiB. Disjoint pre-write limits cover debug
output (2 MiB), stderr (1 MiB), firmware variables (1 MiB), the copied-file
manifest (1 MiB), receipt (1 MiB), configuration (4 KiB), and entropy
(64 bytes). Together these are below the approved 208 MiB whole-case
bound. Unknown outputs, reparse points, and shared files are refused.
The guest has no serial output file; debugcon is drained through a bounded
pipe. Completion, output-limit and timeout events wake the owner without
sampling logs or VM state.

Normal capacity rules remain unchanged. One separate approval file can
authorize the specific review case with a 74 GiB free-space reserve and
175 GiB pool cap. It requires a completed, pinned reference-firstboot
receipt, an identified runtime volume, and a fresh exact output path.
It does not authorize another Windows firstboot or another test case.

This is a bootfiles preparation gate. Its successful firmware exit is not
evidence that Windows reached OOBE or a desktop.

Firstboot also treats an unsolicited QMP `STOP` as a terminal diagnostic
endpoint. WHPX can emit this event after `Unexpected VP exit code 4`
without exiting the QEMU process or closing QMP. The runner captures the
stopped endpoint and quits without `cont`; it marks transport evidence as
failed instead of consuming the remaining three-hour deadline.

For a long firstboot, `--wake-screen` can press and release Shift once at
the fixed endpoint, wait two seconds for display power to recover, then
stop the VM and capture the only screenshot. It never queries progress or
presses Enter/clicks through OOBE. The default remains disabled, and it is
not sent after guest shutdown or an unsolicited STOP. A black screenshot
without this wake is not independently proof of a failed Windows boot.
