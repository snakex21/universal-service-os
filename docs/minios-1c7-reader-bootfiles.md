<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# MiniOS 1c7 — bootstrap MFT i bootfiles

Kod czytnika: 35bddc71. Czysta bramka obrazu: 318921fe.
NT5: ntfs.h ATTRIBUTE_LIST_ENTRY, attrsup.c NtfsLookupExternalAttribute,
mftsup.c NtfsReadMftRecord. Własna implementacja Zig, bez kopiowania kodu NT5.

Odczyt tylko do odczytu celu1c5: PASS, 13 runów MFT, 411 odczytów/7600728 B.
SHA256 obrazu przed/po: 7ff67181a910ee9461211ea5fe9b2e34958be41a30c102cd9356a40560848907.
SHA1 winload.efi, bootmgfw.efi i BCD-Template zgodne z niezależnym manifestem.
Dowody względnie wobec puli: 1c7/reader-real1c5-01/result.json i probe.log.

Bootfiles UEFI x64 na nakładce1c5: PASS, 140 plików/35531192 B, 57.63 s.
Peak allocator+stack1262797 B, stack high-water127032 B. Baza bez zmian.
Dowody: 1c23/qemu-x64/boot-win11-1c7-01/result.json, boot-files.json, debug.log.
Zewnętrzne porównanie bcdboot jawnie odroczone na polecenie użytkownika;
własny REGF i trasa BCD sprawdzone niezależnie. Brak deklaracji PASS Windows.
Wszystkie obrazy zachowane. Bez fizycznych dysków, montowania i deploy.
