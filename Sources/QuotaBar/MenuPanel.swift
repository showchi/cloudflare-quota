import SwiftUI
import QuotaCore

struct MenuPanel: View {
    @Bindable var model: AppModel
    var onManage: () -> Void = {}
    var maximumHeight: CGFloat = 600
    var onLayoutInvalid: () -> Void = {}
    @State private var measuredContentHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text(.todayUsage, language: model.stored.language))
                    .font(.headline)
                Spacer()
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    VStack(alignment: .trailing, spacing: 2) {
                        if let relative = RefreshStamp.relative(from: model.lastRefreshedAt, to: context.date) {
                            Text(L10n.format(.lastRefreshed, relative, language: model.stored.language))
                        } else {
                            Text(L10n.text(.notRefreshedYet, language: model.stored.language))
                        }
                        Text(L10n.format(.resetsRelative, model.resetsAt.formatted(.relative(presentation: .numeric)), language: model.stored.language))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !model.stored.accounts.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) { accountContent }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            guard height != measuredContentHeight else { return }
                            measuredContentHeight = height
                            onLayoutInvalid()
                        }
                }
                .frame(height: accountListHeight)
            } else {
                accountContent
            }

            Text(L10n.text(.sampledWarning, language: model.stored.language))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Button(model.isRefreshing ? L10n.text(.refreshing, language: model.stored.language) : L10n.text(.refresh, language: model.stored.language)) {
                    Task { await model.refresh() }
                }
                .disabled(model.isRefreshing)
                Button(L10n.text(.manageAccounts, language: model.stored.language)) {
                    onManage()
                }
                Spacer()
                Button(L10n.text(.quit, language: model.stored.language)) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 340)
        .frame(maxHeight: maximumHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var accountContent: some View {
        if let error = model.statusPublicationError {
            Text(error).font(.callout).foregroundStyle(.red)
        }
        if let error = model.configurationLoadError {
            Text(error).font(.callout).foregroundStyle(.red)
        } else if model.stored.accounts.isEmpty {
            Text(L10n.text(.noAccountsMenu, language: model.stored.language))
                .font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(model.snapshots) { snapshot in
                AccountUsageRow(snapshot: snapshot, suggested: snapshot.config.id == model.suggestedAccountID, language: model.stored.language)
            }
        }
    }

    /// Measured content height, capped only by the screen so tall multi-script
    /// rows stay fully visible; the seed covers the first layout pass.
    private var accountListHeight: CGFloat {
        let cap = MenuPanelLayout.listHeightCap(maximumPanelHeight: maximumHeight)
        guard let measured = measuredContentHeight, measured > 0 else {
            return MenuPanelLayout.seedHeight(accountCount: model.stored.accounts.count)
        }
        return min(measured, cap)
    }
}

@MainActor
enum RefreshStamp {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = .autoupdatingCurrent
        return formatter
    }()

    /// A relative age such as "3 minutes ago"; the caller's timeline recomputes it.
    static func relative(from date: Date?, to now: Date) -> String? {
        guard let date else { return nil }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }
}

enum MenuPanelLayout {
    static let visibleAccounts = 8
    static let rowHeight: CGFloat = 52
    static let rowSpacing: CGFloat = 10
    /// Header, warning, buttons, padding, and the gaps between them.
    static let chromeHeight: CGFloat = 132

    /// Seeds the first layout before the content height is measured. Row heights
    /// vary with the script breakdown, so this never acts as a limit.
    static func seedHeight(accountCount: Int) -> CGFloat {
        let rows = CGFloat(max(1, min(accountCount, visibleAccounts)))
        return rows * rowHeight + (rows - 1) * rowSpacing
    }

    /// The list may use all the screen height above the chrome; only overflow scrolls.
    static func listHeightCap(maximumPanelHeight: CGFloat) -> CGFloat {
        max(1, maximumPanelHeight - chromeHeight)
    }
}

struct AccountUsageRow: View {
    var snapshot: AccountSnapshot
    var suggested: Bool
    var language: AppLanguage
    var showsActions = false
    var onEdit: () -> Void = {}
    var onToggleEnabled: () -> Void = {}
    var onDelete: () -> Void = {}
    @State private var showsAllScripts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(snapshot.config.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if suggested {
                    Text(L10n.text(.suggested, language: language))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.18), in: Capsule())
                }
                if !snapshot.config.enabled {
                    Text(L10n.text(.disabled, language: language))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(headline)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(tone)
                if showsActions {
                    actionsMenu
                }
            }
            if snapshot.usage != nil {
                progressBar
            }
            if let error = snapshot.usage?.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let scripts = snapshot.usage?.scripts, !scripts.isEmpty {
                scriptBreakdown(scripts)
            }
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button(L10n.text(.edit, language: language)) { onEdit() }
            Button(snapshot.config.enabled ? L10n.text(.disable, language: language) : L10n.text(.enable, language: language)) { onToggleEnabled() }
            Button(L10n.text(.delete, language: language), role: .destructive) { onDelete() }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L10n.text(.editAccount, language: language))
    }

    @ViewBuilder
    private func scriptBreakdown(_ scripts: [ScriptUsage]) -> some View {
        let visible = showsAllScripts ? scripts : Array(scripts.prefix(3))
        Button {
            showsAllScripts.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(visible.indices, id: \.self) { index in
                    Text("\(visible[index].scriptName) \(formatted(visible[index].requests))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !showsAllScripts, scripts.count > visible.count {
                    Text(L10n.format(.moreScripts, scripts.count - visible.count, language: language))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var ratio: Double {
        UsageMath.ratio(requests: snapshot.usage?.requests ?? 0, limit: snapshot.config.dailyLimit)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(barTone)
                    .frame(width: max(0, geo.size.width * min(ratio, 1)))
            }
        }
        .frame(height: 6)
    }

    private var barTone: Color {
        tone == .primary ? .blue : tone
    }

    private var headline: String {
        guard snapshot.config.enabled else { return "—" }
        guard snapshot.usage != nil else { return L10n.text(.pending, language: language) }
        guard snapshot.usage?.error == nil else { return L10n.text(.failed, language: language) }
        let requests = snapshot.usage?.requests ?? 0
        let percent = Int((ratio * 100).rounded())
        return "\(formatted(requests)) / \(formatted(snapshot.config.dailyLimit)) · \(percent)%"
    }

    private var tone: Color {
        if snapshot.usage?.error != nil { return .red }
        if ratio >= snapshot.config.switchThreshold { return .red }
        if ratio >= snapshot.config.switchThreshold * 0.8 { return .orange }
        return .primary
    }

    private func formatted(_ value: Int) -> String {
        Self.number.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let number: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
