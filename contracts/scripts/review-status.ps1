# Reads the AURA launch status and the reviewer's feedback. Writes review-status.json / review-feedback.json.
# The API key is read with a hidden prompt, used only in this process, and never written anywhere.
$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)
$launchId = if ($args.Count) { $args[0] } else { "6a925c3b-a9ee-41bc-a1bb-5cd7c1536de4" }
if (-not $env:PROGRAMMABLE_API_KEY) {
  $secure = Read-Host "Paste your Programmable API key (input hidden), then press Enter" -AsSecureString
  $env:PROGRAMMABLE_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
  if (-not $env:PROGRAMMABLE_API_KEY) { throw "No API key entered." }
}
$headers = @{ Authorization = "Bearer $($env:PROGRAMMABLE_API_KEY)"; Accept = "application/json" }

try {
  $status = Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri "https://api.programmable.market/v3/custom-launches/$launchId" -TimeoutSec 60
  [IO.File]::WriteAllText("$PWD\review-status.json", $status.Content)
  Write-Host "STATUS: HTTP $($status.StatusCode)"
} catch { [IO.File]::WriteAllText("$PWD\review-status.json", "ERROR: $($_.Exception.Message) $($_.ErrorDetails.Message)"); Write-Host "STATUS: error (see review-status.json)" }

try {
  $body = @{ operation = "ownerRead"; chainId = "1"; launchId = $launchId } | ConvertTo-Json -Compress
  $fb = Invoke-WebRequest -UseBasicParsing -Method Post -Headers $headers -ContentType "application/json" -Body $body -Uri "https://api.programmable.market/v1/custom-launch-reviews/feedback" -TimeoutSec 60
  [IO.File]::WriteAllText("$PWD\review-feedback.json", $fb.Content)
  Write-Host "FEEDBACK: HTTP $($fb.StatusCode)"
} catch { [IO.File]::WriteAllText("$PWD\review-feedback.json", "ERROR: $($_.Exception.Message) $($_.ErrorDetails.Message)"); Write-Host "FEEDBACK: error (see review-feedback.json)" }

Write-Host "Done. Tell Claude 'xong'."
