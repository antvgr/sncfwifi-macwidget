import Cocoa
import CoreLocation
import CoreWLAN
import UserNotifications

final class MenuBarController: NSObject {

    // MARK: - Properties

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let apiClient  = TrainAPIClient()
    private var timer: Timer?
    private var clockTimer: Timer?
    private var lastRawData: [String: Any]?

    // Cache pour le redraw de l'icône sans appel API
    private var cachedArrivalDate: Date?
    private var cachedDestShort: String = ""
    private var cachedGlobalProgress: Double = 0.0
    private var cachedSpeed: Int = 0
    private var cachedIsStopped: Bool = false
    private var cachedStoppedStation: String = ""
    private var cachedDelayMins: Int = 0
    private var cachedDelayCause: String = ""
    private static let resetTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()
    private let locationManager = CLLocationManager()
    private let notificationCenter = UNUserNotificationCenter.current()

    private let notifyBeforeArrivalEnabledKey = "notifyBeforeArrivalEnabled"
    private let notifyBeforeArrivalMinutesKey = "notifyBeforeArrivalMinutes"
    private let notifyBeforeArrivalTargetKey = "notifyBeforeArrivalTarget"
    private let lastArrivalNotificationStopIdKey = "lastArrivalNotificationStopId"
    private let allowedNotificationLeadTimes = [5, 10, 15]

    private enum ArrivalNotificationTarget: String {
        case selectedArrival
        case nextStop
    }

    // MARK: - Init

    override init() {
        super.init()
        
        // Demande la permission de localisation pour lire le SSID (macOS 14.4+)
        locationManager.delegate = self
        requestSSIDAuthorizationIfNeeded()

        // Prépare les réglages de notifications locales (avant arrivée en gare).
        registerNotificationDefaults()
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        statusItem.button?.image = NSImage(systemSymbolName: "tram.fill", accessibilityDescription: "Train")
        statusItem.button?.imagePosition = .imageLeft
        
        let loading = NSMenu()
        loading.addItem(label("Chargement…", symbol: "arrow.2.circlepath"))
        statusItem.menu = loading

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSNotification.Name("DemoDataDidUpdate"), object: nil)
        
