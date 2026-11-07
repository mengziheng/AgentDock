#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-/Applications/AgentDock.app}"
swift build --package-path "$ROOT" -c release
# Install only our executable and metadata, never copy source conversations or credentials.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$ROOT/.build/release/AgentDock" "$APP/Contents/MacOS/AgentDock"
install -m 644 "$ROOT/Resources/AgentDock.icns" "$APP/Contents/Resources/AgentDock.icns"
rm -rf "$APP/Contents/Resources/"*.lproj
cp -R "$ROOT/Resources/"*.lproj "$APP/Contents/Resources/"
python3 - "$APP" <<'PY'
import plistlib, sys
from pathlib import Path
app = Path(sys.argv[1])
info = {
    'CFBundleName': 'AgentDock',
    'CFBundleDisplayName': 'AgentDock',
    'CFBundleIdentifier': 'com.local.AgentDock',
    'CFBundleExecutable': 'AgentDock',
    'CFBundlePackageType': 'APPL',
    'CFBundleIconFile': 'AgentDock.icns',
    'CFBundleShortVersionString': '0.4.0',
    'CFBundleVersion': '6',
    'CFBundleDevelopmentRegion': 'en',
    'CFBundleLocalizations': ['en', 'zh-Hans'],
    'LSMinimumSystemVersion': '13.0',
    'LSApplicationCategoryType': 'public.app-category.productivity',
    'NSHighResolutionCapable': True,
    'NSSupportsAutomaticGraphicsSwitching': True,
    'LSUIElement': False,
}
with (app / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump(info, f)
(app / 'Contents/PkgInfo').write_bytes(b'APPL????')
PY
# Ad-hoc signature for this local installation, not a notarized distribution build.
codesign --force --sign - "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
mdimport "$APP"
printf 'Installed: %s\n' "$APP"
