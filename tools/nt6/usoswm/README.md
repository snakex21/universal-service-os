# USOS test-mode desktop presentation (experimental)

Status: host checks and measured PL x64 desktop, opt-out, cold Startup,
Explorer/resolution/Classic-theme trials pass in Vista/2008 QEMU. The complete
setup/RDP/hardware matrix is still pending. **Do not release or deploy this
worktree's package yet.** GPL-3.0-or-later.

This is a user-mode presentation component for Vista SP2 / Server 2008 SP2 x64
(NT 6.0.6002) with TESTSIGNING enabled. It does not change Code Integrity,
PatchGuard, BCD, boot files, kernel memory or Microsoft files.

## Files and lifetime

- `usoswm.exe`: one message-driven launcher per interactive session. It waits
  for shell window events and TaskbarCreated; there is no process polling.
- `usoswm-desktop.dll`: installed with a thread-scoped WH_CALLWNDPROC hook in
  that session's Windows explorer.exe desktop thread. It changes two shell32
  import pointers, PaintDesktop and PaintMonitor, only in that process.
  It pins its module while the Explorer process lives so import pointers cannot
  refer to an unloaded DLL. Restarting Explorer loads a fresh instance.
- `usoswm-register.exe`: target-OS, elevated registration of a single common
  Windows Startup shortcut. Repeated registration preserves a matching link;
  a conflicting foreign link is not overwritten. Opt-out removes only our link.
  Unsupported OS or TESTSIGNING OFF exits before registration.

The user explicitly approved this one external Windows integration entry on
2026-10-18:
`C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\USOS desktop.lnk`.
The actual common-Startup path is resolved by Windows, including a relocated
ProgramData. No Run/Userinit/AppInit registry configuration is used.

Application files, the optional marker and per-session/PID logs stay under
`C:\USOS\usoswm`. Installation protects code from standard-user modification;
interactive logs have their own writable subfolder. No application data is
stored in AppData or a user profile. Moving the application folder preserves
its data; Windows registration must be refreshed for its new path.
Remove the matching old shortcut before moving, then run registration from
the new dedicated `usoswm` folder. A link to another path is treated as a
conflict, rather than silently redirected.

## Rendering and conservative fallback

The DLL validates the OS/CI state, default desktop, actual explorer path,
original USER32 dispatch stubs, import names, bounds and pointer targets.
No hardcoded function RVA is used. Unknown dispatchers or existing third-party
import hooks keep native drawing. Unsupported states retain Windows UI.
Although the import table is process-wide, rendering checks the desktop
thread ID on every call; other Explorer threads retain native drawing.

The renderer reads the current background through IActiveDesktop and renders
solid colour or an opaque image in Vista centre/tile/stretch mode, under the shell's
existing clip region. Icons and application windows retain their normal paint.
It falls back to the original functions if background reconstruction fails,
in safe mode, with PaintDesktopVersion enabled or an unknown/non-genuine
licensing value. WIC decodes opaque JPEG/PNG when LoadImage cannot load a bitmap.
Transparent images, nonzero patterns and unknown formats retain native rendering.
The stock NT 6.0 REG_DWORD-zero pattern and eight zero rows represent no pattern.
There is no injection into Winlogon, LogonUI, DWM or other applications.

The OOBE gate also starts `usoswm.exe --setup` on the setup Default desktop.
This mode owns a temporary solid-colour bottom window below installer windows;
it installs no hooks. It reads the existing setup state, respects the opt-out,
safe-mode, version-text and genuine-status guards, and closes at setup end or
when the real Explorer shell appears. Registry notifications and WinEvents
drive its lifetime without polling. Its files and logs stay beside the app.
It cannot prevent a native paint that happens before the gate starts it.

The gate is a GUI-subsystem program, so it allocates no console. The unchanged
frozen USB bootstrap starts with a hidden console inherited by its console
children; stdout and their file logs remain available. Native Windows GUI
configuration keeps its normal startup behaviour. Both x86/x64 gates are GUI
programs; x86 does not install the watermark component.

RDP reconnection of the existing user's session has measured PL coverage on
Vista/Server 2008. A separate user's desktop, newly created remote sessions,
Aero and real multi-monitor/DPI behaviour still need coverage. Setup has a deliberately rearmed
VM checkpoint with visible-before/hidden-after/opt-out and shutdown-of-background
proof; that fixture is not a complete fresh-install acceptance. Classic-theme changes
have measured VM coverage. A successful build or
an attached hook is not evidence of successful watermark suppression.

## Installation flow and opt-out

The x64 Vista support builder adds this separate package alongside the unchanged
13 frozen USB payload files. The finalizer stages it after its existing BCD
TESTSIGNING operation. The x64 OOBE gate invokes registration before continuing
its normal Windows/USB bootstrap. A cosmetic failure is logged and does not
block OS setup. The x86 OOBE build does not invoke registration.

Empty DATA marker:
`Systems\Windows\<system>\Unattended\testmode-watermark-on.txt`
means **keep the watermark visible**. CSMWrap prepare/target and the native
Vista wimboot plan transmit its presence; the target gets the same empty marker
beside the component. Other profile families do not transmit this setting.

## Reproduce a local build

```powershell
python -I -B tools/nt6/usoswm/build.py --tool-root <pinned-tools> --out zig-out/usoswm
python -I -B tools/nt6/usoswm/test_component.py --tool-root <pinned-tools> --out zig-out/usoswm
```

Pinned toolchain: repository Zig 0.16.0, native x64 Win32 APIs, no C runtime.
The builder keeps its temporary files and Zig caches below its output folder.
`manifest.json` records hashes of our three files. It explicitly marks the
current package unvalidated. Never export vista-support.cpio: it also contains
the frozen Microsoft USB payload. Only our three binaries may accompany the
source/patch delivery.

The host pixel test calls the actual renderer with memory DIBs, never the
host's desktop. It checks centre/tile/stretch, nonzero window origins,
negative monitor coordinates, the update clip and restoration of DC state.
This caught a brush-origin error: SetBrushOrgEx requires device coordinates.
It also exercises WIC with generated opaque JPEG/PNG fixtures and checks
that transparent and damaged inputs are rejected. No host wallpaper changes.
