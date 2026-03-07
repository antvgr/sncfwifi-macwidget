import Cocoa

// Point d'entrée de l'app : pas d'icône Dock, uniquement barre des menus.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
