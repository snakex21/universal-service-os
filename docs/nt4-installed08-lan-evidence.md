# NT4 installed LAN08b: new driver, strict LAN qualification [S18]

This result binds only to `Windows NT 4.0\Windows NT 4.0 Workstation PL.iso`,
502075392B, SHA256
`7aae3d7c36619c4edab58c8dccf9d350c78639f88afa36ae6b21e2e9cee9611b`,
build4.0.1381.1 / pl-PL x86 / windows-nt-4 csmwrap. Original staged SP6a PL
SP6I386.EXE SHA256 is
`a3306f0bc93d1d4709ab784ecd8aebd1a162c8249a219a9e078d1a4a91260542`.
Parent07 native Winver confirmed SP6a;08 preserves those installed OS files
and SYSTEM. Stopped CSDVersion reports Service Pack6. No other ISO,
Server, language or architecture inherits this PASS.

A new COW of completed LAN07 changes only own USOSNET4.SYS. Full4GiB
unrelated-byte and raw/overlay comparisons pass. Own source f8a87c46 changes
four canonical IGB IRQ register defines; f00b1597 selects NDISLoopStart2.
Runtime is BIOS q35/AHCI/igb8086:10C9, EPYC-Rome,2CPU/2048MiB, PS/2 allowed.
This is installed qualification, not a fresh complete AUTO cache or the
original OVMF-to-CSM transition, HTTP/browser, HID, MSC or X470 test.

## Actual LAN and safe completion

- Explorer desktop, exact ARM, GUI helper READY, actual serial first-logon
  token and TESTNET_DONE were observed. No manual FIRSTLO workaround.
- Native IPCONFIG /ALL shows NDISLoop1/usosnet, DHCP Yes,10.0.2.15/24,
  DHCP server/gateway10.0.2.2 and DNS10.0.2.3 (operator13).
- Native gateway ping4/4, every reply <10ms (operator09). Fresh own logger
  ICMP has status0/replies1/echo_match1/RTT0ms.
- The inherited Coverage USABILITY.TXT was deleted at step10; /testnet ran
  again at step11. NT4/USABILITY.TXT was unavailable. Final7NET lines come
  from this run; stale07 success cannot carry08 PASS.
- Configured UDP DNS matches peer10.0.2.3:53, ID2B11, questionfrogfind.com A,
  answer64.227.13.248, dns_match1, reply78ms. Fixed UDP1.1.1.1/8.8.8.8 also
  pass93/63ms; matched TCP1.1.1.1 connects31ms; native gethostbyname125ms is
  separate. GatewayUDP53 remains negative: no reply3000ms.
- Native safe-off16 precedes FINISH/QMPquit/exit0, elapsed841.441s.
  Stopped SYSTEM/SOFTWARE checksums and sequences are clean.

First-logon-scoped DHCP-only PCAP contains two complete DORA exchanges,
XIDc3394551/a3772d62, MAC52:54:00:55:53:01, address10.0.2.15,
server/router10.0.2.2, DNS10.0.2.3, lease86400s:8stored frames/3880B,
SHA256 `c55a7c3bf9f28727568f9956c3730542d6c30e10598130635cdae19b367bc49e`.
ICMP and DNS qualification comes from the strict own guest NET excerpt,
not nonexistent ICMP/DNS PCAP records.

Readonly collector08b completes30.151s/rc0 with **driver_hash_matches,
first_logon_observed, dhcp_pass, gateway_pass, dns_pass and
lan_traffic_matches_lease=true**, observer TESTNET_DONE. Guest sanitation
precedes transport; exact pins, strict host grammar/archive integrity,
actual token/status and matched lease/peer/port/ID/question gates remain.
Generic installed_runtime_pass remains false because it does not assess
Explorer/HID; raw runtime LAN/HID/MSC false fields are not rewritten.

Initial collector08 false flags remain historical: its inherited guest
script used literal21376B although DRIVER_BYTES was changed. The exact
new SYS is21248B. Narrow explicit policy replaces exactly that one guard
with21248 and retains the exact hash; an actual generated-command regression
covers it. This instrumentation mismatch was not Windows/SYS failure.
08b reads a fresh own hardlink alias of stopped08, same inode and readonly,
without Windows reboot or target write. Qualification commits are
`a2c12add4a0b138db6aff87a2e85d3f658f9dba1` and
`1e60b91c93d3dee7c60a87ecf57aa28d02c85164`.

## Actual installed payload and parent pins

| Own payload | Bytes | SHA256 |
|---|---:|---|
| USOSNET4.SYS | 21248 | 89b7337c294ca0c56415cdc4e7023615a628ae8158a5a7ab80dcf6f35ca02233 |
| USOSUSB.SYS, unchanged HID1.3 | 32128 | 2d4557439d7c60f7e0d5cc53d36467cbc36ae24596eb614e078059ddc718cfe1 |
| NT4OBS.EXE | 5632 | 82279b889053a68f42f18fdaeb0a1c0b5a76a00ce21e2685bedb9cb18dc38284 |
| USOSLOG.EXE | 1024000 | fe4ffa555e1cc837185156e7b76639d86b14580150663fd310c35ce3807c94c2 |
| FIRSTLO.CMD | 206 | c0f82213bb319445a9ea6d1407608af2b2cec53cbc633a9931ef4802e3bdbedc |

