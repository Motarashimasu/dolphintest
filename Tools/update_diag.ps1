# Automatic updates: does the server hand out the download links for the current build?
# Does what the launcher does (update.php check, the signed file list, then the links for its
# files, 400 at a time) and prints the server's answer when something fails. Prints no secrets.
#
#   powershell -ExecutionPolicy Bypass -File Tools\update_diag.ps1 -Token <your DRAGON NET token>
#
# The token is in SparkingData\frontend.cfg ([ranked] token="..."). Don't share it.
param(
    [Parameter(Mandatory = $true)][string]$Token,
    [string]$Server = "https://tecshideout.ct.ws/sparking/"
)
$ErrorActionPreference = "Stop"
$headers = @{ "X-Sparking-Token" = $Token; "Accept" = "application/json" }

function Call($body) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri ($Server + "update.php") -Headers $headers `
            -ContentType "application/json" -Body ($body | ConvertTo-Json -Compress -Depth 4) -TimeoutSec 20
        return @{ status = [int]$r.StatusCode; text = $r.Content }
    } catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            return @{ status = [int]$resp.StatusCode; text = $reader.ReadToEnd() }
        }
        return @{ status = 0; text = $_.Exception.Message }
    }
}

function Short($t) { $t = ($t -replace "\s+", " "); return $t.Substring(0, [Math]::Min(300, $t.Length)) }

Write-Host "1. check"
$c = Call @{ action = "check"; game = "bt3" }
if ($c.status -ne 200 -or $c.text -notmatch '"ok":true') { Write-Host "   FAILED ($($c.status)): $(Short $c.text)"; exit 1 }
$url = ($c.text | ConvertFrom-Json).manifest_url
Write-Host "   ok"

Write-Host "2. the file list"
try {
    $env = (Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 30).Content | ConvertFrom-Json
} catch { Write-Host "   FAILED: $($_.Exception.Message)"; exit 1 }
$m = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env.manifest)) | ConvertFrom-Json
$shas = @($m.files | ForEach-Object { $_.sha256 } | Select-Object -Unique)
Write-Host "   version $($m.version): $($m.files.Count) files, $($shas.Count) different"

Write-Host "3. download links, 400 at a time (as the launcher asks)"
$bad = 0
for ($i = 0; $i -lt $shas.Count; $i += 400) {
    $batch = $shas[$i..([Math]::Min($i + 399, $shas.Count - 1))]
    $t0 = Get-Date
    $r = Call @{ action = "files"; files = $batch; game = "bt3" }
    $ms = [int]((Get-Date) - $t0).TotalMilliseconds
    if ($r.status -ne 200 -or $r.text -notmatch '"ok":true') {
        $bad++
        Write-Host "   files $i-$($i + $batch.Count - 1): FAILED ($($r.status), $ms ms): $(Short $r.text)"
        # Narrow it down: which single fingerprint does the server refuse?
        foreach ($s in $batch) {
            $one = Call @{ action = "files"; files = @($s); game = "bt3" }
            if ($one.status -ne 200 -or $one.text -notmatch '"ok":true') {
                Write-Host "     refused alone: $s ($($one.status)): $(Short $one.text)"
                break
            }
        }
    } else {
        Write-Host "   files $i-$($i + $batch.Count - 1): ok ($ms ms, $($r.text.Length) bytes)"
    }
}
if ($bad -eq 0) { Write-Host "All batches ok: the server side works." } else { Write-Host "$bad batch(es) failed." }
