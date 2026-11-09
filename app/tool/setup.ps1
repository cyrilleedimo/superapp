# Prépare les dossiers natifs Windows + Android à exécuter UNE fois sur ton PC.
# Usage (PowerShell, dans le dossier app) :  .\tool\setup.ps1 -Org "[com.votre-domaine]"
param([Parameter(Mandatory = $true)][string]$Org)
$ErrorActionPreference = "Stop"

# 1. Génère windows/ et android/ sans toucher à lib/ ni pubspec.yaml.
flutter create --platforms=windows,android --org $Org --project-name superapp .

# 2. Android 12 minimum (API 31).
$gradle = @("android/app/build.gradle.kts", "android/app/build.gradle") | Where-Object { Test-Path $_ } | Select-Object -First 1
$content = Get-Content $gradle -Raw
$content = $content -replace 'minSdk\s*=\s*flutter\.minSdkVersion', 'minSdk = 31'
$content = $content -replace 'minSdkVersion\s+flutter\.minSdkVersion', 'minSdkVersion 31'
Set-Content $gradle $content
Write-Host "minSdk fixé à 31 dans $gradle"

# 3. Permission Internet (absente du manifeste principal par défaut) + pas de sauvegarde cloud des données.
$manifest = "android/app/src/main/AndroidManifest.xml"
$m = Get-Content $manifest -Raw
if ($m -notmatch 'android.permission.INTERNET') {
  $m = $m -replace '<application', "<uses-permission android:name=`"android.permission.INTERNET`"/>`r`n    <application"
}
if ($m -notmatch 'allowBackup') {
  $m = $m -replace '<application', '<application android:allowBackup="false"'
}
Set-Content $manifest $m

# 4. En DEBUG uniquement : autorise http vers le backend local (10.0.2.2).
$debugManifest = "android/app/src/debug/AndroidManifest.xml"
$d = Get-Content $debugManifest -Raw
if ($d -notmatch 'usesCleartextTraffic') {
  $d = $d -replace '</manifest>', "    <application android:usesCleartextTraffic=`"true`"/>`r`n</manifest>"
  Set-Content $debugManifest $d
}

flutter pub get
Write-Host "Prêt. Lance : flutter run -d windows   (ou)   flutter run -d <id-android>"
