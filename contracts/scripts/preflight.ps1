# Rebuilds the AURA config, packs it and runs Programmable's remote preflight (no launch is created, no quota used).
# Requires $env:PROGRAMMABLE_API_KEY in this terminal. The permit window is 1 hour: run submit.ps1 within it.
$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)
if (-not $env:PROGRAMMABLE_API_KEY) {
  # Hidden prompt: the key is never echoed or written to disk, and lives only in this process.
  $secure = Read-Host "Paste your Programmable API key (input hidden), then press Enter" -AsSecureString
  $env:PROGRAMMABLE_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
  if (-not $env:PROGRAMMABLE_API_KEY) { throw "No API key entered." }
}

$cli = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "tools\cli4\node_modules\@programmable\launch\bin\programmable-launch.mjs"
if (-not (Test-Path $cli)) { throw "CLI not found at $cli" }
Remove-Item launch.json, launch.json.receipt.json -ErrorAction SilentlyContinue

node --env-file=.env build-and-configure.mjs | Out-Null
if ($LASTEXITCODE -ne 0) { throw "build failed" }
node --import ./scripts/win-fsync-shim.mjs $cli pack --config programmable-launch.config.json --output launch.json | Out-Null
if ($LASTEXITCODE -ne 0) { throw "pack failed" }

node --import ./scripts/win-fsync-shim.mjs $cli validate launch.json --config programmable-launch.config.json --remote *> preflight-result.json
Write-Host "PREFLIGHT EXIT CODE: $LASTEXITCODE (result saved to contracts\preflight-result.json)"
Write-Host "Tell Claude 'xong'. Keep this window open: submit must run in it within 1 hour, reusing the key you entered."
$env:AURA_PREFLIGHT_DONE = "1"
