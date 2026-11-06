import AppKit
import SwiftUI
import QuotaCore

struct MainWindow: View {
    @Bindable var model: AppModel
    @State private var pendingDelete: AccountConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let logo = NSImage(named: "AppIcon") {
                    Image(nsImage: logo)
                        .resizable()
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(.windowTitle, language: model.stored.language))
                        .font(.title2.weight(.semibold))
                    Text(L10n.format(.windowSubtitle, UsageMath.defaultDailyLimit, language: model.stored.language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(refreshStamp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Stepper(
                    L10n.format(.refreshEvery, model.stored.refreshMinutes, language: model.stored.language),
                    value: Binding(
                        get: { model.stored.refreshMinutes },
                        set: { model.setRefreshMinutes($0) }
                    ),
                    in: 1...120
                )
                .frame(width: 190)
            }
            .padding()

            List {
                if let error = model.statusPublicationError {
                    Text(error).foregroundStyle(.red)
                }
                if let error = model.configurationLoadError {
                    Text(error).foregroundStyle(.red)
                } else if model.stored.accounts.isEmpty {
                    ContentUnavailableView(
                        L10n.text(.noAccountsTitle, language: model.stored.language),
                        systemImage: "cloud",
                        description: Text(L10n.text(.noAccountsDescription, language: model.stored.language))
                    )
                } else {
                    ForEach(model.snapshots) { snapshot in
                        AccountUsageRow(
                            snapshot: snapshot,
                            suggested: snapshot.config.id == model.suggestedAccountID,
                            language: model.stored.language
                        )
                        .contextMenu {
                            Button(L10n.text(.edit, language: model.stored.language)) { model.beginEdit(snapshot.config) }
                            Button(snapshot.config.enabled ? L10n.text(.disable, language: model.stored.language) : L10n.text(.enable, language: model.stored.language)) {
                                model.setEnabled(!snapshot.config.enabled, id: snapshot.config.id)
                            }
                            Button(L10n.text(.delete, language: model.stored.language), role: .destructive) {
                                pendingDelete = snapshot.config
                            }
                        }
                        .swipeActions {
                            Button(L10n.text(.delete, language: model.stored.language), role: .destructive) {
                                pendingDelete = snapshot.config
                            }
                            Button(L10n.text(.edit, language: model.stored.language)) { model.beginEdit(snapshot.config) }
                        }
                    }
                }
            }

            HStack {
                Button(L10n.text(.addAccount, language: model.stored.language)) { model.beginAdd() }
                Button(model.isRefreshing ? L10n.text(.refreshing, language: model.stored.language) : L10n.text(.refreshNow, language: model.stored.language)) {
                    Task { await model.refresh() }
                }
                .disabled(model.isRefreshing)
                Spacer()
                Toggle(
                    L10n.text(.showMenuBar, language: model.stored.language),
                    isOn: Binding(
                        get: { model.stored.showMenuBar },
                        set: { model.setShowMenuBar($0) }
                    )
                )
                .toggleStyle(.switch)
            }
            .padding()

            PreferenceBar(model: model)
                .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 620, minHeight: 460)
        .sheet(isPresented: Binding(
            get: { model.draft != nil },
            set: { if !$0 { model.draft = nil } }
        )) {
            if let draft = model.draft {
                AccountEditor(
                    draft: Binding(
                        get: { model.draft ?? draft },
                        set: { model.draft = $0 }
                    ),
                    language: model.stored.language,
                    onSave: { model.saveDraft() }
                )
            }
        }
        .confirmationDialog(
            L10n.format(.deleteTitle, pendingDelete?.name ?? L10n.text(.thisAccount, language: model.stored.language), language: model.stored.language),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text(.delete, language: model.stored.language), role: .destructive) {
                if let pendingDelete {
                    model.delete(pendingDelete.id)
                }
                pendingDelete = nil
            }
            Button(L10n.text(.cancel, language: model.stored.language), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(L10n.text(.deleteMessage, language: model.stored.language))
        }
        .alert(
            L10n.text(.alertTitle, language: model.stored.language),
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button(L10n.text(.ok, language: model.stored.language)) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .onAppear {
            model.start()
        }
    }

    private var refreshStamp: String {
        guard let date = model.lastRefreshedAt else {
            return L10n.text(.notRefreshedYet, language: model.stored.language)
        }
        return L10n.format(.lastRefreshed, RefreshStamp.string(from: date), language: model.stored.language)
    }
}

struct PreferenceBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack {
            Picker(L10n.text(.language, language: model.stored.language), selection: Binding(
                get: { model.stored.language },
                set: { model.setLanguage($0) }
            )) {
                Text(L10n.text(.followSystem, language: model.stored.language)).tag(AppLanguage.system)
                Text(L10n.text(.chinese, language: model.stored.language)).tag(AppLanguage.chinese)
                Text(L10n.text(.english, language: model.stored.language)).tag(AppLanguage.english)
            }
            .pickerStyle(.menu)
            .fixedSize()

            Picker(L10n.text(.appearance, language: model.stored.language), selection: Binding(
                get: { model.stored.appearance },
                set: { model.setAppearance($0) }
            )) {
                Text(L10n.text(.followSystem, language: model.stored.language)).tag(AppAppearance.system)
                Text(L10n.text(.light, language: model.stored.language)).tag(AppAppearance.light)
                Text(L10n.text(.dark, language: model.stored.language)).tag(AppAppearance.dark)
            }
            .pickerStyle(.menu)
            .fixedSize()

            Spacer()
            Text(AppVersion.label(language: model.stored.language))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct AccountEditor: View {
    @Binding var draft: AccountDraft
    var language: AppLanguage
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Field?

    private enum Field: Hashable {
        case name, accountID, token, limit, threshold
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.isNew ? L10n.text(.addAccount, language: language) : L10n.text(.editAccount, language: language))
                .font(.title3.weight(.semibold))

            Form {
                TextField(L10n.text(.name, language: language), text: $draft.name)
                    .focused($focused, equals: .name)
                TextField(L10n.text(.accountID, language: language), text: $draft.accountID)
                    .focused($focused, equals: .accountID)
                SecureField(draft.isNew ? L10n.text(.token, language: language) : L10n.text(.tokenUnchanged, language: language), text: $draft.token)
                    .focused($focused, equals: .token)
                TextField(L10n.text(.dailyLimit, language: language), value: $draft.dailyLimit, format: .number)
                    .focused($focused, equals: .limit)
                TextField(L10n.text(.switchPercent, language: language), value: $draft.switchPercent, format: .number)
                    .focused($focused, equals: .threshold)
                Toggle(L10n.text(.includeInSuggestions, language: language), isOn: $draft.enabled)
            }
            .formStyle(.grouped)
            .onAppear {
                AppActivation.becomeRegular()
                focused = .name
            }

            Text(L10n.text(.tokenHelp, language: language))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(L10n.text(.cancel, language: language)) { dismiss() }
                Button(L10n.text(.save, language: language)) { onSave() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
