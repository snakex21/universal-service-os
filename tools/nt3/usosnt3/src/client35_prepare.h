/* NT3.5 Workstation only: configure existing OS services for NEXT boot.
 * No new service, SCM readiness claim, worker, runtime policy PASS or LAN PASS.
 * All request/status/failure files stay beside staged USOSNT3 in DIR.
 */
#define CLIENT35_REQUEST "USOS NT35 client-no-sharing\r\n"
static int g_client35_requested;

static int client35_fail(const char *reason)
{
    say("CLIENT35 FAILED: "); say(reason); say("\r\n");
    if (!write_file_checked("CLNT35.ERR", reason))
        say("CLIENT35 failure record could not be flushed\r\n");
    return 0;
}

static int client35_value(HKEY key, const char *name, DWORD *value)
{
    DWORD type = 0, size = sizeof *value;
    return !RegQueryValueExA(key, name, NULL, &type, (BYTE *)value, &size) &&
        type == REG_DWORD && size == sizeof *value;
}

static int client35_request(void)
{
    HKEY product = NULL;
    DWORD attr, error, version, type = 0, size;
    DWORD (WINAPI *get_version)(void);
    char request[64], actual[16];
    int n;
    g_client35_requested = 0;
    attr = GetFileAttributesA(DIR "CLNT35.REQ");
    if (attr == 0xffffffff) {
        error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
    }
    g_client35_requested = 1;
    if (attr & FILE_ATTRIBUTE_DIRECTORY) return client35_fail("request is a directory");
    attr = GetFileAttributesA(DIR "CLNT35.ERR");
    if (attr != 0xffffffff) return 0; /* A prior refusal is terminal. */
    error = GetLastError();
    if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND)
        return client35_fail("cannot establish absence of prior refusal");
    n = read_text("CLNT35.REQ", request, sizeof request);
    if (n != sizeof CLIENT35_REQUEST - 1 || lstrcmpA(request, CLIENT35_REQUEST))
        return client35_fail("missing, truncated or invalid request");
    get_version = (DWORD (WINAPI *)(void))GetProcAddress(GetModuleHandleA("kernel32.dll"), "GetVersion");
    if (!get_version) return client35_fail("GetVersion unavailable");
    version = get_version();
    if ((version & 0x80000000) || (version & 0xff) != 3 || ((version >> 8) & 0xff) != 50)
        return client35_fail("actual OS is not NT3.5");
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, "SYSTEM\\CurrentControlSet\\Control\\ProductOptions",
                      0, KEY_READ, &product)) return client35_fail("missing ProductOptions");
    size = sizeof actual;
    error = RegQueryValueExA(product, "ProductType", NULL, &type, (BYTE *)actual, &size);
    RegCloseKey(product);
    if (error || type != REG_SZ || size != sizeof "WinNT" ||
        actual[size - 1] || lstrcmpiA(actual, "WinNT"))
        return client35_fail("actual product is not Workstation");
    return 1;
}

static int client35_prepare(int network_state)
{
    static const char *const names[] = { "Browser", "LanmanServer", "LanmanWorkstation", "Tcpip" };
    HKEY keys[4] = { NULL, NULL, NULL, NULL };
    DWORD starts[4], types[4], got, type;
    LONG error;
    char path[128];
    int i, ok = 0;
    if (!g_client35_requested) return 1;
    if (network_state != 2) return client35_fail("selected NET35 takeover did not succeed");
    /* Open every existing key before any mutation. Never RegCreateKey.
       Workstation/Tcpip handles are query-only. Only CurrentControlSet. */
    for (i = 0; i < 4; i++) {
        lstrcpyA(path, SVC_KEY); lstrcatA(path, names[i]);
        error = RegOpenKeyExA(HKEY_LOCAL_MACHINE, path, 0,
                             i < 2 ? KEY_READ | KEY_WRITE : KEY_READ, &keys[i]);
        if (i == 0 && error == ERROR_FILE_NOT_FOUND) continue;
        if (error || !client35_value(keys[i], "Start", &starts[i]) ||
            !client35_value(keys[i], "Type", &types[i])) goto done;
        if (i < 2) {
            if (types[i] != SERVICE_WIN32_SHARE_PROCESS || starts[i] < 2 || starts[i] > 4) goto done;
        } else if (i == 2) {
            if (types[i] != SERVICE_WIN32_SHARE_PROCESS || starts[i] != SERVICE_AUTO_START) goto done;
        } else if (types[i] != SERVICE_KERNEL_DRIVER || starts[i] != SERVICE_DEMAND_START) goto done;
    }
    for (i = 0; i < 2; i++)
        if (keys[i] && !net351_dword(keys[i], "Start", SERVICE_DISABLED)) goto done;
    for (i = 0; i < 4; i++) {
        if (!keys[i]) continue;
        if (!client35_value(keys[i], "Start", &got) || !client35_value(keys[i], "Type", &type) ||
            type != types[i] || got != (i < 2 ? SERVICE_DISABLED : starts[i])) goto done;
    }
    ok = write_file_checked("CLNT35.LOG",
        "configuration_readback=match\r\nBrowser=absent-or-Disabled\r\nLanmanServer=Disabled\r\n"
        "LanmanWorkstation=unchanged\r\nTcpip=unchanged\r\nnext_target_boot_required=true\r\n"
        "installed_runtime_pass=false\r\nclient_policy_runtime_pass=false\r\n");
done:
    for (i = 0; i < 4; i++) if (keys[i]) RegCloseKey(keys[i]);
    if (!ok) return client35_fail("existing service validation, write, readback or status flush failed");
    say("CLIENT35 configured for next target boot; runtime policy is unproven\r\n");
    return 1;
}

static int client35_commit_installer(void)
{
    HKEY own = NULL;
    int ok;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, SVC_KEY SVC_NAME, 0, KEY_READ | KEY_WRITE, &own))
        return client35_fail("existing post service missing at completion");
    ok = net351_dword(own, "Start", SERVICE_DISABLED);
    RegCloseKey(own);
    if (!ok || !write_file_checked("DONE.TXT", "done\r\n"))
        return client35_fail("post disable/readback or DONE flush failed");
    return 1;
}
