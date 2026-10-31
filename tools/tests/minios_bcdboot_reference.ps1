#requires -Version 7.0
# SPDX-License-Identifier: GPL-3.0-or-later
# Retired entry point. No loading mode, receipt or /s target grants permission.
[CmdletBinding()]
param([string]$Workspace,[string]$ReferenceJob,[string]$ReferenceJobSha256)
throw 'HOST_BCDBOOT_FORBIDDEN: use the offline REGF writer; host execution is permanently disabled'
