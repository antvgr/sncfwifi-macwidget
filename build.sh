#!/usr/bin/env bash
# build.sh — Compile et empaquète l'app SNCFWifi dans SNCFWifi.app
set -euo pipefail

APP_NAME="SNCFWifi"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"
SRC_DIR="Sources"

echo "🔨 Compilation de ${APP_NAME} ($(uname -m))…"

# Nettoyage du bundle précédent
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# Compilation de tous les fichiers Swift en un seul binaire
# (swiftc cible automatiquement l'architecture du Mac courant)
swiftc \
    "${SRC_DIR}/main.swift" \
    "${SRC_DIR}/AppDelegate.swift" \
    "${SRC_DIR}/TrainAPIClient.swift" \
    "${SRC_DIR}/MenuBarController.swift" \
    "${SRC_DIR}/MockTrainData.swift" \
    "${SRC_DIR}/StatusBarImageGenerator.swift" \
    -framework Cocoa \
    -O \
    -o "${MACOS_DIR}/${APP_NAME}"

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
