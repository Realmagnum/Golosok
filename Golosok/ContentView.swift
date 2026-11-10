import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum MainTab { case history, dashboard, settings }

struct NoteSelection: Equatable {
    let noteID: UUID
    let range: NSRange
    let screenRect: CGRect
    let fullText: String
    let selectedText: String

    static func == (lhs: NoteSelection, rhs: NoteSelection) -> Bool {
        lhs.noteID == rhs.noteID
            && NSEqualRanges(lhs.range, rhs.range)
            && lhs.screenRect == rhs.screenRect
            && lhs.selectedText == rhs.selectedText
            && lhs.fullText == rhs.fullText
    }
}

struct DateFormattingHelper {
    private static let inputFormatter: DateFormatter = { let df = DateFormatter(); df.dateFormat = "dd.MM.yyyy"; return df }()
    private static let outputFormatter: DateFormatter = { let df = DateFormatter(); df.locale = Locale.current; df.dateFormat = "d MMMM yyyy"; return df }()
    static func formatRussianDate(_ dateStr: String) -> (date: String, time: String) {
        let parts = dateStr.components(separatedBy: ", ")
        let datePart = parts.first ?? dateStr; let timePart = parts.count > 1 ? parts[1] : ""
        if let dateObj = inputFormatter.date(from: datePart) { return (outputFormatter.string(from: dateObj), timePart) }
        return (datePart, timePart)
    }
}

enum TranscriptSearch {
    static func matchedWordIndices(in words: [TimedWord], query: String) -> [Int] {
        guard !query.isEmpty else { return [] }
        let normalizedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
        return words.enumerated().compactMap { (i, w) in
            w.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU")).contains(normalizedQuery) ? i : nil
        }
    }

    static func matchedRanges(in text: String, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let nsText = text as NSString
        var ranges: [NSRange] = []
        var start = 0
        while start < nsText.length {
            let r = nsText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: start, length: nsText.length - start))
            if r.location == NSNotFound { break }
            ranges.append(r)
            start = r.location + max(r.length, 1)
        }
        return ranges
    }
}

struct NativeTextView: NSViewRepresentable {
    let text: String
    var itRanges: [NSRange] = []
    var aiRanges: [NSRange] = []
    var searchRanges: [NSRange] = []
    var currentMatchPosition: Int = -1
    var onSelectionChange: ((NSRange, CGRect?) -> Void)? = nil
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false; textView.isSelectable = true; textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 15, weight: .regular); textView.textColor = NSColor(Color.uiInk)
        textView.textContainerInset = NSSize(width: 0, height: 10)
        textView.unregisterDraggedTypes()
        textView.delegate = context.coordinator
        context.coordinator.onSelectionChange = onSelectionChange
        return scrollView
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        let storage = textView.textStorage

        let textChanged = textView.string != text
        let diffChanged = coordinator.lastITRanges != itRanges || coordinator.lastAIRanges != aiRanges
        if textChanged || diffChanged {
            coordinator.lastITRanges = itRanges
            coordinator.lastAIRanges = aiRanges
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: NSColor(Color.uiInk)
            ])
            let nsLen = (text as NSString).length
            for range in itRanges where range.location != NSNotFound && range.location + range.length <= nsLen {
                attributed.addAttribute(.backgroundColor, value: NSColor.itTermHighlight, range: range)
            }
            for range in aiRanges where range.location != NSNotFound && range.location + range.length <= nsLen {
                attributed.addAttribute(.backgroundColor, value: NSColor.aiReplacedHighlight, range: range)
            }
            storage?.setAttributedString(attributed)
            coordinator.appliedSearchRanges.removeAll()
            coordinator.lastSearchRanges = []
            coordinator.lastMatchPosition = -1
        }
        coordinator.onSelectionChange = onSelectionChange

        let needsReapply = textChanged || diffChanged
            || coordinator.lastSearchRanges != searchRanges
            || coordinator.lastMatchPosition != currentMatchPosition
        guard needsReapply else { return }

        for range in coordinator.appliedSearchRanges where range.location != NSNotFound {
            storage?.removeAttribute(.backgroundColor, range: range)
        }
        coordinator.appliedSearchRanges.removeAll()

        for (pos, range) in searchRanges.enumerated() where range.location != NSNotFound {
            let color: NSColor = (pos == currentMatchPosition) ? .searchCurrentMatch : .searchMatch
            storage?.addAttribute(.backgroundColor, value: color, range: range)
            coordinator.appliedSearchRanges.append(range)
        }
        coordinator.lastSearchRanges = searchRanges
        coordinator.lastMatchPosition = currentMatchPosition

        if !searchRanges.isEmpty, currentMatchPosition >= 0, currentMatchPosition < searchRanges.count {
            let range = searchRanges[currentMatchPosition]
            if range.location != NSNotFound {
                textView.scrollRangeToVisible(range)
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelectionChange: ((NSRange, CGRect?) -> Void)?
        var appliedSearchRanges: [NSRange] = []
        var lastSearchRanges: [NSRange] = []
        var lastMatchPosition: Int = -1
        var lastITRanges: [NSRange] = []
        var lastAIRanges: [NSRange] = []

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let range = tv.selectedRange()
            guard let cb = onSelectionChange else { return }
            if range.location == NSNotFound || range.length == 0 {
                cb(NSRange(location: NSNotFound, length: 0), nil)
                return
            }
            cb(range, Self.selectionScreenRect(in: tv, range: range))
        }

        static func selectionScreenRect(in tv: NSTextView, range: NSRange) -> CGRect? {
            let layoutManager = tv.layoutManager
            let textContainer = tv.textContainer
            guard let lm = layoutManager, let tc = textContainer else { return nil }
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            if glyphRange.length == 0 { return nil }
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let origin = tv.textContainerOrigin
            let rectInView = NSRect(x: rect.origin.x + origin.x,
                                    y: rect.origin.y + origin.y,
                                    width: rect.size.width,
                                    height: rect.size.height)
            let rectInWindow = tv.convert(rectInView, to: nil)
            guard let window = tv.window else { return rectInWindow }
            return window.convertToScreen(rectInWindow)
        }
    }
}

struct SyncedPlayerView: View {
    let text: String
    let words: [TimedWord]
    let audioDuration: Double
    let itemID: UUID
    var itRanges: [NSRange] = []
    var aiRanges: [NSRange] = []
    @ObservedObject var audioCapture = AudioCapture.shared
    var searchMatchWordIndices: [Int] = []
    var currentMatchPosition: Int = -1
    var onSelectionChange: ((NSRange, CGRect?) -> Void)? = nil

    private var isPlaying: Bool {
        audioCapture.playingItemId == itemID && audioCapture.isPlayerPlaying
    }

    private var playhead: Double {
        audioCapture.playingItemId == itemID ? audioCapture.playheadTime : 0
    }

    private var currentWordIndex: Int? {
        guard audioCapture.playingItemId == itemID else { return nil }
        let t = audioCapture.playheadTime
        guard !words.isEmpty else { return nil }
        var lo = 0, hi = words.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if t >= words[mid].start && t < words[mid].end { return mid }
            if t < words[mid].start { hi = mid - 1 } else { lo = mid + 1 }
        }
        if t >= words[words.count - 1].end { return words.count - 1 }
        return lo > 0 ? lo - 1 : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(action: { audioCapture.toggleSyncedPlayback(for: itemID) }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Text(formatTime(playhead))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.uiMidGray)

                UISeekSlider(value: Binding(
                    get: { playhead },
                    set: { audioCapture.seekSynced(to: $0, for: itemID) }
                ), range: 0...max(audioDuration, 0.01))

