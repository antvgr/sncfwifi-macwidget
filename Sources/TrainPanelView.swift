import AppKit
import SwiftUI
import Combine

/// Largeur fixe du panneau (style Centre de contrôle).
private let panelWidth: CGFloat = 300

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0)
    }
}

extension TrainProviderDescriptor {
    /// Couleur d'accent du panneau. Portée par le descripteur : aucune vue ne connaît le réseau.
    var accent: Color { Color(hex: accentHex) }

    /// Logo de marque déposé dans `Resources/Logos/` : `logo-<id>.png` (+ `@2x`), et
    /// `logo-<id>-dark.png` pour une variante sombre facultative. Les logos étant des marques
    /// déposées, leur absence est le cas normal : l'en-tête retombe sur l'icône générique.
    func logo(dark: Bool) -> NSImage? {
        if dark, let variant = NSImage(named: "logo-\(id)-dark") { return variant }
        return NSImage(named: "logo-\(id)")
    }
}

// MARK: - Vue racine

struct TrainPanelView: View {
    @EnvironmentObject var store: TrainStore

    var body: some View {
        VStack(spacing: 0) {
            switch store.route {
            case .menu:
                OnboardMenuView(tint: connectedState?.provider.accent ?? .secondary)
            case .main:
                switch store.state {
                case .loading:
                    LoadingView()
                case .notConnected(let demoMode):
                    NotConnectedView(demoMode: demoMode)
                case .connected(let state):
                    ConnectedView(state: state)
                }
            }
            Divider()
            FooterView()
        }
        .frame(width: panelWidth)
    }

    private var connectedState: TrainViewState? {
        if case let .connected(state) = store.state { return state }
        return nil
    }
}

// MARK: - États simples

private struct LoadingView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Chargement…")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

private struct NotConnectedView: View {
    @EnvironmentObject var store: TrainStore
    let demoMode: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: demoMode ? "network.slash" : "wifi.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(.secondary)

            if demoMode {
                Text("Serveur démo indisponible")
                    .font(.headline)
                Text("Démarre-le avec ./start_demo_server.sh")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Ouvrir le panneau démo") { store.onOpenDemoPanel() }
            } else {
                Text("Non connecté au WiFi d'un train")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("\(TrainProviders.knownNetworkNames.joined(separator: ", ")) — ou API du train indisponible")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 28)
    }
}

// MARK: - Contenu train connecté

private struct ConnectedView: View {
    let state: TrainViewState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HeaderView(state: state)

                if !state.stops.isEmpty {
                    Divider()
                    TimelineView(stops: state.stops, tint: state.provider.accent)
                }

                if !state.metrics.isEmpty {
                    Divider()
                    MetricsView(rows: state.metrics, tint: state.provider.accent)
                }

                if state.wifiQuality != nil || state.dataRatio != nil {
                    Divider()
                    if let quality = state.wifiQuality {
                        WifiView(quality: quality, devices: state.wifiDevices, tint: state.provider.accent)
                    }
                    if let ratio = state.dataRatio {
                        DataView(state: state, ratio: ratio)
                    }
                }

                RefreshStatusView()
                    .padding(.top, 2)
            }
            .padding(16)
        }
        .frame(maxHeight: 460)
    }
}

// MARK: - En-tête

private struct HeaderView: View {
    let state: TrainViewState

    @Environment(\.colorScheme) private var colorScheme

    /// Hauteur de rendu du logo, calée sur celle de l'icône `tram.fill` qu'il remplace.
    private let logoHeight: CGFloat = 20

    private var logo: NSImage? {
        state.provider.logo(dark: colorScheme == .dark)
    }

    /// Quand le logo porte déjà l'identité de la compagnie, seul le numéro de train subsiste —
    /// et Eurostar n'en expose aucun, l'en-tête se réduit alors au logo.
    private var title: String? {
        let number = state.trainNumber.flatMap { $0.isEmpty ? nil : $0 }
        guard logo == nil else { return number.map { "n° \($0)" } }
        let name = state.provider.displayName
        return number.map { "\(name) n° \($0)" } ?? name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                if let logo = logo {
                    Image(nsImage: logo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: logoHeight)
                        // Le nom disparaît du texte : on le conserve pour VoiceOver.
                        .accessibilityLabel(state.provider.displayName)
                } else {
                    Image(systemName: "tram.fill")
                        .font(.system(size: 18))
                        .foregroundColor(state.provider.accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    if let title = title {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    if let subtitle = state.headerSubtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if state.speedKmh > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "speedometer")
                            .foregroundColor(state.provider.accent)
                        Text("\(state.speedKmh) km/h")
                            .foregroundColor(.primary)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize()
                }
            }

            if state.delayMin > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(delayText)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11, weight: .medium))
            }
        }
    }

    private var delayText: String {
        state.delayCause.isEmpty
            ? "Retard +\(state.delayMin) min"
            : "Retard +\(state.delayMin) min · \(state.delayCause)"
    }
}

