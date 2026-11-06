import Foundation

/// WiFi des TER / trains régionaux équipés par Nomad Digital (vu à bord d'un REMI Express,
/// Centre-Val de Loire). Le portail partage l'hôte `wifi.sncf` avec les TGV mais pas son API :
/// seul `/api/v1/connection/data-usage` répond en JSON, ni position ni desserte n'y figurent.
/// La qualité du signal passe par MQTT (`nde1.nomadrail.com:9001`), injoignable depuis le train.
final class NomadDataSource: TrainDataSource {

    let descriptor = TrainProviderDescriptor(
        id: "nomad",
        displayName: "WiFi Nomad",
        ssids: ["wifi_remi"],
        accentHex: 0x0F6E6E,
        features: [.dataQuota],
        apiHost: "wifi.sncf",
        requiresPrivateAPIHost: true
    )

    private let usageURL = URL(string: "https://wifi.sncf/api/v1/connection/data-usage")!
    private let timeout: TimeInterval = 5

    func probe(completion: @escaping (Bool) -> Void) {
        APIBody.fetch(url: usageURL, timeout: timeout) { json in
            completion(NomadDataSource.looksLikeUsage(json))
        }
    }

    func fetch(completion: @escaping (TrainSnapshot?) -> Void) {
        APIBody.fetch(url: usageURL, timeout: timeout) { [weak self] json in
            guard let self, let json, NomadDataSource.looksLikeUsage(json) else {
                completion(nil)
                return
            }
            completion(self.makeSnapshot(json))
        }
    }

    /// Le portail SNCF sert une page HTML pour tout chemin inconnu : seul le contenu tranche.
    static func looksLikeUsage(_ json: [String: Any]?) -> Bool {
        guard let json else { return false }
        return json["consumed_data"] != nil && json["quota"] != nil
    }

    func makeSnapshot(_ json: [String: Any]) -> TrainSnapshot {
        let used = APIValue.double(json["consumed_data"]) ?? 0
        let quota = APIValue.double(json["quota"]) ?? 0
        let remaining = APIValue.double(json["remaining_data"]) ?? max(0, quota - used)

        var state = TrainViewState(provider: descriptor,
                                   trainNumber: nil,
                                   headerSubtitle: nil)
        if quota > 0 {
            state.dataConsumedMB = used
            state.dataTotalMB = quota
            state.dataRemainingMB = remaining
            state.dataRatio = max(0, min(1, used / quota))
        }
        state.metrics = [.footnote("Trajet, position et horaires non fournis par ce WiFi.")]

        let text = quota > 0
            ? "\(descriptor.displayName) · \(DataVolume.label(remaining)) restants"
            : descriptor.displayName
        return TrainSnapshot(viewState: state,
                             badge: StatusBadge(text: text, progress: nil),
                             rawPayloads: ["data-usage": json])
    }
}
