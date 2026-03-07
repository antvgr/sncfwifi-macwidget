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
    -framework Cocoa \
    -O \
    -o "${MACOS_DIR}/${APP_NAME}"

# Info.plist dans Contents/ (pas Resources/)
cp Resources/Info.plist "${CONTENTS}/Info.plist"

# Retirer l'attribut de quarantaine pour éviter le blocage Gatekeeper au premier lancement
xattr -dr com.apple.quarantine "${APP_BUNDLE}" 2>/dev/null || true

echo ""
echo "✅ Application créée : ${APP_BUNDLE}"
echo ""
echo "▶  Pour lancer :"
echo "   open ${APP_BUNDLE}"
echo ""
echo "▶  Pour démarrage automatique :"
echo "   Réglages Système > Général > Éléments de connexion > ajouter ${APP_BUNDLE}"
