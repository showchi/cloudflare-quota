import Foundation

public enum L10n {
    public enum Key: String, Sendable {
        case refreshIntervalInvalid
        case duplicateAccountID
        case invalidAccountFields
        case recoveryFailed
        case invalidResponse
        case httpFailed
        case emptyAccountList
        case incompleteUsage
        case multipleAccounts
        case apiFailed
        case graphqlFailed
        case messageSeparator
        case missingToken
        case nameRequired
        case dailyLimitInvalid
        case thresholdInvalid
        case tokenRequired
        case configurationNotSaved
        case tokenCleanupFailed
        case statusNotWritten
        case statusInvalidationFailed
        case configurationUnreadable
        case todayUsage
        case resetsRelative
        case lastRefreshed
        case notRefreshedYet
        case noAccountsMenu
        case sampledWarning
        case refreshing
        case refresh
        case manageAccounts
        case quit
        case suggested
        case disabled
        case failed
        case pending
        case windowTitle
        case windowSubtitle
        case refreshEvery
        case noAccountsTitle
        case noAccountsDescription
        case edit
        case disable
        case enable
        case delete
        case addAccount
        case refreshNow
        case showMenuBar
        case deleteTitle
        case thisAccount
        case cancel
        case deleteMessage
        case alertTitle
        case ok
        case editAccount
        case name
        case accountID
        case token
        case tokenUnchanged
        case dailyLimit
        case switchPercent
        case includeInSuggestions
        case tokenHelp
        case save
        case language
        case appearance
        case followSystem
        case chinese
        case english
        case light
        case dark
        case versionFormat
        case quitApp
        case invalidTransaction
        case pendingCleanupFailed
        case invalidRecoveryRecord
        case keychainFailed
    }

    public static func text(_ key: Key, language: AppLanguage = .system) -> String {
        catalog(language.resolved())[key] ?? key.rawValue
    }

    public static func format(_ key: Key, _ arguments: any CVarArg..., language: AppLanguage = .system) -> String {
        String(format: text(key, language: language), locale: locale(language), arguments: arguments)
    }

    private static func locale(_ language: AppLanguage) -> Locale {
        language.resolved() == .chinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
    }

    private static func catalog(_ language: AppLanguage) -> [Key: String] {
        language == .chinese ? chinese : english
    }

    private static let english: [Key: String] = [
        .refreshIntervalInvalid: "Refresh interval must be from 1 to 120 minutes",
        .duplicateAccountID: "Account IDs must be unique",
        .invalidAccountFields: "The account name, daily limit, or switch threshold is invalid",
        .recoveryFailed: "Could not restore the previous configuration or token. The recovery record was kept. Fix file access and try again or relaunch: %@",
        .invalidResponse: "Cloudflare returned a response that could not be read",
        .httpFailed: "Cloudflare request failed (HTTP %d)",
        .emptyAccountList: "This token cannot see any account",
        .incompleteUsage: "The statistics hit the response limit, so the full usage is unknown. This account is not suggested.",
        .multipleAccounts: "This token can access more than one account. Enter the Account ID.",
        .apiFailed: "Cloudflare API returned a failure",
        .graphqlFailed: "Cloudflare GraphQL returned an error",
        .messageSeparator: "; ",
        .missingToken: "No API token yet",
        .nameRequired: "Enter a name",
        .dailyLimitInvalid: "Daily limit must be greater than 0",
        .thresholdInvalid: "Switch threshold must be from 1% to 99%",
        .tokenRequired: "Enter an API token",
        .configurationNotSaved: "Configuration was not saved: %@",
        .tokenCleanupFailed: "The account was deleted, but the token could not be removed: %@",
        .statusNotWritten: "The status file was not written: %@",
        .statusInvalidationFailed: "The previous recommendation could not be invalidated. Do not use the old status file. Write error: %@; removal error: %@",
        .configurationUnreadable: "The configuration could not be read, so changes are paused. Fix the file and relaunch: %@",
        .todayUsage: "Today",
        .resetsRelative: "UTC reset %@",
        .lastRefreshed: "Refreshed %@",
        .notRefreshedYet: "Not refreshed yet",
        .noAccountsMenu: "No accounts yet. Add a read-only Analytics token to start.",
        .sampledWarning: "These numbers are sampled. Switch before the threshold.",
        .refreshing: "Refreshing",
        .refresh: "Refresh",
        .manageAccounts: "Manage accounts",
        .quit: "Quit",
        .suggested: "Suggested",
        .disabled: "Off",
        .failed: "Failed",
        .pending: "Waiting",
        .windowTitle: "Cloudflare free quota",
        .windowSubtitle: "Workers and Pages Functions share %d requests per day and reset at midnight UTC.",
        .refreshEvery: "Refresh every %d min",
        .noAccountsTitle: "No accounts yet",
        .noAccountsDescription: "Create an Account Analytics Read API token for each Cloudflare login.",
        .edit: "Edit",
        .disable: "Disable",
        .enable: "Enable",
        .delete: "Delete",
        .addAccount: "Add account",
        .refreshNow: "Refresh now",
        .showMenuBar: "Show menu bar icon",
        .deleteTitle: "Delete %@?",
        .thisAccount: "this account",
        .cancel: "Cancel",
        .deleteMessage: "The token is removed from this Mac. The Cloudflare account is unchanged.",
        .alertTitle: "Not completed",
        .ok: "OK",
        .editAccount: "Edit account",
        .name: "Name",
        .accountID: "Account ID, optional",
        .token: "API Token",
        .tokenUnchanged: "API Token, leave blank to keep",
        .dailyLimit: "Daily limit",
        .switchPercent: "Switch threshold (%)",
        .includeInSuggestions: "Include in usage and suggestions",
        .tokenHelp: "The token only needs Account Analytics: Read. It stays on this Mac and is readable only by you. Switch accounts at the threshold, 75% by default.",
        .save: "Save",
        .language: "Language",
        .appearance: "Appearance",
        .followSystem: "Follow system",
        .chinese: "Chinese",
        .english: "English",
        .light: "Light",
        .dark: "Dark",
        .versionFormat: "Version %@ (%@)",
        .quitApp: "Quit Cloudflare Quota",
        .invalidTransaction: "The account save transaction is invalid",
        .pendingCleanupFailed: "The account was saved, but the recovery record could not be removed. The next launch will try again: %@",
        .invalidRecoveryRecord: "The account recovery record is invalid",
        .keychainFailed: "Keychain error (%d)",
    ]

