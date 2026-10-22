# NT351 AUTO policy interface for the separate agent/branch

NT35 owner is nt3; source/guard commit1feadbaf, fixture commit8c7dba7e,
worktree nt35-auto-client. Its fresh case nt35-client-auto-fresh01 is frozen
and running from POST87cb4325/30208B. Do not modify that source, cache,
private harness or VM. No second NT35 installation is requested.

NT351 may share the finite existing-service preparation core, with
**separate explicit version selectors**. Proposed implementation on a
separate NT351 branch based on the completed nt351-fresh664d721e:

1. Reuse the body of client35_prepare.h once as a common preparation core.
   Give it a const configuration carrying expected minor and exact own
   request/status/error filenames/text. Keep two wrappers/selectors:
   NT35 major3/minor50 + CLNT35.REQ/LOG/ERR, and NT351 major3/minor51 +
   CLNT351.REQ/LOG/ERR. Win9x high bit and every other version refuse a
   requested phase. Absent requests skip; **both present refuse before any
   POST mutation**, rather than choosing one. Do not silently widen the
   existing NT35 gate. NT31 stays excluded; its /polish path is separate.
2. Stage only the NT351 request through a new
   usos_nt351_client_request(root, original_product, answer_kind), called
   exclusively in minor51 after usos_nt351_stage. Require
   _u351_enabled=on, original ProductType exactly0, and DEFAULT/PROFILE;
   USER/unknown/Server/off never generate it. Marker text is independently
   versioned, e.g. `USOS NT351 client-no-sharing` plus CRLF. Original
   answer/binding syntax remains NT351 AdapterParameters, not NT35's
   NetCardParameterList. Stage/read only the selected request.
3. Convert the actual NT351 network routine to explicit return states:
   1=not selected, 2=verified selected takeover, 0=refusal. Preserve its
   corrected read_text missing/empty guard (87f599b1 in current NT351
   source/cache). A requested policy accepts only2. Keep original exact
   NDISLoop/NDISLoop1 Ethernet/DHCP/linkage/copy/readback checks. Do not
   copy an older complete usosnt3.c over the NT351 source.
4. Share the current guard/core: actual ProductOptions WinNT, existing
   Browser optional and LanmanServer required, Type32/Start2–4; query-only
   WorkstationType32/Start2 and TcpipType1/Start3. Only existing Browser and
   Server Start become4, only CurrentControlSet, followed by full readback.
   No RegCreate/new service, permanent worker, SCM-ready claim or inner LAN
   inference. Those service types/start values are already measured in the
   completed original fresh351 baseline; still revalidate at runtime.
5. Carry 1feadbaf's actual failure chain through int post(), service_main,
   requested checked own-service disable + DONE, no restart on refusal,
   failed service/process exit3, and /post return3. Parameterize the local
   records instead of adding a second resident frontend. Keep an existing
   error record terminal. Request/status/error data remain at staged app
   C:\USOS\NT3, with no profile/public/registry app-data fallback.

Port tests should execute the common C body with both explicit configs,
including wrong-version35↔351, both-marker refusal, USER/Server/off, missing
Server/wrong type, readback/write/flush failures and the actual DONE/restart
emitter. Preserve NT35's current tests; no new35 runtime is implied by that
refactor. Canonical build is build_windows_usos_res.py:build_nt3 (PE3.10).
Verify the rebuilt binary's actual imports against original NT351 modules
in RAM; NT35's50-import proof is not the NT351 original-export proof.

Fresh351's independent immutable base is
G:\USOS-Kolekcja\_assets\B261020-200536-968CCBE8-nt351-irq-fresh01.
Qualified own SYS17024B is
f579ef120d296eb5d19c9092f3bd87d7d97866ea2798479d5129a61b758f55cf.
Use nt351-fresh/docs/nt351-fresh-irq-qualification.md and its completed
manifest/scripts as the exact frozen media/cache method. Preserve all
unrelated effective entries, own USB, logger and current script hunks;
new private cache needs its own POST/script hashes and side-by-side diff.
No whole repo build is needed for these three own policy entries; if a
full build proves necessary, coordinate the single build.bat slot.

Qualification is one new **normal USOS/blank target NT351** after the
normal RAM guard (8GiB reserve), exact future notifications, metadata-only
retention and live Windows ConsoleMode+isatty. PS/2 baseline is explicit.
Require actual desktop, native SCM/net start showing Workstation active
and Server/Browser absent or disabled, DHCP/native ping/DNS, native safe
shutdown/QMP0 and stopped service/SYS/helper readback. No freshAUTO policy
PASS from DONE, hash/status, inner NIC-less QEMU or earlier overlay PASS.
Old fresh351 Server/Browser RUNNING/Start2 FAIL remains immutable evidence.