                Text(formatTime(audioDuration))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.uiMidGray)
            }

            SyncedTextView(text: text, words: words, itRanges: itRanges, aiRanges: aiRanges, currentWordIndex: currentWordIndex,
                           searchMatchWordIndices: searchMatchWordIndices,
                           currentMatchPosition: currentMatchPosition,
                           onSelectionChange: onSelectionChange) { time in
                audioCapture.seekSynced(to: time, for: itemID)
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct SyncedTextView: NSViewRepresentable {
    let text: String
    let words: [TimedWord]
    var itRanges: [NSRange] = []
    var aiRanges: [NSRange] = []
    let currentWordIndex: Int?
    var searchMatchWordIndices: [Int] = []
    var currentMatchPosition: Int = -1
    var onSelectionChange: ((NSRange, CGRect?) -> Void)? = nil
    let onSeek: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSeek: onSeek) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        textView.textColor = NSColor(Color.uiInk)
        textView.textContainerInset = NSSize(width: 0, height: 10)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor(Color.uiInk),
            .underlineStyle: 0,
            .cursor: NSCursor.pointingHand
        ]
        textView.delegate = context.coordinator
        textView.unregisterDraggedTypes()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.onSeek = onSeek
        coordinator.onSelectionChange = onSelectionChange
        coordinator.itRanges = itRanges
        coordinator.aiRanges = aiRanges

        let diffChanged = coordinator.lastITRanges != itRanges || coordinator.lastAIRanges != aiRanges
        let textChanged = coordinator.cachedText != text || coordinator.cachedWords != words || diffChanged
        if textChanged {
            coordinator.lastITRanges = itRanges
            coordinator.lastAIRanges = aiRanges
            coordinator.cachedText = text
            coordinator.cachedWords = words
            coordinator.cachedRanges = coordinator.wordRanges(text: text, words: words)
            coordinator.highlightedIndex = nil
            coordinator.lastScrolledIndex = nil
            coordinator.yellowedWordIndices.removeAll()

            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: NSColor(Color.uiInk)
            ])
            for (i, range) in coordinator.cachedRanges.enumerated() where i < words.count && range.location != NSNotFound {
                let url = URL(string: "golosok://seek/\(words[i].start)")
                attributed.addAttribute(.link, value: url as Any, range: range)
                attributed.addAttribute(.underlineStyle, value: 0, range: range)
            }
            let nsLen = (text as NSString).length
            for range in itRanges where range.location != NSNotFound && range.location + range.length <= nsLen {
                attributed.addAttribute(.backgroundColor, value: NSColor.itTermHighlight, range: range)
            }
            for range in aiRanges where range.location != NSNotFound && range.location + range.length <= nsLen {
                attributed.addAttribute(.backgroundColor, value: NSColor.aiReplacedHighlight, range: range)
            }
            textView.textStorage?.setAttributedString(attributed)
        }

        let searchChanged = textChanged || coordinator.searchMatchWordIndices != searchMatchWordIndices
        let matchPosChanged = coordinator.currentMatchPosition != currentMatchPosition

        if searchChanged {
            coordinator.searchMatchWordIndices = searchMatchWordIndices
            coordinator.searchMatchSet = Set(searchMatchWordIndices)
            coordinator.searchMatchPositionMap = Dictionary(searchMatchWordIndices.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        }
        coordinator.currentMatchPosition = currentMatchPosition

        let needsSearchRefresh = searchChanged || (matchPosChanged && !searchMatchWordIndices.isEmpty)
        if needsSearchRefresh {
            coordinator.applySearchHighlights(in: textView)
            if searchChanged && searchMatchWordIndices.isEmpty {
                coordinator.lastScrolledIndex = nil
            }
        }

        coordinator.applyHighlight(in: textView, currentWordIndex: currentWordIndex)

        let isSearchActive = !searchMatchWordIndices.isEmpty
        if !isSearchActive, let index = currentWordIndex, index != coordinator.lastScrolledIndex, index < coordinator.cachedRanges.count {
            let range = coordinator.cachedRanges[index]
            if range.location != NSNotFound {
                textView.scrollRangeToVisible(range)
                coordinator.lastScrolledIndex = index
            }
        }

        if isSearchActive, !searchMatchWordIndices.isEmpty, currentMatchPosition >= 0, currentMatchPosition < searchMatchWordIndices.count,
           (searchChanged || matchPosChanged) {
            let wordIdx = searchMatchWordIndices[currentMatchPosition]
            if wordIdx < coordinator.cachedRanges.count {
                let range = coordinator.cachedRanges[wordIdx]
                if range.location != NSNotFound {
                    textView.scrollRangeToVisible(range)
                    coordinator.lastScrolledIndex = wordIdx
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSeek: (Double) -> Void
        var onSelectionChange: ((NSRange, CGRect?) -> Void)?
        var cachedText: String?
        var cachedWords: [TimedWord]?
        var cachedRanges: [NSRange] = []
        var highlightedIndex: Int?
        var lastScrolledIndex: Int?
        var searchMatchWordIndices: [Int] = []
        var searchMatchSet: Set<Int> = []
        var searchMatchPositionMap: [Int: Int] = [:]
        var currentMatchPosition: Int = -1
        var yellowedWordIndices: Set<Int> = []
        var itRanges: [NSRange] = []
        var aiRanges: [NSRange] = []
        var lastITRanges: [NSRange] = []
        var lastAIRanges: [NSRange] = []

        init(onSeek: @escaping (Double) -> Void) { self.onSeek = onSeek }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView, let cb = onSelectionChange else { return }
            let range = tv.selectedRange()
            if range.location == NSNotFound || range.length == 0 {
                cb(NSRange(location: NSNotFound, length: 0), nil)
                return
            }
            cb(range, NativeTextView.Coordinator.selectionScreenRect(in: tv, range: range))
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == "golosok",
                  let time = Double(url.lastPathComponent) else { return false }
            onSeek(time)
            return true
        }

        func baseColor(for range: NSRange) -> NSColor? {
            if itRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                return NSColor.itTermHighlight
            }
            if aiRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                return NSColor.aiReplacedHighlight
            }
            return nil
        }

        func applyHighlight(in textView: NSTextView, currentWordIndex: Int?) {
            let storage = textView.textStorage
            if let prev = highlightedIndex, prev != currentWordIndex, prev < cachedRanges.count {
                let range = cachedRanges[prev]
                if range.location != NSNotFound {
                    storage?.removeAttribute(.backgroundColor, range: range)
                    if searchMatchSet.contains(prev) {
                        let color: NSColor = (searchMatchPositionMap[prev] == currentMatchPosition) ? .searchCurrentMatch : .searchMatch
                        storage?.addAttribute(.backgroundColor, value: color, range: range)
                        yellowedWordIndices.insert(prev)
                    } else if let base = baseColor(for: range) {
                        storage?.addAttribute(.backgroundColor, value: base, range: range)
                    }
                }
            }
            highlightedIndex = currentWordIndex
            if let index = currentWordIndex, index < cachedRanges.count {
                let range = cachedRanges[index]
                if range.location != NSNotFound {
                    storage?.addAttribute(.backgroundColor, value: NSColor.transcriptHighlight, range: range)
                    yellowedWordIndices.remove(index)
                }
            }
        }

        func applySearchHighlights(in textView: NSTextView) {
            let storage = textView.textStorage
            for wordIdx in yellowedWordIndices {
                guard wordIdx < cachedRanges.count else { continue }
                let range = cachedRanges[wordIdx]
                if range.location != NSNotFound {
                    storage?.removeAttribute(.backgroundColor, range: range)
                }
            }
            yellowedWordIndices.removeAll()
            for (pos, wordIdx) in searchMatchWordIndices.enumerated() {
                guard wordIdx < cachedRanges.count else { continue }
                let range = cachedRanges[wordIdx]
                guard range.location != NSNotFound else { continue }
                if wordIdx == highlightedIndex { continue }
                let color: NSColor = (pos == currentMatchPosition) ? .searchCurrentMatch : .searchMatch
                storage?.addAttribute(.backgroundColor, value: color, range: range)
                yellowedWordIndices.insert(wordIdx)
            }
        }

        func wordRanges(text: String, words: [TimedWord]) -> [NSRange] {
            guard !words.isEmpty, !text.isEmpty else { return [] }
            let nsText = text as NSString
            let length = nsText.length

            func isWhitespace(_ c: unichar) -> Bool {
                CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(c) ?? " ")
            }
            func normalized(_ s: String) -> String {
                s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
                    .filter { $0.isLetter || $0.isNumber }
                    .lowercased()
            }

            var tokens: [NSRange] = []
            var scan = 0
            while scan < length {
                if isWhitespace(nsText.character(at: scan)) { scan += 1; continue }
                let start = scan
                while scan < length && !isWhitespace(nsText.character(at: scan)) { scan += 1 }
                tokens.append(NSRange(location: start, length: scan - start))
            }
            guard !tokens.isEmpty else { return [] }

            let n = words.count
            let m = tokens.count

            // Fast path: exact positional alignment.
            var pos = 0
            var strict = true
            for w in words {
                let word = w.text
                while pos < length && isWhitespace(nsText.character(at: pos)) { pos += 1 }
                guard pos < length else { strict = false; break }
                let found = nsText.range(of: word, options: [], range: NSRange(location: pos, length: length - pos))
                if found.location != pos { strict = false; break }
                pos += found.length
            }
            if strict {
                var ranges: [NSRange] = []
                pos = 0
                for w in words {
                    while pos < length && isWhitespace(nsText.character(at: pos)) { pos += 1 }
                    let word = w.text as NSString
                    ranges.append(NSRange(location: pos, length: word.length))
                    pos += word.length
                }
                return ranges
            }

            // Robust path: longest-common-subsequence alignment on normalized tokens.
            let textNorm = tokens.map { normalized(nsText.substring(with: $0)) }
            let wordNorm = words.map { normalized($0.text) }
            let maxCells = 5_000_000
            if n * m <= maxCells {
                var dp = [[Int16]](repeating: [Int16](repeating: 0, count: m + 1), count: n + 1)
                var back = [[Int8]](repeating: [Int8](repeating: 0, count: m + 1), count: n + 1)
                for a in stride(from: n - 1, through: 0, by: -1) {
                    for b in stride(from: m - 1, through: 0, by: -1) {
                        let wn = wordNorm[a]
                        if !wn.isEmpty && wn == textNorm[b] {
                            dp[a][b] = dp[a + 1][b + 1] + 1
                            back[a][b] = 1
                        } else if dp[a + 1][b] >= dp[a][b + 1] {
                            dp[a][b] = dp[a + 1][b]
                            back[a][b] = 2
                        } else {
                            dp[a][b] = dp[a][b + 1]
                            back[a][b] = 3
                        }
                    }
                }
                var ranges = [NSRange](repeating: NSRange(location: NSNotFound, length: 0), count: n)
                var a = 0, b = 0
                while a < n && b < m {
                    if back[a][b] == 1 { ranges[a] = tokens[b]; a += 1; b += 1 }
                    else if back[a][b] == 2 { a += 1 }
                    else { b += 1 }
                }
                Self.interpolateUnalignedGaps(ranges: &ranges, tokens: tokens, n: n, m: m)
                return ranges
            }

            // Greedy fallback for very large texts.
            var ranges = [NSRange](repeating: NSRange(location: NSNotFound, length: 0), count: n)
            pos = 0
            for (k, w) in words.enumerated() {
                let word = w.text
                guard !word.isEmpty else { continue }
                while pos < length && isWhitespace(nsText.character(at: pos)) { pos += 1 }
                guard pos < length else { break }
                let rest = NSRange(location: pos, length: length - pos)
                if nsText.range(of: word, options: [], range: rest).location == pos {
                    ranges[k] = NSRange(location: pos, length: (word as NSString).length)
                    pos += (word as NSString).length
                } else if nsText.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: rest).location == pos {
                    ranges[k] = NSRange(location: pos, length: (word as NSString).length)
                    pos += (word as NSString).length
                }
            }
            Self.interpolateUnalignedGaps(ranges: &ranges, tokens: tokens, n: n, m: m)
            return ranges
        }

        private static func interpolateUnalignedGaps(ranges: inout [NSRange], tokens: [NSRange], n: Int, m: Int) {
            guard !tokens.isEmpty else { return }
            var lastB = -1
            var lastA = -1
            for a in 0..<n {
                if ranges[a].location != NSNotFound {
                    if let b = tokens.firstIndex(where: { $0.location == ranges[a].location }) {
                        let gapAStart = lastA + 1
                        let gapAEnd = a - 1
                        let gapBStart = lastB + 1
                        let gapBEnd = b - 1
                        if gapAStart <= gapAEnd {
                            if gapBStart <= gapBEnd {
                                for curA in gapAStart...gapAEnd {
                                    let ratio = Double(curA - gapAStart) / Double(max(1, gapAEnd - gapAStart + 1))
                                    let targetB = gapBStart + Int(ratio * Double(gapBEnd - gapBStart + 1))
                                    let clampedB = min(max(targetB, gapBStart), gapBEnd)
                                    ranges[curA] = tokens[clampedB]
                                }
                            } else {
                                let fallbackB = b < tokens.count ? b : max(0, lastB)
                                if fallbackB >= 0 && fallbackB < tokens.count {
                                    for curA in gapAStart...gapAEnd {
                                        ranges[curA] = tokens[fallbackB]
                                    }
                                }
                            }
                        }
                        lastB = b
                        lastA = a
                    }
                }
            }
            if lastA < n - 1 {
                let gapAStart = lastA + 1
                let gapAEnd = n - 1
                let gapBStart = lastB + 1
                let gapBEnd = tokens.count - 1
                for curA in gapAStart...gapAEnd {
                    if gapBStart <= gapBEnd {
                        let ratio = Double(curA - gapAStart) / Double(max(1, gapAEnd - gapAStart + 1))
                        let targetB = gapBStart + Int(ratio * Double(gapBEnd - gapBStart + 1))
                        let clampedB = min(max(targetB, gapBStart), gapBEnd)
                        ranges[curA] = tokens[clampedB]
                    } else if lastB >= 0 && lastB < tokens.count {
                        ranges[curA] = tokens[lastB]
                    }
                }
            }
            for a in 0..<n {
                if ranges[a].location == NSNotFound, let firstValid = ranges.first(where: { $0.location != NSNotFound }) {
                    ranges[a] = firstValid
                }
            }
        }
    }
}

