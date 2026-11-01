#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$PROJECT_DIR/.." && pwd)"

echo "==> Compilazione Shuriken in modalità release..."
cd "$PROJECT_DIR"
swift build -c release

BINARY_PATH="$PROJECT_DIR/.build/release/Shuriken"
if [ ! -f "$BINARY_PATH" ]; then
    echo "ERRORE: Binary non trovato in $BINARY_PATH"
    exit 1
fi
echo "Binary trovato in: $BINARY_PATH"

# Prepara bundle
DMG_DIR="$PROJECT_DIR/ShurikenApp/Payload"
PAYLOAD_APP="$DMG_DIR/Shuriken.app"
ROOT_APP="$WORKSPACE_DIR/Shuriken.app"

for APP_TARGET in "$PAYLOAD_APP" "$ROOT_APP"; do
    echo "==> Aggiornamento bundle: $APP_TARGET"
    CONTENTS_DIR="$APP_TARGET/Contents"
    MACOS_DIR="$CONTENTS_DIR/MacOS"
    RESOURCES_DIR="$CONTENTS_DIR/Resources"

    mkdir -p "$MACOS_DIR"
    mkdir -p "$RESOURCES_DIR"

    # Copia binary (nome per matchare CFBundleExecutable)
    cp "$BINARY_PATH" "$MACOS_DIR/Shuriken"
    chmod +x "$MACOS_DIR/Shuriken"

    # Copia icona e Info.plist
    cp "$PROJECT_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
    cp "$PROJECT_DIR/MenuIcon.png" "$RESOURCES_DIR/MenuIcon.png"
    cp "$PROJECT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
done

# Crea DMG di installazione con symlink ad /Applications
echo "==> Creazione DMG di installazione Shuriken.dmg..."
DMG_OUTPUT="$PROJECT_DIR/Shuriken.dmg"
DMG_STAGING="/tmp/ShurikenStaging"

# Smonta eventuali vecchi volumi residui
hdiutil detach "/Volumes/Shuriken*" -force 2>/dev/null || true

rm -f "$DMG_OUTPUT"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

# Copia l'app nel folder di staging
cp -R "$PAYLOAD_APP" "$DMG_STAGING/Shuriken.app"

# Crea symlink diretto ad /Applications (consente il drag-and-drop immediato per l'installazione)
ln -s /Applications "$DMG_STAGING/Applications"

# Crea il file DMG finale (UDZO compresso)
hdiutil create -volname "Shuriken Installer" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_OUTPUT"

# Copia il DMG anche nel workspace root per comodità
cp "$DMG_OUTPUT" "$WORKSPACE_DIR/Shuriken.dmg"

# Cleanup
rm -rf "$DMG_STAGING"

echo "==> Build e packaging completati con successo!"
echo "DMG installabile: $DMG_OUTPUT"
echo "DMG (root): $WORKSPACE_DIR/Shuriken.dmg"
echo "App standalone: $ROOT_APP"