# USOS 1.0 release notes (draft)

Draft of the notes for the 1.0 release; filled in while the "Przed 1.0"
checklist of [ROADMAP.md](ROADMAP.md) (section 2a) is worked through.

## Known issues

### Windows Vista: USB flash drives are not visible in the installed system

On boards with only USB 3 (xHCI) ports, such as the ASRock X470, Vista has
no USB 3 driver of its own; USOS installs a test-signed USB 3 backport so
that the keyboard and the mouse work. With that stack, USB flash drives and
other USB mass-storage devices do not show up in Explorer or Disk
Management. Keyboard and mouse are not affected. The cause is still being
investigated (logs from the X470 are pending).

Workaround:

- move files over the network (a shared folder on another PC), or through a
  second internal disk (SATA) or an optical drive;
- or fit a PCIe USB 3 card with a Renesas uPD72020x controller and install
  its vendor driver for Vista: its own USB stack should also drive USB
  storage, and it is the only way to leave the test mode on the X470.

### Windows Vista on X470 stays in test mode

The USB 3 backport is test-signed, so Vista x64 runs with test signing on
("Test Mode" on the desktop). See ROADMAP.md section 3.
