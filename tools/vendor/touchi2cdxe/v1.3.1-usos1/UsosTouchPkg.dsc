## @file
#  Minimal platform DSC used by USOS to build TouchI2cDxe (MdePkg only).
#  Not part of upstream; see tools/vendor/touchi2cdxe/*/PROVENANCE.md.
##
[Defines]
  PLATFORM_NAME           = UsosTouch
  PLATFORM_GUID           = 6b0f3c1e-5a2d-4a7c-9e61-3f1d2c8b7a90
  PLATFORM_VERSION        = 1.0
  DSC_SPECIFICATION       = 0x00010005
  OUTPUT_DIRECTORY        = Build/UsosTouch
  SUPPORTED_ARCHITECTURES = X64
  BUILD_TARGETS           = RELEASE
  SKUID_IDENTIFIER        = DEFAULT

!include MdePkg/MdeLibs.dsc.inc

[LibraryClasses]
  UefiDriverEntryPoint|MdePkg/Library/UefiDriverEntryPoint/UefiDriverEntryPoint.inf
  UefiBootServicesTableLib|MdePkg/Library/UefiBootServicesTableLib/UefiBootServicesTableLib.inf
  UefiRuntimeServicesTableLib|MdePkg/Library/UefiRuntimeServicesTableLib/UefiRuntimeServicesTableLib.inf
  UefiLib|MdePkg/Library/UefiLib/UefiLib.inf
  BaseLib|MdePkg/Library/BaseLib/BaseLib.inf
  BaseMemoryLib|MdePkg/Library/BaseMemoryLib/BaseMemoryLib.inf
  MemoryAllocationLib|MdePkg/Library/UefiMemoryAllocationLib/UefiMemoryAllocationLib.inf
  IoLib|MdePkg/Library/BaseIoLibIntrinsic/BaseIoLibIntrinsic.inf
  DebugLib|MdePkg/Library/BaseDebugLibNull/BaseDebugLibNull.inf
  PrintLib|MdePkg/Library/BasePrintLib/BasePrintLib.inf
  PcdLib|MdePkg/Library/BasePcdLibNull/BasePcdLibNull.inf
  DevicePathLib|MdePkg/Library/UefiDevicePathLib/UefiDevicePathLib.inf

[Components]
  UsosTouchPkg/src/TouchI2cDxe.inf

[BuildOptions]
  # Reproducible PE: no timestamp/debug directory path differences.
  MSFT:RELEASE_*_*_DLINK_FLAGS = /Brepro
  MSFT:RELEASE_*_*_CC_FLAGS = /Brepro
