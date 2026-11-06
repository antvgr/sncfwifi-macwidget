import Foundation

/// WiFi des TER / trains régionaux équipés par Nomad Digital (vu à bord d'un REMI Express,
/// Centre-Val de Loire). Le portail partage l'hôte `wifi.sncf` avec les TGV mais pas son API :
/// seul `/api/v1/connection/data-usage` répond en JSON, sans trajet ni position.
/// La desserte vient donc de tchoo.net, à partir d'un numéro de train saisi par l'utilisateur.
/// La qualité du signal passe par MQTT (`nde1.nomadrail.com:9001`), injoignable depuis le train.
final class NomadDataSource: TrainDataSource {

    static let trainNumberKey = "nomadTrainNumber"

    let descriptor = TrainProviderDescriptor(
        id: "nomad",
        displayName: "WiFi Nomad",
        ssids: ["wifi_remi"],
        accentHex: 0x0F6E6E,
        features: [.journey, .dataQuota, .manualTrainNumber],
        apiHost: "wifi.sncf",
        requiresPrivateAPIHost: true
    )

    private let usageURL = URL(string: "https://wifi.sncf/api/v1/connection/data-usage")!
    private let timeout: TimeInterval = 5

    /// Un arrêt commercial. `arrival` et `departure` sont théoriques : tchoo.net ne publie pas de
    /// temps réel.
    struct Stop {
        let uic: String
        let name: String
        let arrival: Date
        let departure: Date
        let km: Double
    }

    /// Point du tracé horodaté (arrêts commerciaux et points de passage), pour estimer la position.
    private struct Waypoint {
        let arrival: Date
        let departure: Date
        let km: Double
    }

    private struct Trip {
        let number: String
        let stops: [Stop]
        let waypoints: [Waypoint]
        let raw: [String: Any]
    }

    private let lock = NSLock()
    private var trip: Trip?
    private var lastTripAttempt = Date.distantPast

    func probe(completion: @escaping (Bool) -> Void) {
        APIBody.fetch(url: usageURL, timeout: timeout) { json in
            completion(NomadDataSource.looksLikeUsage(json))
        }
    }

    func fetch(completion: @escaping (TrainSnapshot?) -> Void) {
        let number = UserDefaults.standard.string(forKey: NomadDataSource.trainNumberKey)
        let group = DispatchGroup()
        var usage: [String: Any]?

        group.enter()
        APIBody.fetch(url: usageURL, timeout: timeout) { usage = $0; group.leave() }

        if let number { group.enter(); loadTrip(number: number) { group.leave() } }

        group.notify(queue: .global(qos: .utility)) { [weak self] in
            guard let self, let usage, NomadDataSource.looksLikeUsage(usage) else {
                completion(nil)
                return
            }
            self.lock.lock()
            let current = self.trip?.number == number ? self.trip : nil
            self.lock.unlock()
            completion(self.makeSnapshot(usage: usage, trip: current, requestedNumber: number))
        }
    }

    /// Le portail SNCF sert une page HTML pour tout chemin inconnu : seul le contenu tranche.
    static func looksLikeUsage(_ json: [String: Any]?) -> Bool {
        guard let json else { return false }
        return json["consumed_data"] != nil && json["quota"] != nil
    }

    // MARK: - Desserte (tchoo.net)

    /// La réponse pèse ~35 Ko à cause du tracé : on la garde pour toute la durée du trajet.
    /// Après un échec, on attend une minute plutôt que de rappeler à chaque cycle.
    private func loadTrip(number: String, completion: @escaping () -> Void) {
        lock.lock()
        let cached = trip?.number == number
        let recentlyTried = Date().timeIntervalSince(lastTripAttempt) < 60
        if !cached && !recentlyTried { lastTripAttempt = Date() }
        lock.unlock()

        guard !cached, !recentlyTried,
              let url = URL(string: "https://api.tchoo.net/api/carto.php?action=train&numero=\(number)")
        else { return completion() }

        APIBody.fetch(url: url, timeout: 10) { [weak self] json in
            if let self, let json, let parsed = NomadDataSource.parseTrip(json, number: number) {
                self.lock.lock()
                self.trip = parsed
                self.lock.unlock()
            }
            completion()
        }
    }

    private static func parseTrip(_ json: [String: Any], number: String) -> Trip? {
        guard let features = json["features"] as? [[String: Any]] else { return nil }

        var day: String?
        var rows: [[String: Any]] = []
        for feature in features {
            guard let props = feature["properties"] as? [String: Any] else { continue }
            if let date = props["date"] as? String { day = date }
            if props["uic"] != nil { rows.append(props) }
        }
        guard let day, rows.count > 1 else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = TimeZone(identifier: "Europe/Paris")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        // Les heures sont sans date : un train qui passe minuit repasse sous l'heure précédente.
        var midnightShift: TimeInterval = 0
        var previous = Date.distantPast
        func date(_ text: Any?) -> Date? {
            guard let text = text as? String, var value = formatter.date(from: "\(day) \(text)")
            else { return nil }
            value.addTimeInterval(midnightShift)
            if value < previous.addingTimeInterval(-3600) {
                midnightShift += 86400
                value.addTimeInterval(86400)
            }
            previous = max(previous, value)
            return value
        }

        var stops: [Stop] = []
        var waypoints: [Waypoint] = []
        for row in rows.sorted(by: { APIValue.int($0["etape"]) < APIValue.int($1["etape"]) }) {
            guard let arrival = date(row["debut"]), let departure = date(row["fin"]) else { continue }
            let km = APIValue.double(row["offset"]) ?? APIValue.double(row["pk"]) ?? 0
            waypoints.append(Waypoint(arrival: arrival, departure: departure, km: km))

            // `arret` distingue les arrêts commerciaux des simples points de passage.
            if APIValue.int(row["arret"]) == 1, let uic = row["uic"] as? String,
               let name = row["localite"] as? String {
                stops.append(Stop(uic: uic, name: name, arrival: arrival, departure: departure, km: km))
            }
        }
        // « Paris Austerlitz » et « Paris Austerlitz RER » portent le même horaire : on ne garde
        // que l'arrêt commercial.
        guard stops.count > 1 else { return nil }
        return Trip(number: number, stops: stops, waypoints: waypoints,
                    raw: ["train": number, "stops": stops.map { $0.name }])
    }