// MARK: - Métriques du réseau

/// Rend les `MetricRow` fournies par la source : un réseau expose ses spécificités
/// (position, cap, opérateurs mobiles…) sans qu'aucune vue ne le connaisse.
private struct MetricsView: View {
    let rows: [MetricRow]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(groups) { group in
                if group.isFootnote {
                    Text(group.rows.map { $0.text }.joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundColor(Color.secondary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 16) {
                        ForEach(group.rows) { row in
                            MetricPill(symbol: row.symbol, text: row.text, tint: tint)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private struct Group: Identifiable {
        let id: String
        let rows: [MetricRow]
        var isFootnote: Bool { rows.first?.isFootnote ?? false }
    }

    /// Deux métriques `.half` consécutives partagent une ligne.
    private var groups: [Group] {
        var groups: [Group] = []
        var pending: [MetricRow] = []

        func flush() {
            guard !pending.isEmpty else { return }
            groups.append(Group(id: pending[0].id, rows: pending))
            pending = []
        }

        for row in rows {
            if row.span == .half, !row.isFootnote {
                pending.append(row)
                if pending.count == 2 { flush() }
            } else {
                flush()
                groups.append(Group(id: row.id, rows: [row]))
            }
        }
        flush()
        return groups
    }
}

// MARK: - Timeline des arrêts

private struct TimelineView: View {
    let stops: [StopRow]
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                StopRowView(stop: stop,
                            tint: tint,
                            isFirst: index == 0,
                            isLast: index == stops.count - 1)
            }
        }
    }
}

private struct StopRowView: View {
    let stop: StopRow
    let tint: Color
    let isFirst: Bool
    let isLast: Bool

    private var dotColor: Color {
        stop.status == .upcoming ? .secondary : tint
    }

    private var symbol: String {
        switch stop.status {
        case .passed:   return "checkmark.circle.fill"
        case .current:  return "record.circle.fill"
        case .upcoming: return "circle"
        }
    }

    /// Voie annoncée. En cas de changement, la voie prévue est barrée et la nouvelle passe en
    /// orange — même traitement que les horaires retardés juste à côté.
    @ViewBuilder
    private var platformLabel: some View {
        if let platform = stop.platform, !platform.isEmpty {
            if stop.platformChanged, let scheduled = stop.scheduledPlatform {
                HStack(spacing: 3) {
                    Text("voie")
                        .foregroundColor(.secondary)
                    Text(scheduled)
                        .strikethrough()
                        .foregroundColor(.secondary)
                    Text(platform)
                        .foregroundColor(.orange)
                }
                .font(.system(size: 11, weight: .medium))
                .fixedSize()
            } else {
                Text("voie \(platform)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize()
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .padding(.top, isFirst ? 9 : 0)
                    .padding(.bottom, isLast ? 9 : 0)
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundColor(dotColor)
            }
            .frame(width: 18)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(stop.label)
                    .font(.system(size: 12, weight: stop.status == .current ? .semibold : .regular))
                    .foregroundColor(stop.status == .upcoming ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if stop.delayMin > 0 && !stop.theoricTime.isEmpty && stop.theoricTime != stop.realTime {
                    Text(stop.theoricTime)
                        .strikethrough()
                        .foregroundColor(.secondary)
                    Text(stop.realTime)
                        .foregroundColor(.orange)
                } else if !stop.realTime.isEmpty {
                    Text(stop.realTime)
                        .foregroundColor(.secondary)
                }
                platformLabel
            }
            .font(.system(size: 12))
            .padding(.bottom, isLast ? 0 : 12)
        }
    }
}

// MARK: - Qualité WiFi

private struct WifiView: View {
    let quality: Int
    let devices: Int?
    let tint: Color

    var body: some View {
        HStack(spacing: 16) {
            MetricPill(symbol: quality >= 3 ? "wifi" : "wifi.exclamationmark",
                       text: wifiText,
                       tint: quality < 3 ? .orange : tint)
            Spacer(minLength: 0)
        }
    }

    private var wifiText: String {
        guard let devices else { return "WiFi \(quality)/5" }
        return "WiFi \(quality)/5 · \(devices) pers."
    }
}

private struct MetricPill: View {
    let symbol: String
    let text: String
    var tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundColor(tint)
            Text(text).foregroundColor(.primary)
        }
        .font(.system(size: 12, weight: .medium))
    }
}

// MARK: - Consommation data

private struct DataView: View {
    let state: TrainViewState
    let ratio: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Données", systemImage: "arrow.up.arrow.down.circle")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int((ratio * 100).rounded())) %")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            ProgressView(value: min(max(ratio, 0), 1))
                .accentColor(ratio > 0.85 ? .red : state.provider.accent)
            if let consumed = state.dataConsumedMB, let total = state.dataTotalMB {
                Text(usageLine(consumed: consumed, total: total, reset: state.dataResetTime))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func usageLine(consumed: Double, total: Double, reset: String?) -> String {
        var text = "\(DataVolume.label(consumed)) / \(DataVolume.label(total)) utilisés"
        if let reset { text += " · reset \(reset)" }
        return text
    }
}

// MARK: - Indicateur discret d'actualisation

private struct RefreshStatusView: View {
    @EnvironmentObject var store: TrainStore
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()

