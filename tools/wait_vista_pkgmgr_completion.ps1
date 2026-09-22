$ErrorActionPreference='Stop'
Wait-Process -Name pkgmgr -ErrorAction SilentlyContinue
Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\artifacts\vista\offline-kmdf-20260921-174803\pkgmgr.log.txt') -Tail 30
