import Foundation
import Combine

// MARK: - Модель правила термина автозамены

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

// MARK: - Модель кандидата автообучения (Staging Buffer перед верификацией)

struct TechTermCandidate: Identifiable, Codable, Equatable {
    var id: String
    var canonical: String
    var pattern: String
    var occurrences: Int
    var firstSeen: Date
    var lastSeen: Date

    init(id: String = UUID().uuidString, canonical: String, pattern: String, occurrences: Int = 1, firstSeen: Date = Date(), lastSeen: Date = Date()) {
        self.id = id
        self.canonical = canonical
        self.pattern = pattern
        self.occurrences = occurrences
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

// MARK: - Хранилище и движок применения правил

final class TechTermStore: ObservableObject {
    static let shared = TechTermStore()

    @Published private(set) var rules: [TechTermRule] = []
    @Published private(set) var candidates: [TechTermCandidate] = []
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
    private var isVerifyingCandidates = false

    private init() {
        self.isReplacementEnabled = UserDefaults.standard.object(forKey: "techterms.replacement.enabled") as? Bool ?? true
        self.isAutoLearnEnabled = UserDefaults.standard.object(forKey: "techterms.autoLearn.enabled") as? Bool ?? true
        load()
        loadCandidates()
        rebuildRegexCache()
    }

    private var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Golosok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("terms_dictionary.json")
    }

    private var candidatesFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Golosok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("terms_candidates.json")
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

    // MARK: - Динамический выбор терминов-кандидатов (Fuzzy Dynamic Context для LLM)

    /// Быстрый нечеткий отбор 2–5 наиболее вероятных терминов из словаря для динамической подсказки в LLM
    func findFuzzyCandidateTerms(for text: String, limit: Int = 4) -> [TechTermRule] {
        guard isReplacementEnabled, !text.isEmpty else { return [] }

        let lowerText = text.lowercased()
        let words = lowerText
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }

        guard !words.isEmpty else { return [] }

        // Добавляем биграммы для поиска многословных терминов ("open roater", "hard war")
        var ngrams = words
        if words.count >= 2 {
            for i in 0..<(words.count - 1) {
                ngrams.append("\(words[i]) \(words[i + 1])")
            }
        }

        var scored: [(rule: TechTermRule, score: Double)] = []

        for rule in rules where rule.isEnabled {
            var bestScore = 0.0

            var targets = [rule.canonical.lowercased()]
            targets.append(contentsOf: rule.patterns.map { $0.lowercased() })

            for target in targets {
                // Если точное каноническое имя уже есть в тексте, термин уже распознан
                if lowerText.contains(target) {
                    if target != rule.canonical.lowercased() {
                        bestScore = Swift.max(bestScore, 0.95)
                    }
                    continue
                }

                for token in ngrams {
                    // Префиксное совпадение для длинных корней
                    if target.count >= 5 && (token.hasPrefix(target) || target.hasPrefix(token)) {
                        bestScore = Swift.max(bestScore, 0.8)
                    }

                    // Быстрый Левенштейн для созвучных опечаток
                    let s1 = token
                    let s2 = target
                    let a = Array(s1)
                    let b = Array(s2)
                    let n = a.count
                    let m = b.count
                    if abs(n - m) > 3 { continue }

                    var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
                    for i in 0...n { dp[i][0] = i }
                    for j in 0...m { dp[0][j] = j }
                    for i in 1...n {
                        for j in 1...m {
                            if a[i - 1] == b[j - 1] {
                                dp[i][j] = dp[i - 1][j - 1]
                            } else {
                                dp[i][j] = 1 + Swift.min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
                            }
                        }
                    }

                    let sim = Swift.max(0.0, 1.0 - (Double(dp[n][m]) / Double(Swift.max(n, m))))
                    if sim > bestScore {
                        bestScore = sim
                    }
                }
            }

            if bestScore >= 0.55 {
                scored.append((rule, bestScore))
            }
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0.rule }
    }

    // MARK: - Буфер кандидатов автообучения и пакетная верификация через LLM

    func approveCandidate(_ candidate: TechTermCandidate) {
        addPattern(candidate.pattern, toCanonical: candidate.canonical)
        candidates.removeAll { $0.id == candidate.id }
        persistCandidates()
    }

    func rejectCandidate(_ candidate: TechTermCandidate) {
        candidates.removeAll { $0.id == candidate.id }
        persistCandidates()
    }

    func clearCandidates() {
        candidates.removeAll()
        persistCandidates()
    }