NDISLoop/TCPIP/DHCP/WorkstationStart2, Server/BrowserStart4,
i8042prt/USBStart1, SerialStart2; final TESTNET_DONE, ARM and both Run/RunOnce
hooks absent. No raw hive/answer/key/MS binary/private Setup frame export;
scratch raw removed.

- Final08: `G:\USOS-Kolekcja\_vm\nt4-installed07-canonical-irq08\target.qcow2`,
  SHA256 `f0f976d0af544fc3b2a87dbaac84811785332d9ef487d6e3e0c6a1ed6ad820ee`.
- Parent07: `G:\USOS-Kolekcja\_vm\nt4-installed03-network07\target.qcow2`,
  SHA256 `29036264e022d760223f2f091805e8c170888b3b8d6b1f933888c0193ce0da10`,
  verified unchanged after08.
- Original retained03 parent SHA256:
  `cf04c232df2dc3bcbc2775c0d31963fd1fc4abd4daf7a2967eba9be1f8af2a21`.

## IRQ measurement limitation

**IRQ_delivery_observed=false remains a measurement limitation**, without
full IRQ-route PASS or a negative Windows IRQ verdict. One endpoint query
reads PCI configuration IRQ12; that alone does not prove the HAL/PIRQ route.
PIC12 interrupts and the selected special nonmsix-ICR event were not captured.
Separately, the bounded passive trace records **57 assertedC0 clears
(0x80000080->0),114canonical IMS writes and57INTx assertions after the actual
first-logon boundary**. No active MMIO/ICR read or guest RAM probe is issued;
229404B trace,512KiB cap, zero dropped/overflow/error.147282 PIC events were
skipped before selection to preserve the budget.

The public QEMU igb_mac_icr_read INT_ASSERTED branch clears ICR before the
special nonmsix trace branch; that selected event is not a general ICR-read
counter. [QEMU source](https://github.com/qemu/qemu/blob/master/hw/net/igb_core.c#L2698).
This is a consistency explanation, not exact build-source proof: source URL
for local11.1.0/e470268ff4 was unavailable. Own IgbIrqRead is reached through
MpIsr; TimerFn does not read ICR; Reset also reads it during initialization.
These facts remain separate from full IRQ-route qualification and LAN PASS.

## Pinned completed metadata

- `C:\Users\ASRock\usos-work\macierz-windows\artifacts\coverage\nt4-installed08b-network-excerpt\collection.json`
  SHA256 `6c0b0212fd277d0fbc255ee8050ff49a2cbcf9ec9d6fb85eea9b96d0ae0366a5`.
- `C:\Users\ASRock\usos-work\nt4-net\artifacts\coverage\vm\nt4-installed07-canonical-irq08\result.json`
  SHA256 `36887cf2803eed9f46c7867e2d12525a695194b4d8a4c4271ef4ced58c2e484e`.
- `C:\Users\ASRock\usos-work\nt4-net\artifacts\coverage\vm\nt4-installed07-canonical-irq08\completed.json`
  SHA256 `14eb25e4fe80779a092397e4324834e2b79b7597d68331057cbf071746054576`.
- `C:\Users\ASRock\usos-work\nt4-net\artifacts\coverage\vm\nt4-installed07-canonical-irq08\irq-events.jsonl`
  SHA256 `6e1ede8d186915c2e809dd61085166f0a75238966b9201b1dc9fbe0e2a8e78a9`.
- `C:\Users\ASRock\usos-work\nt4-net\artifacts\coverage\vm\nt4-installed07-canonical-irq08\irq-assessment.json`
  SHA256 `0af6146fdafd6b47a0d0860c2a3d13c5b54f563ad1952158814d615d5bc9bd4e`.
- `C:\Users\ASRock\usos-work\nt4-net\artifacts\nt4-success-review\candidate08-irq-preparation.json`
  SHA256 `bd5317b037c92ab7fa29fe9f15e76a93a702a3da135397e22869a4d0f480277e`.
- `C:\Users\ASRock\usos-work\nt4-net\artifacts\nt4-success-review\candidate08-stopped-readback.json`
  SHA256 `7d7dc25974243cd0e84beb4cb60fa6aadbf0b00c6bb110cde35933d32d92d31f`.
- `C:\Users\ASRock\usos-work\nt4-net\artifacts\nt4-success-review\candidate08-evaluation.json`
  SHA256 `b3e6212412ca6e7f5fc7e03e2aab6194b05036323f0c3e62ea9d1c384298c240`.
- `C:\Users\ASRock\usos-work\nt4-net\tools\tests\coverage\nt4page_snapshot\installed03\network08_policy.py`
  SHA256 `2e449f70569d53467f4b52f6f9b941747ce7296173a2144ec90e004615ad666e`.

MAIN `C:\Users\ASRock\usos-work\macierz-windows\docs\windows-coverage-matrix.md`, SHA256 `85870445ef32dd3372a463fdc15ab8c2db8c6463324c4a238c6954086801ac86`,96rows; first4columns match the existing inventory.

LAN07 [S16] remains the old4f2/21376 qualification. LAN05 false and
matched unchanged Start3/control06 without adapter remain historical.
HID01 [S14] and frozenUSB313952/43648B MSC04 [S17] retain separate payloads
and outcomes. S18 adds no combined MSC/HID PASS. Focused source tests11PASS
(trace4,explicit08policy4,inherited07policy3). This matrix/doc update starts
no VM and performs no cleanup, asset change, merge, push or deployment.