struct StagePickerMenuButton: View {
    @Binding var textStageMode: DisplayedTextStage
    var note: TranscriptionItem? = nil

    private var hasChanges: Bool {
        guard let note = note, let raw = note.rawText else { return false }
        return raw != note.text || (note.termsText != nil && note.termsText != note.text)
    }

    var body: some View {
        UIDropdownMenu(items: [
            .action((textStageMode == .final ? "✓ " : "  ") + String(localized: "Итоговый текст")) {
                withAnimation(.easeInOut(duration: 0.15)) { textStageMode = .final }
            },
            .action((textStageMode == .terms ? "✓ " : "  ") + String(localized: "После IT-словаря")) {
                withAnimation(.easeInOut(duration: 0.15)) { textStageMode = .terms }
            },
            .action((textStageMode == .raw ? "✓ " : "  ") + String(localized: "Сырой ASR (до обработки)")) {
                withAnimation(.easeInOut(duration: 0.15)) { textStageMode = .raw }
            }
        ]) {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                Text(textStageMode == .final ? LocalizedStringKey("Этапы") : LocalizedStringKey(textStageMode.rawValue))
                    .font(UIStyleFont.body(size: 13, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.uiMidGray)
            }
            .foregroundColor(textStageMode == .final ? .uiInk : .orange)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(textStageMode == .final ? Color.uiPaper : Color.orange.opacity(0.12))
            .cornerRadius(18)
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(textStageMode == .final ? Color.uiHairline : Color.orange.opacity(0.4), lineWidth: 1))
        }
        .fixedSize(horizontal: true, vertical: false)
        .help(hasChanges ? "Просмотр исходного сырого текста ASR и промежуточных этапов обработки" : "Сырой текст ASR и результат обработки идентичны")
    }
}

struct NoteAIMenuButton: View {
    let note: TranscriptionItem
    @ObservedObject var promptStore = PromptStore.shared
    @Binding var aiRequest: AIActionRequest?
    @Binding var showCreatePrompt: Bool
    @Binding var showPromptManager: Bool

    var body: some View {
        UIDropdownMenu(items: {
            var arr: [UIDropdownItem] = promptStore.actionTemplates.map { t in
                let isBuiltin = AIPromptDefaults.builtinIDs.contains(t.id)
                let label: Text = (!t.isCustom || isBuiltin) ? Text(LocalizedStringKey(t.title)) : Text(t.title)
                return .action(text: label, icon: t.icon) {
                    aiRequest = AIActionRequest(template: t, noteID: note.id, noteText: note.text)
                }
            }
            arr.append(.divider)
            arr.append(.action(LocalizedStringKey("Новый промпт…"), icon: "plus") { showCreatePrompt = true })
            arr.append(.action(LocalizedStringKey("Управлять промптами…"), icon: "slider.horizontal.3") { showPromptManager = true })
            return arr
        }()) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .medium))
                Text(LocalizedStringKey("ИИ")).font(UIStyleFont.body(size: 13, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundColor(.uiMidGray)
            }
            .lineLimit(1).foregroundColor(.uiInk).padding(.vertical, 8).padding(.horizontal, 14).background(Color.uiPaper).cornerRadius(18).overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.uiHairline, lineWidth: 1))
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct NoteExportMenuButton: View {
    let note: TranscriptionItem
    @ObservedObject var audioCapture = AudioCapture.shared

    var body: some View {
        UIDropdownMenu(items: [
            .action("Markdown (.md)") { audioCapture.exportTranscription(note, format: "md") },
            .action("Текст (.txt)") { audioCapture.exportTranscription(note, format: "txt") },
            .action("Excel (.csv)") { audioCapture.exportTranscription(note, format: "csv") },
            .action("JSON (.json)") { audioCapture.exportTranscription(note, format: "json") },
            .divider,
            .action("Субтитры (.srt)") { audioCapture.exportTranscription(note, format: "srt") },
            .action("Субтитры (.vtt)") { audioCapture.exportTranscription(note, format: "vtt") }
        ]) {
            HStack(spacing: 4) { Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .medium)); Text(LocalizedStringKey("Экспорт")).font(UIStyleFont.body(size: 13, weight: .medium)); Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundColor(.uiMidGray) }
            .lineLimit(1).foregroundColor(.uiInk).padding(.vertical, 8).padding(.horizontal, 14).background(Color.uiPaper).cornerRadius(18).overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.uiHairline, lineWidth: 1))
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

