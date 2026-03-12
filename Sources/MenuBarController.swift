import Cocoa
import CoreLocation

final class MenuBarController: NSObject {

    // MARK: - Properties

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let apiClient  = TrainAPIClient()
    private var timer: Timer?
    private var lastRawData: [String: Any]?

    // MARK: - Init

    override init() {
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "tram.fill", accessibilityDescription: "Train")
        statusItem.button?.imagePosition = .imageLeft
        
        let loading = NSMenu()
        loading.addItem(label("Chargement…", symbol: "arrow.2.circlepath"))
        statusItem.menu = loading

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Refresh

    @objc func refresh() {
        apiClient.fetchAll { [weak self] gps, details, bar, stats, status in
            guard let self else { return }
            if gps == nil && details == nil {
                self.statusItem.button?.image = NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: nil)
                self.statusItem.button?.title = ""
                self.statusItem.menu = self.notConnectedMenu()
            } else {
                self.statusItem.button?.image = NSImage(systemSymbolName: "tram.fill", accessibilityDescription: nil)
                let (title, menu) = self.trainMenu(gps: gps, details: details, bar: bar, stats: stats, status: status)
                // Ajoute un espace avant le texte pour aérer par rapport à l'icône
                self.statusItem.button?.title = title.isEmpty ? "" : " \(title)"
                self.statusItem.menu = menu
            }
        }
    }

    // MARK: - Menu: non connecté / API indisponible

    private func notConnectedMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(label("Non connecté au WiFi SNCF inOui", symbol: "wifi.exclamationmark"))
        m.addItem(label("(ou API du train indisponible)"))
        m.addItem(.separator())
        appendFooter(to: m)
        return m
    }

    // MARK: - Menu: données du train

    private func trainMenu(gps: [String: Any]?,
                           details: [String: Any]?,
                           bar: [String: Any]?,
                           stats: [String: Any]?,
                           status: [String: Any]?) -> (String, NSMenu) {

        let speed = safeInt(gps?["speed"])

        var trainNumber:       String?
        var originLabel:       String?
        var destinationLabel:  String?
        var nextStopLabel:     String?
        var nextStopIndex:     Int = 0
        var isStoppedAtStation: Bool = false
        var allStops:          [[String: Any]] = []

        let currentLat = asDouble(gps?["latitude"]) ?? asDouble(gps?["lat"])
        let currentLon = asDouble(gps?["longitude"]) ?? asDouble(gps?["lon"]) ?? asDouble(gps?["lng"])

        let distanceToStop: ([String: Any]) -> Double = { stop in
            guard let lat = currentLat, let lon = currentLon,
                  let coords = stop["coordinates"] as? [String: Any],
                  let sLat = self.asDouble(coords["latitude"]),
                  let sLon = self.asDouble(coords["longitude"]) else {
                return 999999.0
            }
            return CLLocation(latitude: lat, longitude: lon).distance(from: CLLocation(latitude: sLat, longitude: sLon))
        }

        if let det = details {
            trainNumber = det["trainId"] as? String

            allStops = (det["stops"] as? [[String: Any]]) ?? []
            originLabel      = allStops.first?["label"] as? String
            destinationLabel = allStops.last?["label"]  as? String

            // Trouver le segment en cours (le premier qui n'est pas à 100%)
            var currentSegmentIndex = 0
            for (i, stop) in allStops.enumerated() {
                let progressDict = stop["progress"] as? [String: Any]
                let pct = (progressDict?["progressPercentage"] as? Double) ?? 0.0
                if pct < 100.0 {
                    currentSegmentIndex = i
                    break
                }
                currentSegmentIndex = i
            }
            
            let depIndex = currentSegmentIndex
            let arrIndex = min(depIndex + 1, max(0, allStops.count - 1))
            
            let distToDep = allStops.indices.contains(depIndex) ? distanceToStop(allStops[depIndex]) : 999999.0
            let distToArr = allStops.indices.contains(arrIndex) ? distanceToStop(allStops[arrIndex]) : 999999.0
            
            // Logique de positionnement
            var isStopped = false
            var stoppedAt = arrIndex
            
            if speed < 10 {
                if distToDep < 1500 {
                    isStopped = true
                    stoppedAt = depIndex
                } else if distToArr < 1500 {
                    isStopped = true
                    stoppedAt = arrIndex
                } else if currentLat == nil {
                    // Fallback si pas de GPS coord : utilisation de l'API
                    let depStop = allStops[depIndex]
                    let pDict = depStop["progress"] as? [String: Any]
                    let pct = (pDict?["progressPercentage"] as? Double) ?? 0.0
                    let remDistAPI = (pDict?["remainingDistance"] as? Double) ?? 999999.0
                    let travDistAPI = (pDict?["traveledDistance"] as? Double) ?? 999999.0
                    
                    if pct < 2.0 || travDistAPI < 1500 {
                        isStopped = true
                        stoppedAt = depIndex
                    } else if pct > 98.0 || remDistAPI < 1500 {
                        isStopped = true
                        stoppedAt = arrIndex
                    }
                }
            }
            
            isStoppedAtStation = isStopped
            // En mouvement, la "prochaine gare" est la gare d'arrivée du segment (arrIndex)
            nextStopIndex = isStopped ? stoppedAt : arrIndex

            if !allStops.isEmpty && allStops.indices.contains(nextStopIndex) {
                nextStopLabel = allStops[nextStopIndex]["label"] as? String
            }
        }

        // ── Titre icône de la barre des tâches ────────────────────────
        let barTitle: String
        if let next = nextStopLabel {
            if isStoppedAtStation {
                barTitle = "À quai : \(next)"
            } else if speed > 0 {
                barTitle = "\(speed) km/h  ›  \(next)"
            } else {
                barTitle = "› \(next)"
            }
        } else if speed > 0 {
            barTitle = "\(speed) km/h"
        } else {
            barTitle = "inOui"
        }

        // ── Construction du menu natif ──────────────────────────────────
        let m = NSMenu()

        // 1. En-tête : Numéro de train et destination
        if let num = trainNumber {
            var headerTitle = "TGV INOUI n° \(num)"
            if let dest = destinationLabel {
                headerTitle += " à destination de \(dest)"
            }
            m.addItem(label(headerTitle, symbol: "tram.fill"))
            m.addItem(.separator())
        } else {
            m.addItem(label("Train TGV INOUI", symbol: "tram.fill"))
            m.addItem(.separator())
        }

        // 2. Desserte du train (tous les arrêts passés, actuels, futurs)
        if !allStops.isEmpty {
            for (i, stop) in allStops.enumerated() {
                let lbl = (stop["label"] as? String) ?? "?"
                let theoricDate = (stop["theoricDate"] as? String) // Date prévue de base
                let realDate = (stop["realDate"] as? String) // Date réelle (peut être égale à theoric s'il n'y a pas de retard)
                
                let delay = (stop["delay"] as? Int) ?? 0 // Retard en minutes
                
                var timeStr = ""
                // Si la date réelle est différente de la date théorique (et que delay > 0),
                // on affiche l'heure théorique barrée suivie de l'heure réelle
                let tTimeStr = formatTime(theoricDate) ?? ""
                let rTimeStr = formatTime(realDate) ?? ""
                
                if delay > 0, rTimeStr != tTimeStr, !tTimeStr.isEmpty {
                     // Utilisation des caractères Unicode pour barrer l'heure théorique (strikethrough)
                     let strikethroughTime = tTimeStr.map { String($0) + "\u{0336}" }.joined()
                     timeStr = "\(strikethroughTime)  \(rTimeStr) (+\(delay) min)"
                } else {
                     timeStr = rTimeStr
                }
                
                var line = lbl
                if !timeStr.isEmpty {
                    line = timeStr + "    " + line
                }
                
                var symbolStr = "circle" // Futur, pas encore atteint
                if i < nextStopIndex {
                    symbolStr = "checkmark.circle.fill" // Passé
                } else if i == nextStopIndex {
                    symbolStr = "record.circle.fill" // En cours ou prochain arrêt immédiat
                }

                m.addItem(label(line, symbol: symbolStr))
            }
            m.addItem(.separator())
        }

        // 3. Infos Vitesse
        if speed > 0 {
            m.addItem(label("Vitesse actuelle : \(speed) km/h", symbol: "speedometer"))
        }

        // 4. Qualité du WiFi inOui
        if let stats = stats {
            var networkStr = "Qualité WiFi"
            var wifiSymbol = "wifi"
            if let quality = stats["quality"] as? Int {
                if quality < 3 { wifiSymbol = "wifi.exclamationmark" }
                // Ajout d'une petite appréciation selon la note
                let qualText = (quality >= 4) ? "Bonne" : (quality == 3 ? "Moyenne" : "Faible")
                networkStr = "WiFi : \(quality)/5 (\(qualText))"
            }
            // "il faut prendre compte le nombre de personne connecté a celui-ci"
            if let devices = stats["devices"] as? Int {
                networkStr += " — \(devices) pers. connectées"
            }
            m.addItem(label(networkStr, symbol: wifiSymbol))
        }

        // 5. Consommation data
        if let status = status {
            let remaining = safeInt(status["remaining_data"])
            let consumed  = safeInt(status["consumed_data"])
            let total = remaining + consumed

            if total > 0 {
                let remainingMB = String(format: "%.1f", Double(remaining) / 1000.0)
                let consumedMB  = String(format: "%.1f", Double(consumed) / 1000.0)
                let totalMB     = String(format: "%.1f", Double(total) / 1000.0)
                let pct = Int(Double(consumed) * 100.0 / Double(total))

                // Barre de progression visuelle
                let safePct = max(0, min(100, pct))
                let filled  = max(0, min(10, safePct / 10))
                let empty   = 10 - filled
                let bar     = String(repeating: "▓", count: filled) + String(repeating: "░", count: empty)

                m.addItem(label("Data : \(consumedMB) / \(totalMB) Mo utilisés (\(pct)%)", symbol: "arrow.up.arrow.down.circle"))
                m.addItem(label("  \(bar)  \(remainingMB) Mo restants"))
            }

            if let nextReset = status["next_reset"] as? NSNumber {
                let resetDate = Date(timeIntervalSince1970: nextReset.doubleValue / 1000.0)
                let tf = DateFormatter()
                tf.dateFormat = "HH:mm"
                tf.timeZone = .current
                m.addItem(label("  Prochain reset : \(tf.string(from: resetDate))"))
            }
        }

        // 6. Affluence au Bar
        if let barDict = bar {
            // Selon l'API, parfois "attendance": 0, parfois "isBarQueueEmpty": true
            let isQueueEmpty = (barDict["isBarQueueEmpty"] as? Bool) == true
            let attendance = (barDict["attendance"] as? Int) ?? -1
            
            if attendance == 0 || isQueueEmpty {
                m.addItem(label("Bar : Pas d'attente 🎉", symbol: "cup.and.saucer.fill"))
            } else if attendance > 0 {
                m.addItem(label("Bar : Attente en cours (\(attendance) pers.)", symbol: "person.3.sequence.fill"))
            } else {
                m.addItem(label("Bar : Attente en cours", symbol: "person.3.sequence.fill"))
            }
        }

        // Sauvegarde des données brutes pour le mode Debug
        var rawData: [String: Any] = [:]
        if let g = gps { rawData["gps"] = g }
        if let d = details { rawData["details"] = d }
        if let b = bar { rawData["bar"] = b }
        if let s = stats { rawData["stats"] = s }
        if let st = status { rawData["status"] = st }
        self.lastRawData = rawData

        // Menu Debug
        if !rawData.isEmpty {
            m.addItem(.separator())
            let debugItem = label("Debug", symbol: "ladybug.fill")
            let debugMenu = NSMenu()
            
            let copyItem = label("Copier le JSON (presse-papiers)", symbol: "doc.on.doc.fill")
            copyItem.target = self
            copyItem.action = #selector(copyDebugData)
            debugMenu.addItem(copyItem)
            
            debugMenu.addItem(.separator())
            
            if let g = gps, !g.isEmpty {
                debugMenu.addItem(submenuItem(title: "API GPS (brut)", data: g, symbol: "network"))
            }
            if let d = details, !d.isEmpty {
                debugMenu.addItem(submenuItem(title: "API Détails (brut)", data: d, symbol: "doc.text.fill"))
            }
            if let b = bar, !b.isEmpty {
                debugMenu.addItem(submenuItem(title: "API Bar (brut)", data: b, symbol: "cup.and.saucer"))
            }
            if let s = stats, !s.isEmpty {
                debugMenu.addItem(submenuItem(title: "API Stats (brut)", data: s, symbol: "antenna.radiowaves.left.and.right"))
            }
            if let st = status, !st.isEmpty {
                debugMenu.addItem(submenuItem(title: "API Status (brut)", data: st, symbol: "arrow.up.arrow.down.circle"))
            }
            
            debugItem.submenu = debugMenu
            m.addItem(debugItem)
        }

        m.addItem(.separator())
        appendFooter(to: m)

        return (barTitle, m)
    }

    private func parseDate(_ isoString: String?) -> Date? {
        guard let isoString else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: isoString) { return date }
        
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: isoString)
    }

    /// Convertit une date ISO 8601 en "HH:mm" heure locale.
    private func formatTime(_ isoString: String?) -> String? {
        guard let date = parseDate(isoString) else { return nil }
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        tf.timeZone = .current
        return tf.string(from: date)
    }

    // MARK: - Helpers de construction

    private func label(_ title: String, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol = symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            item.image = img
        }
        return item
    }

    private func indent(_ title: String) -> NSMenuItem {
        NSMenuItem(title: "  " + title, action: nil, keyEquivalent: "")
    }

    /// Crée un item avec sous-menu contenant toutes les paires clé/valeur aplaties.
    private func submenuItem(title: String, data: [String: Any], symbol: String? = nil) -> NSMenuItem {
        let item = label(title, symbol: symbol)
        let sub  = NSMenu()
        appendFlattened(data, prefix: "", to: sub)
        item.submenu = sub
        return item
    }

    private func appendFlattened(_ data: Any, prefix: String, to menu: NSMenu) {
        if let dict = data as? [String: Any] {
            for key in dict.keys.sorted() {
                let p = prefix.isEmpty ? key : "\(prefix).\(key)"
                appendFlattened(dict[key]!, prefix: p, to: menu)
            }
        } else if let arr = data as? [Any] {
            for (i, v) in arr.enumerated() {
                appendFlattened(v, prefix: "\(prefix)[\(i)]", to: menu)
            }
        } else {
            menu.addItem(NSMenuItem(title: "  \(prefix): \(data)", action: nil, keyEquivalent: ""))
        }
    }

    private func appendFooter(to menu: NSMenu) {
        let r = NSMenuItem(title: "Actualiser", action: #selector(refresh), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)

        let a = NSMenuItem(title: "À propos", action: #selector(openAbout), keyEquivalent: "")
        a.target = self
        menu.addItem(a)

        menu.addItem(.separator())

        let q = NSMenuItem(title: "Quitter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        q.target = NSApp
        menu.addItem(q)
    }

    // MARK: - Conversions sûres

    private func safeInt(_ value: Any?) -> Int {
        guard let value else { return 0 }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let d = Double(s) { return Int(d) }
        return 0
    }

    private func asDouble(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String    { return Double(s) }
        return nil
    }

    // MARK: - Actions

    @objc private func openURL(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let url = URL(string: str) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openAbout() {
        NSWorkspace.shared.open(URL(string: "https://github.com/antvgr/sncfwifi-macwidget")!)
    }

    @objc private func copyDebugData() {
        guard let data = lastRawData,
              let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted]),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(jsonString, forType: .string)
    }
}