    // MARK: - Instantané

    private func makeSnapshot(usage: [String: Any], trip: Trip?, requestedNumber: String?,
                      now: Date = Date()) -> TrainSnapshot {
        let used = APIValue.double(usage["consumed_data"]) ?? 0
        let quota = APIValue.double(usage["quota"]) ?? 0
        let remaining = APIValue.double(usage["remaining_data"]) ?? max(0, quota - used)

        var state = TrainViewState(provider: descriptor, trainNumber: requestedNumber, headerSubtitle: nil)
        if quota > 0 {
            state.dataConsumedMB = used
            state.dataTotalMB = quota
            state.dataRemainingMB = remaining
            state.dataRatio = max(0, min(1, used / quota))
        }

        var raw: [String: Any] = ["data-usage": usage]
        guard let trip else {
            state.metrics = [.footnote(requestedNumber == nil
                ? "Saisis le numéro de train (réglages) pour afficher la desserte."
                : "Desserte du train \(requestedNumber ?? "") introuvable.")]
            let text = quota > 0
                ? "\(descriptor.displayName) · \(DataVolume.label(remaining)) restants"
                : descriptor.displayName
            return TrainSnapshot(viewState: state,
                                 badge: StatusBadge(text: text, progress: nil),
                                 rawPayloads: raw)
        }
        raw["trip"] = trip.raw

        let stoppedIndex = trip.stops.firstIndex { $0.arrival <= now && now <= $0.departure
            && $0.departure > $0.arrival }
        let nextStopIndex = stoppedIndex
            ?? trip.stops.firstIndex { $0.arrival > now }
            ?? trip.stops.count - 1
        let progress = NomadDataSource.progress(trip, now: now)

        let stops = trip.stops.enumerated().map { index, stop -> StopRow in
            let time = APIValue.time(stop.arrival)
            return StopRow(
                id: stop.uic,
                label: stop.name,
                theoricTime: time,
                realTime: time,
                arrivalDate: stop.arrival,
                delayMin: 0,
                status: index < nextStopIndex ? .passed : (index == nextStopIndex ? .current : .upcoming)
            )
        }

        var arrivalIndex = stops.count - 1
        if let savedId = UserDefaults.standard.string(forKey: "arrivalStationId"),
           let index = stops.firstIndex(where: { $0.id == savedId || $0.label == savedId }),
           index >= nextStopIndex {
            arrivalIndex = index
        }
        let arrivalStop = stops[arrivalIndex]

        state.stops = stops
        state.globalProgress = progress
        state.headerSubtitle = "→ \(arrivalStop.label)"
        state.arrivalOptions = stops.map { ArrivalOption(id: $0.id, label: $0.label) }
        state.selectedArrivalId = arrivalStop.id
        state.metrics = [.footnote("Horaires théoriques (tchoo.net) : position estimée, sans retard en direct.")]

        let short = LyriaDataSource.shortStationName(arrivalStop.label)
        let badge = StatusBadge(
            text: short,
            destination: short,
            arrivalDate: arrivalStop.arrivalDate,
            stoppedStation: stoppedIndex.map { LyriaDataSource.shortStationName(stops[$0].label) },
            progress: progress
        )
        let journey = JourneyContext(nextStopIndex: nextStopIndex,
                                     selectedArrivalIndex: arrivalIndex,
                                     isStoppedAtStation: stoppedIndex != nil)
        return TrainSnapshot(viewState: state, badge: badge, rawPayloads: raw, journey: journey)
    }

    /// Avancement 0…1 en kilomètres, interpolé sur l'horaire entre deux points du tracé :
    /// les points de passage évitent de traiter comme homogène un segment entre deux gares.
    private static func progress(_ trip: Trip, now: Date) -> Double {
        guard let first = trip.waypoints.first, let last = trip.waypoints.last,
              last.km > first.km else { return 0 }
        let total = last.km - first.km
        if now <= first.departure { return 0 }
        if now >= last.arrival { return 1 }

        for (from, to) in zip(trip.waypoints, trip.waypoints.dropFirst()) {
            if now >= from.arrival && now <= from.departure { return (from.km - first.km) / total }
            guard now > from.departure, now < to.arrival else { continue }
            let span = to.arrival.timeIntervalSince(from.departure)
            let ratio = span > 0 ? now.timeIntervalSince(from.departure) / span : 0
            return (from.km + (to.km - from.km) * ratio - first.km) / total
        }
        return 0
    }
}
