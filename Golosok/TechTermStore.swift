import Foundation
import Combine

// MARK: - Модель термина автозамены

struct TechTermRule: Identifiable, Codable, Equatable {
    var id: String
    var canonical: String
    var patterns: [String]
    var isEnabled: Bool

    init(id: String = UUID().uuidString, canonical: String, patterns: [String], isEnabled: Bool = true) {
        self.id = id
        self.canonical = canonical
        self.patterns = patterns
        self.isEnabled = isEnabled
    }
}

// MARK: - Хранилище и движок применения правил

final class TechTermStore: ObservableObject {
    static let shared = TechTermStore()

    @Published private(set) var rules: [TechTermRule] = []
    @Published var isReplacementEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isReplacementEnabled, forKey: "techterms.replacement.enabled")
        }
    }

    private let ioQueue = DispatchQueue(label: "Golosok.TechTermStore.io")
    private var compiledRegexCache: [(regex: NSRegularExpression, canonical: String)] = []

    private init() {
        self.isReplacementEnabled = UserDefaults.standard.object(forKey: "techterms.replacement.enabled") as? Bool ?? true
        load()
        rebuildRegexCache()
    }

    private var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Golosok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("terms_dictionary.json")
    }

    // MARK: - Public API

    @discardableResult
    func add(canonical: String, patterns: [String]) -> String {
        let cleanCanonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPatterns = patterns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleanCanonical.isEmpty && !cleanPatterns.isEmpty else { return "" }

        let rule = TechTermRule(canonical: cleanCanonical, patterns: cleanPatterns, isEnabled: true)
        rules.append(rule)
        rebuildRegexCache()
        persist()
        return rule.id
    }

    func update(_ rule: TechTermRule) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        var updated = rule
        updated.canonical = updated.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.patterns = updated.patterns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        rules[idx] = updated
        rebuildRegexCache()
        persist()
    }

    func delete(id: String) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules.remove(at: idx)
        rebuildRegexCache()
        persist()
    }

    func toggle(id: String) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].isEnabled.toggle()
        rebuildRegexCache()
        persist()
    }

    func resetToDefaults() {
        rules = Self.defaultRules
        rebuildRegexCache()
        persist()
    }

    // MARK: - Применение правил автозамены (0 мс задержки)

    func applyReplacements(to text: String) -> String {
        guard isReplacementEnabled, !text.isEmpty, !compiledRegexCache.isEmpty else { return text }

        var result = text
        for item in compiledRegexCache {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = item.regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: item.canonical)
            )
        }
        return result
    }

    // MARK: - Внутренняя оптимизация регулярных выражений

    private func rebuildRegexCache() {
        var cache: [(regex: NSRegularExpression, canonical: String)] = []
        let activeRules = rules.filter { $0.isEnabled }

        for rule in activeRules {
            let sortedPatterns = rule.patterns.sorted { $0.count > $1.count }
            for pat in sortedPatterns {
                let trimmed = pat.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                let escaped = NSRegularExpression.escapedPattern(for: trimmed)
                let patternString = "(?<![\\p{L}\\p{N}_])" + escaped + "(?![\\p{L}\\p{N}_])"

                if let rx = try? NSRegularExpression(pattern: patternString, options: [.caseInsensitive]) {
                    cache.append((regex: rx, canonical: rule.canonical))
                }
            }
        }
        self.compiledRegexCache = cache
    }

    // MARK: - Persistence

    private func persist() {
        let snapshot = rules
        ioQueue.async { [weak self] in
            guard let self, let url = self.fileURL else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func load() {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([TechTermRule].self, from: data) else {
            rules = Self.defaultRules
            persist()
            return
        }
        rules = decoded
    }

    // MARK: - Базовый проверенный набор правил (по результатам анализа history.json)

    static let defaultRules: [TechTermRule] = [
        .init(canonical: "Tailscale", patterns: ["stale skale", "talescale", "тейлскейл", "тайлскейл", "staleskale"]),
        .init(canonical: "OpenCode", patterns: ["open-код", "опен-код", "опин-код", "open-code", "open coda", "open cod", "опенкод"]),
        .init(canonical: "Hindsight", patterns: ["hinsite", "хинсайт", "хинсайд", "hinesid", "хайндсайт", "хайндсайд"]),
        .init(canonical: "Vaultwarden", patterns: ["vout warden", "woutwarden", "веб-ваут", "web-vault", "веб-вольт", "веб-вольта"]),
        .init(canonical: "Ollama", patterns: ["alama local", "alama", "оллама", "олламу"]),
        .init(canonical: "symlink", patterns: ["simlink", "симлинк", "симлинка"]),
        .init(canonical: "upstream", patterns: ["абстрим", "абстрима", "абстриме", "ваб-стриме", "ваб-стрим"]),
        .init(canonical: "Cloudflare", patterns: ["cloud flaer", "клаудфлер", "клауд флеер"]),
        .init(canonical: "NetBox", patterns: ["netbox", "нетбокс"]),
        .init(canonical: "LLDP", patterns: ["лдп", "lldp"]),
        .init(canonical: "CDP", patterns: ["сдп", "cdp"]),
        .init(canonical: "SNMP", patterns: ["snm", "снмп", "snmp"]),
        .init(canonical: "VoIP", patterns: ["wip-устройств", "wip-устройства", "воип", "voip"]),
        .init(canonical: "sidebar", patterns: ["site bare", "сайтбар", "сайтбаре"]),
        .init(canonical: "timeout", patterns: ["mout 80", "таймаут", "таймаута"]),
        .init(canonical: "digest", patterns: ["дальшест", "дайлжест", "дайджест"]),
        .init(canonical: "remote", patterns: ["remout", "ремоут"]),
        .init(canonical: "Kubernetes", patterns: ["кубернетес", "кубернетис", "k8s"]),
        .init(canonical: "Docker", patterns: ["докер", "докера", "докер-контейнер"]),
        .init(canonical: "SSH", patterns: ["ссш", "ссх", "ssh-ключ", "sh-верь"]),
        .init(canonical: "Nginx", patterns: ["нжинкс", "нгинкс", "энджинкс", "nginx"]),
        .init(canonical: "GitHub", patterns: ["гитхаб", "гитхабе", "гитхабан", "github"]),
        .init(canonical: "macOS", patterns: ["макос", "мак ос", "macos"]),
        .init(canonical: "Linux", patterns: ["линукс", "линуксе", "linux"]),
        .init(canonical: "Python", patterns: ["пайтон", "питон", "python"]),
        .init(canonical: "Swift", patterns: ["свифт", "свифта", "swift"])
    ]
}
