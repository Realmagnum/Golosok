import Foundation

/// Модуль расчёта диапазонов слов, заменённых IT-словарём и ИИ-моделью
struct NoteDiffHighlighter {

    static func highlightRanges(raw: String?, terms: String?, final: String) -> (itRanges: [NSRange], aiRanges: [NSRange]) {
        var itRanges: [NSRange] = []
        var aiRanges: [NSRange] = []
        let nsFinal = final as NSString
        let finalLen = nsFinal.length
        guard finalLen > 0 else { return ([], []) }

        // 1. Поиск диапазонов слов, заменённых IT-словарём
        let activeRules = TechTermStore.shared.rules.filter { $0.isEnabled }
        for rule in activeRules {
            let canon = rule.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canon.isEmpty else { continue }

            let rawHadPattern = rule.patterns.contains { pat in
                guard let raw = raw else { return false }
                return raw.range(of: pat, options: .caseInsensitive) != nil
            }
            let rawHadCanon = (raw?.range(of: canon, options: .caseInsensitive) != nil)

            if rawHadPattern || (!rawHadCanon && raw != nil) || (raw == nil && terms == nil) {
                var search = NSRange(location: 0, length: finalLen)
                while search.location < finalLen {
                    let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: canon) + "(?![\\p{L}\\p{N}_])"
                    if let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                       let m = rx.firstMatch(in: final, options: [], range: search) {
                        itRanges.append(m.range)
                        let next = m.range.location + m.range.length
                        search = NSRange(location: next, length: finalLen - next)
                    } else { break }
                }
            }
        }

        // 2. Поиск диапазонов слов, изменённых ИИ-моделью
        let baseForAI = terms ?? raw
        if let base = baseForAI, base != final {
            func clean(_ s: String) -> String {
                s.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
            }

            let baseTokens = base.components(separatedBy: .whitespacesAndNewlines).filter { !clean($0).isEmpty }
            let finalTokens = final.components(separatedBy: .whitespacesAndNewlines).filter { !clean($0).isEmpty }
            let n = baseTokens.count
            let m = finalTokens.count

            if n > 0 && m > 0 {
                var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
                for i in 1...n {
                    for j in 1...m {
                        if clean(baseTokens[i - 1]).lowercased() == clean(finalTokens[j - 1]).lowercased() {
                            dp[i][j] = dp[i - 1][j - 1] + 1
                        } else {
                            dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                        }
                    }
                }

                var i = n, j = m
                var aiWords = Set<String>()
                while i > 0 || j > 0 {
                    if i > 0 && j > 0 && clean(baseTokens[i - 1]).lowercased() == clean(finalTokens[j - 1]).lowercased() {
                        i -= 1; j -= 1
                    } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                        aiWords.insert(clean(finalTokens[j - 1]))
                        j -= 1
                    } else if i > 0 && (j == 0 || dp[i][j - 1] < dp[i - 1][j]) {
                        i -= 1
                    } else { break }
                }

                for w in aiWords where !w.isEmpty {
                    var search = NSRange(location: 0, length: finalLen)
                    while search.location < finalLen {
                        let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: w) + "(?![\\p{L}\\p{N}_])"
                        if let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                           let m = rx.firstMatch(in: final, options: [], range: search) {
                            let overlaps = itRanges.contains { NSIntersectionRange($0, m.range).length > 0 }
                            if !overlaps {
                                aiRanges.append(m.range)
                            }
                            let next = m.range.location + m.range.length
                            search = NSRange(location: next, length: finalLen - next)
                        } else { break }
                    }
                }
            }
        }

        return (itRanges, aiRanges)
    }
}
