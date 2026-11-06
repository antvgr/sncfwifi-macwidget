import Foundation

/// WiFi Eurostar (transmanche et continental ex-Thalys) : portail Icomera « Internet Ombord ».
/// Aucune donnée de trajet : l'API PIS du portail répond `journey not found` là où elle a été
/// testée, donc ni desserte, ni retard, ni ETA — d'où un bloc position / réseau à la place.
final class EurostarDataSource: TrainDataSource {

    let descriptor = TrainProviderDescriptor(
        id: "eurostar",
        displayName: "Eurostar",
        ssids: ["eurostarwifi", "eurostar wifi", "eurostar", "eurostartrainswifi", "_eurostar_wifi", "thalysnet", "_thalysnet"],
        accentHex: 0x173D85,
        features: [.speed, .position, .uplink, .dataQuota],
        apiHost: "www.ombord.info",
        requiresPrivateAPIHost: true
    )

    private let client = EurostarAPIClient()

    func probe(completion: @escaping (Bool) -> Void) {
        client.probe(completion: completion)
    }

    func fetch(completion: @escaping (TrainSnapshot?) -> Void) {
        client.fetchAll { [weak self] snapshot in
            guard let self, let snapshot else {
                completion(nil)
                return
            }
            completion(self.makeSnapshot(snapshot))
        }
    }

    func makeSnapshot(_ snap: EurostarSnapshot) -> TrainSnapshot {
        var state = TrainViewState(
            provider: descriptor,
            // La plateforme Icomera n'expose aucun numéro commercial, seulement la rame.
            trainNumber: nil,
            headerSubtitle: snap.rameNumber.map { "Rame \($0)" } ?? snap.systemName,
            speedKmh: snap.speedKmh
        )

        if let used = snap.dataUsedMB, let limit = snap.dataLimitMB, limit > 0 {
            state.dataConsumedMB = used
            state.dataTotalMB = limit
            state.dataRemainingMB = max(0, limit - used)
            state.dataRatio = max(0, min(1, used / limit))
        }

        state.metrics = metrics(for: snap)
        return TrainSnapshot(viewState: state, badge: badge(for: snap), rawPayloads: snap.raw)
    }

    private func badge(for snap: EurostarSnapshot) -> StatusBadge {
        let text = snap.speedKmh > 0
            ? "\(descriptor.displayName) · \(snap.speedKmh) km/h"
            : "\(descriptor.displayName) · à l'arrêt"
        return StatusBadge(text: text, progress: nil)
    }

    private func metrics(for snap: EurostarSnapshot) -> [MetricRow] {
        var rows: [MetricRow] = []

        if let latitude = snap.latitude, let longitude = snap.longitude {
            let text = String(format: "%.4f° %@ · %.4f° %@",
                              abs(latitude), latitude >= 0 ? "N" : "S",
                              abs(longitude), longitude >= 0 ? "E" : "O")
            rows.append(MetricRow(id: "position", symbol: "location.fill", text: text))
        }
        if let altitude = snap.altitudeM {
            rows.append(MetricRow(id: "altitude",
                                  symbol: "arrow.up",
                                  text: "\(Int(altitude.rounded())) m d'altitude",
                                  span: .half))
        }
        // Le cap n'a pas de sens à l'arrêt : le GPS dérive.
        if let heading = snap.headingDeg, snap.speedKmh > 0 {
            rows.append(MetricRow(id: "heading",
                                  symbol: "location.north.fill",
                                  text: "Cap \(EurostarDataSource.cardinal(heading)) (\(Int(heading.rounded()))°)",
                                  span: .half))
        }
        if let uplink = uplinkText(snap) {
            rows.append(MetricRow(id: "uplink",
                                  symbol: "antenna.radiowaves.left.and.right",
                                  text: uplink))
        }
        if !snap.operators.isEmpty {
            let text = snap.operators
                .map { $0.links > 1 ? "\($0.name) ×\($0.links)" : $0.name }
                .joined(separator: " · ")
            rows.append(MetricRow(id: "operators", symbol: "simcard", text: text))
        }
        if let online = snap.devicesOnline {
            var text = "\(online) appareil\(online > 1 ? "s" : "") en ligne"
            if let total = snap.devicesTotal, total > online { text += " sur \(total)" }
            rows.append(MetricRow(id: "devices", symbol: "person.2.fill", text: text))
        }
        // Sans quota annoncé, la jauge de données n'est pas affichable : on montre la conso brute.
        if snap.dataLimitMB == nil, let used = snap.dataUsedMB {
            rows.append(MetricRow(id: "data",
                                  symbol: "arrow.up.arrow.down.circle",
                                  text: "\(DataVolume.label(used)) utilisés"))
        }
        if let mbps = snap.bandwidthDownMbps {
            rows.append(MetricRow(id: "bandwidth",
                                  symbol: "speedometer",
                                  text: String(format: "Débit max %.0f Mbit/s", mbps),
                                  span: .half))
        }
        if let text = EurostarDataSource.sessionLeftText(snap.sessionSecondsLeft) {
            rows.append(MetricRow(id: "session", symbol: "hourglass", text: text, span: .half))
        }

        var footnote = "Desserte et horaires non fournis par le WiFi Eurostar."
        if let satellites = snap.satellites {
            let label = satellites > 1 ? "\(satellites) satellites" : "\(satellites) satellite"
            footnote = "\(label) · desserte et horaires non fournis par le WiFi Eurostar."
        }
        rows.append(.footnote(footnote))

        return rows
    }

    /// « Reste 1 h 20 » / « Reste 45 min ». `nil` quand la plateforme n'impose aucune durée.
    private static func sessionLeftText(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let minutes = seconds / 60
        guard minutes >= 60 else { return "Reste \(max(1, minutes)) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest > 0 ? "Reste \(hours) h \(rest)" : "Reste \(hours) h"
    }

    /// « 4G · 5/5 liens · -35 dBm », ou « Hors ligne » si le routeur n'a plus de lien montant.
    private func uplinkText(_ snap: EurostarSnapshot) -> String? {
        if snap.isOnline == false && snap.uplinkLinksUp == 0 { return "Hors ligne" }

        var parts: [String] = []
        if let technology = snap.technologyLabel { parts.append(technology) }
        if snap.uplinkLinksTotal > 0 { parts.append("\(snap.uplinkLinksUp)/\(snap.uplinkLinksTotal) liens") }
        if let rssi = snap.uplinkRSSI { parts.append("\(rssi) dBm") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Cap en degrés → point cardinal français (16 secteurs, « O » pour ouest).
    private static func cardinal(_ degrees: Double) -> String {
        let names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                     "S", "SSO", "SO", "OSO", "O", "ONO", "NO", "NNO"]
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        return names[Int((positive / 22.5).rounded()) % names.count]
    }
}
