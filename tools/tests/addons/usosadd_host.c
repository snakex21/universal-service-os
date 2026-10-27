/* Host harness for the pure parts of USOSADD (src/platform/win32_legacy/
 * usosadd): unit tests and a plan printer for the cross-check with
 * tools/addons/legacy_manifest.py. Built by test_legacy_pack.py with
 * zig cc. GPL-3.0-or-later.
 *
 *   usosadd_host selftest
 *   usosadd_host plan <manifest> <os> <lang> <ntsp|-> <full 0|1> <options|-> <exclude|->
 *   usosadd_host select <manifest> <select.ini>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ua.h"

static int failures;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static char *slurp(const char *path, int *len) {
    FILE *f = fopen(path, "rb");
    char *buf;
    long n;
    if (!f) return 0;
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fseek(f, 0, SEEK_SET);
    buf = malloc((size_t)n + 1);
    *len = (int)fread(buf, 1, (size_t)n, f);
    buf[*len] = 0;
    fclose(f);
    return buf;
}

static void detect_case(int nt, int major, int minor, int build, const char *csd, int k0, int k1,
                        int sp6a, unsigned lang, const char *os, const char *l, const char *sp) {
    ua_facts f;
    ua_system s;
    memset(&f, 0, sizeof f);
    f.nt = nt; f.major = major; f.minor = minor; f.build = build;
    strcpy(f.csd, csd);
    f.ntkern_ver[0] = k0; f.ntkern_ver[1] = k1;
    f.sp6a_hotfix = sp6a;
    f.lang_id = lang;
    ua_detect(&f, &s);
    if (strcmp(s.os, os) || strcmp(s.lang, l) || strcmp(s.ntsp, sp)) {
        printf("FAIL detect %d.%d.%d '%s' -> %s %s %s, want %s %s %s\n", major, minor, build, csd, s.os, s.lang, s.ntsp, os, l, sp);
        failures++;
    }
}

/* 9x with an empty szCSDVersion: the registry SubVersionNumber decides. */
static void detect_sub(int build, const char *csd, const char *subver, const char *os) {
    ua_facts f;
    ua_system s;
    memset(&f, 0, sizeof f);
    f.major = 4; f.build = build;
    strcpy(f.csd, csd);
    strcpy(f.subver, subver);
    f.lang_id = 0x409;
    ua_detect(&f, &s);
    if (strcmp(s.os, os)) {
        printf("FAIL detect 4.0.%d '%s' SubVersionNumber '%s' -> %s, want %s\n", build, csd, subver, s.os, os);
        failures++;
    }
}