enum DisplayedTextStage: String, CaseIterable {
    case final = "Итоговый"
    case terms = "После словаря"
    case raw = "Сырой ASR"
}

struct ContentView: View {
    @ObservedObject var audioCapture = AudioCapture.shared
    @ObservedObject var permissions = PermissionManager.shared
    @ObservedObject var promptStore = PromptStore.shared
    
    @State private var isSplashFinished = false
    @State private var currentTab: MainTab = .history
    @State private var selectedItemId: UUID?
    @State private var showOnboarding = false
    
    @State private var searchText = ""
    @State private var filteredResults: [TranscriptionItem] = []
    @State private var searchDebounce: DispatchWorkItem?
    @State private var isSearching = false
    @State private var itemToDelete: UUID?
    @State private var showingDeleteAlert = false
    @State private var selectedTimings: (words: [TimedWord], duration: Double)?
    @State private var textStageMode: DisplayedTextStage = .final
    
    @State private var showAboutSheet = false
    @State private var isFileDropTargeted = false
    @State private var aiRequest: AIActionRequest?
    @State private var showPromptManager = false
    @State private var showCreatePrompt = false

    @State private var isEditing: Bool = false
    @State private var editableText: String = ""
    @State private var editingItemID: UUID?
    @State private var editSaveWorkItem: DispatchWorkItem?
    @State private var currentSelection: NoteSelection?

    @State private var isSearchBarVisible: Bool = false
    @State private var transcriptSearchText: String = ""
    @State private var currentMatchPosition: Int = 0
    @State private var cachedSyncedMatchIndices: [Int] = []
    @State private var cachedNativeMatchRanges: [NSRange] = []
    @FocusState private var isSearchFieldFocused: Bool
    @FocusState private var isSidebarSearchFocused: Bool
    
    private var displayedHistory: [TranscriptionItem] {
        searchText.isEmpty ? audioCapture.history : filteredResults
    }

    private func displayedText(for item: TranscriptionItem) -> String {
        switch textStageMode {
        case .raw:
            return item.rawText ?? item.text
        case .terms:
            return item.termsText ?? item.text
        case .final:
            return item.text
        }
    }

    private func diffRanges(for item: TranscriptionItem) -> (itRanges: [NSRange], aiRanges: [NSRange]) {
        switch textStageMode {
        case .raw:
            return ([], [])
        case .terms:
            let termsText = item.termsText ?? item.text
            let res = NoteDiffHighlighter.highlightRanges(raw: item.rawText, terms: nil, final: termsText)
            return (itRanges: res.itRanges, aiRanges: [])
        case .final:
            return NoteDiffHighlighter.highlightRanges(raw: item.rawText, terms: item.termsText, final: item.text)
        }
    }
    
    var body: some View {
        ZStack {
            if !isSplashFinished {
                SplashView(isFinished: $isSplashFinished).transition(.opacity).zIndex(2)
            } else {
                Group {
                    if !permissions.onboardingCompleted { OnboardingView(isPresented: $showOnboarding) }
                    else { mainInterface }
                }
                .transition(.opacity).onAppear { permissions.checkPermissions() }
            }
        }
        // Автоматическое открытие заметки
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AutoSelectNote"))) { notification in
            if audioCapture.autoOpenNoteEnabled, let newId = notification.object as? UUID {
                withAnimation {
                    self.currentTab = .history
                    self.searchText = ""
                    self.selectedItemId = newId
                }
                audioCapture.markAsRead(id: newId)
            }
        }
        .sheet(isPresented: $showAboutSheet) {
            AboutView()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenAboutModal"))) { _ in
            showAboutSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            audioCapture.checkUpdates()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ToggleTranscriptSearch"))) { _ in
            toggleSearchBar()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NoteTimingsUpdated"))) { notification in
            if let updatedId = notification.object as? UUID, updatedId == selectedItemId {
                loadSelectedTimings()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FindNextInTranscript"))) { _ in
            goToMatch(offset: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FindPreviousInTranscript"))) { _ in
            goToMatch(offset: -1)
        }
        .onChange(of: transcriptSearchText) { _ in
            recomputeSearchMatches()
        }
        .background(
            Button("CloseSearch") {
                if isSearchBarVisible {
                    closeSearchBar()
                } else if isSidebarSearchFocused {
                    isSidebarSearchFocused = false
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            }
                .keyboardShortcut(.escape)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
        .background(
            KeyMonitorView { event in
                handleKeyDown(event)
            }
            .frame(width: 0, height: 0)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $isFileDropTargeted) { providers in
            handleDroppedProviders(providers)
        }
        .onChange(of: searchText) { newValue in
            scheduleSearch(newValue)
        }
        .overlay {
            if isFileDropTargeted {
                FileDropOverlay()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: isFileDropTargeted)
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        let fileType = UTType.fileURL.identifier
        let loaders = providers.filter { $0.hasItemConformingToTypeIdentifier(fileType) }
        guard !loaders.isEmpty else { return false }
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in loaders {
            group.enter()
            provider.loadItem(forTypeIdentifier: fileType, options: nil) { item, _ in
                defer { group.leave() }
                if let url = item as? URL {
                    urls.append(url)
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                } else if let str = item as? String, let url = URL(string: str) {
                    urls.append(url)
                }
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { audioCapture.importFiles(urls) }
        }
        return true
    }

    private func scheduleSearch(_ query: String) {
        searchDebounce?.cancel()
        if query.isEmpty {
            withAnimation(.easeOut(duration: 0.16)) {
                isSearching = false
                filteredResults = []
            }
            return
        }
        withAnimation(.easeOut(duration: 0.16)) {
            isSearching = true
        }
        let item = DispatchWorkItem {
            self.performSearch(query)
        }
        searchDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: item)
    }

    private func performSearch(_ query: String) {
        let history = audioCapture.history
        DispatchQueue.global(qos: .userInitiated).async {
            let results = history.filter {
                $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            DispatchQueue.main.async {
                guard self.searchText == query else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    self.filteredResults = results
                    self.isSearching = false
                }
            }
        }
    }
    
    var mainInterface: some View {
        HStack(spacing: 0) {
            sidebarView
            Divider().background(Color.uiHairline)
            Group {
                switch currentTab {
                case .history: historyDetailView
                case .dashboard: DashboardView()
                case .settings: SettingsView()
                }
            }
        }.frame(minWidth: 840, minHeight: 520)
    }
    
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 16) {
            sidebarHeader
            VStack(spacing: 4) {
                SidebarTabButton(title: "История", icon: "clock.fill", isActive: currentTab == .history) {
                    currentTab = .history
                    selectedItemId = nil
                }
                SidebarTabButton(title: "Борд", icon: "chart.bar.fill", isActive: currentTab == .dashboard) {
                    currentTab = .dashboard
                    searchText = ""
                }
                SidebarTabButton(title: "Настройки", icon: "gearshape.fill", isActive: currentTab == .settings) {
                    currentTab = .settings
                    searchText = ""
                }
            }
            .padding(.horizontal, 8)
            Divider().background(Color.uiHairline)
            if currentTab == .history { historySearchAndList } else { Spacer() }
            sidebarFooter
        }.frame(width: 270).background(Color.uiSidebar)
    }
    
    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Image("AppLogo").resizable().aspectRatio(contentMode: .fit).frame(width: 22, height: 22).cornerRadius(4)
            VStack(alignment: .leading, spacing: -2) {
                Text("Голосок").font(UIStyleFont.display(size: 16, weight: .bold)).foregroundColor(.uiInk)
                HStack(spacing: 4) {
                    let versionStr = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                    Text(versionStr).font(UIStyleFont.body(size: 10, weight: .medium)).foregroundColor(.uiMidGray)
                }
            }
            Spacer()
        }.padding(.horizontal, 16).padding(.top, 16)
    }
    