    private func addPattern(_ rawPattern: String, toCanonical canonical: String) {
        let cleanCan = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPat = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCan.isEmpty, !cleanPat.isEmpty else { return }

        if let existingIdx = rules.firstIndex(where: { $0.canonical.caseInsensitiveCompare(cleanCan) == .orderedSame }) {
            let existingPats = Set(rules[existingIdx].patterns.map { $0.lowercased() })
            if !existingPats.contains(cleanPat.lowercased()) {
                rules[existingIdx].patterns.append(cleanPat)
                rebuildRegexCache()
                persist()
                AppLogger.shared.info("TechTerms", "Словарь пополнен подтвержденным вариантом", details: "\(cleanCan) <- '\(cleanPat)'")
            }
        } else {
            let newRule = TechTermRule(canonical: cleanCan, patterns: [cleanPat], isEnabled: true)
            rules.append(newRule)
            rebuildRegexCache()
            persist()
            AppLogger.shared.info("TechTerms", "Словарь пополнен подтвержденным термином", details: "\(cleanCan) <- '\(cleanPat)'")
        }
    }

    private func loadCandidates() {
        guard let url = candidatesFileURL,
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([TechTermCandidate].self, from: data) else {
            candidates = []
            return
        }
        candidates = list
    }

    private func persistCandidates() {
        let snapshot = candidates
        ioQueue.async { [weak self] in
            guard let self, let url = self.candidatesFileURL else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Автоматическое обучение словаря на основе правок ИИ

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

            let rawCleanLower = rawPattern.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters)

            // Валидация правдоподобности (Phonetic / Structural Validation):
            let existingPatterns = rules.first(where: { $0.canonical.caseInsensitiveCompare(canonical) == .orderedSame })?.patterns ?? []
            let isPlausible = isPhoneticallyPlausible(pattern: rawCleanLower, canonical: canonical, existingPatterns: existingPatterns)
            guard isPlausible else {
                AppLogger.shared.warn("TechTerms", "Отклонено добавление непохожего паттерна (галлюцинация ИИ)", details: "\(canonical) <- '\(rawPattern)'")
                continue
            }

            // Проверяем, есть ли уже этот паттерн в боевом словаре
            if existingPatterns.contains(where: { $0.caseInsensitiveCompare(rawPattern) == .orderedSame }) {
                continue
            }

            // Добавляем или обновляем кандидата в буфере на проверку
            if let cIdx = candidates.firstIndex(where: { $0.canonical.caseInsensitiveCompare(canonical) == .orderedSame && $0.pattern.caseInsensitiveCompare(rawPattern) == .orderedSame }) {
                candidates[cIdx].occurrences += 1
                candidates[cIdx].lastSeen = Date()
                changesCount += 1

                // Если кандидат встретился 2+ раза и фонетически проверен, он автоматически одобряется в боевой словарь!
                if candidates[cIdx].occurrences >= 2 {
                    approveCandidate(candidates[cIdx])
                }
            } else {
                let candidate = TechTermCandidate(canonical: canonical, pattern: rawPattern)
                candidates.append(candidate)
                changesCount += 1
                AppLogger.shared.info("TechTerms", "Кандидат добавлен в буфер верификации", details: "\(canonical) <- '\(rawPattern)'")
            }
        }

