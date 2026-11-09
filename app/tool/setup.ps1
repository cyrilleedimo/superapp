# Prépare les projets natifs Windows + Android sur ton PC (une seule fois).
# Usage (PowerShell, dans le dossier app) :  .\tool\setup.ps1 -Org "[com.votre-domaine]"
param([Parameter(Mandatory = $true)][string]$Org)
$ErrorActionPreference = "Stop"
flutter create --platforms=windows,android --org $Org --project-name superapp .
Remove-Item test\widget_test.dart -ErrorAction SilentlyContinue
python tool/patch_platforms.py "Lumo"
flutter pub get
dart run flutter_launcher_icons
Write-Host "Prêt. Lance : flutter run -d windows   (ou)   flutter run -d <id-android>"
