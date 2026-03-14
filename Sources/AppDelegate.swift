import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Si l'app démarre en mode .regular (pour la dialog TCC localisation),
        // la mettre au premier plan pour que la dialog apparaisse au-dessus de tout.
        if NSApp.activationPolicy() == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
        controller = MenuBarController()
    }
}
