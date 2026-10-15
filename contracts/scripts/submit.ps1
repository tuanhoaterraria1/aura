# Submits the exact launch.json produced by preflight.ps1 into Programmable's manual review.
# Retries after a timeout / 429 / 503 must reuse the same bytes: just run this script again, never re-run preflight.ps1.
$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)
if (-not $env:PROGRAMMABLE_API_KEY) {
  $secure = Read-Host "Paste your Programmable API key (input hidden), then press Enter" -AsSecureString
  $env:PROGRAMMABLE_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
  if (-not $env:PROGRAMMABLE_API_KEY) { throw "No API key entered." }
}
if (-not (Test-Path launch.json)) { throw "launch.json missing: run .\scripts\preflight.ps1 first." }

$cli = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "tools\cli4\node_modules\@programmable\launch\bin\programmable-launch.mjs"
if (-not (Test-Path $cli)) { throw "CLI not found at $cli" }
node --import ./scripts/win-fsync-shim.mjs $cli submit launch.json --config programmable-launch.config.json *> submit-result.json
Write-Host "SUBMIT EXIT CODE: $LASTEXITCODE (result saved to contracts\submit-result.json)"
Write-Host "Tell Claude 'xong'. On a timeout, 429 or 503, just run this same script again (same bytes, same idempotency key)."
