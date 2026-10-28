/* Win32 APIs missing from the original NT 3.1 KERNEL32.
 * Own bounded copy and GetVersion fallback; no replacement OS libraries.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 */
static char *compat_strcopy(char *out, const char *in, DWORD cap)
{
    DWORD i = 0;
    if (!cap) return out;
    while (i + 1 < cap && in[i]) { out[i] = in[i]; i++; }
    out[i] = 0;
    return out;
}

static BOOL compat_os_version(OSVERSIONINFOA *version)
{
    typedef BOOL (WINAPI *VERSION_EX)(OSVERSIONINFOA *);
    HMODULE kernel = GetModuleHandleA("KERNEL32.DLL");
    VERSION_EX extended = kernel ? (VERSION_EX)GetProcAddress(kernel, "GetVersionExA") : 0;
    DWORD legacy;
    mset(version, 0, sizeof(*version));
    version->dwOSVersionInfoSize = sizeof(*version);
    if (extended && extended(version)) return TRUE;
    legacy = GetVersion();
    if (!legacy) return FALSE;
    mset(version, 0, sizeof(*version));
    version->dwOSVersionInfoSize = sizeof(*version);
    version->dwMajorVersion = legacy & 255;
    version->dwMinorVersion = (legacy >> 8) & 255;
    if (!(legacy & 0x80000000UL)) {
        version->dwPlatformId = VER_PLATFORM_WIN32_NT;
        version->dwBuildNumber = legacy >> 16;
    } else {
        version->dwPlatformId = version->dwMajorVersion < 4 ? VER_PLATFORM_WIN32s : VER_PLATFORM_WIN32_WINDOWS;
    }
    return TRUE;
}