    var body: some View {
        HStack {
            Spacer()
            if let text = statusText {
                Text(text)
                    .font(.system(size: 10))
                    .foregroundColor(Color.secondary.opacity(0.7))
            }
            Spacer()
        }
        .onReceive(ticker) { now = $0 }
    }

    private var statusText: String? {
        guard let last = store.lastRefreshDate else { return nil }
        let elapsed = now.timeIntervalSince(last)
        let remaining = max(0, Int((store.refreshInterval - elapsed).rounded()))
        return "Actualisé à \(RefreshStatusView.timeFormatter.string(from: last)) · prochaine dans \(remaining) s"
    }
}

// MARK: - Carte du bar-restaurant

/// Second écran du popover. La carte n'est chargée qu'à l'ouverture, jamais dans le cycle de
/// rafraîchissement : elle pèse ~90 Ko et ne change pas d'une minute à l'autre.
private struct OnboardMenuView: View {
    @EnvironmentObject var store: TrainStore
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                store.onCloseMenu()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .help("Retour")

            Text("Bar-restaurant")
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 4)
            if case let .loaded(menu) = store.menu {
                Text("\(menu.availableCount)/\(menu.itemCount)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch store.menu {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Chargement de la carte…")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)

        case .unavailable:
            VStack(spacing: 8) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(.secondary)
                Text("Carte indisponible")
                    .font(.headline)
                Text("Le service de commande à bord n'est pas actif.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 24)

        case .loaded(let menu):
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Libellés en allemand : c'est la seule langue que l'API expose.
                    ForEach(menu.categories) { category in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(category.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(tint)
                                Spacer()
                                Text("\(category.availableCount)/\(category.items.count)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            ForEach(category.items) { item in
                                itemRow(item)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 420)
        }
    }

    private func itemRow(_ item: OnboardMenu.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundColor(item.available ? .primary : .secondary)
                    .strikethrough(!item.available)
                if let detail = item.detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(Color.secondary.opacity(0.8))
                }
            }
            Spacer(minLength: 4)
            if item.available {
                if let price = item.price {
                    Text(price)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize()
                }
            } else {
                Text("épuisé")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.orange)
                    .fixedSize()
            }
        }
    }
}

// MARK: - Pied de page (actions + réglages + debug)

private struct FooterView: View {
    @EnvironmentObject var store: TrainStore

    @AppStorage("notifyBeforeArrivalEnabled") private var notifyEnabled = true
    @AppStorage("notifyBeforeArrivalMinutes") private var notifyMinutes = 10
    @AppStorage("notifyBeforeArrivalTarget") private var notifyTarget = "selectedArrival"
    @AppStorage("notifyPlatformChangeEnabled") private var notifyPlatform = true
    @AppStorage("isDemoMode") private var demoMode = false
    @AppStorage("demoOperator") private var demoProvider = "sncf"

