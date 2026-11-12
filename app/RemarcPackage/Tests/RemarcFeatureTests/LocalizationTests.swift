import Combine
import Foundation
import Testing
@testable import RemarcFeature

@Suite("Interface language")
struct LocalizationTests {
    @Test("System selection supports Chinese and English, falling back to English for other languages")
    func systemLanguage() {
        #expect(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN"]) == .simplifiedChinese)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["zh-Hant-TW"]) == .simplifiedChinese)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["en-GB"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "zh-Hans"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: []) == .english)
        #expect(AppLanguage.english.resolved(preferredLanguages: ["zh-CN"]) == .english)
        #expect(AppLanguage.simplifiedChinese.resolved(preferredLanguages: ["en-US"]) == .simplifiedChinese)
    }

    @Test("The four status names are short and consistent; storage and export remain stable")
    func statuses() {
        let statuses = CommentStatus.allCases
        #expect(statuses.map { $0.localizedLabel(language: .simplifiedChinese) } == ["待处理", "已转交", "进行中", "已完成"])
        #expect(statuses.map { $0.localizedLabel(language: .english) } == ["Open", "Handed Off", "In Progress", "Resolved"])
        #expect(statuses.map(\.rawValue) == ["open", "handedOff", "inProgress", "resolved"])
        #expect(statuses.map(\.exportLabel) == ["Open", "Handed Off", "正在开发中", "Resolved"])
        #expect(CommentType.quickNote.exportDisplayName == "Quick Note")
    }

    @Test("Translations reorder arguments and preserve user text, braces, percent signs and line breaks exactly")
    func interpolation() {
        let name = "Open {0} %n \"原文\"\nIn Progress"
        #expect(L10n.tr("Moved to \(name)", language: .english) == "Moved to " + name)
        #expect(L10n.tr("Moved to \(name)", language: .simplifiedChinese) == "已移至 " + name)
        #expect(L10n.tr("Resolve all \(3) comments in \(name)?", language: .simplifiedChinese) == "将“" + name + "”中的 3 条评论全部设为已完成？")
        #expect(L10n.tr("Copied \(2) comment\("s")", language: .english) == "Copied 2 comments")
        #expect(L10n.tr("Copied \(2) comment\("s")", language: .simplifiedChinese) == "已复制 2 条评论")
        #expect(L10n.lookup("Remarc cannot access the snapshot files.", language: .simplifiedChinese) == "Remarc 无法访问快照文件。")
        #expect(L10n.lookup("Remarc 无法访问快照文件。", language: .english) == "Remarc cannot access the snapshot files.")
    }

    @Test("The bundled catalog contains core surfaces and only references arguments supplied by its source key")
    func catalog() throws {
        #expect(!L10n.chinese.isEmpty)
        for key in ["Follow System", "Language", "General", "Settings…", "Copy All", "Copy and Start", "Comment History", "Screen Recording Permission", "iCloud Sync", "MCP Integrations", "Open", "Handed Off", "In Progress", "Resolved"] {
            #expect(L10n.chinese[key]?.isEmpty == false, "Missing translation: \(key)")
        }
        let expression = try NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
        func arguments(_ value: String) -> Set<String> {
            Set(expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
                Range(match.range(at: 1), in: value).map { String(value[$0]) }
            })
        }
        for (key, value) in L10n.chinese {
            #expect(!value.isEmpty, "Empty translation: \(key)")
            // Chinese can omit English plural suffix arguments, but must never
            // introduce an argument that the source cannot supply.
            #expect(arguments(value).isSubset(of: arguments(key)), "Invalid placeholders: \(key)")
        }
    }

    @Test("A saved language is restored and publishes changes without changing another defaults domain")
    @MainActor
    func persistenceAndObservation() throws {
        let domain = "Remarc.LanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let productionPreference = UserDefaults.standard.object(forKey: LocalizationManager.preferenceKey) as? String
        let manager = LocalizationManager(defaults: defaults)
        #expect(manager.language == .system)
        var changes = 0
        let subscription = manager.objectWillChange.sink { changes += 1 }
        manager.language = .simplifiedChinese
        #expect(defaults.string(forKey: LocalizationManager.preferenceKey) == AppLanguage.simplifiedChinese.rawValue)
        #expect(LocalizationManager(defaults: defaults).language == .simplifiedChinese)
        manager.language = .english
        #expect(changes == 2)
        #expect(LocalizationManager(defaults: defaults).language == .english)
        #expect(UserDefaults.standard.object(forKey: LocalizationManager.preferenceKey) as? String == productionPreference)
        withExtendedLifetime(subscription) {}
    }
}

@Suite("Snapshot timestamp language")
struct SnapshotTimestampLanguageTests {
    @Test func explicitLanguageControlsMonthPresentation() {
        let date = Date(timeIntervalSince1970: 1_794_485_000)
        let chinese = date.snapshotInterfaceFormatted(language: .simplifiedChinese)
        let english = date.snapshotInterfaceFormatted(language: .english)
        #expect(chinese.contains("月"))
        #expect(!english.contains("月"))
        #expect(chinese != english)
    }
}
