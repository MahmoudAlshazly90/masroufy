param([int]$Port = 3000)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
$env:PORT = "$Port"
$cabal = Get-Command cabal -ErrorAction SilentlyContinue
if (-not $cabal) { throw 'Install GHC and Cabal with GHCup first: https://www.haskell.org/ghcup/' }
Write-Host "Starting Masroufy at http://127.0.0.1:$Port" -ForegroundColor Green
& $cabal.Source run masroufy
