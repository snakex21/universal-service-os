# Windows 7 SP1 x64: Microsoft NVMe packages

The bundle contains original Microsoft components from KB2990941 v3 and
KB3087873 v2. These are proprietary Windows update components, not USOS code.
They are used only with the user's Windows 7 SP1 x64 installation media.
No driver binary, INF or catalog is patched; signature enforcement remains on.

Official download provenance:

| Lenovo wrapper | SHA-256 |
| --- | --- |
| [ho7105ww_64.exe](https://download.lenovo.com/pccbbs/mobiles/ho7105ww_64.exe) | `44782958fcce195275c667f06d42ab2ed3569090c5adfce06500acc5da8797c8` |
| [ho7106ww_64.exe](https://download.lenovo.com/pccbbs/mobiles/ho7106ww_64.exe) | `86c15a67c4d287e11c4dc142cec59d64aaa0625eac8e355d246567a4976cbfc3` |

The wrappers were extracted, never installed on the host. Their MSU payloads
are independently pinned in `tools/prepare_windows7_nvme_assets.py`:

| MSU | SHA-256 |
| --- | --- |
| windows6.1-kb2990941-v3-x64.msu | `d1acbdd8652d6c78ce284bf511f3a7f5f776a0a91357aca060039a99c6a93a16` |
| Windows6.1-KB3087873-v2-x64.msu | `6d511fb126495579f681ecf5f4052dcb2c4c21154a0a9faa5d9d8ae06d4be538` |

To regenerate the deterministic archive on Windows, run from the repository:

```text
python tools/prepare_windows7_nvme_assets.py path/to/windows6.1-kb2990941-v3-x64.msu path/to/Windows6.1-KB3087873-v2-x64.msu
```

The producer extracts CAB files with the Windows cabinet utility into its
workspace directory. `manifest.json` records every file hash;
`build_windows7_nvme.py` pins the archive hash separately and verifies both
inventory and contents before embedding them. The full CBS CABs service the
installed system through native Windows Setup. Bootstrap files update the
disposable WinPE image; this is not an offline CBS installation into WinPE.
WinRE servicing is not implemented.

Reference: [Microsoft NVMe update and integration procedure](https://support.microsoft.com/en-au/topic/update-to-add-native-driver-support-in-nvm-express-in-windows-7-and-windows-server-2008-r2-03cd423b-d42e-66c2-722b-019d16455a6b).
