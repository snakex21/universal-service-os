# Windows 95 HID transport evidence — runtime pending

The private RTM R46/R47 comparison changed only i8042 from off to on.
Both retained the same 512 MiB, CPU, CSMWrap, NVMe, USB and diagnostic
image with own miniports inactive. R46 remained at Windows loading; R47
reached graphical hardware setup and asked for the deliberately absent
NVMe driver. This does not prove a desktop or USB input. It does show
that removing the controller is unsuitable for this RTM coverage case.

Keep the controller available, but require three independent observations:
guest-visible keyboard/mouse actions after replug, completed reports in
the corresponding USB device PCAP, and no PS2 input in the audit interval.
The audit proxy starts PS2 traces before the first actual HID removal and
gives every reinserted device a new PCAP file. It never assigns PASS.
Use only after independently verified preparation/key acceptance; never
open ProductID/System Properties or key pages. Store captures privately.

The actual local QEMU binary exposes USB `pcap` properties and the three
PS2 trace names. An own boot-sector positive control R48 exercised all
three: ready nonce, exit85, one keyboard event/keycode and two mouse
packets in 0.532 s. This validates the tracing mechanism, not Windows.

Upstream reference semantics: [PS2 events](https://raw.githubusercontent.com/qemu/qemu/master/hw/input/ps2.c)
and [USB PCAP](https://raw.githubusercontent.com/qemu/qemu/master/hw/usb/pcap.c).
The local binary reports 11.1.0-12130-ge470268ff4; that commit was not
available in the upstream mirror, so the references are not claimed as
an exact source match. The real positive control uses the actual binary.

Seven synthetic instrumentation contract tests pass. Guest USB report
decoding, guest actions and a full fresh normal installation remain to
be verified. A trace or QMP acknowledgement alone is not functional proof.
