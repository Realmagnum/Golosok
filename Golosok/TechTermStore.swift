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
    @Published var isAutoLearnEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoLearnEnabled, forKey: "techterms.autoLearn.enabled")
        }
    }

    private let ioQueue = DispatchQueue(label: "Golosok.TechTermStore.io")
    private var compiledRegexCache: [(regex: NSRegularExpression, canonical: String)] = []

    private init() {
        self.isReplacementEnabled = UserDefaults.standard.object(forKey: "techterms.replacement.enabled") as? Bool ?? true
        self.isAutoLearnEnabled = UserDefaults.standard.object(forKey: "techterms.autoLearn.enabled") as? Bool ?? true
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

    func setAllEnabled(_ enabled: Bool) {
        for i in 0..<rules.count {
            rules[i].isEnabled = enabled
        }
        rebuildRegexCache()
        persist()
    }

    func resetToDefaults() {
        rules = Self.defaultRules
        rebuildRegexCache()
        persist()
    }

    // MARK: - Импорт и Экспорт словаря

    @discardableResult
    func importFromURL(_ url: URL, overwrite: Bool = false) -> (imported: Int, error: String?) {
        guard let data = try? Data(contentsOf: url) else {
            return (0, "Не удалось прочитать выбранный файл")
        }

        // Поддерживаем как полноценный JSON массив TechTermRule, так и упрощенный формат {"canonical": ["pattern1", "pattern2"]}
        var incomingRules: [TechTermRule] = []

        if let decoded = try? JSONDecoder().decode([TechTermRule].self, from: data) {
            incomingRules = decoded
        } else if let dict = try? JSONDecoder().decode([String: [String]].self, from: data) {
            incomingRules = dict.map { TechTermRule(canonical: $0.key, patterns: $0.value, isEnabled: true) }
        } else if let jsonObject = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            for item in jsonObject {
                if let can = item["canonical"] as? String {
                    let pats = (item["patterns"] as? [String]) ?? []
                    let enabled = (item["isEnabled"] as? Bool) ?? true
                    if !pats.isEmpty {
                        incomingRules.append(TechTermRule(canonical: can, patterns: pats, isEnabled: enabled))
                    }
                }
            }
        }

        guard !incomingRules.isEmpty else {
            return (0, "Файл не содержит корректных записей словаря (поддерживается JSON)")
        }

        if overwrite {
            rules = incomingRules
        } else {
            // Умное слияние: дополняем существующие канонические термины новыми паттернами, либо добавляем новые
            for incoming in incomingRules {
                let cleanCan = incoming.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanCan.isEmpty else { continue }
                if let existingIdx = rules.firstIndex(where: { $0.canonical.caseInsensitiveCompare(cleanCan) == .orderedSame }) {
                    var existingPats = Set(rules[existingIdx].patterns.map { $0.lowercased() })
                    for p in incoming.patterns {
                        let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty && !existingPats.contains(trimmed.lowercased()) {
                            rules[existingIdx].patterns.append(trimmed)
                            existingPats.insert(trimmed.lowercased())
                        }
                    }
                } else {
                    rules.append(incoming)
                }
            }
        }

        rebuildRegexCache()
        persist()
        return (incomingRules.count, nil)
    }

    func exportToURL(_ url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(rules) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
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

    // MARK: - Автоматическое обучение словаря на основе правок ИИ

    @discardableResult
    func autoLearn(fromRaw rawVoiceText: String, aiCorrected: String) -> Int {
        guard isAutoLearnEnabled, isReplacementEnabled else { return 0 }
        let pairs = extractDiffPairs(raw: rawVoiceText, ai: aiCorrected)
        guard !pairs.isEmpty else { return 0 }

        var changesCount = 0

        for pair in pairs {
            let canonical = pair.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawPattern = pair.rawPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty, !rawPattern.isEmpty else { continue }
            guard canonical.lowercased() != rawPattern.lowercased() else { continue }

            if let existingIdx = rules.firstIndex(where: { $0.canonical.caseInsensitiveCompare(canonical) == .orderedSame }) {
                // Добавляем к существующему правилу, проверяя на дубликаты
                let existingPats = Set(rules[existingIdx].patterns.map { $0.lowercased() })
                if !existingPats.contains(rawPattern.lowercased()) {
                    rules[existingIdx].patterns.append(rawPattern)
                    changesCount += 1
                    AppLogger.shared.info("TechTerms", "Словарь пополнен новым вариантом", details: "\(canonical) <- '\(rawPattern)'")
                }
            } else {
                // Создаем новое правило для ранее неизвестного термина
                let newRule = TechTermRule(canonical: canonical, patterns: [rawPattern], isEnabled: true)
                rules.append(newRule)
                changesCount += 1
                AppLogger.shared.info("TechTerms", "Словарь пополнен новым термином", details: "\(canonical) <- '\(rawPattern)'")
            }
        }

        if changesCount > 0 {
            rebuildRegexCache()
            persist()
        }
        return changesCount
    }

    private func extractDiffPairs(raw: String, ai: String) -> [(rawPhrase: String, canonical: String)] {
        func clean(_ w: String) -> String {
            w.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
        }

        let englishStopwords: Set<String> = [
            "the", "and", "in", "on", "at", "to", "for", "of", "with", "is", "are", "was", "were",
            "a", "an", "this", "that", "it", "from", "by", "as", "be", "or", "not", "your", "my", "we", "you",
            "he", "she", "they", "them", "his", "her", "their", "so", "if", "but", "about", "into", "then"
        ]

        let rawTokens = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let aiTokens = ai.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        let n = rawTokens.count
        let m = aiTokens.count
        guard n > 0 && m > 0 else { return [] }

        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                let rClean = clean(rawTokens[i - 1]).lowercased()
                let aClean = clean(aiTokens[j - 1]).lowercased()
                if rClean == aClean && !rClean.isEmpty {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        var pairs: [(rawPhrase: String, canonical: String)] = []
        var i = n
        var j = m

        var diffRaw: [String] = []
        var diffAI: [String] = []

        func flushDiff() {
            if !diffRaw.isEmpty && !diffAI.isEmpty {
                let cleanRawList = diffRaw.map { clean($0) }.filter { !$0.isEmpty }
                let cleanAIList = diffAI.map { clean($0) }.filter { !$0.isEmpty }

                if cleanRawList.count == cleanAIList.count && cleanRawList.count > 1 {
                    for k in 0..<cleanRawList.count {
                        let r = cleanRawList[k]
                        let a = cleanAIList[k]
                        if !r.isEmpty && !a.isEmpty && r.lowercased() != a.lowercased() {
                            if a.range(of: "[a-zA-Z]", options: .regularExpression) != nil && !englishStopwords.contains(a.lowercased()) {
                                pairs.append((rawPhrase: r, canonical: a))
                            }
                        }
                    }
                } else {
                    let rawStr = cleanRawList.joined(separator: " ")
                    let aiStr = cleanAIList.joined(separator: " ")
                    if !rawStr.isEmpty && !aiStr.isEmpty && rawStr.lowercased() != aiStr.lowercased() {
                        if aiStr.range(of: "[a-zA-Z]", options: .regularExpression) != nil && !englishStopwords.contains(aiStr.lowercased()) {
                            pairs.append((rawPhrase: rawStr, canonical: aiStr))
                        }
                    }
                }
            }
            diffRaw.removeAll()
            diffAI.removeAll()
        }

        while i > 0 || j > 0 {
            if i > 0 && j > 0 && clean(rawTokens[i - 1]).lowercased() == clean(aiTokens[j - 1]).lowercased() && !clean(rawTokens[i - 1]).isEmpty {
                flushDiff()
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                diffAI.insert(aiTokens[j - 1], at: 0)
                j -= 1
            } else if i > 0 && (j == 0 || dp[i][j - 1] < dp[i - 1][j]) {
                diffRaw.insert(rawTokens[i - 1], at: 0)
                i -= 1
            } else {
                break
            }
        }
        flushDiff()

        return pairs.reversed()
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
        .init(canonical: "Tailscale", patterns: ["TL Skale", "stale skale", "talescale", "тейлскейл", "тайлскейл", "staleskale"]),
        .init(canonical: "OpenCode", patterns: ["Open Code", "open-код", "опен-код", "опин-код", "open-code", "open coda", "open cod", "опенкод"]),
        .init(canonical: "Hindsight", patterns: ["хин-сайт", "hinsite", "хинсайт", "хинсайд", "hinesid", "хайндсайт", "хайндсайд"]),
        .init(canonical: "Vaultwarden", patterns: ["vout warden", "woutwarden", "веб-ваут", "web-vault", "веб-вольт", "веб-вольта"]),
        .init(canonical: "Ollama", patterns: ["alama local", "alama", "оллама", "олламу"]),
        .init(canonical: "symlink", patterns: ["simlink", "симлинк", "симлинка"]),
        .init(canonical: "upstream", patterns: ["вабстрим", "абстрим", "абстрима", "абстриме", "ваб-стриме", "ваб-стрим"]),
        .init(canonical: "Cloudflare", patterns: ["cloudfla", "cloud flaer", "клаудфлер", "клауд флеер"]),
        .init(canonical: "NetBox", patterns: ["netbox", "нетбокс"]),
        .init(canonical: "LLDP", patterns: ["лдп", "lldp"]),
        .init(canonical: "CDP", patterns: ["сдп", "cdp"]),
        .init(canonical: "SNMP", patterns: ["snm", "снмп", "snmp"]),
        .init(canonical: "VoIP", patterns: ["wip-устройств", "wip-устройства", "воип", "voip"]),
        .init(canonical: "sidebar", patterns: ["Side Bar", "site bare", "сайтбар", "сайтбаре"]),
        .init(canonical: "gateway", patterns: ["Gate Way", "гейтвей", "гейтвейем", "шлюз"]),
        .init(canonical: "timeout", patterns: ["mout 80", "таймаут", "таймаута"]),
        .init(canonical: "digest", patterns: ["дальшест", "дайлжест", "дайджест"]),
        .init(canonical: "remote", patterns: ["remout", "ремоут"]),
        .init(canonical: "Kubernetes", patterns: ["cubernetis", "кубернетес", "кубернетис", "k8s"]),
        .init(canonical: "Docker", patterns: ["Doker", "докер", "докера", "докер-контейнер"]),
        .init(canonical: "SSH", patterns: ["ссш", "ссх", "ssh-ключ", "sh-верь"]),
        .init(canonical: "Nginx", patterns: ["Enginx", "нжинкс", "нгинкс", "энджинкс", "nginx"]),
        .init(canonical: "GitHub", patterns: ["гитхаб", "гитхабе", "гитхабан", "github"]),
        .init(canonical: "macOS", patterns: ["макос", "мак ос", "macos"]),
        .init(canonical: "Linux", patterns: ["линукс", "линуксе", "linux"]),
        .init(canonical: "Python", patterns: ["пайтон", "питон", "python"]),
        .init(canonical: "Swift", patterns: ["свифт", "свифта", "swift"])
    ]
}
