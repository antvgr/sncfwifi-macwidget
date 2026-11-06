import Foundation
import Combine

/// Modèle de vue exposé au panneau SwiftUI. Purement des données, aucune logique AppKit.

enum StopStatus {
    case passed
    case current
    case upcoming
}

struct StopRow: Identifiable {
    let id: String
    let label: String
    /// Heure théorique "HH:mm" (affichée barrée si retard).
    let theoricTime: String
    let realTime: String
    /// Heure d'arrivée réelle, pour les notifications avant arrivée.
    let arrivalDate: Date?
    let delayMin: Int
    let status: StopStatus
    /// Voie réelle, quand le réseau l'expose. Chaîne libre : « 4 », « 3/4 », « Fern 5 ».
    var platform: String?
    /// Voie initialement prévue, pour signaler un changement.
    var scheduledPlatform: String?

    /// Vrai quand la voie annoncée n'est plus celle prévue.
    var platformChanged: Bool {
        guard let platform, let scheduledPlatform, !platform.isEmpty, !scheduledPlatform.isEmpty
        else { return false }
        return platform != scheduledPlatform
    }
}

struct ArrivalOption: Identifiable {
    let id: String
    let label: String
}

/// Métrique libre affichée par le panneau. Permet à un réseau d'exposer ses spécificités
/// sans toucher aux vues.
struct MetricRow: Identifiable {
    /// `.half` = deux métriques sur la même ligne (altitude + cap).
    enum Span {
        case full
        case half
    }

    let id: String
    let symbol: String
    let text: String
    var span: Span = .full
    var isFootnote: Bool = false

    /// Petite ligne grise de bas de bloc (limites de l'API, qualité du point GPS…).
    static func footnote(_ text: String) -> MetricRow {
        MetricRow(id: "footnote", symbol: "", text: text, isFootnote: true)
    }
}

/// Carte du bar-restaurant, chargée à la demande et non à chaque cycle.
struct OnboardMenu {
    struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String?
        /// Prix déjà formaté (« 13,90 € »), nil si le réseau n'en annonce pas.
        let price: String?
        let available: Bool
    }

    struct Category: Identifiable {
        let id: String
        let name: String
        let items: [Item]
        var availableCount: Int { items.filter(\.available).count }
    }

    let categories: [Category]

    var itemCount: Int { categories.reduce(0) { $0 + $1.items.count } }
    var availableCount: Int { categories.reduce(0) { $0 + $1.availableCount } }
}

enum MenuState {
    case idle
    case loading
    case loaded(OnboardMenu)
    case unavailable
}

/// Vue affichée par le popover. Le panneau restaurant est un second écran, pas une fenêtre.
enum PanelRoute {
    case main
    case menu
}

/// Instantané de tout ce que le panneau affiche pour un train connecté.
struct TrainViewState {
    let provider: TrainProviderDescriptor

    /// Numéro commercial du train, quand le réseau l'expose. L'en-tête compose lui-même
    /// « TGV INOUI n° 6201 » ou « n° 6201 » selon qu'un logo de compagnie est présent.
    var trainNumber: String?
    /// Destination (SNCF) ou identifiant de rame (Eurostar), déjà mis en forme par la source.
    var headerSubtitle: String?

    var delayMin: Int = 0
    var delayCause: String = ""

    var stops: [StopRow] = []
    var globalProgress: Double = 0

    var speedKmh: Int = 0

    var wifiQuality: Int?      // 0…5
    var wifiDevices: Int?

    // Data en Mo
    var dataConsumedMB: Double?
    var dataTotalMB: Double?
    var dataRemainingMB: Double?
    var dataRatio: Double?     // 0…1
    var dataResetTime: String? // "HH:mm"

    var metrics: [MetricRow] = []

    var arrivalOptions: [ArrivalOption] = []
    var selectedArrivalId: String?

}

/// Mise en forme des volumes de données, partagée entre le panneau et la barre des menus.
///
/// Les deux plateformes n'ont pas les mêmes ordres de grandeur de quota (quelques dizaines de Mo
/// côté SNCF, 1 Go côté Eurostar), d'où la bascule automatique d'unité. Le séparateur décimal
/// suit la locale : virgule en français.
enum DataVolume {
    /// "16,9 Mo", "1,0 Go" — bascule en Go au-delà de 1000 Mo.
    static func label(_ megabytes: Double) -> String {
        if megabytes >= 1000 {
            return String(format: "%.1f Go", locale: .current, megabytes / 1000)
        }
        return String(format: "%.1f Mo", locale: .current, megabytes)
    }

    /// Variante compacte pour la barre des menus : pas de décimale en Mo ("983 Mo", "1,4 Go").
    static func compactLabel(_ megabytes: Double) -> String {
        if megabytes >= 1000 {
            return String(format: "%.1f Go", locale: .current, megabytes / 1000)
        }
        return String(format: "%.0f Mo", locale: .current, megabytes)
    }
}

enum PanelState {
    case loading
    case notConnected(demoMode: Bool)
    case connected(TrainViewState)
}

/// Source d'observation pour la vue SwiftUI. Le `MenuBarController` pousse l'état
/// et branche les closures d'action.
final class TrainStore: ObservableObject {
    @Published var state: PanelState = .loading

    @Published var lastRefreshDate: Date?
    @Published var route: PanelRoute = .main
    @Published var menu: MenuState = .idle
    /// Doit refléter le Timer du contrôleur.
    let refreshInterval: TimeInterval = 30

    var onRefresh: () -> Void = {}
    var onQuit: () -> Void = {}
    var onSelectArrival: (String) -> Void = { _ in }
    var onToggleDemo: () -> Void = {}
    /// Change le réseau simulé en mode démo (le serveur local sert les deux plateformes),
    /// désigné par l'identifiant de son descripteur.
    var onSetDemoOperator: (String) -> Void = { _ in }
    var onOpenDemoPanel: () -> Void = {}
    var onCopyJSON: () -> Void = {}
    var onOpenAbout: () -> Void = {}
    var onPromptTrainNumber: () -> Void = {}
    /// Ouvre le panneau restaurant, ce qui déclenche le chargement de la carte.
    var onOpenMenu: () -> Void = {}
    var onCloseMenu: () -> Void = {}
    /// Appelée quand un réglage de notification change (pour relancer un refresh).
    var onSettingsChanged: () -> Void = {}
}