static int selftest(void) {
    static ua_ini ini;
    static ua_pkgs pk;
    static ua_state st, st2;
    static ua_ini sti;
    char text[] =
        "; comment\r\n[pack]\r\nos=95RTM,98SE,NT4\r\ngroup_95=95RTM\r\n"
        "[os:98SE]\r\nprovides=ie:5.0\r\n[os:NT4]\r\nprovides=\r\n"
        "[pkg:a]\r\n  tier = full \r\nos=98SE\r\nlang=*\r\norder=10\r\nprovides=msi:2.0\r\nreboot=now\r\n"
        "[pkg:b]\r\ntier=full\r\nos=98SE\r\nlang=PL\r\norder=20\r\nneeds=msi:2.0,ie:5.01\r\n"
        "[pkg:sp]\r\ntier=full\r\nos=NT4\r\nlang=*\r\nntsp=<6a\r\norder=5\r\nprovides=ntsp:6a\r\n"
        "[pkg:c]\r\ntier=full\r\nos=NT4\r\nlang=*\r\nntsp=6a+\r\norder=30\r\nneeds=ntsp:6a\r\n";
    char out[4096], stbuf[4096];
    ua_system s;
    ua_plan plan;
    ua_vars v;
    ua_cmd c;
    ua_check k;

    /* versions */
    CHECK(ua_vercmp("6.0.2800.1106", "5.50.4807.2300") > 0);
    CHECK(ua_vercmp("4.09.00.0904", "4.09.00.0904") == 0);
    CHECK(ua_vercmp("9,0,0,2980", "9.0.0.2980") == 0);
    CHECK(ua_vercmp("9.0c", "9.0") > 0);
    CHECK(ua_vercmp("6a", "6") > 0);
    CHECK(ua_vercmp("6", "6a") < 0);
    CHECK(ua_vercmp("2.81.1117.0", "2.81") > 0);
    CHECK(ua_vercmp("2.81.0.0", "2.81") == 0);
    CHECK(ua_vercmp("2.80", "2.81") < 0);
    CHECK(ua_vercmp("", "0") == 0);
    CHECK(ua_cap_satisfies("ie:6.0", "ie:5.01"));
    CHECK(!ua_cap_satisfies("ie:5.0", "ie:5.01"));
    CHECK(ua_cap_satisfies("dx:9.0c", "dx"));
    CHECK(!ua_cap_satisfies("msi:2.0", "ie:1"));

    /* lists */
    CHECK(ua_list_has(" a, b ,c", "B"));
    CHECK(!ua_list_has("a,b", "ab"));
    CHECK(!ua_list_has("", "a"));

    /* INI */
    ua_ini_parse(&ini, text, (int)strlen(text));
    CHECK(!ini.overflow);
    CHECK(ua_ini_get(&ini, "PKG:A", "TIER") && strcmp(ua_ini_get(&ini, "pkg:a", "tier"), "full") == 0);
    CHECK(ua_ini_get(&ini, "pkg:a", "missing") == 0);
    CHECK(ua_load_pkgs(&ini, &pk) == 4);
    CHECK(pk.pkg[0].reboot == UA_REBOOT_NOW && pk.pkg[1].reboot == UA_REBOOT_NO);
    CHECK(ua_os_match(&ini, "95", "95RTM") && !ua_os_match(&ini, "95", "98SE"));
    /* without reboot_setup/check_setup the 950 coordinator changes nothing */
    CHECK(ua_setup_overrides(&ini, &pk) == 0);
    CHECK(pk.pkg[0].reboot == UA_REBOOT_NOW && pk.pkg[1].reboot == UA_REBOOT_NO && !*pk.pkg[1].check);
    {
        static ua_ini oi;
        static ua_pkgs op;
        char otext[] =
            "[pkg:ie]\r\ntier=full\r\nos=95\r\nlang=PL\r\norder=1\r\ncheck=reg:HKLM\\A\r\nreboot=end\r\nreboot_setup=now\r\n"
            "[pkg:q]\r\ntier=full\r\nos=95\r\nlang=PL\r\norder=2\r\nreboot=end\r\n"
            "check_setup=file:%SYS%\\MSHTML.DLL>=5.50.4923.2500\r\n"
            "[pkg:o]\r\ntier=full\r\nos=98SE\r\nlang=*\r\norder=3\r\nreboot=end\r\ncheck=file:X\r\n";
        ua_ini_parse(&oi, otext, (int)strlen(otext));
        CHECK(ua_load_pkgs(&oi, &op) == 3);
        /* the ordinary Run flow (OSR2 and later, 98, Me) keeps reboot=/check= */
        CHECK(op.pkg[0].reboot == UA_REBOOT_END && op.pkg[1].reboot == UA_REBOOT_END && !*op.pkg[1].check);
        CHECK(ua_setup_overrides(&oi, &op) == 2);
        CHECK(op.pkg[0].reboot == UA_REBOOT_NOW && strcmp(op.pkg[0].check, "reg:HKLM\\A") == 0);
        CHECK(op.pkg[1].reboot == UA_REBOOT_END && strcmp(op.pkg[1].check, "file:%SYS%\\MSHTML.DLL>=5.50.4923.2500") == 0);
        CHECK(op.pkg[2].reboot == UA_REBOOT_END && strcmp(op.pkg[2].check, "file:X") == 0);
        CHECK(ua_after_run(1, op.pkg[0].reboot, 1, 1) == UA_AFTER_RESTART);
        /* the 950 coordinator's reboot_setup=now (DCOM95 / IE 5.5 SP2) restarts
         * whatever the installer's exit code: forced */
        CHECK(ua_reboot_for_run(op.pkg[0].reboot, 0, 1) == UA_REBOOT_NOW);
        CHECK(ua_after_run(1, ua_reboot_for_run(op.pkg[0].reboot, 0, 1), 0, 1) == UA_AFTER_RESTART);
    }
    {
        /* requires= (ws2-95: TCP/IP bound, X470 95 OSR2.1 PL 2026-10-27):
         * the first absent component, an unknown name counts as absent. */
        static ua_ini ri;
        static ua_pkgs rp;
        char item[32];
        char rtext[] = "[pkg:ws2]\r\nos=95\r\nrequires=tcpip\r\n[pkg:none]\r\nos=95\r\n"
                       "[pkg:two]\r\nos=95\r\nrequires= TCPIP , ipx\r\n";
        ua_ini_parse(&ri, rtext, (int)strlen(rtext));
        CHECK(ua_load_pkgs(&ri, &rp) == 3);
        CHECK(strcmp(rp.pkg[0].requires, "tcpip") == 0 && !*rp.pkg[1].requires);
        CHECK(ua_requires_missing(&rp.pkg[0], 1, item, sizeof item) == 0);
        CHECK(ua_requires_missing(&rp.pkg[0], 0, item, sizeof item) == item && strcmp(item, "tcpip") == 0);
        CHECK(ua_requires_missing(&rp.pkg[1], 0, item, sizeof item) == 0);
        CHECK(ua_requires_missing(&rp.pkg[2], 0, item, sizeof item) && strcmp(item, "TCPIP") == 0);
        CHECK(ua_requires_missing(&rp.pkg[2], 1, item, sizeof item) && strcmp(item, "ipx") == 0);
    }
    {
        /* option_os=: tier=full except there (options= / needs= still bring it in) */
        static ua_ini wi;
        static ua_pkgs wp;
        static ua_plan wpl;
        ua_system ws;
        char wtext[] =
            "[pack]\r\ngroup_95=95RTM,95OSR1,95OSR2\r\n"
            "[pkg:ws2]\r\ntier=full\r\noption_os=95RTM,95OSR1\r\nos=95\r\nlang=*\r\norder=1\r\nprovides=ws2:2\r\n"
            "[pkg:dun]\r\ntier=option\r\nos=95\r\nlang=EN\r\norder=2\r\nneeds=ws2:2\r\n";
        memset(&ws, 0, sizeof ws);
        ua_ini_parse(&wi, wtext, (int)strlen(wtext));
        CHECK(ua_load_pkgs(&wi, &wp) == 2);
        strcpy(ws.lang, "PL");
        strcpy(ws.os, "95OSR2"); ua_resolve(&wi, &wp, &ws, 1, "", "", &wpl);
        CHECK(wpl.count == 1 && wpl.why[0] == UA_WHY_FULL);
        strcpy(ws.os, "95RTM"); ua_resolve(&wi, &wp, &ws, 1, "", "", &wpl);
        CHECK(wpl.count == 0 && wpl.why[0] == 0);
        ua_resolve(&wi, &wp, &ws, 1, "ws2", "", &wpl);
        CHECK(wpl.count == 1 && wpl.why[0] == UA_WHY_OPTION);
        strcpy(ws.lang, "EN"); ua_resolve(&wi, &wp, &ws, 1, "dun", "", &wpl);
        CHECK(wpl.count == 2 && wpl.why[0] == UA_WHY_NEEDED && wpl.idx[0] == 0);
    }

    /* plan: b needs msi (a, earlier) and ie 5.01 (98 SE has only 5.0) */
    strcpy(s.os, "98SE"); strcpy(s.lang, "PL"); s.ntsp[0] = 0;
    ua_resolve(&ini, &pk, &s, 1, "", "", &plan);
    CHECK(plan.count == 1 && plan.idx[0] == 0);
    CHECK(plan.why[1] == UA_OUT_NEEDS && strcmp(plan.unmet[1], "ie:5.01") == 0);
    /* NT4 SP3: the SP comes first, c is planned behind it */
    strcpy(s.os, "NT4"); strcpy(s.lang, "EN"); strcpy(s.ntsp, "3");
    ua_resolve(&ini, &pk, &s, 1, "", "", &plan);
    CHECK(plan.count == 2 && plan.idx[0] == 2 && plan.idx[1] == 3);
    CHECK(strcmp(plan.eff_ntsp, "6a") == 0);
    /* NT4 SP6a: no SP, c alone */
    strcpy(s.ntsp, "6a");
    ua_resolve(&ini, &pk, &s, 1, "", "", &plan);
    CHECK(plan.count == 1 && plan.idx[0] == 3);

    /* detection table (docs/design/legacy-compat-pack.md 2.2) */
    detect_case(0, 4, 0, 950, "", 0, 0, 0, 0x415, "95RTM", "PL", "");
    detect_case(0, 4, 0, 950, " A", 0, 0, 0, 0x409, "95OSR1", "EN", "");
    /* OSR1 EN on X470 (2026-10-27): CSD "" but SubVersionNumber "a" */
    detect_sub(950, "", "a", "95OSR1");
    detect_sub(950, "", " A", "95OSR1");
    detect_sub(950, " ", " a ", "95OSR1");
    detect_sub(950, "", "", "95RTM");
    detect_sub(950, "", " ", "95RTM");
    detect_sub(950, " A", "", "95OSR1");
    detect_sub(950, "", "b", "95RTM");
    detect_sub(1111, "", " C", "95OSR25");
    detect_case(0, 4, 0, 1111, " B", 4, 0, 0, 0x415, "95OSR2", "PL", "");
    detect_case(0, 4, 0, 1111, " B", 4, 3, 0, 0x415, "95OSR21", "PL", "");
    detect_case(0, 4, 0, 1212, " B", 0, 0, 0, 0x415, "95OSR2", "PL", "");
    detect_case(0, 4, 0, 1111, " C", 0, 0, 0, 0x415, "95OSR25", "PL", "");
    detect_case(0, 4, 10, 1998, " ", 0, 0, 0, 0x415, "98FE", "PL", "");
    detect_case(0, 4, 10, 2222, " A ", 0, 0, 0, 0x415, "98SE", "PL", "");
    detect_case(0, 4, 90, 3000, " ", 0, 0, 0, 0x407, "ME", "XX", "");
    detect_case(1, 4, 0, 1381, "", 0, 0, 0, 0x415, "NT4", "PL", "0");
    detect_case(1, 4, 0, 1381, "Service Pack 3", 0, 0, 0, 0x409, "NT4", "EN", "3");
    detect_case(1, 4, 0, 1381, "Service Pack 6", 0, 0, 1, 0x415, "NT4", "PL", "6a");
    detect_case(1, 4, 0, 1381, "Service Pack 6", 0, 0, 0, 0x415, "NT4", "PL", "6");
    detect_case(1, 4, 0, 1381, "Dodatek Service Pack 6a", 0, 0, 0, 0x415, "NT4", "PL", "6a");
    detect_case(1, 5, 0, 2195, "Service Pack 4", 0, 0, 0, 0x415, "?", "PL", "");

    /* variables */
    v.root = "C:\\USOS\\ADDONS"; v.win = "C:\\WINDOWS"; v.sys = "C:\\WINDOWS\\SYSTEM";
    v.pf = "C:\\Program Files"; v.dir = "DX9C";
    ua_expand(&v, "%PKG%\\DX9DEC06.EXE /Q /T:%TMP% /C", out, sizeof out);
    CHECK(strcmp(out, "C:\\USOS\\ADDONS\\PKG\\DX9C\\DX9DEC06.EXE /Q /T:C:\\USOS\\ADDONS\\TMP\\DX9C /C") == 0);
    ua_expand(&v, "%sys%\\a %% %WIN% %ADD% %PF%\\x /S:\"\"#E\"\" %UNKNOWN% 100%", out, sizeof out);
    CHECK(strcmp(out, "C:\\WINDOWS\\SYSTEM\\a % C:\\WINDOWS C:\\USOS\\ADDONS C:\\Program Files\\x /S:\"\"#E\"\" %UNKNOWN% 100%") == 0);

    /* builtins */
    ua_parse_cmd("copy C:\\A\\B.DLL \"C:\\Program Files\\X Y\\B.DLL\"", &c);
    CHECK(c.kind == UA_CMD_COPY && strcmp(c.a, "C:\\A\\B.DLL") == 0 && strcmp(c.b, "C:\\Program Files\\X Y\\B.DLL") == 0);
    ua_parse_cmd("append C:\\CONFIG.SYS DEVICE=C:\\WINDOWS\\IFSHLP.SYS", &c);
    CHECK(c.kind == UA_CMD_APPEND && strcmp(c.a, "C:\\CONFIG.SYS") == 0 && strcmp(c.b, "DEVICE=C:\\WINDOWS\\IFSHLP.SYS") == 0);
    ua_parse_cmd("cd C:\\T C:\\P\\WINMEDOS.COM", &c);
    CHECK(c.kind == UA_CMD_CD && strcmp(c.a, "C:\\T") == 0 && strcmp(c.b, "C:\\P\\WINMEDOS.COM") == 0);
    ua_parse_cmd("inf C:\\X.INF", &c);
    CHECK(c.kind == UA_CMD_INF && strcmp(c.b, "DefaultInstall") == 0);
    ua_parse_cmd("msi C:\\D.MSI REBOOT=ReallySuppress", &c);
    CHECK(c.kind == UA_CMD_MSI && strcmp(c.a, "C:\\D.MSI") == 0 && strcmp(c.b, "REBOOT=ReallySuppress") == 0);
    ua_parse_cmd("C:\\P\\SETUP.EXE /Q:A /R:N", &c);
    CHECK(c.kind == UA_CMD_RUN && strcmp(c.b, "C:\\P\\SETUP.EXE /Q:A /R:N") == 0);
    ua_parse_cmd("copyfile.exe /x", &c);
    CHECK(c.kind == UA_CMD_RUN);

    /* checks */
    CHECK(ua_parse_check("file:C:\\W\\S\\MSI.DLL>=2.0.2600.2", &k) && k.kind == UA_CHK_FILE &&
          strcmp(k.path, "C:\\W\\S\\MSI.DLL") == 0 && strcmp(k.min, "2.0.2600.2") == 0);
    CHECK(ua_parse_check("file:C:\\W\\MSCONFIG.EXE", &k) && k.min[0] == 0);
    CHECK(ua_parse_check("regver:HKLM\\Software\\Microsoft\\Internet Explorer,Version>=6.0.2800.1106", &k) &&
          k.kind == UA_CHK_REGVER && k.hive == 0 && strcmp(k.path, "Software\\Microsoft\\Internet Explorer") == 0 &&
          strcmp(k.value, "Version") == 0 && strcmp(k.min, "6.0.2800.1106") == 0);
    CHECK(ua_parse_check("reg:HKLM\\SOFTWARE\\X\\Hotfix\\Q299444", &k) && k.kind == UA_CHK_REG && k.value[0] == 0);
    CHECK(ua_parse_check("reg:HKLM\\Software\\Microsoft\\OLE,EnableDCOM", &k) && strcmp(k.value, "EnableDCOM") == 0);
    CHECK(ua_parse_check("regdw:HKLM\\A\\v1.1.4322,SP>=1", &k) && k.kind == UA_CHK_REGDW && strcmp(k.min, "1") == 0);
    CHECK(ua_parse_check("ntsp:6a", &k) && k.kind == UA_CHK_NTSP);
    CHECK(!ua_parse_check("regver:HKLM\\A,B", &k));
    CHECK(!ua_parse_check("reg:HKXX\\A", &k));
    CHECK(!ua_parse_check("bogus:1", &k));
    CHECK(ua_parse_check("", &k) && k.kind == UA_CHK_NONE);

    /* state round trip and resume */
    ua_state_load(&st, 0, &pk);
    st.st[0] = UA_ST_DONE; st.st[2] = UA_ST_RUNNING; st.tries[2] = 1; st.pending_reboot = 1; st.starts = 3;
    st.st[1] = UA_ST_SKIPPED; strcpy(st.why[1], "needs ie:5.01");
    ua_state_write(&st, &pk, stbuf, sizeof stbuf);
    CHECK(strstr(stbuf, "a=done\r\n") && strstr(stbuf, "sp=running:1\r\n") && strstr(stbuf, "b=skipped\r\n"));
    CHECK(strstr(stbuf, "[why]\r\nb=needs ie:5.01\r\n") != 0);
    ua_ini_parse(&sti, stbuf, (int)strlen(stbuf));
    ua_state_load(&st2, &sti, &pk);
    CHECK(st2.st[0] == UA_ST_DONE && st2.st[1] == UA_ST_SKIPPED && st2.st[2] == UA_ST_RUNNING && st2.tries[2] == 1);
    CHECK(strcmp(st2.why[1], "needs ie:5.01") == 0 && st2.why[0][0] == 0);
    st2.st[1] = UA_ST_NEW;
    CHECK(st2.pending_reboot == 1 && st2.starts == 3);
    CHECK(ua_resume_decision(1, 1, 1) == 1);
    CHECK(ua_resume_decision(1, 0, 0) == 2);
    CHECK(ua_resume_decision(2, 1, 0) == 3);
    CHECK(ua_resume_decision(1, 1, 0) == 2);
    /* restarts are batched: only reboot=now restarts at once */
    CHECK(ua_after_run(1, UA_REBOOT_NOW, 0, 1) == UA_AFTER_RESTART);
    CHECK(ua_after_run(1, UA_REBOOT_NOW, 1, 1) == UA_AFTER_RESTART);
    CHECK(ua_after_run(1, UA_REBOOT_END, 1, 1) == UA_AFTER_PENDING);
    CHECK(ua_after_run(1, UA_REBOOT_NO, 1, 1) == UA_AFTER_CONTINUE);
    /* a failure with a restart pending (or of a package that needs its own
     * restart) is retried once after a restart, then it stands */
    CHECK(ua_after_run(0, UA_REBOOT_NO, 1, 1) == UA_AFTER_RETRY);
    CHECK(ua_after_run(0, UA_REBOOT_END, 0, 1) == UA_AFTER_RETRY);
    CHECK(ua_after_run(0, UA_REBOOT_NOW, 0, 1) == UA_AFTER_RETRY);
    CHECK(ua_after_run(0, UA_REBOOT_NO, 0, 1) == UA_AFTER_CONTINUE);
    CHECK(ua_after_run(0, UA_REBOOT_END, 1, 2) == UA_AFTER_CONTINUE);
    CHECK(ua_command_exit("C:\\TMP\\DXSETUP.EXE /silent",1)==3010);
    CHECK(ua_command_exit("\"C:\\A B\\dxsetup.exe\" /silent",1)==3010);
    CHECK(ua_command_exit("dxsetup.exe /silent",3010)==3010);
    CHECK(ua_command_exit("dxsetup.exe /silent",0)==0);
    CHECK(ua_command_exit("dxsetup.exe /silent",2)==2);
    CHECK(ua_command_exit("DX80POL.EXE /C",1)==1);
    CHECK(ua_command_exit("OTHER.EXE DXSETUP.EXE",1)==1);
    CHECK(ua_command_exit("DXSETUP.EXE.other /silent",1)==1);
    CHECK(ua_after_run(ua_command_exit("DXSETUP.EXE /silent",1)==3010,UA_REBOOT_END,0,1)==UA_AFTER_PENDING);
    /* reboot=now on 9x: at once only when the installer asked (3010 / 1641,
     * X470 98 FE PL 2026-10-27: DCOM98 and IE 6 SP1 exit 3010, MDAC exit 0) */
    CHECK(ua_reboot_for_run(UA_REBOOT_NOW, 1, 0) == UA_REBOOT_NOW);
    CHECK(ua_reboot_for_run(UA_REBOOT_NOW, 0, 0) == UA_REBOOT_END);
    CHECK(ua_reboot_for_run(UA_REBOOT_NOW, 0, 1) == UA_REBOOT_NOW);
    CHECK(ua_reboot_for_run(UA_REBOOT_END, 1, 0) == UA_REBOOT_END);
    CHECK(ua_reboot_for_run(UA_REBOOT_NO, 1, 1) == UA_REBOOT_NO);
    CHECK(ua_after_run(1, ua_reboot_for_run(UA_REBOOT_NOW, 0, 0), 0, 1) == UA_AFTER_PENDING);
    CHECK(ua_after_run(1, ua_reboot_for_run(UA_REBOOT_NOW, 1, 0), 0, 1) == UA_AFTER_RESTART);
    /* not asked and failed: still one retry after a restart */
    CHECK(ua_after_run(0, ua_reboot_for_run(UA_REBOOT_NOW, 0, 0), 0, 1) == UA_AFTER_RETRY);
    {
        ua_plan repair_plan;
        ua_system repair_system;
        ua_pkgs repair_pkgs;
        ua_state repair_state;
        memset(&repair_plan,0,sizeof repair_plan);memset(&repair_pkgs,0,sizeof repair_pkgs);
        memset(&repair_state,0,sizeof repair_state);memset(&repair_system,0,sizeof repair_system);
        repair_plan.count=1;repair_pkgs.pkg[0].id="ws2-95";strcpy(repair_system.os,"95RTM");
        CHECK(!ua_ndis_repair_needed(&repair_pkgs,&repair_plan,&repair_state,&repair_system));
        repair_state.tries[0]=1;CHECK(ua_ndis_repair_needed(&repair_pkgs,&repair_plan,&repair_state,&repair_system));
        strcpy(repair_system.os,"95OSR1");CHECK(ua_ndis_repair_needed(&repair_pkgs,&repair_plan,&repair_state,&repair_system));
        strcpy(repair_system.os,"98SE");CHECK(!ua_ndis_repair_needed(&repair_pkgs,&repair_plan,&repair_state,&repair_system));
        strcpy(repair_system.os,"NT4");CHECK(!ua_ndis_repair_needed(&repair_pkgs,&repair_plan,&repair_state,&repair_system));
        strcpy(repair_system.os,"95RTM");repair_pkgs.pkg[0].id="other";
        CHECK(!ua_ndis_repair_needed(&repair_pkgs,&repair_plan,&repair_state,&repair_system));
    }
    /* the retried package resumes as running: check true = done, else runs again */
    CHECK(ua_resume_decision(1, 1, 1) == 1 && ua_resume_decision(1, 1, 0) == 2);

    /* runtime needs: b needs msi (a done) and ie:5.01 (not there) */
    {
        char unmet[48];
        strcpy(s.os, "98SE"); strcpy(s.lang, "PL"); s.ntsp[0] = 0;
        CHECK(!ua_needs_met(&ini, &pk, &st2, &s, 1, unmet, sizeof unmet) && strcmp(unmet, "ie:5.01") == 0);
        st2.st[0] = UA_ST_NEW;
        CHECK(!ua_needs_met(&ini, &pk, &st2, &s, 1, unmet, sizeof unmet) && strcmp(unmet, "msi:2.0") == 0);
        /* a provider done in this session counts before its restart (IE 5.5
         * SP2 -> Q810847 on 95): pending_reboot does not hide it */
        st2.st[0] = UA_ST_DONE; st2.pending_reboot = 1;
        strcpy(s.os, "NT4"); /* no OS-provided ie: only a's msi:2.0 is asked */
        CHECK(!ua_needs_met(&ini, &pk, &st2, &s, 1, unmet, sizeof unmet) && strcmp(unmet, "ie:5.01") == 0);
    }
    printf(failures ? "selftest: %d failure(s)\n" : "selftest: ok\n", failures);
    return failures ? 1 : 0;
}