    private var historySearchAndList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack {
                    if isSearching {
                        ProgressView().controlSize(.small)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    } else {
                        Image(systemName: "magnifyingglass").foregroundColor(.uiMidGray)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                    TextField("Поиск...", text: $searchText)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(UIStyleFont.body(size: 13, weight: .regular))
                        .foregroundColor(.uiInk)
                        .focused($isSidebarSearchFocused)
                    if !searchText.isEmpty { Button(action: { searchText = "" }) { Image(systemName: "xmark.circle.fill").foregroundColor(.uiMidGray) }.buttonStyle(.plain) }
                }
                .padding(8).background(Color.uiPaper).cornerRadius(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))
                Button(action: createNote) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.uiInk)
                        .frame(width: 30, height: 30)
                        .background(Color.uiPaper)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))
                }
                .buttonStyle(TactileButtonStyle())
                .help(String(localized: "Новая заметка"))
            }.padding(.horizontal, 12).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if isSearching {
                            ForEach(0..<4, id: \.self) { _ in
                                HistorySkeletonCard()
                            }
                        } else if displayedHistory.isEmpty {
                            Text(searchText.isEmpty ? LocalizedStringKey("История пуста") : LocalizedStringKey("Ничего не найдено")).font(UIStyleFont.body(size: 13, weight: .regular)).foregroundColor(.uiMidGray).padding(.vertical, 20)
                        } else {
                            ForEach(displayedHistory) { item in
                                Button {
                                    isSidebarSearchFocused = false
                                    selectNote(item)
                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                } label: {
                                    HistoryCard(item: item, isSelected: selectedItemId == item.id)
                                }
                                .buttonStyle(TactileButtonStyle())
                                .id(item.id)
                            }
                        }
                    }.padding(.horizontal, 8)
                }
                .onChange(of: selectedItemId) { newId in
                    if let id = newId {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(id, anchor: nil)
                        }
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: isSearching)
    }
    
    private var sidebarFooter: some View {
        HStack {
            Circle().fill(audioCapture.isRecording ? Color.uiEmber : Color.green).frame(width: 8, height: 8)
            Text(audioCapture.isRecording ? LocalizedStringKey("Запись...") : LocalizedStringKey("Готов к работе")).font(UIStyleFont.body(size: 12, weight: .regular)).foregroundColor(.uiMidGray)
        }.padding(.horizontal, 16).padding(.bottom, 16)
    }
    
    var historyDetailView: some View {
        ZStack {
            Color.uiCanvas.ignoresSafeArea()
            VStack {
                if let selected = audioCapture.history.first(where: { $0.id == selectedItemId }) {
                    UICard {
                        VStack(alignment: .leading, spacing: 16) {
                            let formattedDate = DateFormattingHelper.formatRussianDate(selected.date)
                            let dateHeader: () -> AnyView = {
                                AnyView(
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(formattedDate.date).font(UIStyleFont.display(size: 16, weight: .bold)).foregroundColor(.uiInk).lineLimit(1)
                                        if !formattedDate.time.isEmpty { Text(formattedDate.time).font(UIStyleFont.body(size: 11, weight: .medium)).foregroundColor(.uiMidGray).padding(.horizontal, 6).padding(.vertical, 2).background(Color.uiCanvas).cornerRadius(6) }
                                    }
                                )
                            }
                            let buttonsRow: () -> AnyView = {
                                AnyView(
                                    HStack(spacing: 8) {
                                        StagePickerMenuButton(textStageMode: $textStageMode, note: selected)
                                        CopyFeedbackButton(textToCopy: displayedText(for: selected))
                                        EditToggleButton(isEditing: isEditing) {
                                            if isEditing { commitEditing(for: selected) } else { beginEditing(selected) }
                                        }
                                        if audioCapture.hasAudioFile(for: selected) {
                                            UIOutlineButton(title: "Распознать заново") {
                                                audioCapture.retranscribeNote(id: selected.id) { success in
                                                    if success, let updated = audioCapture.history.first(where: { $0.id == selected.id }) {
                                                        editableText = updated.text
                                                        loadSelectedTimings()
                                                    }
                                                }
                                            }
                                        }
                                        NoteAIMenuButton(
                                            note: selected,
                                            promptStore: promptStore,
                                            aiRequest: $aiRequest,
                                            showCreatePrompt: $showCreatePrompt,
                                            showPromptManager: $showPromptManager
                                        )
                                        NoteExportMenuButton(note: selected, audioCapture: audioCapture)
                                        UIDestructiveButton(title: "Удалить") { itemToDelete = selected.id; showingDeleteAlert = true }
                                    }.fixedSize(horizontal: true, vertical: false).layoutPriority(1)
                                )
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .center) {
                                    dateHeader()
                                    Spacer(minLength: 12)
                                    buttonsRow()
                                }
                                VStack(alignment: .leading, spacing: 10) {
                                    dateHeader()
                                    HStack {
                                        Spacer(minLength: 0)
                                        buttonsRow()
                                    }
                                }
                            }
                            
                            let diff = diffRanges(for: selected)
                            HStack(spacing: 8) {
                                if selected.isAITransform == true || selected.duration == "AI" {
                                    MetadataPill(icon: "sparkles", text: String(localized: "History.AI"), color: Color(hex: "#A855F7"))
                                } else {
                                    MetadataPill(icon: "waveform", text: selected.duration, color: Color.blue)
                                    MetadataPill(icon: "bolt.fill", text: selected.formattedSpeedup, color: Color.orange)
                                }
                                MetadataPill(icon: "text.alignleft", text: "\(selected.text.count) " + String(localized: "зн"), color: Color(hex: "#10B981"))
                                let readMin = max(1, selected.text.count / 900)
                                MetadataPill(icon: "book.fill", text: "~\(readMin) " + String(localized: "мин чтения"), color: Color.purple)

                                if !diff.itRanges.isEmpty {
                                    HStack(spacing: 4) {
                                        Circle().fill(Color(hex: "#10B981")).frame(width: 6, height: 6)
                                        Text(LocalizedStringKey("IT-термин"))
                                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                                            .foregroundColor(Color(hex: "#10B981"))
                                    }
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color(hex: "#10B981").opacity(0.12))
                                    .cornerRadius(6)
                                }
                                if !diff.aiRanges.isEmpty {
                                    HStack(spacing: 4) {
                                        Circle().fill(Color(hex: "#8B5CF6")).frame(width: 6, height: 6)
                                        Text(LocalizedStringKey("ИИ-правка"))
                                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                                            .foregroundColor(Color(hex: "#8B5CF6"))
                                    }
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color(hex: "#8B5CF6").opacity(0.12))
                                    .cornerRadius(6)
                                }

                                if selectedTimings == nil && audioCapture.hasAudioFile(for: selected) {
                                    Button(action: { audioCapture.toggleAudioPlayback(for: selected) }) {
                                        HStack(spacing: 4) { Image(systemName: audioCapture.playingItemId == selected.id ? "pause.fill" : "play.fill").font(.system(size: 9, weight: .bold)); Text(audioCapture.playingItemId == selected.id ? LocalizedStringKey("Пауза") : LocalizedStringKey("Слушать голос")).font(.system(size: 10, weight: .bold, design: .rounded)) }
                                        .foregroundColor(.blue).padding(.horizontal, 8).padding(.vertical, 4).background(Color.blue.opacity(0.12)).cornerRadius(6)
                                    }.buttonStyle(.plain)
                                }
                                Spacer(minLength: 8)
                                if !isEditing && !isSearchBarVisible {
                                    Button(action: toggleSearchBar) {
                                        HStack(spacing: 5) {
                                            Image(systemName: "magnifyingglass")
                                                .font(.system(size: 9, weight: .semibold))
                                            Text(LocalizedStringKey("Поиск"))
                                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                            Text("⌘F")
                                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                                .foregroundColor(.uiMidGray)
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(Color.uiCanvas)
                                                .cornerRadius(4)
                                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.uiHairline, lineWidth: 0.5))
                                        }
                                        .foregroundColor(.uiMidGray)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(String(localized: "Поиск по стенограмме (⌘F)"))
                                }
                            }
                            
                            Divider().background(Color.uiHairline).padding(.vertical, 4)
                            if isSearchBarVisible && !isEditing {
                                transcriptSearchBar
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                            if textStageMode != .final {
                                let activeStageText = displayedText(for: selected)
                                let isIdentical = (activeStageText == selected.text)
                                HStack(spacing: 8) {
                                    Image(systemName: "eye.fill")
                                        .foregroundColor(isIdentical ? .uiMidGray : .orange)
                                    Text(isIdentical
                                         ? (textStageMode == .raw
                                            ? String(localized: "Просмотр: Сырой текст голосовой модели (совпадает с итоговым, замен не было)")
                                            : String(localized: "Просмотр: Текст после словаря (совпадает с итоговым, замен не было)"))
                                         : (textStageMode == .raw
                                            ? String(localized: "Просмотр: Сырой текст голосовой модели (до обработки словарём и ИИ)")
                                            : String(localized: "Просмотр: Текст после словаря IT-терминов (до обработки ИИ-шаблоном)")))
                                        .font(UIStyleFont.body(size: 12, weight: .medium))
                                        .foregroundColor(isIdentical ? .uiMidGray : .uiInk)
                                    Spacer()
                                    Button(action: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            textStageMode = .final
                                        }
                                    }) {
                                        Text(LocalizedStringKey("Вернуться к итоговому"))
                                            .font(UIStyleFont.body(size: 11, weight: .semibold))
                                            .foregroundColor(.blue)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(isIdentical ? Color.uiCanvas : Color.orange.opacity(0.12))
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(isIdentical ? Color.uiHairline : Color.orange.opacity(0.25), lineWidth: 1))
                                .padding(.bottom, 4)
                            }

                            let activeText = displayedText(for: selected)
                            let effectiveDiff = diff

                            if isEditing {
                                ZStack(alignment: .topLeading) {
                                    EditableTextView(text: $editableText) { _ in
                                        if let id = selectedItemId { scheduleEditSave(for: id) }
                                    }
                                    if editableText.isEmpty {
                                        Text("Начните вводить текст…")
                                            .font(UIStyleFont.body(size: 15, weight: .regular))
                                            .foregroundColor(.uiMidGray.opacity(0.55))
                                            .padding(.top, 10)
                                            .padding(.leading, 5)
                                            .allowsHitTesting(false)
                                    }
                                }
                            } else if let timings = selectedTimings, textStageMode == .final || textStageMode == .terms {
                                SyncedPlayerView(text: activeText, words: timings.words, audioDuration: timings.duration, itemID: selected.id,
                                                 itRanges: effectiveDiff.itRanges,
                                                 aiRanges: effectiveDiff.aiRanges,
                                                 searchMatchWordIndices: cachedSyncedMatchIndices,
                                                 currentMatchPosition: cachedSyncedMatchIndices.isEmpty ? -1 : currentMatchPosition,
                                                 onSelectionChange: { range, rect in
                                    handleNoteSelectionChange(range: range, screenRect: rect)
                                })
                            } else {
                                NativeTextView(text: activeText,
                                               itRanges: effectiveDiff.itRanges,
                                               aiRanges: effectiveDiff.aiRanges,
                                               searchRanges: cachedNativeMatchRanges,
                                               currentMatchPosition: cachedNativeMatchRanges.isEmpty ? -1 : currentMatchPosition,
                                               onSelectionChange: { range, rect in
                                    handleNoteSelectionChange(range: range, screenRect: rect)
                                })
                            }
                        }
                    }
                } else {
                    UICard {
                        VStack(spacing: 24) {
                            VStack(spacing: 6) {
                                HStack(spacing: 8) {
                                    Image("AppLogo")
                                        .resizable()
                                        .frame(width: 26, height: 26)
                                        .cornerRadius(6)
                                    Text("Голосок")
                                        .font(UIStyleFont.display(size: 20, weight: .bold))
                                        .foregroundColor(.uiInk)
                                }
                                Text("Локальное приложение для надиктовки, расшифровки созвонов и работы с медиафайлами")
                                    .font(UIStyleFont.body(size: 13, weight: .regular))
                                    .foregroundColor(.uiMidGray)
                                    .multilineTextAlignment(.center)
                            }
                            VStack(spacing: 10) {
                                HeroActionRow(
                                    icon: "mic.fill",
                                    badge: NativeHotKeyManager.shared.displayName(),
                                    title: "Надиктовать",
                                    subtitle: "Текст сразу появится под курсором в любом приложении"
                                ) {
                                    audioCapture.toggleRecording()
                                }

                                HeroActionRow(
                                    icon: "video.fill",
                                    badge: String(localized: "⌘ + O"),
                                    title: "Расшифровать файл",
                                    subtitle: "Созвоны Zoom, Телемост и медиафайлы: MP3, MP4, WebM"
                                ) {
                                    audioCapture.importAndTranscribeFile()
                                }
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Что ещё умеет")
                                    .font(UIStyleFont.body(size: 11, weight: .medium))
                                    .foregroundColor(.uiMidGray)

                                Button(action: openAccountSettings) {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.uiCanvas)
                                                .frame(width: 34, height: 34)
                                            Image(systemName: "icloud.fill").font(.system(size: 15, weight: .semibold)).foregroundColor(.uiInk)
                                        }
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text("Голосок+").font(UIStyleFont.display(size: 13, weight: .semibold)).foregroundColor(.uiInk)
                                            Text("Облачный ИИ помогает редактировать заметки. Расшифровка — всегда локально").font(UIStyleFont.body(size: 11, weight: .regular)).foregroundColor(.uiMidGray)
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundColor(.uiMidGray)
                                    }
                                    .padding(12)
                                    .background(Color.uiSidebar)
                                    .cornerRadius(14)
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.uiHairline, lineWidth: 1))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(TactileButtonStyle())

                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.down.doc").font(.system(size: 11, weight: .medium)).foregroundColor(.uiMidGray)
                                    Text("Перетащите файл в окно программы — расшифровка начнётся автоматически")
                                        .font(UIStyleFont.body(size: 11, weight: .regular))
                                        .foregroundColor(.uiMidGray)
                                }
                            }
                        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }.padding(20)
        }
        .onAppear { loadSelectedTimings() }
        .onChange(of: selectedItemId) { newId in
            textStageMode = .final
            audioCapture.stopSyncedPlayback()
            if isEditing, let prev = editingItemID, prev != newId {
                flushPendingEdits()
                isEditing = false
                editingItemID = nil
            }
            if currentSelection != nil { currentSelection = nil }
            AISelectionToolbarPresenter.shared.close()
            if let id = newId { selectedTimings = audioCapture.timings(for: id) } else { selectedTimings = nil }
            isSearchBarVisible = false
            transcriptSearchText = ""
            cachedSyncedMatchIndices = []
            cachedNativeMatchRanges = []
            currentMatchPosition = 0
        }
        .onChange(of: currentTab) { _ in
            if isEditing { flushPendingEdits(); isEditing = false; editingItemID = nil }
            if currentSelection != nil { currentSelection = nil }
            AISelectionToolbarPresenter.shared.close()
            isSearchBarVisible = false
            transcriptSearchText = ""
            cachedSyncedMatchIndices = []
            cachedNativeMatchRanges = []
            currentMatchPosition = 0
        }
        .onChange(of: isEditing) { editing in
            if editing {
                if currentSelection != nil { currentSelection = nil }
                AISelectionToolbarPresenter.shared.close()
                isSearchBarVisible = false
                transcriptSearchText = ""
                cachedSyncedMatchIndices = []
                cachedNativeMatchRanges = []
                currentMatchPosition = 0
            }
        }
        .sheet(item: $aiRequest) { request in
            AIResultSheet(request: request) { newID in
                withAnimation {
                    self.selectedItemId = newID
                    self.searchText = ""
                    self.selectedTimings = nil
                }
                audioCapture.markAsRead(id: newID)
            }
        }
        .sheet(isPresented: $showPromptManager) {
            PromptManagerView()
        }
        .sheet(isPresented: $showCreatePrompt) {
            PromptEditorView(prompt: nil)
        }
        .alert("Удалить запись?", isPresented: $showingDeleteAlert) {
            Button("Отмена", role: .cancel) { }
            Button("Удалить", role: .destructive) {
                if let id = itemToDelete, let idx = audioCapture.history.firstIndex(where: { $0.id == id }) {
                    SoundEffect.playDelete()
                    audioCapture.stopSyncedPlayback()
                    audioCapture.deleteItem(at: idx)
                    if selectedItemId == id { selectedItemId = nil; selectedTimings = nil }
                }
            }
        } message: { Text("Это действие нельзя отменить.") }
    }

    private func loadSelectedTimings() {
        if let id = selectedItemId { selectedTimings = audioCapture.timings(for: id) }
        else { selectedTimings = nil }
    }

    // MARK: - Поиск по стенограмме (⌘ + F)

    private var transcriptSearchBar: some View {
        let count = currentMatchCount
        let hasQuery = !transcriptSearchText.isEmpty
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.uiMidGray)
            TextField("Поиск в стенограмме", text: $transcriptSearchText)
                .textFieldStyle(PlainTextFieldStyle())
                .font(UIStyleFont.body(size: 13, weight: .regular))
                .foregroundColor(.uiInk)
                .focused($isSearchFieldFocused)
            if hasQuery {
                Text(count > 0 ? "\(currentMatchPosition + 1)/\(count)" : "0/0")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.uiMidGray)
                    .monospacedDigit()
                Button(action: { goToMatch(offset: -1) }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(count > 0 ? .uiInk : .uiMidGray)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(count == 0)
                .help(String(localized: "Предыдущее совпадение (⇧⌘G)"))
                Button(action: { goToMatch(offset: 1) }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(count > 0 ? .uiInk : .uiMidGray)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(count == 0)
                .help(String(localized: "Следующее совпадение (⌘G)"))
            }
            Button(action: closeSearchBar) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.uiMidGray)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Закрыть поиск (Esc)"))
        }
        .padding(8)
        .background(Color.uiCanvas)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))
    }

    private var currentMatchCount: Int {
        selectedTimings != nil ? cachedSyncedMatchIndices.count : cachedNativeMatchRanges.count
    }

    private func recomputeSearchMatches() {
        guard !transcriptSearchText.isEmpty else {
            cachedSyncedMatchIndices = []
            cachedNativeMatchRanges = []
            currentMatchPosition = 0
            return
        }
        if let timings = selectedTimings {
            cachedSyncedMatchIndices = TranscriptSearch.matchedWordIndices(in: timings.words, query: transcriptSearchText)
            cachedNativeMatchRanges = []
        } else if let selected = audioCapture.history.first(where: { $0.id == selectedItemId }) {
            cachedNativeMatchRanges = TranscriptSearch.matchedRanges(in: selected.text, query: transcriptSearchText)
            cachedSyncedMatchIndices = []
        } else {
            cachedSyncedMatchIndices = []
            cachedNativeMatchRanges = []
        }
        currentMatchPosition = 0
    }

    private func goToMatch(offset: Int) {
        guard isSearchBarVisible else { return }
        let count = currentMatchCount
        guard count > 0 else { return }
        currentMatchPosition = (currentMatchPosition + offset + count) % count
        seekToCurrentMatch()
    }

    private func seekToCurrentMatch() {
        guard let id = selectedItemId, let timings = selectedTimings else { return }
        guard currentMatchPosition < cachedSyncedMatchIndices.count else { return }
        let wordIdx = cachedSyncedMatchIndices[currentMatchPosition]
        guard wordIdx < timings.words.count else { return }
        audioCapture.seekSynced(to: timings.words[wordIdx].start, for: id)
    }

    private func toggleSearchBar() {
        guard selectedItemId != nil, !isEditing else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            isSearchBarVisible.toggle()
        }
        if isSearchBarVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { isSearchFieldFocused = true }
        } else {
            transcriptSearchText = ""
            cachedSyncedMatchIndices = []
            cachedNativeMatchRanges = []
            currentMatchPosition = 0
        }
    }

    private func closeSearchBar() {
        withAnimation(.easeOut(duration: 0.18)) {
            isSearchBarVisible = false
        }
        transcriptSearchText = ""
        cachedSyncedMatchIndices = []
        cachedNativeMatchRanges = []
        currentMatchPosition = 0
        isSearchFieldFocused = false
    }

    // MARK: - Редактор заметок

    private func beginEditing(_ item: TranscriptionItem) {
        audioCapture.stopSyncedPlayback()
        editSaveWorkItem?.cancel()
        editSaveWorkItem = nil
        editableText = item.text
        editingItemID = item.id
        isEditing = true
    }

    private func commitEditing(for item: TranscriptionItem) {
        editSaveWorkItem?.cancel()
        editSaveWorkItem = nil
        let newText = editableText.trimmingCharacters(in: .whitespacesAndNewlines)
        if newText != item.text {
            // При ручном редактировании текста заметки обязательно сбрасываем ASR-этапы,
            // чтобы скопированный и отображаемый текст полностью соответствовал правкам пользователя
            audioCapture.replaceNoteText(id: item.id, text: newText, rawText: newText, termsText: newText)
        }
        textStageMode = .final
        editingItemID = nil
        isEditing = false
    }

    private func scheduleEditSave(for id: UUID) {
        editSaveWorkItem?.cancel()
        let snapshot = editableText
        let work = DispatchWorkItem { [weak audioCapture] in
            audioCapture?.replaceNoteText(id: id, text: snapshot)
        }
        editSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func flushPendingEdits() {
        guard isEditing, let id = editingItemID else { return }
        editSaveWorkItem?.cancel()
        editSaveWorkItem = nil
        audioCapture.replaceNoteText(id: id, text: editableText)
    }

    // MARK: - AI-обработка выделенного фрагмента

    private func handleNoteSelectionChange(range: NSRange, screenRect: CGRect?) {
        guard let selected = audioCapture.history.first(where: { $0.id == selectedItemId }) else {
            if currentSelection != nil { currentSelection = nil }
            AISelectionToolbarPresenter.shared.close()
            return
        }
        if range.location == NSNotFound || range.length == 0 {
            if currentSelection != nil { currentSelection = nil }
            AISelectionToolbarPresenter.shared.close()
            return
        }
        let fullText = selected.text
        let ns = fullText as NSString
        guard range.location + range.length <= ns.length else {
            if currentSelection != nil { currentSelection = nil }
            AISelectionToolbarPresenter.shared.close()
            return
        }
        let selectedText = ns.substring(with: range)
        guard let rect = screenRect else { return }

        let sel = NoteSelection(noteID: selected.id, range: range, screenRect: rect, fullText: fullText, selectedText: selectedText)
        currentSelection = sel

        AISelectionToolbarPresenter.shared.update(
            anchorScreenRect: rect,
            templates: promptStore.actionTemplates,
            onPick: { tpl in openSelectionAI(with: tpl) },
            onClose: { currentSelection = nil }
        )
    }

    private func openSelectionAI(with template: AIPromptTemplate) {
        guard let sel = currentSelection else { return }
        aiRequest = AIActionRequest(
            template: template,
            noteID: sel.noteID,
            noteText: sel.selectedText,
            scope: .selection(range: sel.range, fullText: sel.fullText)
        )
    }

    private func openAccountSettings() {
        currentTab = .settings
        searchText = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: NSNotification.Name("ScrollToAccount"), object: nil)
        }
    }

    private func createNote() {
        if isEditing { flushPendingEdits(); isEditing = false; editingItemID = nil }
        let id = audioCapture.addNote(text: "")
        editSaveWorkItem?.cancel()
        editSaveWorkItem = nil
        withAnimation {
            searchText = ""
            selectedItemId = id
            selectedTimings = nil
        }
        audioCapture.markAsRead(id: id)
        editableText = ""
        editingItemID = id
        isEditing = true
    }

    // MARK: - Навигация с клавиатуры по списку заметок (Стрелки ↑ / ↓)

    private func selectNote(_ item: TranscriptionItem) {
        withAnimation(.easeInOut(duration: 0.15)) {
            selectedItemId = item.id
        }
        audioCapture.markAsRead(id: item.id)
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let isDown = event.keyCode == 125
        let isUp = event.keyCode == 126
        guard isDown || isUp else { return event }

        guard currentTab == .history else { return event }
        guard !displayedHistory.isEmpty else { return event }
        guard !isEditing else { return event }
        guard !(isSearchBarVisible && isSearchFieldFocused) else { return event }
        guard currentSelection == nil else { return event }
        guard !showAboutSheet,
              !showPromptManager,
              !showCreatePrompt,
              !showingDeleteAlert,
              aiRequest == nil,
              !showOnboarding,
              permissions.onboardingCompleted else { return event }

        guard let window = NSApp.keyWindow,
              window === NSApp.mainWindow || window.contentView?.window === window else {
            return event
        }

        if let responder = window.firstResponder as? NSTextView {
            if responder.isEditable && !responder.isFieldEditor {
                return event
            }
            if responder.selectedRange().length > 0 {
                return event
            }
        }

        let isCmd = event.modifierFlags.contains(.command)

        if isSidebarSearchFocused {
            if isDown {
                isSidebarSearchFocused = false
                window.makeFirstResponder(nil)
                if let first = displayedHistory.first {
                    selectNote(first)
                }
                return nil
            }
            return event
        }

        if isCmd && isDown {
            if let last = displayedHistory.last {
                selectNote(last)
            }
            return nil
        }

        if isCmd && isUp {
            if let first = displayedHistory.first {
                selectNote(first)
            }
            return nil
        }

        if let currentId = selectedItemId,
           let currentIndex = displayedHistory.firstIndex(where: { $0.id == currentId }) {
            if isDown {
                let nextIndex = currentIndex + 1
                if nextIndex < displayedHistory.count {
                    selectNote(displayedHistory[nextIndex])
                }
                return nil
            } else if isUp {
                let prevIndex = currentIndex - 1
                if prevIndex >= 0 {
                    selectNote(displayedHistory[prevIndex])
                } else {
                    isSidebarSearchFocused = true
                }
                return nil
            }
        } else {
            if isDown {
                if let first = displayedHistory.first {
                    selectNote(first)
                }
            } else if isUp {
                if let last = displayedHistory.last {
                    selectNote(last)
                }
            }
            return nil
        }

        return event
    }
}

