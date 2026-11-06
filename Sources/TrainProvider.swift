import Foundation

/// Ce qu'une API embarquée sait fournir. Pilote la forme du panneau, l'éligibilité aux
/// notifications d'arrivée, et le tableau du README.
struct TrainProviderFeatures: OptionSet {
    let rawValue: Int

    static let journey       = TrainProviderFeatures(rawValue: 1 << 0)
    static let speed         = TrainProviderFeatures(rawValue: 1 << 1)
    static let position      = TrainProviderFeatures(rawValue: 1 << 2)
    static let uplink        = TrainProviderFeatures(rawValue: 1 << 3)
    static let dataQuota     = TrainProviderFeatures(rawValue: 1 << 4)
    static let wifiQuality   = TrainProviderFeatures(rawValue: 1 << 5)
    /// Carte du bar-restaurant : ouvre le panneau restaurant du popover.
    static let onboardMenu   = TrainProviderFeatures(rawValue: 1 << 6)
    /// Le portail n'annonce pas le numéro de train : l'utilisateur le saisit dans les réglages.
    static let manualTrainNumber = TrainProviderFeatures(rawValue: 1 << 7)
}

/// Fiche d'identité d'un réseau : tout ce qui ne demande aucun appel réseau.
struct TrainProviderDescriptor {
    let id: String
    let displayName: String
    /// SSID reconnus, en minuscules (la casse varie d'une rame à l'autre).
    let ssids: Set<String>
    let accentHex: UInt32
    let features: TrainProviderFeatures
    let apiHost: String
    /// N'accepter l'API que si `apiHost` résout vers une adresse privée. À bord,
    /// `ombord.info` pointe sur le routeur du train ; sans ce contrôle, une API joignable
    /// depuis l'internet public afficherait un train fantôme.
    var requiresPrivateAPIHost: Bool = false
}

/// Ce dont les notifications avant arrivée ont besoin, quel que soit le réseau.
struct JourneyContext {
    let nextStopIndex: Int
    let selectedArrivalIndex: Int
    let isStoppedAtStation: Bool
}

/// Contenu de la pastille. Recalculable localement : le `clockTimer` rafraîchit le décompte
/// toutes les 10 s sans rappeler l'API.
struct StatusBadge {
    /// Texte affiché en l'absence de décompte — « Eurostar · 297 km/h », « Milano », « inOui ».
    var text: String
    /// Décompte, quand une heure d'arrivée est connue.
    var destination: String?
    var arrivalDate: Date?
    var stoppedStation: String?
    /// nil = pas de jauge dessinée.
    var progress: Double?
    var delayMin: Int = 0
    var delayCause: String = ""

    func title(now: Date = Date()) -> String {
        if let stoppedStation, !stoppedStation.isEmpty { return "En gare de \(stoppedStation)" }
        guard let arrivalDate, arrivalDate > now else { return text }
        let remaining = StatusBadge.duration(from: now, to: arrivalDate)
        guard let destination, !destination.isEmpty else { return remaining }
        return "\(destination) · \(remaining)"
    }

    var delayTitle: String? {
        guard delayMin > 0 else { return nil }
        return delayCause.isEmpty ? "⚠ +\(delayMin)min" : "⚠ +\(delayMin)min · \(delayCause)"
    }

