import Foundation
import AVFoundation
import AppKit
import UniformTypeIdentifiers
import ServiceManagement

// MARK: - Кастомная акустическая айдентика
struct SoundEffect {
    static func playStart() { LuxurySoundSynth.shared.playStart() }
    static func playSuccess() { LuxurySoundSynth.shared.playSuccess() }
    static func playCancel() { LuxurySoundSynth.shared.playCancel() }
    static func playCopy() { LuxurySoundSynth.shared.playCopy() }
    static func playDelete() { LuxurySoundSynth.shared.playDelete() }
    static func playWarning() { LuxurySoundSynth.shared.playWarning() }
}

struct UpdateInfo: Codable {
    let version: String
    let codename: String
    let url: URL
}

struct TranscriptionItem: Identifiable, Codable, Hashable {
    var id = UUID()
    let date: String
    var text: String
    let duration: String
    var speedup: Double?
    var isUnread: Bool? = false
    var isAITransform: Bool? = false
    var rawText: String? = nil
    var termsText: String? = nil
    
    var formattedSpeedup: String {
        if let s = speedup, s > 0 { return String(format: "x%.0f", s) }
        return "x1"
    }
}

struct TimedWord: Codable, Hashable {
    let text: String
    let start: Double
    let end: Double
}

struct TimingFilePayload: Codable {
    let words: [TimedWord]
    let duration: Double
}

struct SubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

