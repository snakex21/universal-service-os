## @file
#  USOS platform DSC for rebuilding UefiSeven 1.30 from the vendored sources
#  (src/, upstream commit b8f0baba63e60e74d4ed3e86b15b76319d316b83) with
#  EDK2 edk2-stable202411 and VS2022. Not part of upstream; the upstream DSC
#  (src/UefiSevenPkg/UefiSevenPkg.dsc) targets GCC49 and a 2021 EDK2.
#  Same library mapping as upstream, plus MdeLibs.dsc.inc (required by current
#  EDK2) and /Brepro for a reproducible PE. See ../PROVENANCE.md.
##
[Defines]
  PLATFORM_NAME           = UsosUefiSeven
  PLATFORM_GUID           = 3c1d6f0a-8e2b-4d57-9a41-6b7e2f0c5d18
  PLATFORM_VERSION        = 1.0
  DSC_SPECIFICATION       = 0x00010005
  OUTPUT_DIRECTORY        = Build/UsosUefiSeven
  SUPPORTED_ARCHITECTURES = X64
  BUILD_TARGETS           = RELEASE
  SKUID_IDENTIFIER        = DEFAULT

!include MdePkg/MdeLibs.dsc.inc

[LibraryClasses]
  BaseLib|MdePkg/Library/BaseLib/BaseLib.inf
  BaseMemoryLib|MdePkg/Library/BaseMemoryLib/BaseMemoryLib.inf
  DebugLib|MdePkg/Library/BaseDebugLibNull/BaseDebugLibNull.inf
  CpuLib|MdePkg/Library/BaseCpuLib/BaseCpuLib.inf
  DevicePathLib|MdePkg/Library/UefiDevicePathLib/UefiDevicePathLib.inf
  IoLib|MdePkg/Library/BaseIoLibIntrinsic/BaseIoLibIntrinsic.inf
  MemoryAllocationLib|MdePkg/Library/UefiMemoryAllocationLib/UefiMemoryAllocationLib.inf
  MtrrLib|UefiCpuPkg/Library/MtrrLib/MtrrLib.inf
  PcdLib|MdePkg/Library/BasePcdLibNull/BasePcdLibNull.inf
  PrintLib|MdePkg/Library/BasePrintLib/BasePrintLib.inf
  UefiApplicationEntryPoint|MdePkg/Library/UefiApplicationEntryPoint/UefiApplicationEntryPoint.inf
  UefiBootServicesTableLib|MdePkg/Library/UefiBootServicesTableLib/UefiBootServicesTableLib.inf
  UefiLib|MdePkg/Library/UefiLib/UefiLib.inf
  UefiRuntimeServicesTableLib|MdePkg/Library/UefiRuntimeServicesTableLib/UefiRuntimeServicesTableLib.inf
  IniParsingLib|SignedCapsulePkg/Library/IniParsingLib/IniParsingLib.inf

[Components]
  UefiSevenPkg/Platform/UefiSeven/UefiSeven.inf

[BuildOptions]
  # Upstream flags (RELEASE, MSFT) ...
  MSFT:RELEASE_*_*_CC_FLAGS = /D MDEPKG_NDEBUG -D DISABLE_NEW_DEPRECATED_INTERFACES -D TARGET_BUILD_RELEASE /Brepro
  # ... and a reproducible PE: no timestamp or debug directory path differences.
  MSFT:RELEASE_*_*_DLINK_FLAGS = /Brepro
  RELEASE_*_*_GENFW_FLAGS = --zero
