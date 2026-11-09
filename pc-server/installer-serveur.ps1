# Installe le serveur Lumo sur ce PC Windows (à lancer une seule fois).
#   - Node.js LTS et cloudflared via winget (l'installeur officiel de Windows)
#   - code du serveur dans %LOCALAPPDATA%\Lumo\serveur
#   - données dans  Bureau\Base de données\
#        système\        base PostgreSQL embarquée (ne pas modifier)
#        Utilisateurs\   un fichier lisible par utilisateur
#        photos\         images envoyées par les utilisateurs
#   - raccourci « Démarrer le serveur Lumo » sur le bureau
$ErrorActionPreference = "Stop"
$Desktop = [Environment]::GetFolderPath("Desktop")
$DataRoot = Join-Path $Desktop "Base de données"
$AppDir = Join-Path $env:LOCALAPPDATA "Lumo\serveur"

function Need($cmd, $wingetId) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
    Write-Host "Installation de $wingetId…"
    winget install --id $wingetId -e --silent --accept-package-agreements --accept-source-agreements
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
  }
}
Need node "OpenJS.NodeJS.LTS"
Need cloudflared "Cloudflare.cloudflared"

# Code du serveur (dossier backend du dépôt)
$zip = Join-Path $env:TEMP "lumo-main.zip"
Invoke-WebRequest "https://github.com/cyrilleedimo/superapp/archive/refs/heads/main.zip" -OutFile $zip
$tmp = Join-Path $env:TEMP "lumo-src"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
Expand-Archive $zip $tmp
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
Copy-Item (Join-Path $tmp "superapp-main\backend\*") $AppDir -Recurse -Force
Copy-Item (Join-Path $tmp "superapp-main\pc-server\demarrer-serveur.ps1") $AppDir -Force
Push-Location $AppDir
npm ci --no-audit --no-fund
Pop-Location

# Dossiers de données
foreach ($d in @("", "Utilisateurs", "photos")) { New-Item -ItemType Directory -Force -Path (Join-Path $DataRoot $d) | Out-Null }

# Configuration (.env) : secrets aléatoires générés sur place, jamais envoyés ailleurs.
$envFile = Join-Path $AppDir ".env"
if (-not (Test-Path $envFile)) {
  function Rand($n) { $b = New-Object byte[] $n; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); [Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_') }
  $content = @"
NODE_ENV=development
PORT=8080
TRUST_PROXY_HOPS=1
JWT_SECRET=$(Rand 32)
PG_PASSWORD=$(Rand 24)
PG_PORT=54329
PG_DATA_DIR=$(Join-Path $DataRoot "système")
EXPORT_DIR=$(Join-Path $DataRoot "Utilisateurs")
UPLOAD_DIR=$(Join-Path $DataRoot "photos")
# Frais de protection acheteur (500 = 5 %). DÉCISION COMMERCIALE.
BUYER_FEE_BPS=500
PAYMENT_PROVIDER=sandbox
SANDBOX_WEBHOOK_SECRET=$(Rand 24)
# Tarif VTC (DÉCISION COMMERCIALE) : retire le # et mets tes montants pour activer le VTC.
# RIDE_BASE_XAF=
# RIDE_PER_KM_XAF=
"@
  # UTF-8 SANS BOM (sinon Node lit mal la première ligne)
  [IO.File]::WriteAllText($envFile, $content, (New-Object Text.UTF8Encoding($false)))
}

# Raccourci sur le bureau
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $Desktop "Démarrer le serveur Lumo.lnk"))
$lnk.TargetPath = "powershell.exe"
$lnk.Arguments = "-NoExit -ExecutionPolicy Bypass -File `"$(Join-Path $AppDir 'demarrer-serveur.ps1')`""
$lnk.WorkingDirectory = $AppDir
$lnk.Save()
Write-Host "Installation terminée. Double-clique sur « Démarrer le serveur Lumo » sur le bureau."
