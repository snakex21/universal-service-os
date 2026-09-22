# XP launcher and Vista signing follow-up

The physical screenshot shows the experimental XP EFI launcher waiting for
Enter, before starting Linux. It is not evidence of a driver or kernel hang.
Remove that redundant pause and console text: the parent's graphical loading
screen stays visible until Linux takes over. The existing graphical disk
selection and destructive-operation confirmation in Linux are unchanged.
Error messages clear the screen so they do not overlap the parent's UI.

`python tools/build_xp_uefi_csm_trial.py --launchers-only` returned 0.
Guarded `deploy_xp_uefi_csm_trial.ps1 -LaunchersOnly` returned 0, readback hashes
matched, and partition layout, production BIOS/Vista payloads and BOOTX64.EFI
were preserved. Backup: `artifacts/xp-pae/deploy-20260921-234707`.
No physical boot, VM or E2E was run by the agent. The next physical boot must
verify that Linux actually reaches the graphical selection screen.

Intel was identified as disk 8, GUID 8e281c54-58d1-4ad0-8afd-ad76d2e48148,
120034123776 bytes; Vista OS M: partition 8dca99dc-9f12-46c9-9c0d-5230748ee536.
Only read operations were performed there. The existing firstboot log records
two started USB controllers, one mouse, two keyboards and final error zero.
The installed SYS files have vendor signatures, while the installed package
uses USBXHCI.cat signed by USOS Vista USB Test Publisher v10 (local test CA).
Host Get-AuthenticodeSignature reports valid Riolin signatures, which does not
prove Vista kernel-policy acceptance. Host SignTool /kp checks of the embedded
primary signatures return 1 / 0x800B0101 (expired, not timestamped). This is a
host check, not a Vista boot test; it is not proof that every signature path
fails on Vista. Therefore TESTSIGNING was not disabled blindly: the working USB
configuration is only hardware-verified with it enabled. Removing the desktop
watermark would not be equivalent to disabling test mode.

Reference: https://learn.microsoft.com/en-us/windows-hardware/drivers/install/the-testsigning-boot-configuration-option
