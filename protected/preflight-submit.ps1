# Rebuilds the protected AURA launch (fresh 1-hour permit window), runs Programmable's remote preflight (retrying
# transient 503s), and submits only if preflight reports no blocking findings. The API key is read with a hidden
# prompt, kept only in this PowerShell process, and never written anywhere.
Set-Location $PSScriptRoot
if (-not $env:PROGRAMMABLE_API_KEY) {
  $secure = Read-Host "Paste your Programmable API key (input hidden), then press Enter" -AsSecureString
  $env:PROGRAMMABLE_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
  if (-not $env:PROGRAMMABLE_API_KEY) { throw "No API key entered." }
}
# Relative on purpose: node --import rejects bare "C:\..." paths on Windows (it reads "C:" as a URL scheme).
$shim = "../contracts/scripts/win-fsync-shim.mjs"
$cli = "../tools/cli417/node_modules/@programmable/launch/bin/programmable-launch.mjs"
if (-not (Test-Path $cli)) { throw "CLI not found at $cli" }
# Let native stderr flow into the log files instead of turning into terminating PowerShell errors.
$ErrorActionPreference = "Continue"

Remove-Item launch.json, launch.json.receipt.json, preflight-result.json, preflight-log.txt -ErrorAction SilentlyContinue
node --import $shim build-protected.mjs *> build-log.txt
if ($LASTEXITCODE -ne 0) { Get-Content build-log.txt -Tail 25; throw "protected build failed (see protected\build-log.txt)" }
Write-Host "BUILD OK"

$preflightOk = $false
for ($attempt = 1; $attempt -le 4; $attempt++) {
  node --import $shim $cli validate launch.json --config protected-launch.config.json --remote 1> preflight-result.json 2> preflight-log.txt
  $code = $LASTEXITCODE
  $log = (Get-Content preflight-log.txt -Raw -ErrorAction SilentlyContinue)
  Write-Host "PREFLIGHT attempt $attempt exit code: $code"
  if ($code -eq 0) { $preflightOk = $true; break }
  if ($log) { Write-Host ($log.Trim()) }
  if ($attempt -lt 4 -and $log -match "503|429|timed out|ECONNRESET") { Write-Host "Transient error, retrying in 30s..."; Start-Sleep -Seconds 30; continue }
  break
}
if (-not $preflightOk) { throw "Preflight failed; not submitting. Details: protected\preflight-log.txt" }

$pre = Get-Content preflight-result.json -Raw | ConvertFrom-Json
if ($pre.preflight.hardBlockFindingCodes.Count -ne 0 -or -not $pre.preflight.launchEligibility.deployable) {
  throw "Preflight reports blocking findings; not submitting."
}

node --import $shim $cli submit launch.json --config protected-launch.config.json 1> submit-result.json 2> submit-log.txt
Write-Host "SUBMIT EXIT CODE: $LASTEXITCODE (saved to protected\submit-result.json, errors in protected\submit-log.txt)"
Write-Host "Tell Claude 'xong'. On a timeout, 429 or 503 during submit, tell Claude before retrying."
