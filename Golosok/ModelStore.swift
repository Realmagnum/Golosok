import Foundation

enum InferenceType: String, Codable {
    case bundledCLI       // Встроенная GigaAM через transcribe-cli
    case localWhisperCLI   // Локальная whisper через whisper-cli
    case remoteOpenAI      // Внешний HTTP инференс (llama-swap, OpenAI audio transcriptions, Whisper server)
}

struct RecognitionModel: Identifiable, Codable {
    let id: String
    var name: String
    var systemName: String
    var languageCode: String
    var fileName: String
    var isBundled: Bool
    var sizeMB: Int
    var downloadURL: URL?
    
    // Новые поля для кастомных инференсов
    var inferenceType: InferenceType = .localWhisperCLI
    var endpointURL: String? = nil
    var modelIdentifier: String? = nil
    var apiKey: String? = nil
    var isCustom: Bool = false
    
    enum CodingKeys: String, CodingKey {
        case id, name, systemName, languageCode, fileName, isBundled, sizeMB, downloadURL
        case inferenceType, endpointURL, modelIdentifier, apiKey, isCustom
    }
    
    init(id: String, name: String, systemName: String, languageCode: String, fileName: String,
         isBundled: Bool, sizeMB: Int, downloadURL: URL?,
         inferenceType: InferenceType = .localWhisperCLI,
         endpointURL: String? = nil, modelIdentifier: String? = nil, apiKey: String? = nil, isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.systemName = systemName
        self.languageCode = languageCode
        self.fileName = fileName
        self.isBundled = isBundled
        self.sizeMB = sizeMB
        self.downloadURL = downloadURL
        self.inferenceType = inferenceType
        self.endpointURL = endpointURL
        self.modelIdentifier = modelIdentifier
        self.apiKey = apiKey
        self.isCustom = isCustom
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        systemName = try container.decode(String.self, forKey: .systemName)
        languageCode = try container.decode(String.self, forKey: .languageCode)
        fileName = try container.decode(String.self, forKey: .fileName)
        isBundled = try container.decode(Bool.self, forKey: .isBundled)
        sizeMB = try container.decode(Int.self, forKey: .sizeMB)
        downloadURL = try container.decodeIfPresent(URL.self, forKey: .downloadURL)
        inferenceType = try container.decodeIfPresent(InferenceType.self, forKey: .inferenceType) ?? (isBundled ? .bundledCLI : .localWhisperCLI)
        endpointURL = try container.decodeIfPresent(String.self, forKey: .endpointURL)
        modelIdentifier = try container.decodeIfPresent(String.self, forKey: .modelIdentifier)
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
        isCustom = try container.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
    }
}

extension RecognitionModel {
    static let russianGigaAM = RecognitionModel(
        id: "ru_giga",
        name: "RecognitionModel.Russian",
        systemName: "GigaAM",
        languageCode: "ru",
        fileName: "gigaam",
        isBundled: true,
        sizeMB: 273,
        downloadURL: nil,
        inferenceType: .bundledCLI
    )
    static let englishTurbo = RecognitionModel(
        id: "en_turbo",
        name: "RecognitionModel.EnglishTurbo",
        systemName: "Whisper Large-v3 Turbo",
        languageCode: "en",
        fileName: "ggml-large-v3-turbo-q8_0.bin",
        isBundled: false,
        sizeMB: 820,
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin"),
        inferenceType: .localWhisperCLI
    )
    static let englishMedium = RecognitionModel(
        id: "en_medium",
        name: "RecognitionModel.EnglishMedium",
        systemName: "Whisper Medium (Q5)",
        languageCode: "en",
        fileName: "ggml-medium-q5_0.bin",
        isBundled: false,
        sizeMB: 510,
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin"),
        inferenceType: .localWhisperCLI
    )
}

final class ModelStore: NSObject, ObservableObject {
    static let shared = ModelStore()

    static let builtinCatalog: [RecognitionModel] = [.russianGigaAM, .englishTurbo, .englishMedium]

    @Published private(set) var customModels: [RecognitionModel] = []
    
    var allModels: [RecognitionModel] {
        Self.builtinCatalog + customModels
    }
    
    // Сохраняем обратную совместимость с catalog
    static var catalog: [RecognitionModel] {
        ModelStore.shared.allModels
    }