        if changesCount > 0 {
            persistCandidates()
            triggerBatchVerificationIfNeeded()
        }
        return changesCount
    }

    /// Пакетная верификация накопленных кандидатов через ИИ (когда накопилось от 5 кандидатов)
    func triggerBatchVerificationIfNeeded(force: Bool = false) {
        guard !isVerifyingCandidates else { return }
        guard force || candidates.count >= 5 else { return }
        guard AIProviderStore.shared.isConfigured else { return }

        isVerifyingCandidates = true
        let snapshot = candidates
        let itemsPrompt = snapshot.enumerated().map { idx, c in
            "\(idx + 1). Исходное слово: \"\(c.pattern)\" -> Предложенный термин: \"\(c.canonical)\""
        }.joined(separator: "\n")

        let verifyPrompt = """
        Ты — специализированный верификатор словаря автозамены IT-терминов после голосовой модели GigaAM.
        Определи для каждого пункта, является ли исходное слово фонетическим транслитом, созвучным написанием или ослышкой указанного термина в IT-контексте (например, "сайт-бар" для "sidebar", "опен-код" для "OpenCode", "веп-н-код" для "OpenCode", "веб-ваут" для "Vaultwarden" — это ВАЛИДНЫЕ искажения). Дефисные и транслитерационные формы являются нормой голосового распознавания и ДОЛЖНЫ одобряться.
        
        Отклоняй ТОЛЬКО очевидные смысловые галлюцинации и совершенно несвязанные русские слова (например: "голосок" -> "Vaultwarden", "программа" -> "OpenCode", "кнопка" -> "SSH" — это НЕТ).

        Список кандидатов:
        \(itemsPrompt)

        Ответь ТОЛЬКО валидным JSON-объектом без пояснений в формате:
        {"1": true, "2": false, ...}
        """

        let messages = [
            AIChatMessage(role: "system", content: "Ты — API-валидатор терминов. Отвечай только чистым JSON."),
            AIChatMessage(role: "user", content: verifyPrompt)
        ]

        AIService.shared.chat(messages: messages, using: AIProviderStore.shared.config) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isVerifyingCandidates = false
                switch result {
                case .success(let answer):
                    self.parseAndApplyVerification(answer: answer, candidatesBatch: snapshot)
                case .failure(let error):
                    AppLogger.shared.warn("TechTerms", "Пакетная верификация кандидатов через ИИ не удалась", details: error.localizedDescription)
                }
            }
        }
    }

    private func parseAndApplyVerification(answer: String, candidatesBatch: [TechTermCandidate]) {
        // Извлекаем JSON из ответа
        let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = clean.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else {
            AppLogger.shared.warn("TechTerms", "Не удалось разобрать JSON-ответ валидатора", details: clean)
            return
        }

        var approvedCount = 0
        var rejectedCount = 0

        for (idx, candidate) in candidatesBatch.enumerated() {
            let key = "\(idx + 1)"
            if let approved = dict[key] {
                if approved {
                    approveCandidate(candidate)
                    approvedCount += 1
                } else {
                    rejectCandidate(candidate)
                    rejectedCount += 1
                    AppLogger.shared.warn("TechTerms", "ИИ-валидатор отклонил кандидата", details: "\(candidate.canonical) <- '\(candidate.pattern)'")
                }
            }
        }

        AppLogger.shared.info("TechTerms", "Пакетная верификация ИИ завершена", details: "Одобрено: \(approvedCount), Отклонено: \(rejectedCount)")
    }

    /// Проверяет, похоже ли искаженное слово на канонический термин или его варианты (защита от галлюцинаций модели)
    private func isPhoneticallyPlausible(pattern: String, canonical: String, existingPatterns: [String]) -> Bool {
        let patNorm = phoneticNormalize(pattern)
        let canNorm = phoneticNormalize(canonical)

        let patCompact = patNorm.replacingOccurrences(of: " ", with: "")
        let canCompact = canNorm.replacingOccurrences(of: " ", with: "")

        // 1. Прямое совпадение или подстрока в нормализованном виде
        if canCompact.contains(patCompact) || patCompact.contains(canCompact) {
            return true
        }

        // 2. Сходство целых строк
        if stringSimilarity(patCompact, canCompact) >= 0.38 {
            return true
        }

        // 3. Токенизированное сходство (если хотя бы одно слово созвучно части термина)
        let patTokens = patNorm.components(separatedBy: " ").filter { $0.count >= 3 }
        let canTokens = canNorm.components(separatedBy: " ").filter { $0.count >= 3 }
        for pt in patTokens {
            if canCompact.contains(pt) { return true }
            for ct in canTokens {
                if stringSimilarity(pt, ct) >= 0.50 { return true }
            }
        }

        // 4. Проверка против существующих проверенных паттернов
        for p in existingPatterns {
            let pNorm = phoneticNormalize(p)
            let pCompact = pNorm.replacingOccurrences(of: " ", with: "")
            if stringSimilarity(patCompact, pCompact) >= 0.38 {
                return true
            }
            let pTokens = pNorm.components(separatedBy: " ").filter { $0.count >= 3 }
            for pt in patTokens {
                if pCompact.contains(pt) { return true }
                for pct in pTokens {
                    if stringSimilarity(pt, pct) >= 0.50 { return true }
                }
            }
        }

        return false
    }

    private func phoneticNormalize(_ text: String) -> String {
        var s = transliterateRussianToLatin(text.lowercased())
        s = s.replacingOccurrences(of: "-", with: " ")
        s = s.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: "ph", with: "f")
        s = s.replacingOccurrences(of: "ey", with: "ai")
        s = s.replacingOccurrences(of: "ay", with: "ai")
        s = s.replacingOccurrences(of: "c", with: "k")
        s = s.replacingOccurrences(of: "w", with: "v")
        s = s.replacingOccurrences(of: "x", with: "ks")
        s = s.replacingOccurrences(of: "zh", with: "j")
        return s
    }

    private func transliterateRussianToLatin(_ text: String) -> String {
        let mapping: [Character: String] = [
            "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo",
            "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
            "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
            "ф": "f", "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sch",
            "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya"
        ]
        var res = ""
        for ch in text.lowercased() {
            if let lat = mapping[ch] {
                res += lat
            } else {
                res.append(ch)
            }
        }
        return res
    }

    private func stringSimilarity(_ s1: String, _ s2: String) -> Double {
        let a = Array(s1)
        let b = Array(s2)
        let n = a.count
        let m = b.count
        guard n > 0 && m > 0 else { return 0.0 }
        if abs(n - m) > 4 { return 0.0 }

        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dp[i][0] = i }
        for j in 0...m { dp[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = 1 + Swift.min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
                }
            }
        }
        return Swift.max(0.0, 1.0 - (Double(dp[n][m]) / Double(Swift.max(n, m))))
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
