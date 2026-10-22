/* Explicit NT3.5/NT3.51 Workstation selectors: configure existing OS services for NEXT boot.
 * No new service, SCM readiness claim, worker, runtime policy PASS or LAN PASS.
 * All request/status/failure files stay beside staged USOSNT3 in DIR.
 */
typedef struct ClientConfig {
    unsigned minor;
    const char *label, *request, *request_text, *status, *error;
} ClientConfig;
#define CLIENT35_REQUEST "USOS NT35 client-no-sharing\r\n"
#define CLIENT351_REQUEST "USOS NT351 client-no-sharing\r\n"
static const ClientConfig client35_config = {50, "CLIENT35", "CLNT35.REQ", CLIENT35_REQUEST, "CLNT35.LOG", "CLNT35.ERR"};
static const ClientConfig client351_config = {51, "CLIENT351", "CLNT351.REQ", CLIENT351_REQUEST, "CLNT351.LOG", "CLNT351.ERR"};
static const ClientConfig *g_client_config;
static int g_client_requested;

static int client_fail(const char *reason)
{
    say(g_client_config->label); say(" FAILED: "); say(reason); say("\r\n");
    if (!write_file_checked(g_client_config->error, reason))
        say("CLIENT failure record could not be flushed\r\n");
    return 0;
}

static int client_value(HKEY key, const char *name, DWORD *value)
{
    DWORD type = 0, size = sizeof *value;
    return !RegQueryValueExA(key, name, NULL, &type, (BYTE *)value, &size) &&
        type == REG_DWORD && size == sizeof *value;
}

/* Inspect both versioned requests before any POST registry/driver mutation.
 * Missing requests skip. Presence is never inferred from version or filename. */
static int client_presence(const char *name, DWORD *attributes)
{
    char path[MAX_PATH];
    DWORD error;
    lstrcpyA(path, DIR); lstrcatA(path, name);
    *attributes = GetFileAttributesA(path);
    if (*attributes != 0xffffffff) return 1;
    error = GetLastError();
    return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND ? 0 : -1;
}

static int client_request(void)
{
    HKEY product = NULL;
    DWORD attr35, attr351, attr, error, version, type = 0, size;
    DWORD (WINAPI *get_version)(void);
    char request[64], actual[16];
    int have35, have351, n;
    g_client_requested = 0; g_client_config = NULL;
    have35 = client_presence(client35_config.request, &attr35);
    have351 = client_presence(client351_config.request, &attr351);
    if (!have35 && !have351) return 1;
    g_client_requested = 1;
    g_client_config = have351 ? &client351_config : &client35_config;
    if (have35 < 0 || have351 < 0) return client_fail("cannot establish request presence");
    if (have35 && have351) {
        client_fail("conflicting versioned requests");
        g_client_config = &client35_config;
        return client_fail("conflicting versioned requests");
    }
    attr = have351 ? attr351 : attr35;
    if (attr & FILE_ATTRIBUTE_DIRECTORY) return client_fail("request is a directory");
    if (client_presence(g_client_config->error, &attr)) return 0; /* Prior refusal is terminal. */
    n = read_text(g_client_config->request, request, sizeof request);
    if (n != len(g_client_config->request_text) || lstrcmpA(request, g_client_config->request_text))
        return client_fail("missing, truncated or invalid request");
    get_version = (DWORD (WINAPI *)(void))GetProcAddress(GetModuleHandleA("kernel32.dll"), "GetVersion");
    if (!get_version) return client_fail("GetVersion unavailable");
    version = get_version();
    if ((version & 0x80000000) || (version & 0xff) != 3 || ((version >> 8) & 0xff) != g_client_config->minor)
        return client_fail("actual OS does not match explicit requested NT minor");
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, "SYSTEM\\CurrentControlSet\\Control\\ProductOptions",
                      0, KEY_READ, &product)) return client_fail("missing ProductOptions");
    size = sizeof actual;
    error = RegQueryValueExA(product, "ProductType", NULL, &type, (BYTE *)actual, &size);
    RegCloseKey(product);
    if (error || type != REG_SZ || size != sizeof "WinNT" ||
        actual[size - 1] || lstrcmpiA(actual, "WinNT"))
        return client_fail("actual product is not Workstation");
    return 1;
}

static int client_prepare(int network_state)
{
    static const char *const names[] = { "Browser", "LanmanServer", "LanmanWorkstation", "Tcpip" };
    HKEY keys[4] = { NULL, NULL, NULL, NULL };
    DWORD starts[4], types[4], got, type;
    LONG error;
    char path[128];
    int i, ok = 0;
    if (!g_client_requested) return 1;
    if (network_state != 2) return client_fail("selected versioned takeover did not succeed");
    /* Open every existing key before any mutation. Never RegCreateKey.
       Workstation/Tcpip handles are query-only. Only CurrentControlSet. */
    for (i = 0; i < 4; i++) {
        lstrcpyA(path, SVC_KEY); lstrcatA(path, names[i]);
        error = RegOpenKeyExA(HKEY_LOCAL_MACHINE, path, 0,
                             i < 2 ? KEY_READ | KEY_WRITE : KEY_READ, &keys[i]);
        if (i == 0 && error == ERROR_FILE_NOT_FOUND) continue;
        if (error || !client_value(keys[i], "Start", &starts[i]) ||
            !client_value(keys[i], "Type", &types[i])) goto done;
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
        if (!client_value(keys[i], "Start", &got) || !client_value(keys[i], "Type", &type) ||
            type != types[i] || got != (i < 2 ? SERVICE_DISABLED : starts[i])) goto done;
    }
    ok = write_file_checked(g_client_config->status,
        "configuration_readback=match\r\nBrowser=absent-or-Disabled\r\nLanmanServer=Disabled\r\n"
        "LanmanWorkstation=unchanged\r\nTcpip=unchanged\r\nnext_target_boot_required=true\r\n"
        "installed_runtime_pass=false\r\nclient_policy_runtime_pass=false\r\n");
done:
    for (i = 0; i < 4; i++) if (keys[i]) RegCloseKey(keys[i]);
    if (!ok) return client_fail("existing service validation, write, readback or status flush failed");
    say("CLIENT configured for next target boot; runtime policy is unproven\r\n");
    return 1;
}

static int client_commit_installer(void)
{
    HKEY own = NULL;
    int ok;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, SVC_KEY SVC_NAME, 0, KEY_READ | KEY_WRITE, &own))
        return client_fail("existing post service missing at completion");
    ok = net351_dword(own, "Start", SERVICE_DISABLED);
    RegCloseKey(own);
    if (!ok || !write_file_checked("DONE.TXT", "done\r\n"))
        return client_fail("post disable/readback or DONE flush failed");
    return 1;
}
