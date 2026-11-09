import Foundation

struct TextFormatter {
    private static let cardinalNumbers: [String: Int] = [
        "ноль": 0, "один": 1, "одна": 1, "одно": 1, "два": 2, "две": 2,
        "три": 3, "четыре": 4, "пять": 5, "шесть": 6, "семь": 7,
        "восемь": 8, "девять": 9, "десять": 10, "одиннадцать": 11,
        "двенадцать": 12, "тринадцать": 13, "четырнадцать": 14,
        "пятнадцать": 15, "шестнадцать": 16, "семнадцать": 17,
        "восемнадцать": 18, "девятнадцать": 19, "двадцать": 20,
        "тридцать": 30, "сорок": 40, "пятьдесят": 50, "шестьдесят": 60,
        "семьдесят": 70, "восемьдесят": 80, "девяносто": 90,
        "сто": 100, "двести": 200, "триста": 300, "четыреста": 400,
        "пятьсот": 500, "шестьсот": 600, "семьсот": 700,
        "восемьсот": 800, "девятьсот": 900
    ]

    private static let numberMultipliers: [String: Int] = [
        "тысяча": 1_000, "тысячи": 1_000, "тысяч": 1_000, "тысячу": 1_000,
        "миллион": 1_000_000, "миллиона": 1_000_000, "миллионов": 1_000_000,
        "миллиард": 1_000_000_000, "миллиарда": 1_000_000_000,
        "миллиардов": 1_000_000_000
    ]

    /// Converts unambiguous Russian cardinal phrases to digits.
    /// Call only on the ASR result, never on arbitrary prose. Ordinals are
    /// deliberately not converted because inflection/gender agreement is lossy.
    static func normalizeRussianNumbers(_ text: String) -> String {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return text }
        let allWords = Set(cardinalNumbers.keys).union(numberMultipliers.keys)
        var output: [String] = []
        var index = 0

        while index < tokens.count {
            let normalized = normalizedNumberToken(tokens[index])
            if normalized.word == "ноль" {
                output.append(tokens[index])
                index += 1
                continue
            }
            guard allWords.contains(normalized.word) else {
                output.append(tokens[index])
                index += 1
                continue
            }

            var parts: [String] = []
            var end = index
            while end < tokens.count {
                let candidate = normalizedNumberToken(tokens[end]).word
                guard allWords.contains(candidate) else { break }
                parts.append(candidate)
                end += 1
            }

            // Don't concatenate independent number phrases split by punctuation.
            var numberEnd = end
            if end < tokens.count {
                let lastToken = normalizedNumberToken(tokens[end - 1])
                if !lastToken.suffix.isEmpty, lastToken.suffix.allSatisfy({ $0.isPunctuation }) {
                    numberEnd -= 1
                    parts.removeLast()
                }
            }

            let value = parseRussianNumber(parts)
            // Preserve a standalone zero and avoid transforming malformed or
            // excessively large accidental runs.
            if let value, value > 0, value <= 999_999_999_999 {
                let first = normalizedNumberToken(tokens[index])
                let last = normalizedNumberToken(tokens[numberEnd - 1])
                let endsWithPunctuation = !last.suffix.isEmpty && last.suffix.allSatisfy { $0.isPunctuation }
                output.append(first.prefix + String(value) + (endsWithPunctuation ? last.suffix : ""))
                if !last.suffix.isEmpty && !endsWithPunctuation {
                    output.append(last.suffix)
                }
            } else {
                output.append(contentsOf: tokens[index..<numberEnd])
            }
            index = numberEnd
        }
        let joined = output.joined(separator: " ")
        return joined
    }

    private static func normalizedNumberToken(_ token: String) -> (word: String, prefix: String, suffix: String) {
        let chars = Array(token)
        var start = 0
        var end = chars.count
        while start < end && !chars[start].isLetter && !chars[start].isNumber { start += 1 }
        while end > start && !chars[end - 1].isLetter && !chars[end - 1].isNumber { end -= 1 }
        return (String(chars[start..<end]).lowercased(), String(chars[..<start]), String(chars[end...]))
    }

    private static func parseRussianNumber(_ parts: [String]) -> Int? {
        var total = 0
        var current = 0
        for part in parts {
            if let multiplier = numberMultipliers[part] {
                total += max(current, 1) * multiplier
                current = 0
            } else if let value = cardinalNumbers[part] {
                current += value
            } else {
                return nil
            }
        }
        return total + current
    }

    static func formatIntoParagraphs(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        
        var sentences: [String] = []
        var currentSentence = ""
        
        let chars = Array(text)
        var i = 0
        
        while i < chars.count {
            let char = chars[i]
            currentSentence.append(char)
            
            if char == "." || char == "!" || char == "?" {
                while i + 1 < chars.count && (chars[i + 1] == "»" || chars[i + 1] == "\"" || chars[i + 1] == "”" || chars[i + 1] == "’") {
                    i += 1
                    currentSentence.append(chars[i])
                }
                
                if i + 1 < chars.count && chars[i + 1].isWhitespace {
                    var nextIdx = i + 1
                    while nextIdx < chars.count && chars[nextIdx].isWhitespace {
                        nextIdx += 1
                    }
                    
                    if nextIdx < chars.count {
                        let nextChar = chars[nextIdx]
                        if nextChar.isUppercase || nextChar == "—" || nextChar == "–" || nextChar == "«" || nextChar == "\"" {
                            let trimmed = currentSentence.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty { sentences.append(trimmed) }
                            currentSentence = ""
                        }
                    }
                }
            }
            i += 1
        }
        
        let lastTrimmed = currentSentence.trimmingCharacters(in: .whitespaces)
        if !lastTrimmed.isEmpty {
            sentences.append(lastTrimmed)
        }
        
        var paragraphs: [String] = []
        var currentParagraph: [String] = []
        
        for sentence in sentences {
            let isDialogue = sentence.hasPrefix("—") || sentence.hasPrefix("–") || sentence.hasPrefix("«—") || sentence.contains("— «")
            
            if (isDialogue && !currentParagraph.isEmpty) || currentParagraph.count >= 3 {
                paragraphs.append(currentParagraph.joined(separator: " "))
                currentParagraph = []
            }
            
            currentParagraph.append(sentence)
        }
        
        if !currentParagraph.isEmpty {
            paragraphs.append(currentParagraph.joined(separator: " "))
        }
        
        return paragraphs.joined(separator: "\n\n")
    }
}
