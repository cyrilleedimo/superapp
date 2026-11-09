# Démarre le serveur Ovia + le tunnel https ngrok (adresse fixe), et affiche
# l'adresse à coller dans l'app (écran de connexion → « Serveur »).
# Laisse cette fenêtre ouverte : la fermer arrête le serveur pour tous les utilisateurs.
$ErrorActionPreference = "Stop"
$AppDir = $PSScriptRoot
$Desktop = [Environment]::GetFolderPath("Desktop")
$DataRoot = Join-Path $Desktop "Base de données"
$logs = Join-Path $env:LOCALAPPDATA "Ovia\logs"
New-Item -ItemType Directory -Force -Path $logs | Out-Null

# Adresse ngrok fixe (compte gratuit : un seul "domaine" de ce type, stable pour toujours).
$NgrokDomain = "unpaired-each-womb.ngrok-free.dev"
$PublicUrl = "https://$NgrokDomain"

# L'adresse publique ne change plus (avant : cloudflared en changeait à chaque
# démarrage, ce qui cassait les liens des photos et le retour de paiement).
# On la (ré)écrit dans .env à chaque démarrage, pour que ça reste vrai même si
# le fichier est un jour régénéré.
$envFile = Join-Path $AppDir ".env"
if (Test-Path $envFile) {
  $lines = Get-Content $envFile -Encoding UTF8
  function SetEnvLine([string[]]$lines, [string]$key, [string]$value) {
    $pattern = "^$key="
    if ($lines -match $pattern) { return $lines -replace $pattern, "$key=$value" }
    return $lines + "$key=$value"
  }
  $lines = SetEnvLine $lines "PUBLIC_BASE_URL" $PublicUrl
  $lines = SetEnvLine $lines "PAYMENT_CALLBACK_URL" "$PublicUrl/payments/return"
  [IO.File]::WriteAllLines($envFile, $lines, (New-Object Text.UTF8Encoding($false)))
}

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
# ngrok peut ne pas être dans le PATH : on cherche aussi l'endroit où on l'installe nous-mêmes.
$ng = (Get-Command ngrok -ErrorAction SilentlyContinue).Source
if (-not $ng) { $ng = Join-Path $env:LOCALAPPDATA "Ovia\outils\ngrok.exe" }
if (-not (Test-Path $ng)) { Write-Host "ngrok introuvable : relance l'installation." -ForegroundColor Red; exit 1 }

if (Test-Path $tunnelLog) { Remove-Item $tunnelLog }
$tunnel = Start-Process -FilePath $ng -ArgumentList "http", "8080", "--url", "https://$NgrokDomain", "--log=stdout", "--log-format=logfmt" `
  -PassThru -WindowStyle Minimized -RedirectStandardOutput $tunnelLog

# L'adresse est fixe : on vérifie seulement que le tunnel est bien monté, via
# l'API locale de ngrok (http://127.0.0.1:4040), avant de l'annoncer comme prête.
$url = $null
for ($i = 0; $i -lt 20 -and -not $url; $i++) {
  Start-Sleep 2
  if ($tunnel.HasExited) { break }
  try {
    $resp = Invoke-RestMethod "http://127.0.0.1:4040/api/tunnels" -TimeoutSec 2
    if ($resp.tunnels | Where-Object { $_.public_url -like "https://$NgrokDomain*" }) { $url = "https://$NgrokDomain" }
  } catch { }
}
if (-not $url) {
  Write-Host "Le tunnel ngrok n'a pas démarré. Vérifie ta connexion Internet, puis le journal :" -ForegroundColor Red
  Write-Host "  $tunnelLog" -ForegroundColor Red
  exit 1
}

[IO.File]::WriteAllText((Join-Path $DataRoot "ADRESSE-DU-SERVEUR.txt"), "$url`r`nCette adresse est fixe : elle ne change plus au redémarrage.`r`n", (New-Object Text.UTF8Encoding($false)))
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
  if ($tunnel -and -not $tunnel.HasExited) { Stop-Process -Id $tunnel.Id -ErrorAction SilentlyContinue }
  Stop-Process -Id $server.Id -ErrorAction SilentlyContinue
}