    private static let chinese: [Key: String] = [
        .refreshIntervalInvalid: "刷新间隔必须为 1 至 120 分钟",
        .duplicateAccountID: "账号的本地 ID 不能重复",
        .invalidAccountFields: "账号名称、每日限额或切换线无效",
        .recoveryFailed: "原配置或 Token 恢复失败，已保留恢复记录，请修复文件访问问题后重试或重新启动：%@",
        .invalidResponse: "Cloudflare 返回了无法解析的响应",
        .httpFailed: "Cloudflare 请求失败（HTTP %d）",
        .emptyAccountList: "这个 Token 看不到任何账号",
        .incompleteUsage: "统计结果达到返回上限，无法确认完整用量，暂不建议使用此账号",
        .multipleAccounts: "这个 Token 能访问多个账号，请填写 Account ID",
        .apiFailed: "Cloudflare API 返回失败",
        .graphqlFailed: "Cloudflare GraphQL 返回错误",
        .messageSeparator: "；",
        .missingToken: "还没有 API Token",
        .nameRequired: "请填写名称",
        .dailyLimitInvalid: "每日上限要大于 0",
        .thresholdInvalid: "切换线要在 1% 到 99% 之间",
        .tokenRequired: "请填写 API Token",
        .configurationNotSaved: "配置没有保存：%@",
        .tokenCleanupFailed: "账号已删除，但 Token 清理失败：%@",
        .statusNotWritten: "状态文件没有写入：%@",
        .statusInvalidationFailed: "无法使旧推荐失效，请勿继续使用旧状态文件。写入错误：%@；删除错误：%@",
        .configurationUnreadable: "配置读取失败，已暂停配置写入。请修复配置文件后重新启动：%@",
        .todayUsage: "今日用量",
        .resetsRelative: "UTC 重置 %@",
        .lastRefreshed: "刷新于 %@",
        .notRefreshedYet: "还没有刷新",
        .noAccountsMenu: "还没有账号。添加一个只读 Analytics Token 后开始统计。",
        .sampledWarning: "数字来自采样统计，到切换线前就换账号。",
        .refreshing: "刷新中",
        .refresh: "刷新",
        .manageAccounts: "管理账号",
        .quit: "退出",
        .suggested: "建议",
        .disabled: "已停用",
        .failed: "失败",
        .pending: "待刷新",
        .windowTitle: "Cloudflare 免费额度",
        .windowSubtitle: "Workers 和 Pages Functions 共用每日 %d 次，午夜 UTC 重置。",
        .refreshEvery: "每 %d 分钟刷新",
        .noAccountsTitle: "还没有账号",
        .noAccountsDescription: "每个 Cloudflare 登录建一个 Account Analytics Read 的 API Token。",
        .edit: "编辑",
        .disable: "停用",
        .enable: "启用",
        .delete: "删除",
        .addAccount: "添加账号",
        .refreshNow: "立即刷新",
        .showMenuBar: "显示菜单栏图标",
        .deleteTitle: "删除%@？",
        .thisAccount: "这个账号",
        .cancel: "取消",
        .deleteMessage: "Token 会从本机配置里移除。Cloudflare 上的账号不受影响。",
        .alertTitle: "没有完成",
        .ok: "好",
        .editAccount: "编辑账号",
        .name: "名称",
        .accountID: "Account ID，可留空",
        .token: "API Token",
        .tokenUnchanged: "API Token，留空则不修改",
        .dailyLimit: "每日上限",
        .switchPercent: "切换线（%）",
        .includeInSuggestions: "参与统计和切换建议",
        .tokenHelp: "Token 只需要 Account Analytics: Read。它只保存在本机，权限是仅当前用户可读。显示用量到切换线就换下一个账号，默认 75%。",
        .save: "保存",
        .language: "语言",
        .appearance: "外观",
        .followSystem: "跟随系统",
        .chinese: "中文",
        .english: "英文",
        .light: "明亮",
        .dark: "暗黑",
        .versionFormat: "版本 %@（%@）",
        .quitApp: "退出 Cloudflare Quota",
        .invalidTransaction: "账号保存事务无效",
        .pendingCleanupFailed: "账号已保存，但恢复记录清理失败，下次加载时会重试：%@",
        .invalidRecoveryRecord: "账号恢复记录无效",
        .keychainFailed: "钥匙串错误（%d）",
    ]
}
