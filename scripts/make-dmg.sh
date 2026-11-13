#!/bin/zsh
# Builds the app and packages it as dist/LeftoverCleaner-<version>.dmg
# (drag-to-Applications layout).
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh
APP="build/Leftover Cleaner.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="dist/LeftoverCleaner-$VERSION.dmg"

STAGE=$(mktemp -d)/dmg
mkdir -p "$STAGE" dist
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<TXT
Leftover Cleaner $VERSION
Finds files left behind by apps you've uninstalled and moves them to the Trash.

DISCLAIMER: USE AT YOUR OWN RISK
I built Leftover Cleaner for my own Mac, with the help of Claude (an AI assistant),
because I wanted a free tool for this. I'm sharing it in case it's useful to others,
but it comes with no warranty and no support, and I'm not responsible for any data
loss or damage to your system. Review what it lists before removing anything, and
keep a backup (for example Time Machine). Removed items go to the Trash, so check it
before you empty it.

Install: drag "Leftover Cleaner" onto the Applications folder.

First launch: this build is not notarized by Apple, so macOS will block it the first time.
  1. Open Leftover Cleaner once and click "Done" on the warning.
  2. Go to System Settings > Privacy & Security, scroll down, and click "Open Anyway".
  3. Confirm with your password. After that it opens normally.

Optional: give it Full Disk Access (System Settings > Privacy & Security > Full Disk Access)
so it can clean protected folders without extra prompts.

Nothing is deleted outright: everything goes to the Trash, and macOS system files are never touched.
TXT

rm -f "$DMG"
hdiutil create -volname "Leftover Cleaner" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"
echo "Built: $PWD/$DMG"