static int plan_cmd(int argc, char **argv) {
    static ua_ini m;
    static ua_pkgs pk;
    static ua_plan plan;
    ua_system s;
    int len, i;
    char *buf;
    if (argc < 9) return 2;
    buf = slurp(argv[2], &len);
    if (!buf) return 2;
    ua_ini_parse(&m, buf, len);
    if (m.overflow || ua_load_pkgs(&m, &pk) < 0) { printf("overflow\n"); return 2; }
    memset(&s, 0, sizeof s);
    strcpy(s.os, argv[3]);
    strcpy(s.lang, argv[4]);
    if (strcmp(argv[5], "-")) strcpy(s.ntsp, argv[5]);
    ua_resolve(&m, &pk, &s, atoi(argv[6]), strcmp(argv[7], "-") ? argv[7] : "", strcmp(argv[8], "-") ? argv[8] : "", &plan);
    for (i = 0; i < plan.count; i++) printf("IN %s\n", pk.pkg[plan.idx[i]].id);
    for (i = 0; i < pk.count; i++) {
        static const char *const why[] = { "", "full", "option", "needed", "out-system", "out-needs", "out-status", "out-unknown" };
        if (plan.why[i]) printf("WHY %s %s %s\n", pk.pkg[i].id, why[plan.why[i]], plan.unmet[i]);
    }
    printf("EFF %s\n", plan.eff_ntsp);
    return 0;
}

static int select_cmd(int argc, char **argv) {
    static ua_ini m, sel;
    ua_choice c;
    int len, len2;
    char *buf, *sbuf;
    if (argc < 4) return 2;
    buf = slurp(argv[2], &len);
    sbuf = slurp(argv[3], &len2);
    if (!buf || !sbuf) return 2;
    ua_ini_parse(&m, buf, len);
    ua_ini_parse(&sel, sbuf, len2);
    ua_selection(&m, &sel, &c);
    printf("PRESET %s\nFULL %d\nOPTIONS %s\nEXCLUDE %s\n", c.preset, c.full, c.options, c.exclude);
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "select") == 0) return select_cmd(argc, argv);
    if (argc >= 2 && strcmp(argv[1], "selftest") == 0) return selftest();
    if (argc >= 2 && strcmp(argv[1], "plan") == 0) return plan_cmd(argc, argv);
    fprintf(stderr, "usage: usosadd_host selftest | plan <manifest> <os> <lang> <ntsp|-> <full> <options|->\n");
    return 2;
}
