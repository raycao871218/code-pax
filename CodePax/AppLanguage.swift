import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, simplifiedChinese = "zh-Hans", english = "en"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }

    func locale(preferredLanguages: [String] = Locale.preferredLanguages) -> Locale {
        let identifier: String
        switch self {
        case .simplifiedChinese: identifier = "zh-Hans"
        case .english: identifier = "en"
        case .system:
            let preferred = preferredLanguages.first { $0.lowercased().hasPrefix("zh") || $0.lowercased().hasPrefix("en") }
            identifier = preferred?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
        }
        return Locale(identifier: identifier)
    }

    static func resolve(_ rawValue: String) -> Self {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains(where: { $0.hasPrefix("--preview-") }),
           let flag = args.first(where: { $0.hasPrefix("--preview-language=") }),
           let preview = Self(rawValue: String(flag.dropFirst("--preview-language=".count))) { return preview }
        #endif
        return Self(rawValue: rawValue) ?? .system
    }
}

struct LanguagePicker: View {
    @AppStorage("appLanguage") private var language = AppLanguage.system.rawValue
    var body: some View {
        Picker("语言", selection: $language) {
            ForEach(AppLanguage.allCases) { Text(LocalizedStringKey($0.title)).tag($0.rawValue) }
        }
    }
}

/// Localizes only app-owned strings. Chat messages, terminal output, filenames,
/// model IDs and user-supplied titles must be rendered verbatim instead.
enum L10n {
    static var locale: Locale {
        AppLanguage.resolve(UserDefaults.standard.string(forKey: "appLanguage") ?? "system").locale()
    }

    private static let english: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [:] }
        return values
    }()

    private static let format = try! NSRegularExpression(pattern: #"%(?:([0-9]+)\$)?(?:lld|ld|@|d|u|f)|%%"#)
    private struct Template {
        let pattern: NSRegularExpression
        let translation: String
    }
    private static let templates: [Template] = english.compactMap { key, translation in
        let range = NSRange(key.startIndex..., in: key)
        let tokens = format.matches(in: key, range: range)
        guard tokens.contains(where: { (key as NSString).substring(with: $0.range) != "%%" }) else { return nil }
        var source = "^", end = 0
        let value = key as NSString
        for token in tokens {
            source += NSRegularExpression.escapedPattern(for: value.substring(with: NSRange(location: end, length: token.range.location - end)))
            source += value.substring(with: token.range) == "%%" ? "%" : "(.*?)"
            end = NSMaxRange(token.range)
        }
        source += NSRegularExpression.escapedPattern(for: value.substring(from: end)) + "$"
        guard let pattern = try? NSRegularExpression(pattern: source, options: .dotMatchesLineSeparators) else { return nil }
        return Template(pattern: pattern, translation: translation)
    }

    static func text(_ value: String, locale: Locale? = nil) -> String {
        guard (locale ?? self.locale).identifier.hasPrefix("en") else { return value }
        if let translated = english[value] { return translated }
        let ns = value as NSString
        for template in templates {
            guard let match = template.pattern.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) else { continue }
            var result = template.translation, index = 1
            let tokens = format.matches(in: result, range: NSRange(result.startIndex..., in: result))
            var replacements: [(NSRange, String)] = []
            for token in tokens {
                if (result as NSString).substring(with: token.range) == "%%" { replacements.append((token.range, "%")); continue }
                let position = token.range(at: 1)
                let argument = position.location == NSNotFound ? index : Int((result as NSString).substring(with: position)) ?? index
                guard argument < match.numberOfRanges else { return value }
                replacements.append((token.range, ns.substring(with: match.range(at: argument))))
                index += 1
            }
            for (range, replacement) in replacements.reversed() {
                if let swiftRange = Range(range, in: result) { result.replaceSubrange(swiftRange, with: replacement) }
            }
            return result
        }
        return value
    }
}

struct AppText: View {
    let value: String
    @Environment(\.locale) private var locale
    init(_ value: String) { self.value = value }
    var body: some View { Text(verbatim: L10n.text(value, locale: locale)) }
}

struct AppLabel: View {
    let value: String
    let systemImage: String
    init(_ value: String, systemImage: String) { self.value = value; self.systemImage = systemImage }
    var body: some View { Label { AppText(value) } icon: { Image(systemName: systemImage) } }
}