// MARK: - Монитор клавиатурных событий для навигации

struct KeyMonitorView: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> NSEvent?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKeyDown = onKeyDown
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var onKeyDown: ((NSEvent) -> NSEvent?)?
        private var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let onKeyDown = self.onKeyDown else { return event }
                return onKeyDown(event)
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

// MARK: - ВСПОМОГАТЕЛЬНЫЕ КОМПОНЕНТЫ

struct HeroActionRow: View {
    let icon: String
    let badge: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.uiCanvas)
                        .frame(width: 40, height: 40)
                    Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundColor(.uiInk)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(UIStyleFont.display(size: 14, weight: .semibold)).foregroundColor(.uiInk)
                    Text(subtitle).font(UIStyleFont.body(size: 12, weight: .regular)).foregroundColor(.uiMidGray).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(badge).font(UIStyleFont.body(size: 10, weight: .semibold)).tracking(0.5).foregroundColor(.uiMidGray)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundColor(.uiMidGray)
            }
            .padding(14)
            .background(Color.uiSidebar)
            .cornerRadius(16)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.uiHairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(TactileButtonStyle())
    }
}

struct CopyFeedbackButton: View {
    let textToCopy: String
    @State private var isCopied = false
    var body: some View {
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(textToCopy, forType: .string)
            SoundEffect.playCopy()
            withAnimation(.spring()) { isCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation(.spring()) { isCopied = false } }
        }) {
            HStack(spacing: 6) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .medium))
                Text(isCopied ? LocalizedStringKey("Готово!") : LocalizedStringKey("Скопировать"))
            }
            .lineLimit(1)
            .font(UIStyleFont.body(size: 13, weight: .medium))
            .foregroundColor(isCopied ? Color(hex: "#10B981") : .uiInk)
            .padding(.vertical, 8).padding(.horizontal, 14)
            .background(Color.uiPaper).cornerRadius(18)
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(isCopied ? Color(hex: "#10B981").opacity(0.5) : Color.uiHairline, lineWidth: 1))
        }
        .buttonStyle(TactileButtonStyle())
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct EditToggleButton: View {
    let isEditing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isEditing ? "checkmark" : "square.and.pencil")
                    .font(.system(size: 11, weight: .medium))
                Text(isEditing ? LocalizedStringKey("Готово") : LocalizedStringKey("Редактировать"))
            }
            .lineLimit(1)
            .font(UIStyleFont.body(size: 13, weight: .medium))
            .foregroundColor(isEditing ? Color(hex: "#10B981") : .uiInk)
            .padding(.vertical, 8).padding(.horizontal, 14)
            .background(Color.uiPaper).cornerRadius(18)
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(isEditing ? Color(hex: "#10B981").opacity(0.5) : Color.uiHairline, lineWidth: 1))
        }
        .buttonStyle(TactileButtonStyle())
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct SidebarTabButton: View {
    let title: LocalizedStringKey
    let icon: String
    let isActive: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { Image(systemName: icon).font(.system(size: 13)); Text(title).font(UIStyleFont.body(size: 13, weight: .medium)); Spacer() }
            .foregroundColor(isActive ? .uiPaper : .uiInk).padding(.vertical, 8).padding(.horizontal, 12)
            .background(isActive ? Color.uiInk : Color.clear).cornerRadius(12).contentShape(Rectangle())
        }
        .buttonStyle(TactileButtonStyle())
    }
}
struct MetadataPill: View {
    let icon: String; let text: String; let color: Color
    var body: some View {
        HStack(spacing: 4) { Image(systemName: icon).font(.system(size: 9, weight: .bold)); Text(text).font(.system(size: 10, weight: .bold, design: .rounded)) }
        .foregroundColor(color).padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.12)).cornerRadius(6)
    }
}

