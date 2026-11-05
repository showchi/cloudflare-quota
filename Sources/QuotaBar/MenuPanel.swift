import SwiftUI
import QuotaCore

struct MenuPanel: View {
    @Bindable var model: AppModel
    var onManage: () -> Void = {}
    var maximumHeight: CGFloat = 600

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text(.todayUsage, language: model.stored.language))
                    .font(.headline)
                Spacer()
                Text(L10n.format(.resetsRelative, model.resetsAt.formatted(.relative(presentation: .numeric)), language: model.stored.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.stored.accounts.isEmpty || model.statusPublicationError != nil {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) { accountContent }
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

    private var accountListHeight: CGFloat {
        MenuPanelLayout.accountListHeight(maximumPanelHeight: maximumHeight)
    }
}

enum MenuPanelLayout {
    static let visibleAccounts = 8
    static let rowHeight: CGFloat = 52
    static let rowSpacing: CGFloat = 10
    /// Header, warning, buttons, padding, and the gaps between them.
    static let chromeHeight: CGFloat = 132

    static var accountListHeight: CGFloat {
        CGFloat(visibleAccounts) * rowHeight + CGFloat(visibleAccounts - 1) * rowSpacing
    }

    static func accountListHeight(maximumPanelHeight: CGFloat) -> CGFloat {
        min(accountListHeight, max(1, maximumPanelHeight - chromeHeight))
    }
}

struct AccountUsageRow: View {
    var snapshot: AccountSnapshot
    var suggested: Bool
    var language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(snapshot.config.name)
                    .font(.body.weight(.semibold))
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
            }
            if snapshot.usage != nil {
                ProgressView(value: min(ratio, 1))
                    .tint(tone)
            }
            if let error = snapshot.usage?.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let scripts = snapshot.usage?.scripts, !scripts.isEmpty {
                Text(scripts.prefix(3).map { "\($0.scriptName) \(formatted($0.requests))" }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var ratio: Double {
        UsageMath.ratio(requests: snapshot.usage?.requests ?? 0, limit: snapshot.config.dailyLimit)
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
