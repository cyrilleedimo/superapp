"""Ajuste les projets natifs générés par `flutter create` (CI et poste local).

- Android : minSdk 31 (Android 12), permissions Internet + localisation,
  visibilité des liens https (url_launcher), pas de sauvegarde cloud des données,
  http autorisé UNIQUEMENT en debug.
- Windows : titre de fenêtre.
- iOS : nom affiché et textes d'autorisation.
- Web : titre, langue, nom de l'application installée.
Idempotent : peut être relancé sans dégâts.
"""
import pathlib
import re
import sys

APP_TITLE = sys.argv[1] if len(sys.argv) > 1 else "Ovia"
root = pathlib.Path(__file__).resolve().parent.parent


def patch(path: pathlib.Path, fn):
    if not path.exists():
        print(f"  (absent) {path}")
        return
    before = path.read_text(encoding="utf-8")
    after = fn(before)
    if after != before:
        path.write_text(after, encoding="utf-8")
        print(f"  modifié : {path.relative_to(root)}")


# ---- Android : minSdk 31
def gradle(s: str) -> str:
    s = re.sub(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = 31", s)
    s = re.sub(r"minSdkVersion\s+flutter\.minSdkVersion", "minSdkVersion 31", s)
    return s


for g in ("android/app/build.gradle.kts", "android/app/build.gradle"):
    patch(root / g, gradle)


# ---- Android : manifeste principal
def manifest(s: str) -> str:
    perms = [
        "android.permission.INTERNET",
        "android.permission.ACCESS_FINE_LOCATION",
        "android.permission.ACCESS_COARSE_LOCATION",
    ]
    for p in perms:
        if p not in s:
            s = s.replace("<application", f'<uses-permission android:name="{p}"/>\n    <application', 1)
    if "allowBackup" not in s:
        s = s.replace("<application", '<application android:allowBackup="false"', 1)
    s = re.sub(r'android:label="[^"]*"', f'android:label="{APP_TITLE}"', s, count=1)
    if 'android:scheme="https"' not in s:
        query = ('        <intent>\n            <action android:name="android.intent.action.VIEW"/>\n'
                 '            <data android:scheme="https"/>\n        </intent>\n')
        if "<queries>" in s:
            s = s.replace("<queries>", "<queries>\n" + query, 1)
        else:
            s = s.replace("</manifest>", "    <queries>\n" + query + "    </queries>\n</manifest>", 1)
    return s


patch(root / "android/app/src/main/AndroidManifest.xml", manifest)


# ---- Android : http autorisé en DEBUG seulement (backend local 10.0.2.2)
def debug_manifest(s: str) -> str:
    if "usesCleartextTraffic" not in s:
        s = s.replace("</manifest>", '    <application android:usesCleartextTraffic="true"/>\n</manifest>', 1)
    return s


patch(root / "android/app/src/debug/AndroidManifest.xml", debug_manifest)


# ---- Windows : titre de la fenêtre
def win_main(s: str) -> str:
    return re.sub(r'window\.Create\(L"[^"]*"', f'window.Create(L"{APP_TITLE}"', s)


patch(root / "windows/runner/main.cpp", win_main)


# ---- iOS : nom affiché + textes d'autorisation (photos, appareil photo, position)
def ios_plist(s: str) -> str:
    s = re.sub(r"(<key>CFBundleDisplayName</key>\s*<string>)[^<]*(</string>)", rf"\g<1>{APP_TITLE}\g<2>", s)
    keys = {
        "NSPhotoLibraryUsageDescription": "Pour ajouter des photos à tes annonces et à tes messages.",
        "NSCameraUsageDescription": "Pour prendre en photo les articles que tu vends.",
        "NSLocationWhenInUseUsageDescription": "Pour indiquer ton point de départ lors d'une course.",
    }
    for k, v in keys.items():
        if k not in s:
            s = s.replace("<dict>", f"<dict>\n\t<key>{k}</key>\n\t<string>{v}</string>", 1)
    return s


patch(root / "ios/Runner/Info.plist", ios_plist)


# ---- Web : titre, langue et nom de l'application installée (PWA)
def web_index(s: str) -> str:
    s = re.sub(r"<title>[^<]*</title>", f"<title>{APP_TITLE}</title>", s)
    s = s.replace('<html>', '<html lang="fr">')
    s = re.sub(r'(<meta name="apple-mobile-web-app-title" content=")[^"]*(")', rf"\g<1>{APP_TITLE}\g<2>", s)
    s = re.sub(r'(<meta name="description" content=")[^"]*(")',
               rf"\g<1>{APP_TITLE} — seconde main, courses, covoiturage, repas, boutiques et voyages.\g<2>", s)
    return s


def web_manifest(s: str) -> str:
    s = re.sub(r'"name":\s*"[^"]*"', f'"name": "{APP_TITLE}"', s, count=1)
    s = re.sub(r'"short_name":\s*"[^"]*"', f'"short_name": "{APP_TITLE}"', s, count=1)
    s = re.sub(r'"description":\s*"[^"]*"', f'"description": "{APP_TITLE} — tout ton quotidien dans une seule application."', s, count=1)
    s = re.sub(r'"background_color":\s*"[^"]*"', '"background_color": "#FFFFFF"', s, count=1)
    s = re.sub(r'"theme_color":\s*"[^"]*"', '"theme_color": "#2B3CF0"', s, count=1)
    return s


patch(root / "web/index.html", web_index)
patch(root / "web/manifest.json", web_manifest)
print("Plateformes prêtes.")
