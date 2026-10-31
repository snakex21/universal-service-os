# MiniOS 1c5: closed performance probes

2026-10-26. Harness HEAD `7104f3c69b8b43b81c455daf63ea355ea72be30a`, clean before and after every probe. This is diagnostic evidence, not a completed installation.

Two unrelated QEMU processes were observed with affinity mask 3. The original harness used the same mask. Follow-up probes used mask 12 (two different logical CPUs), BelowNormal priority, one guest at a time and no concurrent compiler. Other guests were left untouched. A new-clock probe on the shared mask timed out after 400 s during the blank scan; its unchanged EFI subsequently completed on mask 12. Do not attribute that timeout, or the earlier 41 s small-file interval, exclusively to profiling.

Each PM pair used identical EFI SHA-256 `ec52c463e94878d6df239efb412922b94f143b7e5ff67805fcb9b1b2e5d84bd4`, built from `ac7230bb`. Each TSC/buffer probe used identical EFI SHA-256 `058b08519d5a338f05104c51fd9eafbdc0bd12d9607c18cf8a4d85f29b30a196`, built from `ed8ab512`; later changes were BIOS/test/harness only. Both origins are committed. Every probe stopped deliberately at entry 12613, with no installation PASS.

The matched interval is entries 10151 to 12613: 2462 entries, 2000 resources, 10547056 uncompressed bytes.

| Diagnostic | Blank scan | Matched interval | Aggregate IO calls |
|---|---:|---:|---:|
| PM disabled | 62 s | 3 s | 27532 |
| PM enabled | 73 s | 5 s | 27532 |
| New clock, profiling disabled | 60.684 s | 2.652 s | 27532 |
| TSC profiling enabled | 65.682 s | 3.088 s | 27532 |

PM values use quantized RTC seconds, not millisecond precision. These controlled probes show PM profiling overhead plus a separate host-CPU scheduling confounder; the earlier approximately 13.7-fold ratio is not the isolated cost of PM IO. The calibrated TSC is approximate, non-serializing aggregate timing, validated against coarse RTC only at progress boundaries. The virtual CPU does not advertise invariant TSC. All new-clock probes stayed valid. The PM-read count at calibration and diagnostic exit was identical; there are no subsequent PM samples.

| Buffer/profiling | Apply through entry 12613 | Matched interval | Target calls | Target time/call |
|---|---:|---:|---:|---:|
| ON / TSC, first | 28.266 s | 3.088 s | 24894 | 0.092311 ms |
| OFF / TSC, first | 29.353 s | 2.810 s | 25715 | 0.081703 ms |
| OFF / TSC, reversed | 26.987 s | 2.816 s | 25715 | 0.082403 ms |
| ON / TSC, reversed | 28.115 s | 2.910 s | 24894 | 0.086728 ms |
| ON / profiling disabled | 24.916 s | 2.652 s | 24894 | unavailable |
| OFF / profiling disabled | 27.845 s | 2.727 s | 25715 | unavailable |

Per-call values are measured exclusive target-IO time divided by measured target calls, including reads/writes/flushes. They are not wall time divided by source-plus-target calls. Profiling-enabled whole-phase means are essentially tied (ON 28.1905 s, OFF 28.1700 s); run variation exceeds that difference. Keep the existing ON default: it has the better observed unprofiled whole-phase result and fewer IO calls, but a stable overall speed advantage has not been established. Buffer OFF saves exactly 1048576 tracked bytes. Peaks: ON 12044492 B, OFF 10995916 B. BIOS buffer performance is not inferred from UEFI/virtio.

Closed receipts and logs are under pool-relative `1c5/isolated-probes/`, `1c5/buffer-reverse/` and `1c5/probes-result.json`. All images remain retained. The three specifically accepted older images were removed manually by the user after automatic review rejected both deletion commands; hashes and exact inventory remain in `1c5/accepted-1c4-cleanup.json`.

Test-count audit: 1c1 721 = 105 prep + 616 other tests; 1c4 228 = 207 prep + 21 FAT32 (the full project suite was not run). Before 1c5 changes the full suite passed 846 = 207 prep + 21 FAT32 + 618 other tests. New final sources pass 862 = 223 prep + 21 FAT32 + 618 other tests, including nine TSC and seven RTC tests. Full Python discovery passed 340/340 with the native header ABI enabled and no skip; the subsequent ELF-audit change passed its eight targeted tests plus the real BIOS audit/link/pack. Final full Zig log: `1c5/logs/final-core05.log`.