// СИСТЕМНАЯ КАРТОЧКА С СИНЕЙ ТОЧКОЙ
// СКЕЛЕТОН КАРТОЧКИ ПРИ ПОИСКЕ
struct HistorySkeletonCard: View {
    private var bar: Color { Color.uiMidGray.opacity(0.16) }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(Color.blue.opacity(0.4)).frame(width: 6, height: 6).padding(.top, 5)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(bar).frame(width: 56, height: 8)
                    RoundedRectangle(cornerRadius: 3).fill(bar).frame(width: 30, height: 8)
                    Spacer()
                    RoundedRectangle(cornerRadius: 3).fill(bar).frame(width: 40, height: 8)
                }
                RoundedRectangle(cornerRadius: 3).fill(bar).frame(height: 9)
                RoundedRectangle(cornerRadius: 3).fill(bar).frame(width: 180, height: 9)
            }
            .shimmer()
        }
        .padding(12)
    }
}

struct HistoryCard: View {
    let item: TranscriptionItem
    let isSelected: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                // СИНЯЯ ТОЧКА НЕПРОЧИТАННОГО!
                if item.isUnread == true {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                }
                
                let formatted = DateFormattingHelper.formatRussianDate(item.date)
                Text(formatted.date).font(UIStyleFont.body(size: 12, weight: .semibold)).foregroundColor(isSelected ? .uiInk : .uiInkSoft)
                if !formatted.time.isEmpty { Text(formatted.time).font(UIStyleFont.body(size: 10, weight: .regular)).foregroundColor(isSelected ? .uiMidGray : .uiMidGray.opacity(0.8)) }

