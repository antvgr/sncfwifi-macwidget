#!/usr/bin/env bash
# build.sh — Compile et empaquète l'app SNCFWifi dans SNCFWifi.app
# Produit un binaire universel (arm64 + x86_64) compatible Intel et Apple Silicon
set -euo pipefail

APP_NAME="SNCFWifi"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"
SRC_DIR="Sources"

SWIFT_SOURCES=(
    "${SRC_DIR}/main.swift"
    "${SRC_DIR}/AppDelegate.swift"
    "${SRC_DIR}/TrainAPIClient.swift"
    "${SRC_DIR}/MenuBarController.swift"
    "${SRC_DIR}/MockTrainData.swift"
    "${SRC_DIR}/StatusBarImageGenerator.swift"
)

echo "🔨 Compilation de ${APP_NAME} (binaire universel arm64 + x86_64)…"

# Nettoyage du bundle précédent
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# Compilation arm64
swiftc "${SWIFT_SOURCES[@]}" \
    -framework Cocoa \
    -O \
    -target arm64-apple-macos11.0 \
    -o "/tmp/${APP_NAME}_arm64"

# Compilation x86_64
swiftc "${SWIFT_SOURCES[@]}" \
    -framework Cocoa \
    -O \
    -target x86_64-apple-macos11.0 \
    -o "/tmp/${APP_NAME}_x86_64"

# Fusion en binaire universel
lipo -create \
    "/tmp/${APP_NAME}_arm64" \
    "/tmp/${APP_NAME}_x86_64" \
    -output "${MACOS_DIR}/${APP_NAME}"

rm -f "/tmp/${APP_NAME}_arm64" "/tmp/${APP_NAME}_x86_64"

# Info.plist dans Contents/ (pas Resources/)
cp Resources/Info.plist "${CONTENTS}/Info.plist"

# Nettoyer tous les extended attributes (resource forks, quarantaine…) avant de signer
find "${APP_BUNDLE}" -exec xattr -c {} \; 2>/dev/null || true

# Signature ad-hoc : indispensable pour que TCC (Location Services) reconnaisse l'app
# -s -          : signature ad-hoc (pas de certificat developer requis)
# --deep        : signe aussi les frameworks/plugins embarqués
# --force       : remplace toute signature existante
codesign --force --deep -s - \
    --identifier "fr.sncf.wifi-widget" \
    --entitlements "Resources/entitlements.plist" \
    "${APP_BUNDLE}"

echo ""
echo "✅ Application créée : ${APP_BUNDLE}"
echo ""
echo "▶  Pour lancer :"
echo "   open ${APP_BUNDLE}"
echo ""
echo "▶  Pour démarrage automatique :"
echo "   Réglages Système > Général > Éléments de connexion > ajouter ${APP_BUNDLE}"
