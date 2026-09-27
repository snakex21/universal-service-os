@echo -off
#
# Universal Service OS - UEFI Shell start script (EFI\USOS\shell\startup.nsh).
# USOS starts Shell.efi with "-delay 0", so this runs at once. It warns when
# Secure Boot is on (tools cannot be started from the Shell then), finds the
# USOS DATA partition among the mapped file systems and changes to
# DATA\Utilities\UEFI Shell\Tools, where the user keeps EFI tools
# (flashers, testers) and their files.
#
set -v usosdata none
for %i run (0 31)
  if exist fs%i:\Systems\ then
    if exist fs%i:\Utilities\ then
      if exist fs%i:\Programs\ then
        if not exist fs%i:\EFI\USOS\ then
          set -v usosdata fs%i:
        endif
      endif
    endif
  endif
endfor
echo " "
echo "Universal Service OS - UEFI Shell (EDK2, BSD-2-Clause-Patent)"
echo "  map -r      list the file systems again (fs0:, fs1:, ...)"
echo "  exit        return to the USOS menu"
# %usossecureboot% is set by USOS (volatile variable, gShellVariableGuid).
if %usossecureboot% == on then
  echo "Secure Boot is ON: the Shell cannot start .efi tools (shim refuses them"
  echo "  here: 'The image is not an application'). Turn Secure Boot off in the"
  echo "  firmware setup to run tools, or put a signed tool into"
  echo "  DATA\Utilities\<Name>\Images and start it from the USOS menu."
endif
if %usosdata% == none then
  echo "USOS DATA was not found. Type map -r, then fsN: and ls to look around."
else
  echo "USOS DATA = %usosdata% (NTFS, read-only in the Shell)"
  echo "  EFI tools and their files: %usosdata%\Utilities\UEFI Shell\Tools"
  echo "  A file the tool must write (e.g. a ROM backup) goes to the USOS ESP"
  echo "  (FAT32, writable) or to a FAT32 stick, not to DATA."
  %usosdata%
  if exist "\Utilities\UEFI Shell\Tools\" then
    cd "\Utilities\UEFI Shell\Tools"
  endif
endif
echo " "
