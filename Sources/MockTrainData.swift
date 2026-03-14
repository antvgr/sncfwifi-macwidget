import Foundation

/// Mode démo piloté par un serveur local (API mock configurable).
class MockTrainData {
    static let shared = MockTrainData()
    private let timeout: TimeInterval = 2
    private let baseURLKey = "demoServerBaseURL"
    
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "isDemoMode") }
        set { UserDefaults.standard.set(newValue, forKey: "isDemoMode") }
    }

    var baseURLString: String {
        get { UserDefaults.standard.string(forKey: baseURLKey) ?? "http://127.0.0.1:8787" }
        set { UserDefaults.standard.set(newValue, forKey: baseURLKey) }
    }

    private var baseURL: URL? {
        URL(string: baseURLString)
    }

    private init() {}

    func start() {
        NotificationCenter.default.post(name: NSNotification.Name("DemoDataDidUpdate"), object: nil)
    }

    func stop() {
        // Pas d'état à arrêter: la source est externe (serveur local).
    }

    func fetchAll(completion: @escaping (_ gps: [String: Any]?, _ details: [String: Any]?, _ bar: [String: Any]?, _ stats: [String: Any]?) -> Void) {
        guard let baseURL else {
            DispatchQueue.main.async { completion(nil, nil, nil, nil) }
            return
        }

        let group = DispatchGroup()
        var gpsData: [String: Any]?
        var detailsData: [String: Any]?
        var barData: [String: Any]?
        var statsData: [String: Any]?

        let endpoints: [(String, ([String: Any]?) -> Void)] = [
            ("/router/api/train/gps", { gpsData = $0 }),
            ("/router/api/train/progress", { detailsData = $0 }),
            ("/router/api/bar/attendance", { barData = $0 }),
            ("/router/api/connection/statistics", { statsData = $0 })
        ]

        for (path, setter) in endpoints {
            guard let url = URL(string: path, relativeTo: baseURL) else { continue }
            group.enter()
            fetch(url: url) {
                setter($0)
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(gpsData, detailsData, barData, statsData)
        }
    }

    private func fetch(url: URL, completion: @escaping ([String: Any]?) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("sncfwifi-macapp/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                completion(nil)
                return
            }
            completion(json)
        }.resume()
    }
}