class AudioCapture: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = AudioCapture()
    
    private static let chunkOverlapSeconds = 0.75

    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?
    private var startTime: Date?
    private var escMonitor: Any?
    private var pasteTarget: NSRunningApplication?
    
    @Published var isRecording = false
    @Published var isProcessingFile = false
    @Published var fileProcessingProgress: Double = 0.0
    @Published var transcribedText = ""
    @Published var warningMessage: String? = nil
    @Published var audioSamples: [Float] = Array(repeating: 0.15, count: 18)
    @Published var formattedRecordingTime: String = "00:00"
    
    // АПДЕЙТЫ
    @Published var updateInfo: UpdateInfo? = nil
    @Published var isDownloadingUpdate = false
    @Published var updateProgressText: String = ""
    private var downloadTask: URLSessionDownloadTask?
    
    @Published var playingItemId: UUID? = nil
    @Published var playheadTime: Double = 0
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var preloadedPlayerId: UUID?

    @Published var isPlayerPlaying: Bool = false
    
    @Published var isSuccessDone = false
    @Published var aiStatusText: String? = nil
    @Published var isHoveringAICancel = false

    /// Запуск индикации работы ИИ-обработки выделения в оверлее
    func startAIProcessing(status: String = String(localized: "ИИ-обработка...")) {
        DispatchQueue.main.async {
            self.warningMessage = nil
            self.isSuccessDone = false
            self.isHoveringAICancel = false
            self.aiStatusText = status
            OverlayPanelManager.shared.showOverlay()
        }
    }

    /// Успешное завершение ИИ-обработки с анимацией галочки и звуковым сигналом
    func finishAIProcessing() {
        DispatchQueue.main.async {
            self.aiStatusText = nil
            self.isHoveringAICancel = false
            self.isSuccessDone = true
            SoundEffect.playSuccess()
            OverlayPanelManager.shared.scheduleHide(after: 1.0)
        }
    }

    /// Отмена или ошибка ИИ-обработки
    func cancelAIProcessing(warning: String? = nil) {
        DispatchQueue.main.async {
            self.aiStatusText = nil
            self.isHoveringAICancel = false
            self.isSuccessDone = false
            if let warning = warning {
                SoundEffect.playWarning()
                OverlayPanelManager.shared.showWarning(message: warning)
            } else {
                SoundEffect.playCancel()
                OverlayPanelManager.shared.hideOverlay()
            }
        }
    }
    
    @Published var soundEnabled: Bool = UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }
    @Published var autoPasteEnabled: Bool = UserDefaults.standard.object(forKey: "autoPasteEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoPasteEnabled, forKey: "autoPasteEnabled") }
    }
    @Published var autoAIProcessEnabled: Bool = UserDefaults.standard.bool(forKey: "ai.autoProcess.enabled") {
        didSet { UserDefaults.standard.set(autoAIProcessEnabled, forKey: "ai.autoProcess.enabled") }
    }
    @Published var autoAIProcessTemplateID: String = UserDefaults.standard.string(forKey: "ai.autoProcess.templateID") ?? "restoreTechTerms" {
        didSet { UserDefaults.standard.set(autoAIProcessTemplateID, forKey: "ai.autoProcess.templateID") }
    }
    @Published var analyticsEnabled: Bool = UserDefaults.standard.object(forKey: "analyticsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(analyticsEnabled, forKey: "analyticsEnabled") }
    }
    @Published var launchAtLoginEnabled: Bool = UserDefaults.standard.bool(forKey: "launchAtLoginEnabled") {
        didSet {
            UserDefaults.standard.set(launchAtLoginEnabled, forKey: "launchAtLoginEnabled")
            setLaunchAtLogin(enabled: launchAtLoginEnabled)
        }
    }
    
    @Published var autoOpenNoteEnabled: Bool = UserDefaults.standard.object(forKey: "autoOpenNoteEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoOpenNoteEnabled, forKey: "autoOpenNoteEnabled") }
    }
    
    @Published var history: [TranscriptionItem] = [] {
        didSet {
            guard !isLoadingHistory else { return }
            saveHistory()
            DashboardStatsStore.shared.refresh(history: history)
        }
    }
    
    private var isLoadingHistory = false
    
    private let tempAudioURL = FileManager.default.temporaryDirectory.appendingPathComponent("temp_record.wav")
    
    override init() {
        super.init()
        
        if UserDefaults.standard.object(forKey: "analyticsEnabled") == nil {
            self.analyticsEnabled = true
        }

        let currentVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        if let lastActive = UserDefaults.standard.string(forKey: "lastActiveVersion"), lastActive != currentVer {
            UserDefaults.standard.removeObject(forKey: "cachedUpdateInfo")
            UserDefaults.standard.removeObject(forKey: "updateCheckETag")
            UserDefaults.standard.removeObject(forKey: "lastUpdateCheckAt")
            DispatchQueue.main.async { self.updateInfo = nil }
        }
        UserDefaults.standard.set(currentVer, forKey: "lastActiveVersion")

        loadHistory()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            self?.checkUpdates()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard self != nil else { return }
            let launchCount = UserDefaults.standard.integer(forKey: "launch_count") + 1
            UserDefaults.standard.set(launchCount, forKey: "launch_count")
            Telemetry.shared.event("app_launch", [
                "launch_count": launchCount,
                "mic_granted": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                "accessibility_granted": PermissionManager.shared.isAccessibilityGranted,
                "model_id": ModelStore.shared.activeModelID
            ])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self else { return }
            DashboardStatsStore.shared.refresh(history: self.history)
        }
    }

    private func setLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {}
        }
    }
    
    func toggleRecording() {
        if isProcessingFile {
            SoundEffect.playCancel()
            return
        }
        if isRecording { stopRecording() }
        else { startRecording() }
    }
    
    func cancelRecording() {
        removeEscMonitor()
        guard isRecording else { return }
        timer?.invalidate()
        timer = nil
        audioRecorder?.stop()
        audioRecorder = nil
        SoundEffect.playCancel()
        
        DispatchQueue.main.async {
            self.warningMessage = nil
            self.isRecording = false
            self.audioSamples = Array(repeating: 0.15, count: 9)
            self.transcribedText = String(localized: "Запись отменена")
            OverlayPanelManager.shared.hideOverlay()
        }
    }
    
    func startRecording() {
        guard !isProcessingFile else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if granted { DispatchQueue.main.async { self.startRecording() } }
            }
            return
        case .denied, .restricted:
            DispatchQueue.main.async { self.transcribedText = String(localized: "Нет доступа к микрофону.") }
            return
        case .authorized: break
        @unknown default: break
        }
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsFloatKey: false
        ]
        
        do {
            if FileManager.default.fileExists(atPath: tempAudioURL.path) { try FileManager.default.removeItem(at: tempAudioURL) }
            audioRecorder = try AVAudioRecorder(url: tempAudioURL, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()
            guard audioRecorder?.record() == true else { return }
            
            startTime = Date()
            SoundEffect.playStart()
            AppLogger.shared.info("Recording", "Запись началась", details: "режим: \(HotKeySettings.shared.mode == .pushToTalk ? "рация" : "переключатель")")
            
            escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { self?.cancelRecording() }
            }
            
            DispatchQueue.main.async {
                self.warningMessage = nil
                self.isRecording = true
                self.transcribedText = String(localized: "Запись идет...")
                OverlayPanelManager.shared.showOverlay()
            }
            let meteringTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.updateMetering() }
            RunLoop.main.add(meteringTimer, forMode: .common)
            timer = meteringTimer
        } catch {}
    }
    
    func stopRecording() {
        removeEscMonitor()
        pasteTarget = NSWorkspace.shared.frontmostApplication
        timer?.invalidate()
        timer = nil
        audioRecorder?.stop()
        audioRecorder = nil
        
        let durationSec = Date().timeIntervalSince(startTime ?? Date())
        
        AppLogger.shared.info("Recording", "Запись остановлена", details: String(format: "длительность %.1f с, цель вставки: %@", durationSec, NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))
        
        DispatchQueue.main.async {
            self.isRecording = false
            self.isProcessingFile = false
            self.fileProcessingProgress = 0.0
            self.audioSamples = Array(repeating: 0.15, count: 9)
            self.transcribedText = String(localized: "Расшифровка...")
        }
        
        DispatchQueue.global(qos: .utility).async {
            self.processLongFileInChunks(fileURL: self.tempAudioURL, isFileImport: false, audioDurationSec: durationSec)
        }
    }
    
    private func removeEscMonitor() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }
    
    private func updateMetering() {
        guard let recorder = audioRecorder, recorder.isRecording else { return }
        recorder.updateMeters()
        
        let elapsed = Int(Date().timeIntervalSince(startTime ?? Date()))
        let mins = elapsed / 60
        let secs = elapsed % 60
        let timeStr = String(format: "%02d:%02d", mins, secs)
        
        let power = recorder.averagePower(forChannel: 0)
        let level = max(0.15, min(1.0, (power + 40.0) / 35.0))
        
        var newSamples: [Float] = []
        for i in 0..<18 {
            let randomFactor = Float.random(in: 0.7...1.3)
            let targetVal = max(0.15, min(1.0, level * randomFactor))
            let currentVal = i < audioSamples.count ? audioSamples[i] : 0.15
            newSamples.append(currentVal * 0.35 + targetVal * 0.65)
        }
        
        DispatchQueue.main.async {
            self.formattedRecordingTime = timeStr
            self.audioSamples = newSamples
            OverlayPanelManager.shared.keepFront()
        }
    }

    func importAndTranscribeFile() {
        if isRecording || isProcessingFile {
            SoundEffect.playCancel()
            return
        }
        
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let webmType = UTType(filenameExtension: "webm") ?? .movie
        let mkvType = UTType(filenameExtension: "mkv") ?? .movie
        let oggType = UTType(filenameExtension: "ogg") ?? .audio
        panel.allowedContentTypes = [.audio, .movie, .mp3, .mpeg4Audio, .wav, webmType, mkvType, oggType]
        
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            importFiles(panel.urls)
        }
    }
    
    func importFiles(_ urls: [URL]) {
        guard !isRecording, !isProcessingFile else {
            SoundEffect.playCancel()
            return
        }
        let media = urls.filter { Self.isMediaURL($0) }
        guard !media.isEmpty else { return }
        DispatchQueue.main.async {
            self.warningMessage = nil
            self.isProcessingFile = true
            self.fileProcessingProgress = 0.0
            self.transcribedText = String(localized: "Извлечение аудио...")
            OverlayPanelManager.shared.showOverlay()
        }
        DispatchQueue.global(qos: .utility).async {
            self.processQueue(media)
        }
    }
    
    private func processQueue(_ urls: [URL]) {
        processNextInQueue(urls, index: 0)
    }
    
    private func processNextInQueue(_ urls: [URL], index: Int) {
        guard index < urls.count else {
            DispatchQueue.main.async {
                self.isProcessingFile = false
                OverlayPanelManager.shared.scheduleHide(after: 0.8)
            }
            return
        }
        let url = urls[index]
        DispatchQueue.main.async {
            self.warningMessage = nil
            self.isProcessingFile = true
            self.fileProcessingProgress = 0.0
            self.transcribedText = String(localized: "Извлечение аудио...")
            OverlayPanelManager.shared.showOverlay()
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.processLongFileInChunks(fileURL: url, isFileImport: true, audioDurationSec: 0) {
                DispatchQueue.main.async { self.processNextInQueue(urls, index: index + 1) }
            }
        }
    }
    
    private static func isMediaURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let mediaExts: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "aac", "flac", "ogg", "opus", "mp4", "mov", "m4v", "webm", "mkv", "avi"]
        if mediaExts.contains(ext) { return true }
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]), let ut = values.contentType {
            return ut.conforms(to: .audio) || ut.conforms(to: .movie)
        }
        return false
    }
    
    private func processLongFileInChunks(fileURL: URL, isFileImport: Bool, audioDurationSec: Double, completion: (() -> Void)? = nil) {
        let processStartTime = Date()
        let tempWavURL = FileManager.default.temporaryDirectory.appendingPathComponent("temp_file_full.wav")
        let sourceURL = isFileImport ? tempWavURL : fileURL
        
        func finish() {
            if let completion {
                completion()
            } else {
                DispatchQueue.main.async { self.isProcessingFile = false }
            }
        }
        
        if isFileImport {
            var conversionSuccess = false
            conversionSuccess = convertMediaTo16kHzWav(inputURL: fileURL, outputURL: tempWavURL)
            if !conversionSuccess { conversionSuccess = convertWithFFmpeg(inputURL: fileURL, outputURL: tempWavURL) }
            if !conversionSuccess { conversionSuccess = convertAudioTo16kHzWav(inputURL: fileURL, outputURL: tempWavURL) }
            
            if !conversionSuccess {
                DispatchQueue.main.async {
                    OverlayPanelManager.shared.showWarning(message: String(localized: "Не удалось извлечь аудио"))
                }
                finish()
                return
            }
        }
        
        guard let inputFile = try? AVAudioFile(forReading: sourceURL) else {
            DispatchQueue.main.async {
                OverlayPanelManager.shared.showWarning(message: String(localized: "Ошибка чтения файла"))
            }
            finish()
            return
        }
        
        let totalFrames = inputFile.length
        let sampleRate = inputFile.processingFormat.sampleRate
        let realAudioSecs = isFileImport ? (Double(totalFrames) / sampleRate) : audioDurationSec
        
        let durationFormatted: String
        if realAudioSecs >= 60.0 { durationFormatted = String(format: String(localized: "%.0f мин"), realAudioSecs / 60.0) }
        else { durationFormatted = String(format: String(localized: "%.0f сек"), realAudioSecs.rounded()) }
        
        let chunkSizeInSeconds: Double = 25.0
        
        var accumulatedText: [String] = []
        var accumulatedWords: [TimedWord] = []
        var accumulatedWordTexts: [String] = []
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        
        var chunkIndex = 0
        var coveredThroughFrame: Int64 = 0
        while coveredThroughFrame < totalFrames {
            autoreleasepool {
                let overlapFrames = Int64(Self.chunkOverlapSeconds * sampleRate)
                let chunkStartFrame = max(0, coveredThroughFrame - overlapFrames)
                let newAudioFrames = Int64((chunkSizeInSeconds - Self.chunkOverlapSeconds) * sampleRate)
                let maxEndFrame = min(totalFrames, coveredThroughFrame + newAudioFrames)
                let nominalEndFrame = min(maxEndFrame, coveredThroughFrame + Int64(chunkSizeInSeconds * sampleRate))
                let chunkEndFrame = Self.pauseAwareChunkEnd(in: inputFile, from: coveredThroughFrame, nominalEnd: nominalEndFrame, maximumEnd: maxEndFrame, totalFrames: totalFrames, sampleRate: sampleRate)
                let frameCountToRead = AVAudioFrameCount(chunkEndFrame - chunkStartFrame)
                
                inputFile.framePosition = chunkStartFrame
                guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: frameCountToRead) else { return }
                try? inputFile.read(into: pcmBuffer, frameCount: frameCountToRead)
                
                let chunkWavURL = FileManager.default.temporaryDirectory.appendingPathComponent("temp_chunk_\(chunkIndex).wav")
                if writeBufferToWav(buffer: pcmBuffer, targetFormat: targetFormat, outputURL: chunkWavURL) {
                    let chunkResult = runCLIOnWav(wavURL: chunkWavURL, initialPrompt: accumulatedText.last)
                    let chunkText = Self.removeBoundaryDuplicate(previous: accumulatedWordTexts.joined(separator: " "), current: chunkResult.text)
                    if !chunkText.isEmpty && chunkText != String(localized: "Речь не распознана") { accumulatedText.append(chunkText) }
                    if chunkResult.words.isEmpty {
                        accumulatedWordTexts.append(contentsOf: chunkText.split(whereSeparator: \.isWhitespace).map(String.init))
                    }
                    let chunkStart = Double(chunkStartFrame) / sampleRate
                    for word in chunkResult.words {
                        let globalStart = word.start + chunkStart
                        // Only take the newly covered part of the overlapping audio.
                        if chunkIndex == 0 || globalStart >= Double(coveredThroughFrame) / sampleRate {
                            accumulatedWords.append(TimedWord(text: word.text, start: globalStart, end: word.end + chunkStart))
                            accumulatedWordTexts.append(word.text)
                        }
                    }
                    try? FileManager.default.removeItem(at: chunkWavURL)
                }
                
                if isFileImport {
                    DispatchQueue.main.async {
                        self.fileProcessingProgress = min(1, Double(chunkEndFrame) / Double(totalFrames))
                        OverlayPanelManager.shared.keepFront()
                    }
                }
                coveredThroughFrame = chunkEndFrame
                chunkIndex += 1
            }
        }
        
        let rawText = accumulatedText.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = TextFormatter.normalizeRussianNumbers(rawText)
        let termsCorrectedText = TechTermStore.shared.applyReplacements(to: normalizedText)

        var processedText = termsCorrectedText
        if autoAIProcessEnabled && !termsCorrectedText.isEmpty {
            let templateID = autoAIProcessTemplateID
            if let template = PromptStore.shared.templates.first(where: { $0.id == templateID }) ?? PromptStore.shared.templates.first {
                DispatchQueue.main.async {
                    self.transcribedText = "ИИ: \(template.title)…"
                }
                let semaphore = DispatchSemaphore(value: 0)
                let dynamicCandidates = TechTermStore.shared.findFuzzyCandidateTerms(for: termsCorrectedText, limit: 4)
                let messages = template.messages(for: termsCorrectedText, dynamicTerms: dynamicCandidates)
                AIService.shared.chat(messages: messages, using: AIProviderStore.shared.config, promptLength: termsCorrectedText.count) { result in
                    switch result {
                    case .success(let aiOutput):
                        let clean = aiOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty {
                            if TechTermStore.shared.isReplacementEnabled && TechTermStore.shared.isAutoLearnEnabled {
                                TechTermStore.shared.autoLearn(fromRaw: rawText, aiCorrected: clean)
                            }
                            processedText = clean
                        }
                    case .failure(let error):
                        AppLogger.shared.warn("AI", "Автоматическая ИИ-обработка не удалась", details: error.localizedDescription)
                    }
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 60)
            }
        }

        let prettyFormattedText = TextFormatter.formatIntoParagraphs(processedText)
        let processingTimeSecs = Date().timeIntervalSince(processStartTime)
        let calculatedSpeedup = max(1.0, realAudioSecs / max(0.1, processingTimeSecs))
        
        DispatchQueue.main.async {
            if prettyFormattedText.isEmpty {
                AppLogger.shared.warn("Recognition", "Речь не распознана", details: String(format: "аудио %.1f с", realAudioSecs))
                Telemetry.shared.event("dictation_failed", ["audio_duration_sec": realAudioSecs])
                OverlayPanelManager.shared.showWarning(message: String(localized: "Речь не распознана"))
            } else {
                self.transcribedText = prettyFormattedText
                self.isSuccessDone = true
                let formatter = DateFormatter()
                formatter.dateFormat = "dd.MM.yyyy, HH:mm"
                let dateStr = formatter.string(from: Date())
                
                let newItem = TranscriptionItem(
                    id: UUID(),
                    date: dateStr,
                    text: prettyFormattedText,
                    duration: durationFormatted,
                    speedup: calculatedSpeedup,
                    isUnread: true,
                    isAITransform: false,
                    rawText: rawText,
                    termsText: termsCorrectedText
                )
                
                self.saveAudioForNote(id: newItem.id, sourceURL: sourceURL)
                if !accumulatedWords.isEmpty {
                    self.saveTimingsForNote(id: newItem.id, words: accumulatedWords, duration: realAudioSecs)
                }
                if isFileImport { try? FileManager.default.removeItem(at: sourceURL) }
                self.history.insert(newItem, at: 0)
                
                NotificationCenter.default.post(name: NSNotification.Name("AutoSelectNote"), object: newItem.id)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prettyFormattedText, forType: .string)
                
                if !isFileImport && self.autoPasteEnabled {
                    self.pasteToActiveApp()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { SoundEffect.playSuccess() }
                } else {
                    SoundEffect.playSuccess()
                }
                
                if completion == nil {
                    OverlayPanelManager.shared.scheduleHide(after: 0.8)
                }
            }
            
            self.sendTelemetry(eventType: isFileImport ? "file_import" : "dictation", audioDurationSec: realAudioSecs, characterCount: rawText.count, speedup: calculatedSpeedup)
            finish()
        }
    }
    
    func markAsRead(id: UUID) {
        if let idx = history.firstIndex(where: { $0.id == id }) {
            if history[idx].isUnread == true { history[idx].isUnread = false }
        }
    }

    func appendTextToNote(id: UUID, text: String) {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return }
        let item = history[idx]
        let current = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newText = current.isEmpty ? text : current + "\n\n----------------\n\n" + text
        history[idx] = TranscriptionItem(
            id: item.id,
            date: item.date,
            text: newText,
            duration: item.duration,
            speedup: item.speedup,
            isUnread: item.isUnread,
            isAITransform: item.isAITransform,
            rawText: item.rawText,
            termsText: item.termsText
        )
    }

    func replaceNoteText(id: UUID, text: String, rawText: String? = nil, termsText: String? = nil) {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return }
        let item = history[idx]
        history[idx] = TranscriptionItem(
            id: item.id,
            date: item.date,
            text: text,
            duration: item.duration,
            speedup: item.speedup,
            isUnread: item.isUnread,
            isAITransform: item.isAITransform,
            rawText: rawText ?? item.rawText,
            termsText: termsText ?? item.termsText
        )
    }

    func replaceRangeInNote(id: UUID, range: NSRange, newText: String) {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return }
        let item = history[idx]
        let nsText = item.text as NSString
        guard range.location != NSNotFound, range.location + range.length <= nsText.length else { return }
        let result = nsText.replacingCharacters(in: range, with: newText)
        history[idx] = TranscriptionItem(
            id: item.id,
            date: item.date,
            text: result,
            duration: item.duration,
            speedup: item.speedup,
            isUnread: item.isUnread,
            isAITransform: item.isAITransform,
            rawText: item.rawText,
            termsText: item.termsText
        )
    }

    @discardableResult
    func addNote(text: String) -> UUID {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy, HH:mm"
        let dateStr = formatter.string(from: Date())
        let item = TranscriptionItem(id: UUID(), date: dateStr, text: text, duration: "—", speedup: nil, isUnread: false)
        history.insert(item, at: 0)
        return item.id
    }

    @discardableResult
    func addAINote(originalText: String, transformedText: String, templateTitle: String) -> UUID {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy, HH:mm"
        let dateStr = formatter.string(from: Date())

        let afterLabel = String(localized: "Стало")

        let combined = """
        \(originalText.trimmingCharacters(in: .whitespacesAndNewlines))

        ----------------

        \(afterLabel) (\(templateTitle)):

        \(transformedText.trimmingCharacters(in: .whitespacesAndNewlines))
        """

        let item = TranscriptionItem(
            id: UUID(),
            date: dateStr,
            text: combined,
            duration: "AI",
            speedup: nil,
            isUnread: true,
            isAITransform: true
        )
        history.insert(item, at: 0)
        NotificationCenter.default.post(name: NSNotification.Name("AutoSelectNote"), object: item.id)
        return item.id
    }

    private func convertWithFFmpeg(inputURL: URL, outputURL: URL) -> Bool {
        let bundledFFmpeg = Bundle.main.path(forResource: "ffmpeg", ofType: nil)
        var ffmpegPaths: [String] = []
        if let bundledFFmpeg { ffmpegPaths.append(bundledFFmpeg) }
        ffmpegPaths.append(contentsOf: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"])
        guard let ffmpegPath = ffmpegPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            AppLogger.shared.warn("Import", "ffmpeg не найден (встроенный или системный)", details: inputURL.lastPathComponent)
            return false
        }
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) { try FileManager.default.removeItem(at: outputURL) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = ["-i", inputURL.path, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_f32le", outputURL.path, "-y"]
            try process.run()
            process.waitUntilExit()
            let ok = process.terminationStatus == 0 && FileManager.default.fileExists(atPath: outputURL.path)
            if ok {
                AppLogger.shared.info("Import", "Конвертация аудио выполнена", details: "ffmpeg: \(ffmpegPath)")
            } else {
                AppLogger.shared.warn("Import", "ffmpeg не смог конвертировать файл", details: "\(inputURL.lastPathComponent), exit \(process.terminationStatus)")
            }
            return ok
        } catch { return false }
    }

    private func convertMediaTo16kHzWav(inputURL: URL, outputURL: URL) -> Bool {
        let asset = AVURLAsset(url: inputURL)
        let semaphore = DispatchSemaphore(value: 0)
        var audioTrack: AVAssetTrack?
        Task.detached {
            do {
                audioTrack = try await asset.loadTracks(withMediaType: .audio).first
            } catch {
                audioTrack = nil
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let track = audioTrack else { return false }
        do {
            let reader = try AVAssetReader(asset: asset)
            let outputSettings: [String: Any] = [ AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsFloatKey: true ]
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            reader.add(readerOutput)
            let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            if FileManager.default.fileExists(atPath: outputURL.path) { try FileManager.default.removeItem(at: outputURL) }
            let outputFile = try AVAudioFile(forWriting: outputURL, settings: targetFormat.settings)
            reader.startReading()
            while reader.status == .reading {
                autoreleasepool {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer(), let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                        var length: Int = 0
                        var dataPointer: UnsafeMutablePointer<Int8>?
                        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
                        if let ptr = dataPointer, length > 0 {
                            let frameCount = AVAudioFrameCount(length / 4)
                            if let pcmBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) {
                                pcmBuffer.frameLength = frameCount
                                memcpy(pcmBuffer.floatChannelData?[0], ptr, length)
                                try? outputFile.write(from: pcmBuffer)
                            }
                        }
                    }
                }
            }
            return reader.status == .completed
        } catch { return false }
    }

    private func convertAudioTo16kHzWav(inputURL: URL, outputURL: URL) -> Bool {
        guard let inputFile = try? AVAudioFile(forReading: inputURL) else { return false }
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) { try FileManager.default.removeItem(at: outputURL) }
            let outputFile = try AVAudioFile(forWriting: outputURL, settings: targetFormat.settings)
            guard let converter = AVAudioConverter(from: inputFile.processingFormat, to: targetFormat) else { return false }
            let bufferSize: AVAudioFrameCount = 8192
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: bufferSize) else { return false }
            let ratio = 16000.0 / inputFile.processingFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(Double(bufferSize) * ratio)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else { return false }
            let totalFrames = inputFile.length
            var currentFrame: AVAudioFramePosition = 0
            var hasError = false
            while currentFrame < totalFrames && !hasError {
                autoreleasepool {
                    let framesToRead = min(bufferSize, AVAudioFrameCount(totalFrames - currentFrame))
                    if framesToRead == 0 { currentFrame = totalFrames; return }
                    do { try inputFile.read(into: inputBuffer, frameCount: framesToRead) } catch { hasError = true; return }
                    let framesRead = inputBuffer.frameLength
                    if framesRead == 0 { currentFrame = totalFrames; return }
                    currentFrame += Int64(framesRead)
                    var error: NSError?
                    var allConsumed = false
                    let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
                        if allConsumed { outStatus.pointee = .noDataNow; return nil }
                        allConsumed = true; outStatus.pointee = .haveData; return inputBuffer
                    }
                    if status != .error && error == nil { try? outputFile.write(from: outputBuffer) } else { hasError = true }
                }
            }
            return !hasError
        } catch { return false }
    }
    
    private func saveAudioForNote(id: UUID, sourceURL: URL) {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let audioDir = appSupport.appendingPathComponent("Golosok/Audio", isDirectory: true)
        try? fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let destURL = audioDir.appendingPathComponent("\(id.uuidString).wav")
        if fm.fileExists(atPath: destURL.path) { try? fm.removeItem(at: destURL) }
        try? fm.copyItem(at: sourceURL, to: destURL)
    }
    
    private func audioFileURL(for id: UUID) -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport.appendingPathComponent("Golosok/Audio/\(id.uuidString).wav")
    }
    
    private func timingsFileURL(for id: UUID) -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport.appendingPathComponent("Golosok/Audio/\(id.uuidString).segments.json")
    }
    
    private func saveTimingsForNote(id: UUID, words: [TimedWord], duration: Double) {
        guard let url = timingsFileURL(for: id),
              let data = try? JSONEncoder().encode(TimingFilePayload(words: words, duration: duration)) else { return }
        try? data.write(to: url, options: .atomic)
        AppLogger.shared.info("Recognition", "Тайминги слов сохранены", details: "\(words.count) слов, длительность \(String(format: "%.1f с", duration))")
    }
    
    func timings(for id: UUID) -> (words: [TimedWord], duration: Double)? {
        guard let result = readTimings(for: id) else { return nil }
        preloadAudio(for: id)
        return result
    }

    private func readTimings(for id: UUID) -> (words: [TimedWord], duration: Double)? {
        guard let url = timingsFileURL(for: id),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(TimingFilePayload.self, from: data),
              !payload.words.isEmpty else { return nil }
        return (Self.normalizedWords(payload.words, duration: payload.duration), payload.duration)
    }

    static func normalizedWords(_ words: [TimedWord], duration: Double) -> [TimedWord] {
        guard let last = words.last, last.end > duration * 100 else { return words }
        return words.map { TimedWord(text: $0.text, start: $0.start / 1000, end: $0.end / 1000) }
    }

    func retranscribeNote(id: UUID, completion: ((Bool) -> Void)? = nil) {
        guard let audioURL = audioFileURL(for: id),
              FileManager.default.fileExists(atPath: audioURL.path) else {
            completion?(false)
            return
        }

        DispatchQueue.main.async {
            self.warningMessage = nil
            self.isProcessingFile = true
            self.fileProcessingProgress = 0.0
            self.transcribedText = String(localized: "Повторное распознавание...")
            OverlayPanelManager.shared.showOverlay()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let processStartTime = Date()

            guard let inputFile = try? AVAudioFile(forReading: audioURL) else {
                DispatchQueue.main.async {
                    OverlayPanelManager.shared.showWarning(message: String(localized: "Ошибка чтения файла"))
                    self.isProcessingFile = false
                    completion?(false)
                }
                return
            }

            let totalFrames = inputFile.length
            let sampleRate = inputFile.processingFormat.sampleRate
            let realAudioSecs = Double(totalFrames) / sampleRate

            let chunkSizeInSeconds: Double = 25.0

            var accumulatedText: [String] = []
            var accumulatedWords: [TimedWord] = []
            var accumulatedWordTexts: [String] = []
            let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

            var chunkIndex = 0
            var coveredThroughFrame: Int64 = 0
            while coveredThroughFrame < totalFrames {
                autoreleasepool {
                    let overlapFrames = Int64(Self.chunkOverlapSeconds * sampleRate)
                    let chunkStartFrame = max(0, coveredThroughFrame - overlapFrames)
                    let newAudioFrames = Int64((chunkSizeInSeconds - Self.chunkOverlapSeconds) * sampleRate)
                    let maxEndFrame = min(totalFrames, coveredThroughFrame + newAudioFrames)
                    let nominalEndFrame = min(maxEndFrame, coveredThroughFrame + Int64(chunkSizeInSeconds * sampleRate))
                    let chunkEndFrame = Self.pauseAwareChunkEnd(in: inputFile, from: coveredThroughFrame, nominalEnd: nominalEndFrame, maximumEnd: maxEndFrame, totalFrames: totalFrames, sampleRate: sampleRate)
                    let frameCountToRead = AVAudioFrameCount(chunkEndFrame - chunkStartFrame)

                    inputFile.framePosition = chunkStartFrame
                    guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: frameCountToRead) else { return }
                    try? inputFile.read(into: pcmBuffer, frameCount: frameCountToRead)

                    let chunkWavURL = FileManager.default.temporaryDirectory.appendingPathComponent("retranscribe_chunk_\(chunkIndex).wav")
                    if self.writeBufferToWav(buffer: pcmBuffer, targetFormat: targetFormat, outputURL: chunkWavURL) {
                        let chunkResult = self.runCLIOnWav(wavURL: chunkWavURL, initialPrompt: accumulatedText.last)
                        let chunkText = Self.removeBoundaryDuplicate(previous: accumulatedWordTexts.joined(separator: " "), current: chunkResult.text)
                        if !chunkText.isEmpty && chunkText != String(localized: "Речь не распознана") {
                            accumulatedText.append(chunkText)
                        }
                        if chunkResult.words.isEmpty {
                            accumulatedWordTexts.append(contentsOf: chunkText.split(whereSeparator: \.isWhitespace).map(String.init))
                        }
                        let chunkStart = Double(chunkStartFrame) / sampleRate
                        for word in chunkResult.words {
                            let globalStart = word.start + chunkStart
                            if chunkIndex == 0 || globalStart >= Double(coveredThroughFrame) / sampleRate {
                                accumulatedWords.append(TimedWord(text: word.text, start: globalStart, end: word.end + chunkStart))
                                accumulatedWordTexts.append(word.text)
                            }
                        }
                        try? FileManager.default.removeItem(at: chunkWavURL)
                    }

                    DispatchQueue.main.async {
                        self.fileProcessingProgress = min(1, Double(chunkEndFrame) / Double(totalFrames))
                        OverlayPanelManager.shared.keepFront()
                    }
                    coveredThroughFrame = chunkEndFrame
                    chunkIndex += 1
                }
            }

            let rawText = accumulatedText.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedText = TextFormatter.normalizeRussianNumbers(rawText)
            let termsCorrectedText = TechTermStore.shared.applyReplacements(to: normalizedText)

            var processedText = termsCorrectedText
            if self.autoAIProcessEnabled && !termsCorrectedText.isEmpty {
                let templateID = self.autoAIProcessTemplateID
                if let template = PromptStore.shared.templates.first(where: { $0.id == templateID }) ?? PromptStore.shared.templates.first {
                    DispatchQueue.main.async {
                        self.transcribedText = "ИИ: \(template.title)…"
                    }
                    let semaphore = DispatchSemaphore(value: 0)
                    let dynamicCandidates = TechTermStore.shared.findFuzzyCandidateTerms(for: termsCorrectedText, limit: 4)
                    let messages = template.messages(for: termsCorrectedText, dynamicTerms: dynamicCandidates)
                    AIService.shared.chat(messages: messages, using: AIProviderStore.shared.config, promptLength: termsCorrectedText.count) { result in
                        switch result {
                        case .success(let aiOutput):
                            let clean = aiOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !clean.isEmpty {
                                if TechTermStore.shared.isReplacementEnabled && TechTermStore.shared.isAutoLearnEnabled {
                                    TechTermStore.shared.autoLearn(fromRaw: rawText, aiCorrected: clean)
                                }
                                processedText = clean
                            }
                        case .failure(let error):
                            AppLogger.shared.warn("AI", "Автоматическая ИИ-обработка при повторном распознавании не удалась", details: error.localizedDescription)
                        }
                        semaphore.signal()
                    }
                    _ = semaphore.wait(timeout: .now() + 60)
                }
            }

            let prettyFormattedText = TextFormatter.formatIntoParagraphs(processedText)
            let processingTimeSecs = Date().timeIntervalSince(processStartTime)
            let calculatedSpeedup = max(1.0, realAudioSecs / max(0.1, processingTimeSecs))

            DispatchQueue.main.async {
                self.isProcessingFile = false
                if prettyFormattedText.isEmpty {
                    OverlayPanelManager.shared.showWarning(message: String(localized: "Речь не распознана"))
                    completion?(false)
                } else {
                    self.replaceNoteText(id: id, text: prettyFormattedText, rawText: rawText, termsText: termsCorrectedText)
                    if !accumulatedWords.isEmpty {
                        self.saveTimingsForNote(id: id, words: accumulatedWords, duration: realAudioSecs)
                    }
                    SoundEffect.playSuccess()
                    OverlayPanelManager.shared.scheduleHide(after: 0.8)
                    completion?(true)
                }
            }
        }
    }

    private func preloadAudio(for id: UUID) {
        guard preloadedPlayerId != id else { return }
        preloadedPlayerId = id
        guard let fileURL = audioFileURL(for: id) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let player = try? AVAudioPlayer(contentsOf: fileURL) else { return }
            DispatchQueue.main.async {
                guard self?.preloadedPlayerId == id, self?.playingItemId == nil else { return }
                self?.audioPlayer = player
            }
        }
    }

    func toggleSyncedPlayback(for id: UUID) {
        guard audioFileURL(for: id) != nil else { return }
        if playingItemId == id {
            if audioPlayer?.isPlaying == true {
                audioPlayer?.pause(); stopPlaybackTimer(); isPlayerPlaying = false
            } else if let player = audioPlayer {
                player.play(); startPlaybackTimer(for: id); isPlayerPlaying = true
            }
            return
        }
        audioPlayer?.stop()
        if preloadedPlayerId != id, let url = audioFileURL(for: id) {
            do { audioPlayer = try AVAudioPlayer(contentsOf: url) } catch { return }
        }
        preloadedPlayerId = nil
        audioPlayer?.play()
        playingItemId = id
        playheadTime = 0
        isPlayerPlaying = true
        startPlaybackTimer(for: id)
    }
    
    func seekSynced(to time: Double, for id: UUID) {
        guard let player = audioPlayer else { return }
        player.currentTime = min(max(time, 0), player.duration)
        if playingItemId == id {
            if !player.isPlaying {
                player.play()
                startPlaybackTimer(for: id)
                isPlayerPlaying = true
            }
            playheadTime = time
        }
    }
    
    func stopSyncedPlayback() {
        audioPlayer?.stop()
        playingItemId = nil
        preloadedPlayerId = nil
        playheadTime = 0
        isPlayerPlaying = false
        stopPlaybackTimer()
    }
    
    private func startPlaybackTimer(for id: UUID) {
        stopPlaybackTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let player = self.audioPlayer else {
                self?.stopPlaybackTimer()
                return
            }
            guard self.playingItemId == id else { self.stopPlaybackTimer(); return }
            if player.isPlaying {
                self.playheadTime = player.currentTime
            } else {
                if player.duration > 0 && player.currentTime >= player.duration - 0.05 {
                    self.stopSyncedPlayback()
                } else {
                    self.stopPlaybackTimer()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackTimer = timer
    }
    
    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
    
    func hasAudioFile(for item: TranscriptionItem) -> Bool {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
        let fileURL = appSupport.appendingPathComponent("Golosok/Audio/\(item.id.uuidString).wav")
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
    
    func toggleAudioPlayback(for item: TranscriptionItem) {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let fileURL = appSupport.appendingPathComponent("Golosok/Audio/\(item.id.uuidString).wav")
        if playingItemId == item.id { audioPlayer?.stop(); playingItemId = nil; isPlayerPlaying = false; return }
        do { audioPlayer = try AVAudioPlayer(contentsOf: fileURL); audioPlayer?.play(); playingItemId = item.id; isPlayerPlaying = true } catch {}
    }
    
    private func writeBufferToWav(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat, outputURL: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) { try FileManager.default.removeItem(at: outputURL) }
            let file = try AVAudioFile(forWriting: outputURL, settings: targetFormat.settings)
            try file.write(from: buffer)
            return true
        } catch { return false }
    }

    /// Search a small window around the nominal boundary for the quietest 80 ms
    /// frame. This is a lightweight energy-based pause aligner, not a neural VAD.
    private static func pauseAwareChunkEnd(
        in file: AVAudioFile,
        from chunkStart: Int64,
        nominalEnd: Int64,
        maximumEnd: Int64,
        totalFrames: Int64,
        sampleRate: Double
    ) -> Int64 {
        guard nominalEnd < totalFrames,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: file.processingFormat.channelCount, interleaved: false) else {
            return nominalEnd
        }
        let searchRadius = Int64(1.5 * sampleRate)
        let lower = max(chunkStart + Int64(10 * sampleRate), nominalEnd - searchRadius)
        let upper = min(maximumEnd, min(totalFrames - Int64(1.5 * sampleRate), nominalEnd + searchRadius))
        guard upper > lower else { return nominalEnd }

        let windowFrames = max(1, Int64(0.08 * sampleRate))
        let hopFrames = max(1, Int64(0.02 * sampleRate))
        var bestFrame = nominalEnd
        var bestEnergy = Double.greatestFiniteMagnitude
        var cursor = lower
        while cursor + windowFrames <= upper {
            file.framePosition = cursor
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(windowFrames)) else { break }
            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(windowFrames))
            } catch {
                break
            }
            guard let samples = buffer.floatChannelData?[0] else { break }
            var energy = 0.0
            for i in 0..<Int(buffer.frameLength) {
                let sample = Double(samples[i])
                energy += sample * sample
            }
            energy /= Double(max(1, buffer.frameLength))
            let center = cursor + windowFrames / 2
            if energy < bestEnergy && abs(center - nominalEnd) <= searchRadius {
                bestEnergy = energy
                bestFrame = center
            }
            cursor += hopFrames
        }
        file.framePosition = chunkStart
        return min(max(bestFrame, chunkStart + Int64(10 * sampleRate)), maximumEnd)
    }

    static func removeBoundaryDuplicate(previous: String, current: String, maxWords: Int = 12) -> String {
        let previousWords = previous.split(whereSeparator: \.isWhitespace).map(String.init)
        let currentWords = current.split(whereSeparator: \.isWhitespace).map(String.init)
        let maxOverlap = min(maxWords, previousWords.count, currentWords.count)
        guard maxOverlap > 0 else { return current }
        // Require at least two matching words to avoid deleting a genuine
        // repeated one-word utterance ("да, да", "нет, нет") at the seam.
        guard maxOverlap >= 2 else { return current }
        for count in stride(from: maxOverlap, through: 2, by: -1) {
            let left = previousWords.suffix(count).map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            let right = currentWords.prefix(count).map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            if left == right {
                return currentWords.dropFirst(count).joined(separator: " ")
            }
        }
        return current
    }

    struct TimeIntervalMapping {
        let compressedStart: Double
        let compressedEnd: Double
        let originalStart: Double
        let originalEnd: Double
    }

    struct ClampedAudioResult {
        let url: URL
        let mappings: [TimeIntervalMapping]

        func mapCompressedToOriginal(_ t: Double) -> Double {
            for m in mappings {
                if t >= m.compressedStart && t <= m.compressedEnd {
                    let dt = t - m.compressedStart
                    return m.originalStart + dt
                }
            }
            guard let last = mappings.last else { return t }
            if t > last.compressedEnd {
                return last.originalEnd + (t - last.compressedEnd)
            }
            return t
        }
    }

    /// Clamps long pauses in audio before feeding to GigaAM RNN-T.
    /// RNN-T decoders suffer from silence drift / blank-loop collapse when pauses exceed ~1.5s,
    /// which causes subsequent words to be dropped. This compacts pauses longer than 0.5s down to 0.35s,
    /// while preserving exact timestamp mappings for word alignment.
    static func clampSilences(wavURL: URL, maxSilenceDuration: Double = 0.5, clampedSilenceDuration: Double = 0.35) -> ClampedAudioResult? {
        guard let file = try? AVAudioFile(forReading: wavURL) else { return nil }
        let format = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else { return nil }

        do {
            try file.read(into: pcmBuffer, frameCount: totalFrames)
        } catch {
            return nil
        }

        guard let floatData = pcmBuffer.floatChannelData?[0] else { return nil }
        let sampleRate = format.sampleRate
        let frameSize = Int(0.02 * sampleRate) // 20ms
        let totalSamples = Int(pcmBuffer.frameLength)
        guard totalSamples > frameSize else { return nil }

        var energies: [Float] = []
        energies.reserveCapacity(totalSamples / frameSize + 1)

        var sIdx = 0
        while sIdx < totalSamples {
            let count = min(frameSize, totalSamples - sIdx)
            var sumSq: Float = 0
            for i in 0..<count {
                let val = floatData[sIdx + i]
                sumSq += val * val
            }
            let rms = sqrt(sumSq / Float(count))
            energies.append(rms)
            sIdx += count
        }

        guard !energies.isEmpty else { return nil }
        let sortedEnergies = energies.sorted()
        let noiseFloor = sortedEnergies[sortedEnergies.count / 10]
        let peakEnergy = sortedEnergies[Int(Double(sortedEnergies.count) * 0.95)]
        let silenceThreshold = max(noiseFloor * 1.5, min(peakEnergy * 0.08, 0.025))

        let maxSilenceFrames = max(1, Int(clampedSilenceDuration / 0.02))
        let triggerFrames = max(1, Int(maxSilenceDuration / 0.02))

        var compressedSamples: [Float] = []
        compressedSamples.reserveCapacity(totalSamples)
        var mappings: [TimeIntervalMapping] = []
        var didCompress = false

        var i = 0
        while i < energies.count {
            if energies[i] < silenceThreshold {
                var j = i
                while j < energies.count && energies[j] < silenceThreshold {
                    j += 1
                }
                let runFrames = j - i
                let origStartSample = i * frameSize
                let origEndSample = min(totalSamples, j * frameSize)

                if runFrames > triggerFrames {
                    didCompress = true
                    let keepCount = maxSilenceFrames
                    let samplesToKeep = min(origEndSample - origStartSample, keepCount * frameSize)
                    let compStart = compressedSamples.count
                    for s in 0..<samplesToKeep {
                        compressedSamples.append(floatData[origStartSample + s])
                    }
                    let compEnd = compressedSamples.count
                    mappings.append(TimeIntervalMapping(
                        compressedStart: Double(compStart) / sampleRate,
                        compressedEnd: Double(compEnd) / sampleRate,
                        originalStart: Double(origStartSample) / sampleRate,
                        originalEnd: Double(origStartSample + samplesToKeep) / sampleRate
                    ))
                } else {
                    let count = origEndSample - origStartSample
                    let compStart = compressedSamples.count
                    for s in 0..<count {
                        compressedSamples.append(floatData[origStartSample + s])
                    }
                    let compEnd = compressedSamples.count
                    mappings.append(TimeIntervalMapping(
                        compressedStart: Double(compStart) / sampleRate,
                        compressedEnd: Double(compEnd) / sampleRate,
                        originalStart: Double(origStartSample) / sampleRate,
                        originalEnd: Double(origEndSample) / sampleRate
                    ))
                }
                i = j
            } else {
                let origStartSample = i * frameSize
                let origEndSample = min(totalSamples, (i + 1) * frameSize)
                let count = origEndSample - origStartSample
                let compStart = compressedSamples.count
                for s in 0..<count {
                    compressedSamples.append(floatData[origStartSample + s])
                }
                let compEnd = compressedSamples.count
                mappings.append(TimeIntervalMapping(
                    compressedStart: Double(compStart) / sampleRate,
                    compressedEnd: Double(compEnd) / sampleRate,
                    originalStart: Double(origStartSample) / sampleRate,
                    originalEnd: Double(origEndSample) / sampleRate
                ))
                i += 1
            }
        }

        guard didCompress else { return nil }

        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("clamped_\(UUID().uuidString).wav")
        try? FileManager.default.removeItem(at: outURL)

        do {
            let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
            let outFile = try AVAudioFile(forWriting: outURL, settings: targetFormat.settings)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(compressedSamples.count)) else {
                return nil
            }
            outBuffer.frameLength = AVAudioFrameCount(compressedSamples.count)
            if let outData = outBuffer.floatChannelData?[0] {
                for idx in 0..<compressedSamples.count {
                    outData[idx] = compressedSamples[idx]
                }
            }
            try outFile.write(from: outBuffer)
        } catch {
            return nil
        }
        return ClampedAudioResult(url: outURL, mappings: mappings)
    }
    
    private func runCLIOnWav(wavURL: URL, initialPrompt: String? = nil) -> (text: String, words: [TimedWord]) {
        let store = ModelStore.shared
        guard let model = store.model(named: store.activeModelID) else { return ("", []) }

        // 1. Кастомный удаленный инференс (OpenAI-совместимый API / llama-swap)
        if model.inferenceType == .remoteOpenAI, let endpoint = model.endpointURL, let url = URL(string: endpoint) {
            return runRemoteOpenAITranscription(wavURL: wavURL, endpoint: url, model: model)
        }

        // 2. Встроенная модель GigaAM через transcribe-cli
        if model.isBundled {
            guard let cliPath = Bundle.main.path(forResource: "transcribe-cli", ofType: nil),
                  let modelPath = Bundle.main.path(forResource: model.fileName, ofType: "gguf") else {
                AppLogger.shared.error("Recognition", "transcribe-cli или встроенная модель не найдены в бандле")
                return ("", [])
            }
            let clamped = Self.clampSilences(wavURL: wavURL)
            let effectiveWavURL = clamped?.url ?? wavURL
            let output = runCLIProcess(cliPath, arguments: ["-m", modelPath, "--timestamps", "word", effectiveWavURL.path])
            var words = Self.finalizeWords(parseGigaAMTokens(output))
            if let clamped {
                words = words.map { w in
                    TimedWord(
                        text: w.text,
                        start: clamped.mapCompressedToOriginal(w.start),
                        end: clamped.mapCompressedToOriginal(w.end)
                    )
                }
                try? FileManager.default.removeItem(at: clamped.url)
            }
            let lines = output.components(separatedBy: .newlines)
            if let textLine = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("text:") }) {
                let extracted = String(textLine.trimmingCharacters(in: .whitespaces).dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                if extracted != "(empty)" { return (extracted, words) }
            }
            return ("", words)
        } else {
            // 3. Локальные Whisper модели через whisper-cli
            guard let cliPath = Bundle.main.path(forResource: "whisper-cli", ofType: nil),
                  let modelPath = store.localModelPath(for: model.id) else {
                AppLogger.shared.error("Recognition", "whisper-cli или модель \(model.id) не найдены", details: model.id)
                return ("", [])
            }
            var arguments = ["-m", modelPath, "-f", wavURL.path, "-l", model.languageCode, "-nt", "-ojf"]
            if let initialPrompt, !initialPrompt.isEmpty {
                let prompt = String(initialPrompt.suffix(160))
                arguments += ["--initial-prompt", prompt]
            }
            let output = runCLIProcess(cliPath, arguments: arguments)
            let parts = output.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("[") && !$0.lowercased().hasPrefix("whisper") }
            let text = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return (text, Self.finalizeWords(readWhisperWords(wavURL: wavURL)))
        }
    }

    private func runRemoteOpenAITranscription(wavURL: URL, endpoint: URL, model: RecognitionModel) -> (text: String, words: [TimedWord]) {
        let semaphore = DispatchSemaphore(value: 0)
        var resultText = ""
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        if let key = model.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // file
        if let fileData = try? Data(contentsOf: wavURL) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
        }
        // model
        if let modelId = model.modelIdentifier, !modelId.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(modelId)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                AppLogger.shared.error("Recognition", "Ошибка удаленного распознавания: \(error.localizedDescription)")
                return
            }
            guard let data = data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return
            }
            if let t = json["text"] as? String {
                resultText = t.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 120)

        return (resultText, [])
    }

    private func parseGigaAMTokens(_ output: String) -> [TimedWord] {
        var words: [TimedWord] = []
        var currentText = ""
        var wordStart = -1.0
        var wordEnd = -1.0
        let pattern = #"\[\s*([0-9.]+)\s*->\s*([0-9.]+)\]\s*p=[0-9.eE+-]+\s*(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsOutput = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: nsOutput.length))
        for m in matches where m.numberOfRanges == 4 {
            let s = Double(nsOutput.substring(with: m.range(at: 1))) ?? -1
            let e = Double(nsOutput.substring(with: m.range(at: 2))) ?? -1
            var body = nsOutput.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { continue }
            if body.hasPrefix("[_") && body.hasSuffix("_]") { continue }
            let startsNewWord: Bool
            if body.hasPrefix("▁") {
                body = String(body.dropFirst())
                startsNewWord = true
            } else {
                startsNewWord = false
            }
            if currentText.isEmpty || startsNewWord {
                if !currentText.isEmpty { words.append(TimedWord(text: currentText, start: max(wordStart, 0), end: max(wordEnd, 0))) }
                currentText = body
                wordStart = s
                wordEnd = e
            } else {
                currentText += body
                wordEnd = e
            }
        }
        if !currentText.isEmpty { words.append(TimedWord(text: currentText, start: max(wordStart, 0), end: max(wordEnd, 0))) }
        return words
    }

    private static func finalizeWords(_ words: [TimedWord]) -> [TimedWord] {
        guard !words.isEmpty else { return [] }
        var result = words
        for i in 0..<(result.count - 1) {
            let nextStart = result[i + 1].start
            var end = result[i].end
            if end <= result[i].start || end >= nextStart { end = nextStart }
            if end <= result[i].start { end = result[i].start + 0.3 }
            result[i] = TimedWord(text: result[i].text, start: result[i].start, end: end)
        }
        let last = result.count - 1
        if result[last].end <= result[last].start {
            result[last] = TimedWord(text: result[last].text, start: result[last].start, end: result[last].start + 0.3)
        }
        return result
    }

    private func readWhisperWords(wavURL: URL) -> [TimedWord] {
        let jsonURL = wavURL.appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        guard let data = try? Data(contentsOf: jsonURL) else {
            AppLogger.shared.warn("Recognition", "whisper JSON не найден", details: jsonURL.lastPathComponent)
            return []
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let transcription = json["transcription"] as? [[String: Any]] else { return [] }

        let wavEndSecs = Self.audioDurationSeconds(of: wavURL)
        var words: [TimedWord] = []

        for entry in transcription {
            guard let tokens = entry["tokens"] as? [[String: Any]] else { continue }

            var segmentWords: [TimedWord] = []
            var currentText = ""
            var wordStart = -1.0
            var wordEnd = -1.0
            var reliable = true
            var lastEnd = -1.0

            func appendSegmentWord(_ text: String, _ start: Double, _ end: Double) {
                let w = TimedWord(text: text, start: max(start, 0), end: max(end, 0))
                segmentWords.append(w)
                if start < 0 || end < 0 || end <= start || start < lastEnd { reliable = false }
                lastEnd = max(lastEnd, end)
            }

            for token in tokens {
                guard let raw = token["text"] as? String,
                      let offsets = token["offsets"] as? [String: Any],
                      let fromMs = offsets["from"] as? Double,
                      let toMs = offsets["to"] as? Double else { continue }
                let from = fromMs / 1000.0
                let to = toMs / 1000.0
                let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty || (body.hasPrefix("[_") && body.hasSuffix("_]")) { continue }
                if currentText.isEmpty || raw.hasPrefix(" ") {
                    if !currentText.isEmpty { appendSegmentWord(currentText, wordStart, wordEnd) }
                    currentText = body
                    wordStart = from
                    wordEnd = to
                } else {
                    currentText += body
                    wordEnd = to
                }
            }
            if !currentText.isEmpty { appendSegmentWord(currentText, wordStart, wordEnd) }

            if !reliable && segmentWords.count > 1 {
                let offsets = entry["offsets"] as? [String: Any]
                var fromSecs = ((offsets?["from"] as? Double) ?? 0) / 1000.0
                var toSecs = ((offsets?["to"] as? Double) ?? 0) / 1000.0
                if wavEndSecs > 0 {
                    fromSecs = min(max(fromSecs, 0), wavEndSecs)
                    toSecs = min(toSecs, wavEndSecs)
                }
                if toSecs <= fromSecs { toSecs = fromSecs + Double(segmentWords.count) * 0.3 }
                segmentWords = Self.interpolateTimings(segmentWords, from: fromSecs, to: toSecs)
            }
            words.append(contentsOf: segmentWords)
        }

        return Self.finalizeWords(words)
    }

    private static func audioDurationSeconds(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    static func interpolateTimings(_ words: [TimedWord], from startSecs: Double, to endSecs: Double) -> [TimedWord] {
        guard words.count > 1, endSecs > startSecs else { return words }
        var weights: [Double] = words.map { max(1.0, Double(($0.text as NSString).length)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return words }
        var result: [TimedWord] = []
        var cursor = startSecs
        var acc = 0.0
        for (i, w) in words.enumerated() {
            acc += weights[i]
            let wordEndSecs = startSecs + min(1.0, acc / total) * (endSecs - startSecs)
            result.append(TimedWord(text: w.text, start: cursor, end: max(wordEndSecs, cursor + 0.001)))
            cursor = max(wordEndSecs, cursor + 0.001)
        }
        return result
    }

    private func runCLIProcess(_ executable: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch { return "" }
    }
    
    private func pasteToActiveApp() {
        guard autoPasteEnabled else { return }
        guard AXIsProcessTrusted() else {
            AppLogger.shared.warn("Paste", "Доступ AX недоступен — пропускаем вставку. Пользователь должен включить её в Настройках.")
            Telemetry.shared.event("paste_skipped", ["paste_reason": "no_ax_access"])
            return
        }
        guard let target = pasteTarget else { return }
        let pid = target.processIdentifier
        target.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard self.canAcceptPaste(pid: pid) else {
                AppLogger.shared.info("Paste", "Вставка пропущена: под фокусом нет редактируемого поля", details: target.localizedName)
                Telemetry.shared.event("paste_skipped", ["paste_reason": "no_focus"])
                return
            }
            AppLogger.shared.info("Paste", "Cmd+V отправлен", details: target.localizedName)
            Telemetry.shared.event("paste_success", ["paste_method": "cgkey"])
            let source = CGEventSource(stateID: .combinedSessionState)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else { return }
            keyDown.flags = .maskCommand; keyUp.flags = .maskCommand
            keyDown.postToPid(pid)
            keyUp.postToPid(pid)
        }
    }

    private func canAcceptPaste(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedElement = focusedRef else { return true }
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXRoleAttribute as CFString, &roleRef) == .success,
              let roleString = roleRef as? String else { return true }
        switch roleString {
        case "AXTextField", "AXTextArea", "AXTextView", "AXComboBox", "AXSearchField",
             "AXDocument", "AXScrollArea", "AXWebArea":
            return true
        default:
            return false
        }
    }
    
    private func sendTelemetry(eventType: String, audioDurationSec: Double, characterCount: Int, speedup: Double) {
        Telemetry.shared.event(eventType, [
            "audio_duration_sec": audioDurationSec,
            "character_count": characterCount,
            "speedup_factor": speedup
        ])
    }
    
    // MARK: - Субтитры

    static func makeSubtitleCues(from words: [TimedWord]) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var buffer: [String] = []
        var cueStart = 0.0
        var cueEnd = 0.0

        func flush() {
            guard !buffer.isEmpty else { return }
            let end = max(cueEnd, cueStart + 0.5)
            cues.append(SubtitleCue(start: cueStart, end: end, text: buffer.joined(separator: " ")))
            buffer.removeAll()
        }

        for word in words {
            if buffer.isEmpty { cueStart = word.start }
            buffer.append(word.text)
            cueEnd = max(word.end, word.start + 0.2)
            let last = word.text.last
            let isSentenceEnd = last == "." || last == "!" || last == "?" || last == "…"
            if isSentenceEnd || buffer.count >= 12 || (word.end - cueStart) >= 6.0 {
                flush()
            }
        }
        flush()
        return cues
    }

    static func makeSubtitleCuesFromText(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var t = 0.0
        for sentence in Self.splitIntoSentences(text) {
            let words = sentence.split(separator: " ").count
            let dur = max(1.2, Double(words) * 0.4)
            cues.append(SubtitleCue(start: t, end: t + dur, text: sentence))
            t += dur + 0.05
        }
        return cues
    }

    static func splitIntoSentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "…" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }

    static func srtContent(cues: [SubtitleCue]) -> String {
        var out = ""
        for (i, cue) in cues.enumerated() {
            out += "\(i + 1)\n"
            out += "\(srtTime(cue.start)) --> \(srtTime(cue.end))\n"
            out += "\(cue.text)\n\n"
        }
        return out
    }

    static func vttContent(cues: [SubtitleCue]) -> String {
        var out = "WEBVTT\n\n"
        for cue in cues {
            out += "\(vttTime(cue.start)) --> \(vttTime(cue.end))\n"
            out += "\(cue.text)\n\n"
        }
        return out
    }

    static func srtTime(_ t: Double) -> String {
        let ms = Int((t * 1000).rounded())
        let h = ms / 3_600_000
        let m = (ms % 3_600_000) / 60_000
        let s = (ms % 60_000) / 1000
        let millis = ms % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, millis)
    }

    static func vttTime(_ t: Double) -> String {
        let ms = Int((t * 1000).rounded())
        let h = ms / 3_600_000
        let m = (ms % 3_600_000) / 60_000
        let s = (ms % 60_000) / 1000
        let millis = ms % 1000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, millis)
    }

    // ЭКСПОРТ В ВАЛИДНЫЙ UTF-8 С BOM ДЛЯ MS EXCEL / NUMBERS
    func exportTranscription(_ item: TranscriptionItem, format: String) {
        let panel = NSSavePanel()
        panel.title = "Сохранить транскрипцию"
        panel.nameFieldStringValue = "Заметка_\(item.date.replacingOccurrences(of: ":", with: "-")).\(format)"
        if panel.runModal() == .OK, let saveURL = panel.url {
            var content = ""
            let prettyText = TextFormatter.formatIntoParagraphs(item.text)
            switch format.lowercased() {
            case "md": content = "# Транскрипция Голосок\n**Дата:** \(item.date)\n**Длительность:** \(item.duration)\n\n---\n\n\(prettyText)"
            case "txt": content = "Голосок — Транскрипция\nДата: \(item.date)\nДлительность: \(item.duration)\n\n\(prettyText)"
            case "csv":
                // \u{FEFF} — это BOM маркер для того, чтобы Excel открывал русский язык в идеальном UTF-8!
                content = "\u{FEFF}\"Дата\",\"Длительность\",\"Текст\"\n\"\(item.date)\",\"\(item.duration)\",\"\(item.text.replacingOccurrences(of: "\"", with: "\"\""))\""
            case "json":
                let dict: [String: Any] = ["id": item.id.uuidString, "date": item.date, "duration": item.duration, "text": item.text]
                if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) { content = String(data: data, encoding: .utf8) ?? "" }
            case "srt", "vtt":
                let cues: [SubtitleCue]
                if let timings = readTimings(for: item.id), !timings.words.isEmpty {
                    cues = Self.makeSubtitleCues(from: timings.words)
                } else {
                    cues = Self.makeSubtitleCuesFromText(item.text)
                }
                content = format.lowercased() == "srt" ? Self.srtContent(cues: cues) : Self.vttContent(cues: cues)
            default: content = prettyText
            }
            try? content.write(to: saveURL, atomically: true, encoding: .utf8)
        }
    }
    
