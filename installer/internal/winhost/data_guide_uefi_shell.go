package winhost

import (
	"path/filepath"
	"strings"
)

// uefiShellGuide is DATA\Utilities\UEFI Shell\README.txt (Polish, then
// English): how to run the user's EFI tools from the built-in EDK2 Shell
// (src/platform/uefi/uefi_shell.zig, assets/uefi-shell/startup.nsh).
var uefiShellGuide = dataGuide{
	relativePath: filepath.Join("Utilities", "UEFI Shell", "README.txt"),
	contents:     []byte(strings.ReplaceAll(uefiShellGuideText, "\n", "\r\n")),
}

const uefiShellGuideText = `Universal Service OS - UEFI Shell (EDK2)

=== POLSKI ===

Powłoka UEFI (EDK2 UEFI Shell) jest wbudowana w USOS i działa tylko przy
starcie w trybie UEFI: menu Narzędzia (Utilities) -> Powłoka UEFI.
W menu BIOS jej nie ma. Polecenie exit wraca do menu USOS.

Narzędzia EFI - flashery BIOS/VBIOS, testery GPU/VRAM (np. typu NVIDIA
MATS/MODS), memtest86 w wersji .efi itp. - skopiuj razem z ich plikami
(np. plikiem ROM) do folderu:

  Utilities\UEFI Shell\Tools\

USOS nie dołącza żadnego z tych narzędzi i nie musisz uruchamiać Aktualizuj
USOS po ich skopiowaniu.

Po starcie powłoka sama znajduje partycję DATA, wypisuje jej nazwę
(np. "USOS DATA = fs2:") i przechodzi do folderu Tools. Dalej:

  ls                          lista plików
  flasher.efi -parametry      uruchomienie narzędzia (nazwa i parametry
                              według instrukcji narzędzia)

Ręcznie: map -r pokazuje wszystkie systemy plików (fs0:, fs1:, ...).
DATA to ten, na którym są foldery Systems, Utilities i Programs:

  fs2:
  cd "\Utilities\UEFI Shell\Tools"

DATA (NTFS) jest w powłoce tylko do odczytu. Plik, który narzędzie ma
zapisać (np. kopię zapasową ROM), zapisz na partycji USOS_ESP (FAT32, ta
z folderem EFI\USOS) albo na osobnym pendrive FAT32.

Secure Boot: powłoka jest podpisana kluczem USOS i startuje także przy
włączonym Secure Boot (mapowanie dysków, ls, cp itp. działają), ale nie
uruchamia wtedy żadnych programów .efi - nawet podpisanych ("The image is
not an application" albo "Verification failed"); powłoka wypisuje to przy
starcie. Aby użyć narzędzia, wyłącz Secure Boot w ustawieniach firmware
albo włóż podpisane narzędzie do Utilities\<Nazwa>\Images\ i uruchom je
z menu USOS.

Pojedynczy program .efi można też włożyć do Utilities\<Nazwa>\Images\ -
po Aktualizuj USOS pojawi się jako osobna pozycja w menu Narzędzia.

=== ENGLISH ===

The UEFI Shell (EDK2 UEFI Shell) is built into USOS and works only when the
stick starts in UEFI mode: Utilities -> UEFI Shell. The BIOS menu does not
have it. The exit command returns to the USOS menu.

Copy EFI tools - BIOS/VBIOS flashers, GPU/VRAM testers (e.g. NVIDIA
MATS/MODS style), memtest86 as .efi and so on - together with their files
(e.g. the ROM file) to:

  Utilities\UEFI Shell\Tools\

USOS does not bundle any of these tools, and you do not need to run Update
USOS after copying them.

On start the Shell finds the DATA partition, prints its name
(e.g. "USOS DATA = fs2:") and changes to the Tools folder. Then:

  ls                          list the files
  flasher.efi -options        run the tool (name and options as its
                              manual says)

By hand: map -r lists every file system (fs0:, fs1:, ...). DATA is the one
with the Systems, Utilities and Programs folders:

  fs2:
  cd "\Utilities\UEFI Shell\Tools"

DATA (NTFS) is read-only in the Shell. A file the tool has to write (e.g. a
ROM backup) must go to the USOS_ESP partition (FAT32, the one with the
EFI\USOS folder) or to a separate FAT32 stick.

Secure Boot: the Shell is signed with the USOS key and also starts with
Secure Boot on (mapping, ls, cp and so on work), but it then starts no .efi
program at all - not even a signed one ("The image is not an application"
or "Verification failed"); the Shell says so when it starts. To use a tool,
turn Secure Boot off in the firmware setup, or put a signed tool into
Utilities\<Name>\Images\ and start it from the USOS menu.

A single .efi program can also go to Utilities\<Name>\Images\ - it then
shows up as its own entry in the Utilities menu after Update USOS.
`
