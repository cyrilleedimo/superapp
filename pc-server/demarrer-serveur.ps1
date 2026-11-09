# Démarre le serveur Ovia + le tunnel https Cloudflare, et affiche l'adresse à
# coller dans l'app (écran de connexion → « Serveur »).
# Laisse cette fenêtre ouverte : la fermer arrête le serveur pour tous les utilisateurs.
$ErrorActionPreference = "Stop"
$AppDir = $PSScriptRoot
$Desktop = [Environment]::GetFolderPath("Desktop")
$DataRoot = Join-Path $Desktop "Base de données"
$logs = Join-Path $env:LOCALAPPDATA "Ovia\logs"
New-Item -ItemType Directory -Force -Path $logs | Out-Null

# Empêche la mise en veille tant que le serveur tourne.
powercfg /change standby-timeout-ac 0 | Out-Null

Write-Host "Démarrage du serveur…" -ForegroundColor Cyan
$server = Start-Process -FilePath "npm.cmd" -ArgumentList "run", "local" -WorkingDirectory $AppDir -PassThru -WindowStyle Minimized `
  -RedirectStandardOutput (Join-Path $logs "serveur.log") -RedirectStandardError (Join-Path $logs "serveur-erreurs.log")

for ($i = 0; $i -lt 60; $i++) {
  try { if ((Invoke-RestMethod "http://localhost:8080/health" -TimeoutSec 2).ok) { break } } catch { Start-Sleep 2 }
}
Write-Host "Serveur prêt." -ForegroundColor Green

$tunnelLog = Join-Path $logs "tunnel.log"
if (Test-Path $tunnelLog) { Remove-Item $tunnelLog }
# cloudflared peut ne pas être dans le PATH juste après son installation.
$cf = (Get-Command cloudflared -ErrorAction SilentlyContinue).Source
if (-not $cf) { $cf = @("${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe", "$env:ProgramFiles\cloudflared\cloudflared.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1 }
if (-not $cf) { Write-Host "cloudflared introuvable : relance l'installation." -ForegroundColor Red; exit 1 }
$tunnel = Start-Process -FilePath $cf -ArgumentList "tunnel", "--no-autoupdate", "--url", "http://localhost:8080" -PassThru -WindowStyle Minimized `
  -RedirectStandardError $tunnelLog

$url = $null
for ($i = 0; $i -lt 60 -and -not $url; $i++) {
  Start-Sleep 2
  if (Test-Path $tunnelLog) {
    $m = Select-String -Path $tunnelLog -Pattern "https://[a-z0-9-]+\.trycloudflare\.com" | Select-Object -First 1
    if ($m) { $url = $m.Matches[0].Value }
  }
}
if (-not $url) { Write-Host "Le tunnel n'a pas démarré. Vérifie ta connexion Internet." -ForegroundColor Red; exit 1 }

[IO.File]::WriteAllText((Join-Path $DataRoot "ADRESSE-DU-SERVEUR.txt"), "$url`r`nAttention : cette adresse change à chaque redémarrage du serveur.`r`n", (New-Object Text.UTF8Encoding($false)))
Set-Clipboard $url
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  Adresse du serveur (copiée dans le presse-papiers) :" -ForegroundColor Green
Write-Host "  $url" -ForegroundColor Yellow
Write-Host "  Dans l'app : écran de connexion → Serveur → colle l'adresse." -ForegroundColor Green
Write-Host "  Les codes SMS (mode pilote) s'affichent dans : $logs\serveur.log"
Write-Host "  Ferme cette fenêtre pour arrêter le serveur." -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green

try { Wait-Process -Id $server.Id } finally {
  Stop-Process -Id $tunnel.Id -ErrorAction SilentlyContinue
  Stop-Process -Id $server.Id -ErrorAction SilentlyContinue
}