    @Published var downloadingID: String?
    @Published var downloadProgress: Double = 0
    @Published var downloadStatus = ""
    @Published var downloadFailed = false

    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        loadCustomModels()
    }

    var activeModelID: String {
        get { UserDefaults.standard.string(forKey: "recognized.activeModel") ?? RecognitionModel.russianGigaAM.id }
        set {
            UserDefaults.standard.set(newValue, forKey: "recognized.activeModel")
            objectWillChange.send()
        }
    }

    func model(named id: String) -> RecognitionModel? {
        allModels.first { $0.id == id } ?? allModels.first { $0.name == id }
    }

    // MARK: - Управление кастомными инференсами

    private var customModelsFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Golosok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("custom_inferences.json")
    }

    func addCustomModel(name: String, endpointURL: String, modelIdentifier: String, apiKey: String?) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEndpoint = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModelId = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanName.isEmpty, !cleanEndpoint.isEmpty else { return }

        let model = RecognitionModel(
            id: "custom_" + UUID().uuidString.prefix(8),
            name: cleanName,
            systemName: cleanModelId.isEmpty ? cleanName : cleanModelId,
            languageCode: "ru",
            fileName: "",
            isBundled: false,
            sizeMB: 0,
            downloadURL: nil,
            inferenceType: .remoteOpenAI,
            endpointURL: cleanEndpoint,
            modelIdentifier: cleanModelId,
            apiKey: (cleanKey?.isEmpty == false) ? cleanKey : nil,
            isCustom: true
        )
        customModels.append(model)
        persistCustomModels()
        objectWillChange.send()
    }

    func removeCustomModel(id: String) {
        customModels.removeAll { $0.id == id }
        if activeModelID == id {
            activeModelID = RecognitionModel.russianGigaAM.id
        }
        persistCustomModels()
        objectWillChange.send()
    }

    private func persistCustomModels() {
        guard let url = customModelsFileURL,
              let data = try? JSONEncoder().encode(customModels) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadCustomModels() {
        guard let url = customModelsFileURL,
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([RecognitionModel].self, from: data) else { return }
        customModels = list
    }

    private var modelsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Golosok/Models", isDirectory: true)
    }

    func localModelPath(for id: String) -> String? {
        guard let model = model(named: id) else { return nil }
        if model.isBundled {
            return Bundle.main.path(forResource: model.fileName, ofType: model.id == "ru_giga" ? "gguf" : nil)
        }
        let path = modelsDir.appendingPathComponent(model.fileName).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    func isDownloaded(_ id: String) -> Bool {
        guard let model = model(named: id), !model.isBundled else { return true }
        return FileManager.default.fileExists(atPath: modelsDir.appendingPathComponent(model.fileName).path)
    }

    func download(_ id: String) {
        guard let model = model(named: id), let url = model.downloadURL, !isDownloaded(id) else { return }
        downloadFailed = false
        downloadStatus = "DownloadStatus.Connecting"
        downloadingID = id
        downloadProgress = 0
        AppLogger.shared.info("Models", "Начало скачивания модели", details: "\(id) — \(sizeMB(for: model))")
        Telemetry.shared.event("model_download_start", ["model_id": id, "model_size_mb": model.sizeMB])
        task = session?.downloadTask(with: url)
        task?.resume()
    }

    private func sizeMB(for model: RecognitionModel) -> Int { model.sizeMB }

    func cancel() {
        task?.cancel()
        task = nil
        downloadingID = nil
        downloadStatus = ""
    }

    func remove(_ id: String) {
        guard let model = model(named: id), !model.isBundled else { return }
        let path = modelsDir.appendingPathComponent(model.fileName).path
        if FileManager.default.fileExists(atPath: path) { try? FileManager.default.removeItem(atPath: path) }
        if activeModelID == id { activeModelID = RecognitionModel.russianGigaAM.id }
        objectWillChange.send()
    }
}

extension ModelStore: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        DispatchQueue.main.async {
            self.downloadProgress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            let mbW = Double(totalBytesWritten) / (1024.0 * 1024.0)
            let mbT = Double(totalBytesExpectedToWrite) / (1024.0 * 1024.0)
            let pct = Int(self.downloadProgress * 100.0)
            self.downloadStatus = String(format: "%.0f / %.0f МБ (%d%%)", mbW, mbT, pct)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadingID
        guard let id, let model = self.model(named: id), !model.isBundled else {
            DispatchQueue.main.async { self.downloadingID = nil; self.downloadStatus = "" }
            return
        }
        do {
            try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            let dest = modelsDir.appendingPathComponent(model.fileName)
            if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: location, to: dest)
            AppLogger.shared.info("Models", "Модель скачана", details: id)
            Telemetry.shared.event("model_download_done", ["model_id": id, "model_size_mb": model.sizeMB])
            DispatchQueue.main.async {
                self.downloadingID = nil
                self.downloadStatus = "DownloadStatus.Ready"
            }
        } catch {
            AppLogger.shared.error("Models", "Ошибка сохранения модели", details: "\(id): \(error.localizedDescription)")
            Telemetry.shared.event("model_download_failed", ["model_id": id, "error_stage": "move", "error_detail": String(describing: error)])
            DispatchQueue.main.async {
                self.downloadingID = nil
                self.downloadStatus = "DownloadStatus.Failed"
                self.downloadFailed = true
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard error != nil else { return }
        let id = downloadingID
        AppLogger.shared.error("Models", "Скачивание модели прервано", details: "\(id ?? "?") — \(error?.localizedDescription ?? "ошибка")")
        Telemetry.shared.event("model_download_failed", ["model_id": id ?? "?", "error_stage": "network", "error_detail": error?.localizedDescription ?? ""])
        DispatchQueue.main.async {
            self.downloadingID = nil
            self.downloadStatus = "DownloadStatus.Failed"
            self.downloadFailed = true
        }
    }
}