        if MockTrainData.shared.isEnabled {
            MockTrainData.shared.start()
        }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.redrawTitle()
        }
    }

    @objc private func redrawTitle() {
        if cachedDelayMins > 0 {
            // Affiche le retard pendant 5s, puis repasse au texte normal
            var t = "⚠ +\(cachedDelayMins)min"
            if !cachedDelayCause.isEmpty { t += " · \(cachedDelayCause)" }
            applyTitleImage(text: t)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.redrawNormalTitle()
            }
        } else {
            redrawNormalTitle()
        }
    }

    private func redrawNormalTitle() {
        let text: String
        if cachedIsStopped && !cachedStoppedStation.isEmpty {
            text = "En gare de \(cachedStoppedStation)"
        } else {
            var t = cachedDestShort
            if let arrival = cachedArrivalDate, arrival > Date() {
                let diffMins = Int(arrival.timeIntervalSinceNow / 60)
                let timeStr: String
                if diffMins >= 60 {
                    let h = diffMins / 60
                    let m = diffMins % 60
                    timeStr = m > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(h)h"
                } else {
                    timeStr = "\(diffMins)min"
                }
                t = t.isEmpty ? timeStr : "\(t) dans \(timeStr)"
            }
            if cachedSpeed > 0 {
                let speedStr = "\(cachedSpeed)km/h"
                t = t.isEmpty ? speedStr : "\(t) · \(speedStr)"
            }
            text = t
        }
        applyTitleImage(text: text)
    }

    private func applyTitleImage(text: String) {
        guard !text.isEmpty,
              let img = StatusBarImageGenerator.draw(text: text, progress: cachedGlobalProgress)
        else { return }
        statusItem.button?.title = ""
        statusItem.button?.image = img
        statusItem.button?.imagePosition = .imageOnly
    }

    // MARK: - Refresh

    @objc func refresh() {
        if !MockTrainData.shared.isEnabled {
            let ssid = CWWiFiClient.shared().interface()?.ssid() ?? ""
            
            // Liste stricte des réseaux Wi-Fi SNCF / TGV
            let knownSNCFNetworks = [
                "_SNCF_WIFI_INOUI",
                "OUIFI",
                "SNCF_WIFI_INTERCITES",
                "WIFI_SNCF",
                "_WIFI_LYRIA"
            ]
            
            // On vérifie le nom du réseau s'il n'est pas vide (cas avec droits de localisation ou vieux macOS).
            if !ssid.isEmpty && !knownSNCFNetworks.contains(ssid) {
                // Pas sur le wifi du train : on arrête ici pour économiser la batterie
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.statusItem.button?.image = NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: nil)
                    self.statusItem.button?.title = ""
                    self.statusItem.menu = self.notConnectedMenu()
                }
                return
            }
        }

        apiClient.fetchAll { [weak self] gps, details, bar, stats, status in
            guard let self else { return }

            // Conserver un snapshot debug même si l'API est indisponible.
            var snapshot: [String: Any] = [:]
            let ssidInfo = self.currentSSIDInfo()
            snapshot["ssid"] = ssidInfo.ssid
            snapshot["ssidStatus"] = ssidInfo.status
            snapshot["demoMode"] = MockTrainData.shared.isEnabled
            snapshot["demoServerURL"] = MockTrainData.shared.baseURLString
            if let g = gps { snapshot["gps"] = g }
            if let d = details { snapshot["details"] = d }
            if let b = bar { snapshot["bar"] = b }
            if let s = stats { snapshot["stats"] = s }
            if let st = status { snapshot["status"] = st }
            self.lastRawData = snapshot

            if gps == nil && details == nil {
                self.statusItem.button?.image = NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: nil)
                self.statusItem.button?.title = ""
                self.statusItem.menu = self.notConnectedMenu()
            } else {
                let (title, customImage, menu) = self.trainMenu(gps: gps, details: details, bar: bar, stats: stats, status: status)
                if let img = customImage {
                    self.statusItem.button?.title = ""
                    self.statusItem.button?.image = img
                    self.statusItem.button?.imagePosition = .imageOnly
                } else {
                    self.statusItem.button?.image = NSImage(systemSymbolName: "tram.fill", accessibilityDescription: nil)
                    self.statusItem.button?.imagePosition = .imageLeft
                    self.statusItem.button?.title = title.isEmpty ? "" : " \(title)"
                }
                self.statusItem.menu = menu
                // Applique le texte delay-aware (rotation) après avoir peuplé le cache
                if self.cachedArrivalDate != nil || self.cachedIsStopped {
                    self.redrawTitle()
                }
            }
        }
    }

    // MARK: - Menu: non connecté / API indisponible

    private func notConnectedMenu() -> NSMenu {
        let m = NSMenu()
        if MockTrainData.shared.isEnabled {
            m.addItem(infoLabel("Serveur Démo indisponible", symbol: "network.slash"))
            m.addItem(infoLabel("Démarrer: ./start_demo_server.sh"))
            m.addItem(infoLabel("URL: \(MockTrainData.shared.baseURLString)"))
            m.addItem(.separator())

            let openPanel = NSMenuItem(title: "Ouvrir le panneau Démo", action: #selector(openDemoControlPanel), keyEquivalent: "")
            openPanel.target = self
            m.addItem(openPanel)
        } else {
            m.addItem(infoLabel("Non connecté au WiFi SNCF inOui", symbol: "wifi.exclamationmark"))
            m.addItem(infoLabel("(ou API du train indisponible)"))
        }

        m.addItem(.separator())

        let settingsItem = label("Paramètres", symbol: "gearshape.fill")
        let settingsMenu = NSMenu()

        let notifyToggle = NSMenuItem(title: "Notification avant arrivée", action: #selector(toggleBeforeArrivalNotification), keyEquivalent: "")
        notifyToggle.target = self
        notifyToggle.state = isBeforeArrivalNotificationEnabled ? .on : .off
        settingsMenu.addItem(notifyToggle)

        let notifyDelayItem = NSMenuItem(title: "Délai de notification", action: nil, keyEquivalent: "")
        let notifyDelayMenu = NSMenu()
        let selectedLeadTime = beforeArrivalNotificationLeadTime
        for minutes in allowedNotificationLeadTimes {
            let item = NSMenuItem(title: "\(minutes) min", action: #selector(setBeforeArrivalNotificationLeadTime(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = minutes
            item.state = (minutes == selectedLeadTime) ? .on : .off
            notifyDelayMenu.addItem(item)
        }
        notifyDelayItem.submenu = notifyDelayMenu
        notifyDelayItem.isEnabled = isBeforeArrivalNotificationEnabled
        settingsMenu.addItem(notifyDelayItem)

        let notifyTargetItem = NSMenuItem(title: "Type de notification", action: nil, keyEquivalent: "")
        let notifyTargetMenu = NSMenu()

        let selectedArrivalItem = NSMenuItem(title: "Gare d'arrivée sélectionnée", action: #selector(setNotificationTargetSelectedArrival), keyEquivalent: "")
        selectedArrivalItem.target = self
        selectedArrivalItem.state = (arrivalNotificationTarget == .selectedArrival) ? .on : .off
        notifyTargetMenu.addItem(selectedArrivalItem)

        let nextStopItem = NSMenuItem(title: "Prochaine gare", action: #selector(setNotificationTargetNextStop), keyEquivalent: "")
        nextStopItem.target = self
        nextStopItem.state = (arrivalNotificationTarget == .nextStop) ? .on : .off
        notifyTargetMenu.addItem(nextStopItem)

        notifyTargetItem.submenu = notifyTargetMenu
        notifyTargetItem.isEnabled = isBeforeArrivalNotificationEnabled
        settingsMenu.addItem(notifyTargetItem)

        settingsItem.submenu = settingsMenu
        settingsItem.isEnabled = true
        m.addItem(settingsItem)

        let debugItem = label("Debug", symbol: "ladybug.fill")
        let debugMenu = NSMenu()

        let demo = NSMenuItem(title: "Mode Démo (serveur local)", action: #selector(toggleDemoMode), keyEquivalent: "")
        demo.target = self
        demo.state = MockTrainData.shared.isEnabled ? .on : .off
        debugMenu.addItem(demo)

        let openPanel = NSMenuItem(title: "Ouvrir le panneau Démo", action: #selector(openDemoControlPanel), keyEquivalent: "")
        openPanel.target = self
        debugMenu.addItem(openPanel)

        if let raw = lastRawData, !raw.isEmpty {
            debugMenu.addItem(.separator())

            let copyItem = label("Copier le JSON (presse-papiers)", symbol: "doc.on.doc.fill")
            copyItem.target = self
            copyItem.action = #selector(copyDebugData)
            debugMenu.addItem(copyItem)

            debugMenu.addItem(.separator())

            if let g = raw["gps"] as? [String: Any], !g.isEmpty {
                debugMenu.addItem(submenuItem(title: "API GPS (brut)", data: g, symbol: "network"))
            }
            if let d = raw["details"] as? [String: Any], !d.isEmpty {
                debugMenu.addItem(submenuItem(title: "API Détails (brut)", data: d, symbol: "doc.text.fill"))
            }
            if let b = raw["bar"] as? [String: Any], !b.isEmpty {
                debugMenu.addItem(submenuItem(title: "API Bar (brut)", data: b, symbol: "cup.and.saucer"))
            }
            if let s = raw["stats"] as? [String: Any], !s.isEmpty {
                debugMenu.addItem(submenuItem(title: "API Stats (brut)", data: s, symbol: "antenna.radiowaves.left.and.right"))
            }
            if let n = raw["notification"] as? [String: Any], !n.isEmpty {
                debugMenu.addItem(submenuItem(title: "Notification (calcul)", data: n, symbol: "bell"))
            }
        }

        debugItem.submenu = debugMenu
        debugItem.isEnabled = true
        m.addItem(debugItem)

        m.addItem(.separator())
        appendFooter(to: m)
        return m
    }

    // MARK: - Menu: données du train

    private func trainMenu(gps: [String: Any]?,
                           details: [String: Any]?,
                           bar: [String: Any]?,
                           stats: [String: Any]?,
                           status: [String: Any]?) -> (String, NSImage?, NSMenu) {

        // L'API retourne la vitesse en m/s, on convertit en km/h
        let speedRaw = asDouble(gps?["speed"]) ?? 0.0
        let speed = Int(speedRaw * 3.6)

        var trainNumber:       String?
        var destinationLabel:  String?
        var nextStopLabel:     String?
        var nextStopIndex:     Int = 0
        var isStoppedAtStation: Bool = false
        var allStops:          [[String: Any]] = []
        var trainDelayMins:    Int = 0
        var trainDelayCause:   String = ""

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
            // "number" = numéro commercial du train (ex: 6201), "trainId" = numéro de rame matériel
            if let s = det["number"] as? String, !s.isEmpty {
                trainNumber = s
            } else if let n = det["number"] as? Int {
                trainNumber = String(n)
            } else if let n = det["number"] as? Double {
                trainNumber = String(Int(n))
            }

            allStops = (det["stops"] as? [[String: Any]]) ?? []
            destinationLabel = allStops.last?["label"]  as? String

            // Retard global du train — la valeur est sur chaque arrêt, pas à la racine
            trainDelayMins = safeInt(det["delay"])
            if trainDelayMins == 0 { trainDelayMins = safeInt(allStops.last?["delay"]) }

            // Raison du retard : d'abord dans events[], puis sur les arrêts
            if let events = det["events"] as? [[String: Any]] {
                trainDelayCause = events.first(where: { ($0["type"] as? String) == "RETARD" })
                    .flatMap { $0["text"] as? String } ?? ""
            }
            if trainDelayCause.isEmpty {
                trainDelayCause = (det["delayReason"] as? String)
                    ?? allStops.first(where: { ($0["delayReason"] as? String)?.isEmpty == false })
                        .flatMap { $0["delayReason"] as? String }
                    ?? ""
            }

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
            
            if speed < 36 {
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
        var barTitle = ""
        var customImage: NSImage? = nil
        var notificationDebug: [String: Any]?

        if !allStops.isEmpty {
            // Déterminer la gare d'arrivée cible
            var arrivalStationIndex = allStops.count - 1
            if let savedId = UserDefaults.standard.string(forKey: "arrivalStationId"),
               let idx = allStops.firstIndex(where: { ($0["id"] as? String) == savedId || ($0["label"] as? String) == savedId }) {
                if idx >= nextStopIndex {
                    arrivalStationIndex = idx
                }
            }
            let arrivalStop = allStops[arrivalStationIndex]
            let destLabel = arrivalStop["label"] as? String ?? ""
            
            // Calcul du temps estimé restant
            var timeRemainingStr = ""
            let dateStr = arrivalStop["realDate"] as? String ?? arrivalStop["theoricDate"] as? String
            if let targetDate = parseDate(dateStr), targetDate > Date() {
                let diffMins = Int(targetDate.timeIntervalSinceNow / 60)
                if diffMins >= 60 {
                    let h = diffMins / 60
                    let m = diffMins % 60
                    timeRemainingStr = m > 0 ? " \(h)h\(String(format: "%02d", m))" : " \(h)h"
                } else if diffMins > 0 {
                    timeRemainingStr = " \(diffMins)min"
                }
            }

            if let notificationTargetStop = notificationTargetStop(allStops: allStops,
                                                                   nextStopIndex: nextStopIndex,
                                                                   isStoppedAtStation: isStoppedAtStation,
                                                                   arrivalStationIndex: arrivalStationIndex) {
                let notifyLabel = notificationTargetStop["label"] as? String ?? "votre gare"
                let notifyId = (notificationTargetStop["id"] as? String) ?? notifyLabel
                let notifyDateStr = notificationTargetStop["realDate"] as? String ?? notificationTargetStop["theoricDate"] as? String
                if let notifyDate = parseDate(notifyDateStr) {
                    let notifyMins = Int(notifyDate.timeIntervalSinceNow / 60)
                    notificationDebug = [
                        "enabled": isBeforeArrivalNotificationEnabled,
                        "target": arrivalNotificationTarget.rawValue,
                        "targetStopId": notifyId,
                        "targetStopLabel": notifyLabel,
                        "minutesRemaining": notifyMins,
                        "leadTime": beforeArrivalNotificationLeadTime,
                        "isStoppedAtStation": isStoppedAtStation
                    ]
                    maybeNotifyBeforeArrival(
                        stopId: notifyId,
                        stopLabel: notifyLabel,
                        minutesRemaining: notifyMins,
                        isStoppedAtStation: isStoppedAtStation
                    )
                }
            }
            
            // Calcul de la progression basé sur le temps (départ → maintenant → arrivée cible)
            var globalProgress: Double = 0.0
            let firstStop = allStops[0]
            let firstDateStr = firstStop["realDate"] as? String ?? firstStop["theoricDate"] as? String
            let arrDateStr = arrivalStop["realDate"] as? String ?? arrivalStop["theoricDate"] as? String
            if let depDate = parseDate(firstDateStr), let arrDate = parseDate(arrDateStr), arrDate > depDate {
                let totalDuration = arrDate.timeIntervalSince(depDate)
                let elapsed = Date().timeIntervalSince(depDate)
                globalProgress = max(0.0, min(1.0, elapsed / totalDuration))
            }
            
            var text = ""
            if isStoppedAtStation, let station = nextStopLabel, !station.isEmpty {
                text = "En gare de \(shortStationName(station))"
            } else {
                let shortDest = shortStationName(destLabel)
                if !timeRemainingStr.isEmpty {
                    text = "\(shortDest) dans\(timeRemainingStr)"
                } else if !shortDest.isEmpty {
                    text = shortDest
                }
                if speed > 0 {
                    let speedStr = "\(speed)km/h"
                    text = text.isEmpty ? speedStr : "\(text) · \(speedStr)"
                }
            }
            
            // Mise en cache pour le redraw léger (clockTimer)
            cachedArrivalDate = parseDate(arrivalStop["realDate"] as? String ?? arrivalStop["theoricDate"] as? String)
            cachedDestShort = shortStationName(destLabel)
            cachedGlobalProgress = globalProgress
            cachedSpeed = speed
            cachedIsStopped = isStoppedAtStation
            cachedStoppedStation = nextStopLabel.map { shortStationName($0) } ?? ""
            cachedDelayMins = trainDelayMins
            cachedDelayCause = trainDelayCause

            customImage = StatusBarImageGenerator.draw(text: text, progress: globalProgress)
        } else {
            // Fallback s'il n'y a pas la liste des arrêts
            if let next = nextStopLabel {
                if isStoppedAtStation {
                    barTitle = "En gare de \(next)"
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
        }

        // ── Construction du menu natif ──────────────────────────────────
        let m = NSMenu()

        // 1. En-tête : Numéro de train et destination
        if let num = trainNumber {
            var headerTitle = "TGV INOUI n° \(num)"
            if let dest = destinationLabel {
                headerTitle += " à destination de \(dest)"
            }
            m.addItem(infoLabel(headerTitle, symbol: "tram.fill"))
            if trainDelayMins > 0 {
                var delayLine = "Retard : +\(trainDelayMins) min"
                if !trainDelayCause.isEmpty { delayLine += " (\(trainDelayCause))" }
                m.addItem(infoLabel(delayLine, symbol: "exclamationmark.triangle.fill"))
            }
            m.addItem(.separator())
        } else {
            m.addItem(infoLabel("Train TGV INOUI", symbol: "tram.fill"))
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

                m.addItem(infoLabel(line, symbol: symbolStr))
            }

            m.addItem(.separator())
        }

        // 3. Infos Vitesse
        if speed > 0 {
            m.addItem(infoLabel("Vitesse actuelle : \(speed) km/h", symbol: "speedometer"))
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
            m.addItem(infoLabel(networkStr, symbol: wifiSymbol))
        }

        // 5. Consommation data
        if let status = status {
            let remaining = safeInt(status["remaining_data"])
            let consumed = safeInt(status["consumed_data"])
            let total = remaining + consumed

            if total > 0 {
                let remainingMB = String(format: "%.1f", Double(remaining) / 1000.0)
                let consumedMB = String(format: "%.1f", Double(consumed) / 1000.0)
                let totalMB = String(format: "%.1f", Double(total) / 1000.0)
                let consumedRatio = Double(consumed) / Double(total)
                let safeRatio = max(0.0, min(1.0, consumedRatio))
                let safePct = Int((safeRatio * 100.0).rounded())
                let usageBar = progressBar(progress: safeRatio, width: 18)

                m.addItem(infoLabel("Data : \(consumedMB) / \(totalMB) Mo utilisés (\(safePct)%)", symbol: "arrow.up.arrow.down.circle"))
                m.addItem(infoLabel("  \(usageBar)"))
                m.addItem(infoLabel("  Restant : \(remainingMB) Mo"))
            }

            if let nextResetMs = asDouble(status["next_reset"]) {
                let resetDate = Date(timeIntervalSince1970: nextResetMs / 1000.0)
                let tf = MenuBarController.resetTimeFormatter
                m.addItem(infoLabel("  Prochain reset : \(tf.string(from: resetDate))"))
            }
        }

        if !allStops.isEmpty {
            m.addItem(.separator())
            let destItem = label("Gare d'arrivée...", symbol: "flag.fill")
            let destMenu = NSMenu()
            
            let savedId = UserDefaults.standard.string(forKey: "arrivalStationId")
            
            // On ne propose que les gares futures ou la gare actuelle
            // On peut autoriser toutes les gares pour la flexibilité
            for (i, stop) in allStops.enumerated() {
                let lbl = (stop["label"] as? String) ?? "Gare \(i)"
                let stopId = (stop["id"] as? String) ?? lbl
                let stopItem = NSMenuItem(title: lbl, action: #selector(self.setArrivalStation(_:)), keyEquivalent: "")
                stopItem.representedObject = stopId
                stopItem.target = self
                
                if savedId == stopId || (savedId == nil && i == allStops.count - 1) {
                    stopItem.state = .on
                }
                destMenu.addItem(stopItem)
            }
            
            destItem.submenu = destMenu
            destItem.isEnabled = true
            m.addItem(destItem)
        }

        // Sauvegarde des données brutes pour le mode Debug
        var rawData: [String: Any] = [:]
        let ssidInfo = currentSSIDInfo()
        rawData["ssid"] = ssidInfo.ssid
        rawData["ssidStatus"] = ssidInfo.status
        rawData["demoMode"] = MockTrainData.shared.isEnabled
        rawData["demoServerURL"] = MockTrainData.shared.baseURLString
        if let g = gps { rawData["gps"] = g }
        if let d = details { rawData["details"] = d }
        if let b = bar { rawData["bar"] = b }
        if let s = stats { rawData["stats"] = s }
        if let st = status { rawData["status"] = st }
        if let n = notificationDebug { rawData["notification"] = n }
        self.lastRawData = rawData

        m.addItem(.separator())

        let settingsItem = label("Paramètres", symbol: "gearshape.fill")
        let settingsMenu = NSMenu()

        let notifyToggle = NSMenuItem(title: "Notification avant arrivée", action: #selector(toggleBeforeArrivalNotification), keyEquivalent: "")
        notifyToggle.target = self
        notifyToggle.state = isBeforeArrivalNotificationEnabled ? .on : .off
        settingsMenu.addItem(notifyToggle)

        let notifyDelayItem = NSMenuItem(title: "Délai de notification", action: nil, keyEquivalent: "")
        let notifyDelayMenu = NSMenu()
        let selectedLeadTime = beforeArrivalNotificationLeadTime
        for minutes in allowedNotificationLeadTimes {
            let item = NSMenuItem(title: "\(minutes) min", action: #selector(setBeforeArrivalNotificationLeadTime(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = minutes
            item.state = (minutes == selectedLeadTime) ? .on : .off
            notifyDelayMenu.addItem(item)
        }
        notifyDelayItem.submenu = notifyDelayMenu
        notifyDelayItem.isEnabled = isBeforeArrivalNotificationEnabled
        settingsMenu.addItem(notifyDelayItem)

        let notifyTargetItem = NSMenuItem(title: "Type de notification", action: nil, keyEquivalent: "")
        let notifyTargetMenu = NSMenu()

        let selectedArrivalItem = NSMenuItem(title: "Gare d'arrivée sélectionnée", action: #selector(setNotificationTargetSelectedArrival), keyEquivalent: "")
        selectedArrivalItem.target = self
        selectedArrivalItem.state = (arrivalNotificationTarget == .selectedArrival) ? .on : .off
        notifyTargetMenu.addItem(selectedArrivalItem)

        let nextStopItem = NSMenuItem(title: "Prochaine gare", action: #selector(setNotificationTargetNextStop), keyEquivalent: "")
        nextStopItem.target = self
        nextStopItem.state = (arrivalNotificationTarget == .nextStop) ? .on : .off
        notifyTargetMenu.addItem(nextStopItem)

        notifyTargetItem.submenu = notifyTargetMenu
        notifyTargetItem.isEnabled = isBeforeArrivalNotificationEnabled
        settingsMenu.addItem(notifyTargetItem)

        settingsItem.submenu = settingsMenu
        settingsItem.isEnabled = true
        m.addItem(settingsItem)

        let debugItem = label("Debug", symbol: "ladybug.fill")
        let debugMenu = NSMenu()

        let demo = NSMenuItem(title: "Mode Démo (serveur local)", action: #selector(toggleDemoMode), keyEquivalent: "")
        demo.target = self
        demo.state = MockTrainData.shared.isEnabled ? .on : .off
        debugMenu.addItem(demo)

        let openPanel = NSMenuItem(title: "Ouvrir le panneau Démo", action: #selector(openDemoControlPanel), keyEquivalent: "")
        openPanel.target = self
        debugMenu.addItem(openPanel)

        if !rawData.isEmpty {
            debugMenu.addItem(.separator())
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
        }

        debugItem.submenu = debugMenu
        debugItem.isEnabled = true
        m.addItem(debugItem)

        m.addItem(.separator())
        appendFooter(to: m)

        return (barTitle, customImage, m)
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

    private func shortStationName(_ name: String) -> String {
        let exact: [String: String] = [
            "Paris - Gare de Lyon - Hall 1 & 2":                   "Paris Lyon",
            "Paris Montparnasse 1 Et 2":            "Montparnasse",
            "Paris Montparnasse":                   "Montparnasse",
            "Paris Gare du Nord":                   "Paris Nord",
            "Paris Saint-Lazare":                   "St-Lazare",
            "Paris Est":                            "Paris Est",
            "Marseille-Saint-Charles":              "Marseille",
            "Marseille Saint-Charles":              "Marseille",
            "Lyon Part-Dieu":                       "Lyon",
            "Lyon Perrache":                        "Lyon",
            "Bordeaux Saint-Jean":                  "Bordeaux",
            "Toulouse Matabiau":                    "Toulouse",
            "Lille Flandres":                       "Lille",
            "Montpellier Saint-Roch":               "Montpellier",
            "Nice Ville":                           "Nice",
            "Aix-en-Provence TGV":                  "Aix TGV",
            "Valence TGV Rhône-Alpes Sud":          "Valence TGV",
            "Aéroport Charles De Gaulle 2 Tgv":     "CDG TGV",
            "Charles De Gaulle 2 Tgv":              "CDG TGV",
            "Strasbourg Ville":                     "Strasbourg",
            "Marne-La-Vallée Chessy":               "Marne La Vallée",
        ]
        if let short = exact[name] { return short }
        return name.count > 15 ? String(name.prefix(14)) + "…" : name
    }

    private func label(_ title: String, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol = symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            item.image = img
        }
        return item
    }

    /// Item d'information non interactif mais visuellement lisible.
    private func infoLabel(_ title: String, symbol: String? = nil) -> NSMenuItem {
        let item = label(title, symbol: symbol)
        item.target = self
        item.action = #selector(noop)
        item.isEnabled = true
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
        item.isEnabled = true
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

    // MARK: - Handlers

    @objc private func setArrivalStation(_ sender: NSMenuItem) {
        if let stopId = sender.representedObject as? String {
            UserDefaults.standard.set(stopId, forKey: "arrivalStationId")
            refresh()
        }
    }
    
    @objc private func toggleDemoMode() {
        MockTrainData.shared.isEnabled.toggle()
        if MockTrainData.shared.isEnabled {
            MockTrainData.shared.start()
        } else {
            MockTrainData.shared.stop()
        }
        refresh()
    }

    @objc private func openDemoControlPanel() {
        guard let url = URL(string: MockTrainData.shared.baseURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func noop() {
        // Intentionnellement vide.
    }

    @objc private func toggleBeforeArrivalNotification() {
        isBeforeArrivalNotificationEnabled.toggle()
        if !isBeforeArrivalNotificationEnabled {
            lastArrivalNotifiedStopId = nil
        }
        refresh()
    }

    @objc private func setBeforeArrivalNotificationLeadTime(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int,
              allowedNotificationLeadTimes.contains(minutes) else { return }
        beforeArrivalNotificationLeadTime = minutes
        lastArrivalNotifiedStopId = nil
        refresh()
    }

    @objc private func setNotificationTargetSelectedArrival() {
        arrivalNotificationTarget = .selectedArrival
        lastArrivalNotifiedStopId = nil
        refresh()
    }

    @objc private func setNotificationTargetNextStop() {
        arrivalNotificationTarget = .nextStop
        lastArrivalNotifiedStopId = nil
        refresh()
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

    private func asBool(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.intValue != 0 }
        if let s = value as? String {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "oui":
                return true
            case "false", "0", "no", "non":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private func progressBar(progress: Double, width: Int) -> String {
        let safeWidth = max(4, width)
        let clamped = max(0.0, min(1.0, progress))
        let cursorIndex = Int((clamped * Double(safeWidth - 1)).rounded())
        var chars = Array<Character>(repeating: "─", count: safeWidth)

        for i in 0..<safeWidth {
            if i < cursorIndex {
                chars[i] = "█"
            }
        }
        chars[cursorIndex] = "●"

        return "[" + String(chars) + "]"
    }

    private var isBeforeArrivalNotificationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: notifyBeforeArrivalEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: notifyBeforeArrivalEnabledKey) }
    }

    private var beforeArrivalNotificationLeadTime: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: notifyBeforeArrivalMinutesKey)
            return allowedNotificationLeadTimes.contains(value) ? value : 10
        }
        set {
            let safeValue = allowedNotificationLeadTimes.contains(newValue) ? newValue : 10
            UserDefaults.standard.set(safeValue, forKey: notifyBeforeArrivalMinutesKey)
        }
    }

    private var lastArrivalNotifiedStopId: String? {
        get { UserDefaults.standard.string(forKey: lastArrivalNotificationStopIdKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastArrivalNotificationStopIdKey) }
    }

    private var arrivalNotificationTarget: ArrivalNotificationTarget {
        get {
            guard let raw = UserDefaults.standard.string(forKey: notifyBeforeArrivalTargetKey),
                  let target = ArrivalNotificationTarget(rawValue: raw) else {
                return .selectedArrival
            }
            return target
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: notifyBeforeArrivalTargetKey)
        }
    }

    private func registerNotificationDefaults() {
        UserDefaults.standard.register(defaults: [
            notifyBeforeArrivalEnabledKey: true,
            notifyBeforeArrivalMinutesKey: 10,
            notifyBeforeArrivalTargetKey: ArrivalNotificationTarget.selectedArrival.rawValue
        ])
    }

    private func currentSSIDInfo() -> (ssid: String, status: String) {
        if let ssid = CWWiFiClient.shared().interface()?.ssid(), !ssid.isEmpty {
            return (ssid, "ok")
        }

        let auth = locationManager.authorizationStatus
        switch auth {
        case .notDetermined:
            return ("Inconnu", "location_not_determined")
        case .denied:
            return ("Inconnu", "location_denied")
        case .restricted:
            return ("Inconnu", "location_restricted")
        case .authorized, .authorizedAlways:
            if CWWiFiClient.shared().interface() == nil {
                return ("Inconnu", "wifi_interface_unavailable")
            }
            return ("Inconnu", "ssid_unavailable")
        @unknown default:
            return ("Inconnu", "unknown")
        }
    }

    private func requestSSIDAuthorizationIfNeeded() {
        guard locationManager.authorizationStatus == .notDetermined else { return }
        // La politique d'activation (.regular vs .accessory) est gérée dans main.swift
        // et AppDelegate selon le statut TCC au démarrage.
        locationManager.requestWhenInUseAuthorization()
    }

    private func notificationTargetStop(allStops: [[String: Any]],
                                        nextStopIndex: Int,
                                        isStoppedAtStation: Bool,
                                        arrivalStationIndex: Int) -> [String: Any]? {
        guard !allStops.isEmpty else { return nil }

        switch arrivalNotificationTarget {
        case .selectedArrival:
            return allStops.indices.contains(arrivalStationIndex) ? allStops[arrivalStationIndex] : nil
        case .nextStop:
            let index = isStoppedAtStation
                ? min(nextStopIndex + 1, allStops.count - 1)
                : nextStopIndex
            return allStops.indices.contains(index) ? allStops[index] : nil
        }
    }

    private func maybeNotifyBeforeArrival(stopId: String,
                                          stopLabel: String,
                                          minutesRemaining: Int,
                                          isStoppedAtStation: Bool) {
        guard isBeforeArrivalNotificationEnabled else { return }
        guard !isStoppedAtStation else { return }

        // Le train est arrivé ou a dépassé l'heure cible: on autorise les futures notifications.
        if minutesRemaining <= 0 {
            if lastArrivalNotifiedStopId == stopId {
                lastArrivalNotifiedStopId = nil
            }
            return
        }

        let leadTime = beforeArrivalNotificationLeadTime
        guard minutesRemaining <= leadTime else { return }
        guard lastArrivalNotifiedStopId != stopId else { return }

        let content = UNMutableNotificationContent()
        content.title = "Arrivée imminente"
        content.body = "Vous arrivez à \(stopLabel) dans environ \(minutesRemaining) min."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "arrival-\(stopId)", content: content, trigger: trigger)
        notificationCenter.add(request) { _ in }

        lastArrivalNotifiedStopId = stopId
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

extension MenuBarController: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        // Repasser en mode accessory (barre des menus, sans icône Dock) dans tous les cas,
        // que l'utilisateur ait accepté ou refusé.
        if NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
        if status == .authorized || status == .authorizedAlways {
            refresh()
        }
    }
}
