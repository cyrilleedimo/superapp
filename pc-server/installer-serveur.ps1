# Installe le serveur Ovia sur ce PC Windows (à lancer une seule fois).
#   - Node.js LTS via winget (l'installeur officiel de Windows) et ngrok (téléchargement direct :
#     son paquet winget s'est révélé peu fiable)
#   - code du serveur dans %LOCALAPPDATA%\Ovia\serveur
#   - moteur de base PostgreSQL embarqué dans %LOCALAPPDATA%\Ovia\base-systeme
#     (hors du Bureau : OneDrive corromprait une base active en la synchronisant)
#   - Bureau\Base de données\
#        Utilisateurs\   un fichier lisible par utilisateur
#        photos\         images envoyées par les utilisateurs
#   - raccourci « Démarrer le serveur Ovia » sur le bureau
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Desktop = [Environment]::GetFolderPath("Desktop")
$DataRoot = Join-Path $Desktop "Base de données"
$AppDir = Join-Path $env:LOCALAPPDATA "Ovia\serveur"
$OutilsDir = Join-Path $env:LOCALAPPDATA "Ovia\outils"

function Need($cmd, $wingetId) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
    Write-Host "Installation de $wingetId…"
    winget install --id $wingetId -e --silent --accept-package-agreements --accept-source-agreements
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
  }
}
Need node "OpenJS.NodeJS.LTS"

# ngrok (tunnel https à adresse fixe) : le paquet winget (Ngrok.Ngrok) échoue souvent
# avec une erreur de fichier verrouillé. Téléchargement direct du zip officiel à la place.
$ngrokExe = Join-Path $OutilsDir "ngrok.exe"
if (-not (Test-Path $ngrokExe)) {
  Write-Host "Téléchargement de ngrok…"
  New-Item -ItemType Directory -Force -Path $OutilsDir | Out-Null
  $ngrokZip = Join-Path $env:TEMP "ngrok.zip"
  if (Test-Path $ngrokZip) { Remove-Item $ngrokZip -Force }
  # Start-BitsTransfer reprend la progression déjà faite au lieu de repartir de
  # zéro : plus fiable que curl/Invoke-WebRequest sur une connexion lente.
  Start-BitsTransfer -Source "https://bin.ngrok.com/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip" -Destination $ngrokZip
  Expand-Archive -Path $ngrokZip -DestinationPath $OutilsDir -Force
  Remove-Item $ngrokZip
}
Write-Host ""
Write-Host "IMPORTANT : connecte ngrok à ton compte (gratuit) avant le premier démarrage :" -ForegroundColor Yellow
Write-Host "  1. Crée un compte sur https://dashboard.ngrok.com/signup" -ForegroundColor Yellow
Write-Host "  2. Récupère ton authtoken sur https://dashboard.ngrok.com/get-started/your-authtoken" -ForegroundColor Yellow
Write-Host "  3. Lance : & `"$ngrokExe`" config add-authtoken TON_TOKEN" -ForegroundColor Yellow
Write-Host "  4. Réserve ton domaine fixe gratuit sur https://dashboard.ngrok.com/domains, puis" -ForegroundColor Yellow
Write-Host "     mets-le dans demarrer-serveur.ps1 (variable `$NgrokDomain)." -ForegroundColor Yellow
Write-Host ""

# Code du serveur (dossier backend du dépôt)
$zip = Join-Path $env:TEMP "ovia-main.zip"
# curl.exe (intégré à Windows 10/11) : Invoke-WebRequest peut se bloquer sur certains PC
curl.exe -sSL --fail --max-time 300 -o $zip "https://github.com/cyrilleedimo/superapp/archive/refs/heads/main.zip"
if ($LASTEXITCODE -ne 0) { throw "Téléchargement du code impossible" }
$tmp = Join-Path $env:TEMP "ovia-src"
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
PG_DATA_DIR=$(Join-Path $env:LOCALAPPDATA "Ovia\base-systeme")
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
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $Desktop "Démarrer le serveur Ovia.lnk"))
$lnk.TargetPath = "powershell.exe"
$lnk.Arguments = "-NoExit -ExecutionPolicy Bypass -File `"$(Join-Path $AppDir 'demarrer-serveur.ps1')`""
$lnk.WorkingDirectory = $AppDir
$lnk.Save()
Write-Host "Installation terminée. Double-clique sur « Démarrer le serveur Ovia » sur le bureau."
