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
    "${SRC_DIR}/APIParsing.swift"
    "${SRC_DIR}/TrainProvider.swift"
    "${SRC_DIR}/TrainAPIClient.swift"
    "${SRC_DIR}/EurostarAPIClient.swift"
    "${SRC_DIR}/SNCFDataSource.swift"
    "${SRC_DIR}/EurostarDataSource.swift"
    "${SRC_DIR}/ICEAPIClient.swift"
    "${SRC_DIR}/ICEDataSource.swift"
    "${SRC_DIR}/LyriaAPIClient.swift"
    "${SRC_DIR}/LyriaDataSource.swift"
    "${SRC_DIR}/NomadDataSource.swift"
    "${SRC_DIR}/MenuBarController.swift"
    "${SRC_DIR}/MockTrainData.swift"
    "${SRC_DIR}/StatusBarImageGenerator.swift"
    "${SRC_DIR}/TrainPanelModel.swift"
    "${SRC_DIR}/TrainPanelView.swift"
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

# Icône de l'app (Launchpad / Finder) si présente. Régénérable via scripts/make_icon.sh
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "${RESOURCES_DIR}/AppIcon.icns"
fi

# Logos des compagnies (facultatifs — cf. Resources/Logos/README.md). Copiés à plat : c'est à la
# racine de Contents/Resources/ que NSImage(named:) les trouve et gère les suffixes @2x / @3x.
# Le dossier peut être vide, d'où le test préalable qui évite un échec sous `set -e`.
for logo_ext in png pdf; do
    if compgen -G "Resources/Logos/*.${logo_ext}" > /dev/null; then
        cp Resources/Logos/*."${logo_ext}" "${RESOURCES_DIR}/"
    fi
done

# Signature ad-hoc : indispensable pour que TCC (Location Services) reconnaisse l'app
# -s -          : signature ad-hoc (pas de certificat developer requis)
# --deep        : signe aussi les frameworks/plugins embarqués
# --force       : remplace toute signature existante
#
# On nettoie les extended attributes (com.apple.FinderInfo / provenance…) JUSTE avant chaque
# tentative : dans un dossier synchronisé iCloud Drive, le démon fileprovider les ré-applique,
# ce qui fait échouer codesign (« resource fork … detritus not allowed »). D'où la boucle de
# retry avec nettoyage immédiat à chaque essai.
sign_app() {
    xattr -cr "${APP_BUNDLE}" 2>/dev/null || true
    codesign --force --deep -s - \
        --identifier "fr.sncf.wifi-widget" \
        --entitlements "Resources/entitlements.plist" \
        "${APP_BUNDLE}"
}

for attempt in 1 2 3; do
    if sign_app; then
        break
    fi
    if [[ $attempt -eq 3 ]]; then
        echo "❌ Échec de la signature après 3 tentatives." >&2
        exit 1
    fi
    echo "↻ Signature échouée (attribut étendu ré-appliqué) — nouvelle tentative $((attempt + 1))/3…"
    sleep 1
done

echo ""
echo "✅ Application créée : ${APP_BUNDLE}"
echo ""
echo "▶  Pour lancer :"
echo "   open ${APP_BUNDLE}"
echo ""
echo "▶  Pour démarrage automatique :"
echo "   Réglages Système > Général > Éléments de connexion > ajouter ${APP_BUNDLE}"