                Spacer()

                if item.isAITransform == true || item.duration == "AI" {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 8, weight: .bold))
                        Text(LocalizedStringKey("History.AI"))
                            .font(UIStyleFont.body(size: 9, weight: .bold))
                            .lineLimit(1)
                    }
                    .foregroundColor(Color(hex: "#A855F7"))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color(hex: "#A855F7").opacity(0.12))
                    .cornerRadius(5)
                } else {
                    Text(item.duration).font(UIStyleFont.body(size: 10, weight: .regular)).foregroundColor(.uiMidGray)
                }
            }
            Text(item.text).font(UIStyleFont.body(size: 13, weight: .regular)).foregroundColor(isSelected ? .uiInk : .uiInkSoft).lineLimit(2)
        }
        .padding(12).background(isSelected ? Color.uiPaper : Color.clear).cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.uiHairline : Color.clear, lineWidth: 1))
        .shadow(color: isSelected ? Color.black.opacity(0.04) : Color.clear, radius: 4, x: 0, y: 2)
        .contentShape(Rectangle())
    }
}

struct FileDropOverlay: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            LinearGradient(
                colors: [Color.blue.opacity(0.10), Color.blue.opacity(0.04)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 76, height: 76)
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundColor(.blue)
                }

                VStack(spacing: 6) {
                    Text(LocalizedStringKey("Перетащите файл — начнётся расшифровка"))
                        .font(UIStyleFont.display(size: 17, weight: .bold))
                        .foregroundColor(.uiInk)
                        .multilineTextAlignment(.center)
                    Text(LocalizedStringKey("MP3, MP4, WebM, MKV, WAV и другие"))
                        .font(UIStyleFont.body(size: 12, weight: .regular))
                        .foregroundColor(.uiMidGray)
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.uiPaper)
                    .shadow(color: .black.opacity(0.14), radius: 28, x: 0, y: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundColor(Color.blue.opacity(0.55))
            )
        }
        .ignoresSafeArea()
    }
}
