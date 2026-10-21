# USB/LAN staging checkpoint — runtime tests incomplete

Base after rebase: `f28a3fd8155b82dd1be22608f6ef17e82437ad1d`. This audit reads project
source and frozen inputs. It does not infer network or storage PASS from
desktop PASS, source matches, static imports or QMP replies.

| Family | Existing network path | Remaining evidence / gap |
|---|---|---|
| 95 OSR2 / 98 FE / 98 SE / Me | `network_defaults.zig`: MS Client (VREDIR), MSTCP, DHCP, no sharing service; Dial-Up off by default. `network_setup.sh` matches actual PCI IDs before staging usosnet4 for 95 or usosnet for 98/Me. | User reports family X470 PASS; each exact image/language still needs its own lease, gateway ICMP and DNS log. RTM/OSR1 are separate. |
| NT4 | Setup installs LOOP + TCP/IP as a placeholder. `network_setup.sh` stages usosnet4 and switches NDISLoop/NDISLoop1 to the matched physical NIC. `POST.CMD` applies the binding. LAN helper disables Server/Browser services. | Loopback address is not LAN. R5/R6 stopped in internal Setup start 2; no MSC or NIC runtime result. Keyless R7 collects the actual question. |
| Windows 2000 | `prepare_xp_ntfs_target.sh` calls the W2K network stage. An exactly matching usosnet package is copied into OEM source trees. `usos_net_w2k_sif` requests MS Client, TCP/IP and empty NetServices. | Verify the actual installed adapter/bindings and live lease. R8 stopped before writes because the fixture disk was too small; retry R11 uses 32 GiB. |
| XP / 2003 x86 | Base answer has `InstallDefaultComponents=Yes`. The W2K-specific network stage does not run for XP/2003. | Separate unmerged fix/nt5-net d51b445a explicitly requests client/TCP-IP and empty NetServices. Driver staging/connectivity remain unproved. Prefer inbox or a verified redistributable vendor package; do not add a second own driver merely because the fixture lacks one. |
| XP x64 | `nt5_user_drivers.sh` accepts architecture-matched DATA/Drivers packages. Existing usosnet SYS is x86. | Need a matching amd64 NIC package; the x86 SYS cannot serve this route. |
| Server 2003 x86 | `nt5_user_drivers.sh` also stages x86 DATA/Drivers packages and reads every copied file back. | R5 correctly rejected a source-mismatched storage bundle. R12 uses a separately built, exact PL CD1 bundle without weakening source hashes. NIC readiness remains separate. |
| Vista / Server 2008 SP2 x86 | Existing bundled NT6 usosusb and shared notifier path; x86 WinPE donor used only for Setup. | Fresh R13 verifies storage and HID, including reconnect. NIC inbox/vendor presence and LAN defaults still require measurement; PE10 USB/NIC availability does not prove installed-system support. |
| NT3.51 | Existing USB HID path; no mass-storage implementation in current scope. | MSC is after 1.0. usosnet NDIS4/5 does not establish NDIS3 compatibility. |

The first-desktop LAN helper deliberately defers inside a VM and retains its
Run entry for the hardware desktop. QEMU therefore does not exercise that
hardware-only IE/default-user step automatically. The own logger on the
test scripts CD is explicit instrumentation; it does not change that policy
or turn the production staging into a new release. Runtime reports must
distinguish the two paths.

9x/NT LAN settings request LAN/autodial off/proxy off/offline off, a blank
home page and a 68k.news favorite. On IE3 the existing local `START.HTM`
fallback is intentional and must be reported instead of claiming about:blank
support. The current XP/2003 gap above remains work, not PASS. Profile
`network=off` and an explicit Dial-Up choice must remain user decisions.

Separate unmerged changes:

- `fix/nt4-net` / `54282e85` (previous `9859f850`): quiet USOSLOG, explicit DHCP configuration vs
  measured connectivity, validated ICMP gateway reply and DNS; host tests
  and PE4 build passed, fresh NT4 execution pending.
- `fix/nt6x86-usb` / `a624beb4`, `90cefea8` (previous `4f54df6b`, `655af5ef`): notifier installation errors stop
  restart; log location follows EXE, no PUBLIC fallback. 31 selected host
  tests passed, one packaged-support comparison skipped. Private R13 cache
  changes only the own CMD and notifier; USB driver bytes stay unchanged.
- `fix/win95-usb` / `6b18f5c3` (previous `09c399d1`): FAT16 prerequisite for RTM/OSR1; 10 new tests
  and 20 USB/INT13 regressions passed. Not a new RTM NIC/USB driver. R9 tests
  98 FE/SE EN first; R10 tests RTM/OSR1 after it.
- `fix/nt5-net` / `d51b445a`: explicit MS Client/TCP-IP with empty NetServices
  for XP/2003 automatic answers. 3 new component tests, 79 settings checks
  and 9215 renderer checks PASS; fresh runtime pending. Existing custom SIF
  and W2K network-off decisions are preserved.

Upstream now includes the hubs/root-port fix. The reported X470 round 2
confirms keyboard and mouse reconnect on front/rear root ports in Win7 SP1
PL x86, with `usosusb 1.3-nt6`. Hubs remain QEMU only. Frozen R6/R9–R13
fixtures remain the older, explicitly hashed inputs; rebasing source does
not replace their driver bytes or make them a new build. No hub source was
edited by these branches. The unmerged NT4 MSC feature still needs its
owner to integrate it with the upstream hub changes.

QEMU has working NIC interrupts and does not reproduce the X470 I211 IRQ
problem or verify the 20 ms fallback on that hardware. After keyboard/mouse
reconnect, test actual characters, pointer movement and clicks plus driver
diagnostics; PS/2 fallback and a successful QMP command are not USB PASS.
Opening a cached editor buffer after stick removal is not a fresh read:
close and reopen the marker file. No physical disks or host USB passthrough
are used by these fixtures. Images are thin and removed by normal cleanup.

No hubs code, x64 signing policy, firmware release, physical medium, merge
or deployment is changed by this audit.
