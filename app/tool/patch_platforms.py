"""Ajuste les projets natifs générés par `flutter create` (CI et poste local).

- Android : minSdk 31 (Android 12), permissions Internet + localisation,
  visibilité des liens https (url_launcher), pas de sauvegarde cloud des données,
  http autorisé UNIQUEMENT en debug.
- Windows : titre de fenêtre.
Idempotent : peut être relancé sans dégâts.
"""
import pathlib
import re
import sys

APP_TITLE = sys.argv[1] if len(sys.argv) > 1 else "Lumo"
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
print("Plateformes prêtes.")
