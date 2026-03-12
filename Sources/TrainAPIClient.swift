import Foundation

/// Appelle les endpoints de l'API WiFi SNCF en parallèle.
final class TrainAPIClient {
    private let gpsURL        = URL(string: "https://wifi.sncf/router/api/train/gps")!
    // L'endpoint s'appelle `progress` (ou `details`) selon les rames, on laisse les deux pour être sûr mais on priorisera progress.
    private let progressURL   = URL(string: "https://wifi.sncf/router/api/train/progress")!
    private let detailsURL    = URL(string: "https://wifi.sncf/router/api/train/details")!
    private let barURL        = URL(string: "https://wifi.sncf/router/api/bar/attendance")!
    private let statsURL      = URL(string: "https://wifi.sncf/router/api/connection/statistics")!
    private let statusURL     = URL(string: "https://wifi.sncf/router/api/connection/status")!

    private let timeout: TimeInterval = 5

    /// Récupère toutes les infos en parallèle, notifie sur le main thread.
    func fetchAll(completion: @escaping (
        _ gps: [String: Any]?,
        _ details: [String: Any]?, // Retourne `progress` ou `details`
        _ bar: [String: Any]?,
        _ stats: [String: Any]?,
        _ status: [String: Any]?
    ) -> Void) {
        let group = DispatchGroup()

        var gpsData: [String: Any]?
        var progressData: [String: Any]?
        var detailsData: [String: Any]?
        var barData: [String: Any]?
        var statsData: [String: Any]?
        var statusData: [String: Any]?

        group.enter()
        fetch(url: gpsURL) { gpsData = $0; group.leave() }

        group.enter()
        fetch(url: progressURL) { progressData = $0; group.leave() }

        group.enter()
        fetch(url: detailsURL) { detailsData = $0; group.leave() }

        group.enter()
        fetch(url: barURL) { barData = $0; group.leave() }

        group.enter()
        fetch(url: statsURL) { statsData = $0; group.leave() }

        group.enter()
        fetch(url: statusURL) { statusData = $0; group.leave() }

        group.notify(queue: .main) {
            completion(gpsData, progressData ?? detailsData, barData, statsData, statusData)
        }
    }

    private func fetch(url: URL, completion: @escaping ([String: Any]?) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("sncfwifi-macapp/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { completion(nil); return }
            completion(json)
        }.resume()
    }
}