    private let leadTimes = [5, 10, 15]

    var body: some View {
        HStack(spacing: 4) {
            footerButton("arrow.2.circlepath", help: "Actualiser") { store.onRefresh() }

            if showsMenuButton {
                footerButton("fork.knife", help: "Bar-restaurant") { store.onOpenMenu() }
            }

            settingsMenu
            debugMenu

            Spacer()

            footerButton("info.circle", help: "À propos") { store.onOpenAbout() }
            footerButton("power", help: "Quitter") { store.onQuit() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var connectedState: TrainViewState? {
        if case let .connected(state) = store.state { return state }
        return nil
    }

    /// L'icône n'apparaît que sur un réseau qui expose une carte.
    private var showsMenuButton: Bool {
        connectedState?.provider.features.contains(.onboardMenu) ?? false
    }

    /// Réglages d'arrivée inutiles sur un réseau sans desserte (Eurostar) : on les masque
    /// plutôt que d'afficher des options sans effet.
    private var showsArrivalSettings: Bool {
        connectedState?.provider.features.contains(.journey) ?? true
    }

    private var arrival: (options: [ArrivalOption], selectedId: String?)? {
        guard let state = connectedState, !state.arrivalOptions.isEmpty else { return nil }
        return (state.arrivalOptions, state.selectedArrivalId)
    }

    private var settingsMenu: some View {
        Menu {
            if let arrival = arrival {
                Menu("Gare d'arrivée") {
                    ForEach(arrival.options) { option in
                        Button {
                            store.onSelectArrival(option.id)
                        } label: {
                            checkLabel(option.label, on: option.id == arrival.selectedId)
                        }
                    }
                }
                Divider()
            }

            if connectedState?.provider.features.contains(.manualTrainNumber) == true {
                Button("Numéro de train…") { store.onPromptTrainNumber() }
                Divider()
            }

            if showsArrivalSettings {
                Button {
                    notifyEnabled.toggle()
                    store.onSettingsChanged()
                } label: {
                    checkLabel("Notification avant arrivée", on: notifyEnabled)
                }

                Menu("Délai de notification") {
                    ForEach(leadTimes, id: \.self) { minutes in
                        Button {
                            notifyMinutes = minutes
                            store.onSettingsChanged()
                        } label: {
                            checkLabel("\(minutes) min", on: notifyMinutes == minutes)
                        }
                    }
                }

                Menu("Type de notification") {
                    Button {
                        notifyTarget = "selectedArrival"
                        store.onSettingsChanged()
                    } label: {
                        checkLabel("Gare d'arrivée sélectionnée", on: notifyTarget == "selectedArrival")
                    }
                    Button {
                        notifyTarget = "nextStop"
                        store.onSettingsChanged()
                    } label: {
                        checkLabel("Prochaine gare", on: notifyTarget == "nextStop")
                    }
                }

                Button {
                    notifyPlatform.toggle()
                    store.onSettingsChanged()
                } label: {
                    checkLabel("Notifier un changement de voie", on: notifyPlatform)
                }
            } else {
                Text("Aucun réglage pour ce réseau")
            }
        } label: {
            Image(systemName: "gearshape.fill")
        }
        .menuStyle(BorderlessButtonMenuStyle())
        .fixedSize()
        .help("Réglages")
    }

    private var debugMenu: some View {
        Menu {
            Button {
                store.onToggleDemo()
            } label: {
                checkLabel("Mode Démo (serveur local)", on: demoMode)
            }
            if demoMode {
                Menu("Réseau simulé") {
                    ForEach(TrainProviders.all, id: \.descriptor.id) { source in
                        Button {
                            store.onSetDemoOperator(source.descriptor.id)
                        } label: {
                            checkLabel(source.descriptor.displayName, on: source.descriptor.id == demoProvider)
                        }
                    }
                }
            }
            Button("Ouvrir le panneau démo") { store.onOpenDemoPanel() }
            Divider()
            Button {
                store.onCopyJSON()
            } label: {
                Label("Copier le JSON", systemImage: "doc.on.doc")
            }
        } label: {
            Image(systemName: "ladybug.fill")
        }
        .menuStyle(BorderlessButtonMenuStyle())
        .fixedSize()
        .help("Debug")
    }

    @ViewBuilder
    private func checkLabel(_ title: String, on: Bool) -> some View {
        if on {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func footerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .help(help)
    }
}