    private static func duration(from now: Date, to date: Date) -> String {
        let minutes = Int(date.timeIntervalSince(now) / 60)
        guard minutes >= 60 else { return "\(minutes)min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest > 0 ? "\(hours)h\(String(format: "%02d", rest))" : "\(hours)h"
    }
}

/// Ce qu'une source rend au contrôleur.
struct TrainSnapshot {
    var viewState: TrainViewState
    var badge: StatusBadge
    /// Payloads bruts par endpoint, pour « Copier le JSON ».
    var rawPayloads: [String: Any] = [:]
    /// nil quand le réseau n'expose pas de desserte (pas de notification d'arrivée).
    var journey: JourneyContext?
}

/// Un réseau embarqué pris en charge. Une implémentation = un réseau.
protocol TrainDataSource: AnyObject {
    var descriptor: TrainProviderDescriptor { get }
    /// Un seul appel : « suis-je à bord de ce réseau ? »
    func probe(completion: @escaping (Bool) -> Void)
    /// nil = API injoignable.
    func fetch(completion: @escaping (TrainSnapshot?) -> Void)
    /// Carte du bar-restaurant, chargée à l'ouverture du panneau et non à chaque cycle.
    /// `nil` = indisponible. Un réseau sans carte n'a rien à implémenter.
    func fetchMenu(completion: @escaping (OnboardMenu?) -> Void)
}

extension TrainDataSource {
    func fetchMenu(completion: @escaping (OnboardMenu?) -> Void) {
        completion(nil)
    }

    /// Sonde utilisée par la détection : contrôle d'hôte privé si le réseau l'exige,
    /// puis appel API. Notifie sur le main thread.
    func probeOnboard(completion: @escaping (Bool) -> Void) {
        guard descriptor.requiresPrivateAPIHost else {
            probe(completion: completion)
            return
        }
        let host = descriptor.apiHost
        DispatchQueue.global(qos: .utility).async {
            let onboard = TrainProviders.hostLooksOnboard(host)
            TrainProviders.recordHostCheck(host: host, onboard: onboard)
            guard onboard else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            self.probe(completion: completion)
        }
    }
}

enum TrainProviders {

    // ⬇️ AJOUTER UN RÉSEAU ICI (et dans build.sh). L'ordre ne sert que de départage. ⬇️
    static let all: [TrainDataSource] = [
        SNCFDataSource(),
        EurostarDataSource(),
        ICEDataSource(),
        LyriaDataSource(),
        NomadDataSource()
    ]

    static func source(forSSID ssid: String) -> TrainDataSource? {
        let key = ssid.lowercased()
        return all.first { $0.descriptor.ssids.contains(key) }
    }

    static func source(id: String) -> TrainDataSource? {
        all.first { $0.descriptor.id == id }
    }

    /// Réseau rejoué par le serveur démo (voir `scripts/demo_server.py`), choisi dans
    /// **Debug → Réseau simulé** : le serveur sert les deux plateformes en parallèle.
    static var demoSource: TrainDataSource? {
        source(id: MockTrainData.shared.demoProviderId) ?? all.first
    }

    /// Tous les SSID reconnus, pour l'écran « non connecté ».
    static var knownNetworkNames: [String] {
        all.map { $0.descriptor.displayName }
    }

    // MARK: - Contrôle « l'hôte est-il celui du train ? »

    /// Résultat des dernières résolutions, repris dans le dump debug.
    private(set) static var hostChecks: [String: Bool] = [:]

    static func recordHostCheck(host: String, onboard: Bool) {
        DispatchQueue.main.async { hostChecks[host] = onboard }
    }

    /// `getaddrinfo` bloque : à appeler hors du main thread.
    static func hostLooksOnboard(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let list else { return false }
        defer { freeaddrinfo(list) }

        var node: UnsafeMutablePointer<addrinfo>? = list
        while let current = node {
            if let sockaddr = current.pointee.ai_addr,
               sockaddr.pointee.sa_family == sa_family_t(AF_INET) {
                let address = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                if isPrivateIPv4(address) { return true }
            }
            node = current.pointee.ai_next
        }
        return false
    }

    private static func isPrivateIPv4(_ address: UInt32) -> Bool {
        let first = UInt8(truncatingIfNeeded: address >> 24)
        let second = UInt8(truncatingIfNeeded: address >> 16)
        switch first {
        case 10:  return true
        case 172: return (16...31).contains(second)
        case 192: return second == 168
        case 100: return (64...127).contains(second)  // CGNAT
        default:  return false
        }
    }
}