func checkUpdates(force: Bool = false) {
        let lastCheck = UserDefaults.standard.object(forKey: "lastUpdateCheckAt") as? Date
        let currentVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < 4 * 3600 {
            if let data = UserDefaults.standard.data(forKey: "cachedUpdateInfo") {
                if let cached = try? JSONDecoder().decode(UpdateInfo.self, from: data),
                   Self.compareVersions(cached.version, currentVer) == .orderedDescending {
                    DispatchQueue.main.async { self.updateInfo = cached }
                } else {
                    UserDefaults.standard.removeObject(forKey: "cachedUpdateInfo")
                    DispatchQueue.main.async { self.updateInfo = nil }
                }
            }
            return
        }
        guard let url = URL(string: "https://api.github.com/repos/Berliner187/Golosok/releases/latest") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10.0)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let etag = UserDefaults.standard.string(forKey: "updateCheckETag") {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let http = response as? HTTPURLResponse
            if http?.statusCode == 304 {
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheckAt")
                return
            }
            if let etag = http?.value(forHTTPHeaderField: "Etag") {
                UserDefaults.standard.set(etag, forKey: "updateCheckETag")
            }
            defer { UserDefaults.standard.set(Date(), forKey: "lastUpdateCheckAt") }
            guard let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String, let releaseName = json["name"] as? String,
                  let assets = json["assets"] as? [[String: Any]],
                  let firstAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
                  let downloadUrlString = firstAsset["browser_download_url"] as? String,
                  let downloadUrl = URL(string: downloadUrlString) else { return }
            let result: UpdateInfo?
            if Self.compareVersions(tagName, currentVer) == .orderedDescending {
                let codename = releaseName.components(separatedBy: " ").last ?? "UPDATE"
                result = UpdateInfo(version: tagName, codename: codename.uppercased(), url: downloadUrl)
            } else {
                result = nil
                UserDefaults.standard.removeObject(forKey: "updateCheckETag")
            }
            if let result, let encoded = try? JSONEncoder().encode(result) {
                UserDefaults.standard.set(encoded, forKey: "cachedUpdateInfo")
            } else {
                UserDefaults.standard.removeObject(forKey: "cachedUpdateInfo")
            }
            DispatchQueue.main.async { self.updateInfo = result }
        }.resume()
    }

    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let cleanA = a.replacingOccurrences(of: "v", with: "")
        let cleanB = b.replacingOccurrences(of: "v", with: "")
        let ta = cleanA.split(separator: ".").compactMap { Int($0) }
        let tb = cleanB.split(separator: ".").compactMap { Int($0) }
        let n = max(ta.count, tb.count)
        for i in 0..<n {
            let av = i < ta.count ? ta[i] : 0
            let bv = i < tb.count ? tb[i] : 0
            if av != bv { return av < bv ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
    
    func cancelUpdateDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        DispatchQueue.main.async { self.isDownloadingUpdate = false; self.updateProgressText = "" }
    }
    
    func downloadAndInstallUpdate() {
        guard let updateUrl = updateInfo?.url else { return }
        DispatchQueue.main.async { self.isDownloadingUpdate = true; self.updateProgressText = "Подключение..." }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Golosok_Update.dmg")
        if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.removeItem(at: dest) }
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        downloadTask = session.downloadTask(with: updateUrl)
        downloadTask?.resume()
    }
    
    func deleteItem(at index: Int) {
        let item = history[index]
        history.remove(at: index)
        deleteAudioFile(for: item.id)
    }
    func clearAllHistory() {
        history.forEach { deleteAudioFile(for: $0.id) }
        history.removeAll()
    }
    private func historyStoreURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSupport.appendingPathComponent("Golosok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }
    private func saveHistory() {
        guard let url = historyStoreURL(), let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: url, options: .atomic)
    }
    private func loadHistory() {
        guard let url = historyStoreURL() else { return }
        var items: [TranscriptionItem] = []
        var needsSave = false
        if !FileManager.default.fileExists(atPath: url.path),
           let udData = UserDefaults.standard.data(forKey: "transcription_history"),
           let dec = try? JSONDecoder().decode([TranscriptionItem].self, from: udData) {
            items = dec
            UserDefaults.standard.removeObject(forKey: "transcription_history")
            needsSave = true
        } else if let data = try? Data(contentsOf: url),
                  let dec = try? JSONDecoder().decode([TranscriptionItem].self, from: data) {
            items = dec
        }
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let audioDir = appSupport?.appendingPathComponent("Golosok/Audio", isDirectory: true)

        self.history = items.map { item in
            var updated = item

            // Восстановление сырого текста ASR из сохраненных segments.json, если он был утерян
            if updated.rawText == nil, let audioDir {
                let segURL = audioDir.appendingPathComponent("\(item.id.uuidString).segments.json")
                if let segData = try? Data(contentsOf: segURL),
                   let payload = try? JSONDecoder().decode(TimingFilePayload.self, from: segData),
                   !payload.words.isEmpty {
                    let recoveredRaw = payload.words.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !recoveredRaw.isEmpty {
                        updated.rawText = recoveredRaw
                        needsSave = true
                    }
                }
            }

            // Восстановление текста после словаря IT-терминов, если есть сырой текст
            if updated.termsText == nil, let raw = updated.rawText {
                let terms = TechTermStore.shared.applyReplacements(to: raw)
                updated.termsText = terms
                needsSave = true
            }

            // Форматирование абзацев при необходимости (с сохранением всех полей)
            if !updated.text.contains("\n\n") && updated.text.count > 120 {
                needsSave = true
                updated.text = TextFormatter.formatIntoParagraphs(updated.text)
            }
            return updated
        }
        if needsSave { saveHistory() }
    }

    private func deleteAudioFile(for id: UUID) {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let fileURL = appSupport.appendingPathComponent("Golosok/Audio/\(id.uuidString).wav")
        if FileManager.default.fileExists(atPath: fileURL.path) { try? FileManager.default.removeItem(at: fileURL) }
        let segURL = appSupport.appendingPathComponent("Golosok/Audio/\(id.uuidString).segments.json")
        if FileManager.default.fileExists(atPath: segURL.path) { try? FileManager.default.removeItem(at: segURL) }
    }
}

extension AudioCapture: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let mbWritten = Double(totalBytesWritten) / (1024.0 * 1024.0)
        let mbTotal = Double(totalBytesExpectedToWrite) / (1024.0 * 1024.0)
        let percent = Int(progress * 100.0)
        let text = String(format: "%.0f / %.0f МБ (%d%%)", mbWritten, mbTotal, percent)
        DispatchQueue.main.async { self.fileProcessingProgress = progress; self.updateProgressText = text }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Golosok_Update.dmg")
        if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.removeItem(at: dest) }
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            DispatchQueue.main.async {
                self.isDownloadingUpdate = false
                self.updateProgressText = "Открытие..."
                NSWorkspace.shared.open(dest)
            }
        } catch { DispatchQueue.main.async { self.isDownloadingUpdate = false; self.updateProgressText = "Ошибка" } }
    }
}
