# MiniOS WIM: final07 HOST memory and timing

Closed host receipts only. These calculations rerun no apply, VM, mount or oracle. Source seal: `836e5ae9`; the independent Windows acceptance results remain separate.

The counted own budget is the peak requested live bytes in the core tracked allocator, plus the actual PE `SizeOfImage`, plus the full 1 MiB reserved stack. It is **not host-process RSS or committed memory**. It excludes system/runtime DLLs, allocator bookkeeping/rounding, untracked host startup allocations, filesystem cache and the Python/QEMU/oracle processes.

The final WIM host PE maps 749,568 B, with 1,048,576 B stack reserve (4,096 B initial commit). The direct NTFS feature PE maps 688,128 B with the same stack reserve. File sizes are not substituted for mapped image sizes.

## Synthetic codec maxima

Each maximum comes from the closed smoke, large and ADS host cases. The large fixtures contain 1,208 files and a 128 MiB +123 B file.

| Codec | Case | Tracked heap B | Own budget B | MiB | Host seconds |
|---|---|---:|---:|---:|---:|
| XPRESS | large/xpress | 663,212 | 2,461,356 | 2.347 | 2.379 |
| LZX | large/lzx | 674,840 | 2,472,984 | 2.358 | 2.307 |
| LZMS non-solid | large/lzms-nonsolid | 1,314,272 | 3,112,416 | 2.968 | 2.545 |

## Real install.wim cases

Both real inputs use LZX. Thus the worst LZX budget across **all** tested WIMs is the Windows 10 case, rather than the smaller synthetic LZX case above.

| Case | WIM index | Tracked heap B | Own budget B | MiB | Host seconds |
|---|---:|---:|---:|---:|---:|
| Windows 10 22H2 x86, WIM image2 | 2 | 4,644,728 | 6,442,872 | 6.144 | 204.417 |
| Windows 7 SP1 x86, WIM image1 | 1 | 3,996,056 | 5,794,200 | 5.526 | 106.916 |

Worst counted own budget: **6,442,872 B (6.144 MiB)** in `win10-final07`. The direct feature fixture uses 609,480 B tracked heap and 2,346,184 B (2.237 MiB) counted own budget.

Times are harness wall times around the host invocation/source revalidation. They exclude image creation, later Windows file verification/chkdsk and firmware execution. They are not an isolated codec throughput benchmark.

## Six negative outcomes

Every case exited 1 with the expected specific refusal; the complete 256 MiB target SHA256 stayed identical before/after, and no apply PASS marker appeared.

| Case | Expected refusal | Seconds | Whole target unchanged |
|---|---|---:|---|
| refuse-solid-lzms | `UnsupportedSolid` | 0.024 | Yes |
| refuse-split-part1 | `UnsupportedSplitWim` | 0.012 | Yes |
| refuse-split-part2 | `UnsupportedSplitWim` | 0.024 | Yes |
| refuse-index0 | `InvalidImageIndex` | 0.024 | Yes |
| refuse-index3 | `InvalidImageIndex` | 0.015 | Yes |
| refuse-resource-sha1 | `WimHashMismatch` | 0.025 | Yes |

Split SWM is rejected by the host entrypoint before tracked allocation reporting; its allocator peak is recorded as unavailable, not a measured zero. Index0/index3 report an actual tracked peak of zero.

Exact times, parsed PE fields, per-case peaks, complete target hashes and SHA256-pinned relative receipt/log paths are in [the portable metrics JSON](minios-wim-host-final07.json). All images and evidence are retained; this reporting step performs no cleanup.
