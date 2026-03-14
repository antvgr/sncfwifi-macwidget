import Cocoa
import CoreLocation

// Si la permission localisation n'est pas encore accordée, démarrer en mode .regular
// (icône Dock visible) pour que macOS puisse présenter la dialog TCC d'autorisation.
// MenuBarController repasse en .accessory dès que la réponse est reçue.
let app = NSApplication.shared
if CLLocationManager().authorizationStatus == .notDetermined {
    app.setActivationPolicy(.regular)
} else {
    app.setActivationPolicy(.accessory)
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
