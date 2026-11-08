import Foundation
import SwiftUI

struct AIChatMessage: Codable {
    let role: String
    let content: String
}

struct AIProviderPreset: Identifiable, Codable {
    let id: String
    var name: String
    var hint: String
    var baseURL: String
    var defaultModel: String
    var needsKey: Bool
    var isProxy: Bool = false
    var isCustom: Bool = false
}

enum AIProviderPresets {
    static let builtin: [AIProviderPreset] = [
        AIProviderPreset(
            id: "openai",
            name: "OpenAI",
            hint: "gpt-4o-mini, gpt-4o",
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-4o-mini",
            needsKey: true
        ),
        AIProviderPreset(
            id: "neuraldeep",
            name: "Neuraldeep (NP)",
            hint: "neuraldeep.ru — API & OAuth2",
            baseURL: "https://api.neuraldeep.ru/v1",
            defaultModel: "qwen3.6-fp8-noreason",
            needsKey: true
        ),
        AIProviderPreset(
            id: "deepseek",
            name: "DeepSeek",
            hint: "deepseek-flash, deepseek-v4-pro",
            baseURL: "https://api.deepseek.com",
            defaultModel: "deepseek-flash",
            needsKey: true
        ),
        AIProviderPreset(
            id: "groq",
            name: "Groq",
            hint: "llama-3.3-70b-versatile",
            baseURL: "https://api.groq.com/openai/v1",
            defaultModel: "llama-3.3-70b-versatile",
            needsKey: true
        ),
        AIProviderPreset(
            id: "ollama",
            name: "Local AI",
            hint: "LM Studio / Ollama / Local",
            baseURL: "http://localhost:11434/v1",
            defaultModel: "gemma3:1b",
            needsKey: false
        ),
        AIProviderPreset(
            id: "golosok_proxy",
            name: "Голосок+",
            hint: "Облачные модели на серверах Голоска — по подписке",
            baseURL: "https://golosok.space/api/v1",
            defaultModel: "",
            needsKey: false,
            isProxy: true
        )
    ]

    static var all: [AIProviderPreset] {
        AIProviderStore.shared.allPresets
    }

    static func preset(id: String) -> AIProviderPreset? {
        builtin.first { $0.id == id } ?? all.first { $0.id == id }
    }
}

enum AIReasoningEffort: String, CaseIterable, Identifiable {
    case off = "off"
    case low = "low"
    case medium = "medium"
    case high = "high"

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .off: return "Выкл (не передавать)"
        case .low: return "Low (минимальный)"
        case .medium: return "Medium (средний)"
        case .high: return "High (глубокий)"
        }
    }
}

enum AIThinkingBudgetMode: String, CaseIterable, Identifiable {
    case off = "off"
    case fixed1024 = "fixed1024"
    case proportional = "proportional"

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .off: return "Выкл (как сейчас)"
        case .fixed1024: return "Фиксированный (1024 токена)"
        case .proportional: return "Текст × 2 токена"
        }
    }
}

struct AIProviderConfig {
    let baseURL: String
    let apiKey: String
    let model: String
    let isProxy: Bool
    let reasoningEffort: AIReasoningEffort
    let thinkingBudgetMode: AIThinkingBudgetMode
    let maxTokens: Int
}

enum AIError: LocalizedError {
    case notConfigured
    case invalidURL
    case network(String)
    case http(Int, String)
    case emptyResponse
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "ИИ-провайдер не настроен")
        case .invalidURL:
            return String(localized: "Некорректный baseURL")
        case .network(let message):
            return String(localized: "Сетевая ошибка") + ": \(message)"
        case .http(let code, let message):
            return String(localized: "Ошибка сервера") + " \(code): \(message)"
        case .emptyResponse:
            return String(localized: "Модель вернула пустой ответ")
        case .parse(let message):
            return String(localized: "Не удалось разобрать ответ") + ": \(message)"
        }
    }
}

final class AIProviderStore: ObservableObject {
    static let shared = AIProviderStore()

    @Published var providerID: String { didSet { Self.defaults.set(providerID, forKey: "ai.providerID") } }
    @Published var isFailoverEnabled: Bool { didSet { Self.defaults.set(isFailoverEnabled, forKey: "ai.failover.enabled") } }
    @Published var failoverProviderID: String { didSet { Self.defaults.set(failoverProviderID, forKey: "ai.failover.providerID") } }
    @Published var baseURL: String {
        didSet {
            Self.defaults.set(baseURL, forKey: "ai.baseURL")
            Self.defaults.set(baseURL, forKey: "ai.provider.\(providerID).baseURL")
        }
    }
    @Published var model: String {
        didSet {
            Self.defaults.set(model, forKey: "ai.model")
            Self.defaults.set(model, forKey: "ai.provider.\(providerID).model")
        }
    }
    @Published var apiKey: String {
        didSet {
            if apiKey != oldValue {
                KeyStore.set(apiKey, for: "ai.provider.\(providerID).apiKey")
            }
        }
    }
    @Published var allowInsecureHTTP: Bool { didSet { Self.defaults.set(allowInsecureHTTP, forKey: "ai.allowInsecureHTTP") } }
    @Published var reasoningEffort: AIReasoningEffort { didSet { Self.defaults.set(reasoningEffort.rawValue, forKey: "ai.reasoningEffort") } }
    @Published var thinkingBudgetMode: AIThinkingBudgetMode { didSet { Self.defaults.set(thinkingBudgetMode.rawValue, forKey: "ai.thinkingBudgetMode") } }
    @Published var maxTokensString: String { didSet { Self.defaults.set(maxTokensString, forKey: "ai.maxTokens") } }

    var maxTokens: Int {
        if let val = Int(maxTokensString.trimmingCharacters(in: .whitespaces)), val > 0 {
            return val
        }
        return 4096
    }

    @Published var isTesting = false
    @Published var testResult: String?
    @Published var testOK = false
    @Published var installedModels: [String] = []
    @Published var isLoadingModels = false
    @Published var customPresets: [AIProviderPreset] = []
    @Published var customDisplayNames: [String: String] = [:]

    var allPresets: [AIProviderPreset] {
        (AIProviderPresets.builtin + customPresets).map { preset in
            var p = preset
            if let customName = customDisplayNames[preset.id], !customName.isEmpty {
                p.name = customName
            }
            return p
        }
    }

    private static let defaults = UserDefaults.standard

    private var customPresetsFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Golosok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("custom_ai_providers.json")
    }

    private init() {
        var names: [String: String] = [:]
        if let savedNames = Self.defaults.dictionary(forKey: "ai.provider.custom_names") as? [String: String] {
            names = savedNames
        }
        self.customDisplayNames = names

        // Загрузка кастомных провайдеров
        var loadedCustom: [AIProviderPreset] = []
        if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let fileURL = base.appendingPathComponent("Golosok/custom_ai_providers.json")
            if let data = try? Data(contentsOf: fileURL),
               let list = try? JSONDecoder().decode([AIProviderPreset].self, from: data) {
                loadedCustom = list
            }
        }
        self.customPresets = loadedCustom

        let savedID = Self.defaults.string(forKey: "ai.providerID") ?? ""
        let initialPreset = loadedCustom.first(where: { $0.id == savedID })
            ?? AIProviderPresets.builtin.first(where: { $0.id == savedID })
            ?? AIProviderPresets.builtin[0]
        let currentID = savedID.isEmpty ? initialPreset.id : savedID
        self.providerID = currentID
        self.isFailoverEnabled = Self.defaults.object(forKey: "ai.failover.enabled") as? Bool ?? false
        self.failoverProviderID = Self.defaults.string(forKey: "ai.failover.providerID") ?? "ollama"
        let resolvedBaseURL = Self.defaults.string(forKey: "ai.provider.\(currentID).baseURL")
            ?? Self.defaults.string(forKey: "ai.baseURL")
            ?? initialPreset.baseURL
        self.baseURL = resolvedBaseURL
        var resolvedModel = Self.defaults.string(forKey: "ai.provider.\(currentID).model")
            ?? Self.defaults.string(forKey: "ai.model")
            ?? initialPreset.defaultModel
        if currentID == "neuraldeep" && (resolvedModel == "neuraldeep/qwen3.8-27b" || resolvedModel.isEmpty) {
            resolvedModel = "qwen3.6-fp8-noreason"
            Self.defaults.set(resolvedModel, forKey: "ai.provider.neuraldeep.model")
            Self.defaults.set(resolvedModel, forKey: "ai.model")
        }
        if currentID == "deepseek" && (resolvedModel == "deepseek-chat" || resolvedModel == "deepseek-reasoner" || resolvedModel.isEmpty) {
            resolvedModel = "deepseek-flash"
            Self.defaults.set(resolvedModel, forKey: "ai.provider.deepseek.model")
            Self.defaults.set(resolvedModel, forKey: "ai.model")
        }
        self.model = resolvedModel
        self.apiKey = KeyStore.get("ai.provider.\(currentID).apiKey")
            ?? (resolvedBaseURL.contains("8317") ? KeyStore.get("ai.provider.openai.apiKey") : nil)
            ?? KeyStore.get("ai.apiKey")
            ?? ""
        self.allowInsecureHTTP = Self.defaults.object(forKey: "ai.allowInsecureHTTP") as? Bool ?? true

        if let rawEffort = Self.defaults.string(forKey: "ai.reasoningEffort"),
           let effort = AIReasoningEffort(rawValue: rawEffort) {
            self.reasoningEffort = effort
        } else {
            self.reasoningEffort = .low
        }

        if let rawBudget = Self.defaults.string(forKey: "ai.thinkingBudgetMode"),
           let budget = AIThinkingBudgetMode(rawValue: rawBudget) {
            self.thinkingBudgetMode = budget
        } else {
            self.thinkingBudgetMode = .fixed1024
        }

        self.maxTokensString = Self.defaults.string(forKey: "ai.maxTokens") ?? "4096"
    }

    func setPresetName(_ newName: String, for presetId: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            customDisplayNames.removeValue(forKey: presetId)
        } else {
            customDisplayNames[presetId] = clean
        }
        Self.defaults.set(customDisplayNames, forKey: "ai.provider.custom_names")
        objectWillChange.send()
    }

    func addCustomPreset(name: String, baseURL: String, model: String, apiKey: String?) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanURL.isEmpty else { return }

        let id = "custom_" + UUID().uuidString.prefix(8)
        let preset = AIProviderPreset(
            id: id,
            name: cleanName,
            hint: cleanURL,
            baseURL: cleanURL,
            defaultModel: cleanModel.isEmpty ? "default" : cleanModel,
            needsKey: false,
            isProxy: false,
            isCustom: true
        )
        customPresets.append(preset)
        persistCustomPresets()

        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            KeyStore.set(key, for: "ai.provider.\(id).apiKey")
        }

        apply(preset)
    }

    func deleteCustomPreset(id: String) {
        customPresets.removeAll { $0.id == id }
        customDisplayNames.removeValue(forKey: id)
        Self.defaults.set(customDisplayNames, forKey: "ai.provider.custom_names")
        persistCustomPresets()
        KeyStore.delete("ai.provider.\(id).apiKey")

        if providerID == id {
            if let first = AIProviderPresets.builtin.first {
                apply(first)
            }
        } else {
            objectWillChange.send()
        }
    }

    private func persistCustomPresets() {
        guard let url = customPresetsFileURL,
              let data = try? JSONEncoder().encode(customPresets) else { return }
        try? data.write(to: url, options: .atomic)
    }

    var currentPreset: AIProviderPreset? {
        allPresets.first { $0.id == providerID }
    }

    var failoverPreset: AIProviderPreset? {
        allPresets.first { $0.id == failoverProviderID }
    }

    var config: AIProviderConfig {
        let isProxy = currentPreset?.isProxy ?? false
        return AIProviderConfig(
            baseURL: baseURL,
            apiKey: isProxy ? AccountStore.shared.token : apiKey,
            model: model,
            isProxy: isProxy,
            reasoningEffort: reasoningEffort,
            thinkingBudgetMode: thinkingBudgetMode,
            maxTokens: maxTokens
        )
    }

    /// Конфигурация для резервного провайдера (Failover)
    var failoverConfig: AIProviderConfig? {
        guard isFailoverEnabled, !failoverProviderID.isEmpty, failoverProviderID != providerID else { return nil }
        guard let preset = failoverPreset else { return nil }

        let bURL = Self.defaults.string(forKey: "ai.provider.\(preset.id).baseURL") ?? preset.baseURL
        let mdl = Self.defaults.string(forKey: "ai.provider.\(preset.id).model") ?? preset.defaultModel
        let isProxy = preset.isProxy
        let key = isProxy ? AccountStore.shared.token : (KeyStore.get("ai.provider.\(preset.id).apiKey") ?? "")

        guard isProxy || (!bURL.isEmpty && !mdl.isEmpty) else { return nil }

        return AIProviderConfig(
            baseURL: bURL,
            apiKey: key,
            model: mdl,
            isProxy: isProxy,
            reasoningEffort: reasoningEffort,
            thinkingBudgetMode: thinkingBudgetMode,
            maxTokens: maxTokens
        )
    }

    var isConfigured: Bool {
        if currentPreset?.isProxy == true {
            return true
        }
        return !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func apply(_ preset: AIProviderPreset) {
        guard providerID != preset.id else {
            // Если выбран тот же пресет, не сбрасываем пользовательские настройки
            return
        }

        providerID = preset.id

        // Восстанавливаем ранее сохраненные настройки именно для этого провайдера,
        // либо берем дефолтные значения пресета
        baseURL = Self.defaults.string(forKey: "ai.provider.\(preset.id).baseURL") ?? preset.baseURL
        var savedModel = Self.defaults.string(forKey: "ai.provider.\(preset.id).model") ?? preset.defaultModel
        if preset.id == "neuraldeep" && savedModel == "neuraldeep/qwen3.8-27b" {
            savedModel = "qwen3.6-fp8-noreason"
        }
        if preset.id == "deepseek" && (savedModel == "deepseek-chat" || savedModel == "deepseek-reasoner") {
            savedModel = "deepseek-flash"
        }
        model = savedModel
        apiKey = KeyStore.get("ai.provider.\(preset.id).apiKey")
            ?? (preset.baseURL.contains("8317") ? KeyStore.get("ai.provider.openai.apiKey") : nil)
            ?? KeyStore.get("ai.apiKey")
            ?? (preset.needsKey ? "" : "")

        testResult = nil
        testOK = false
        installedModels = []
        if preset.id == "ollama" {
            refreshModels()
        }
        AppLogger.shared.info("AI", "Выбран провайдер \(preset.name)", details: baseURL)
    }

    func refreshModels() {
        guard !(currentPreset?.isProxy ?? false) else { return }
        isLoadingModels = true
        installedModels = []
        AIService.shared.listModels(using: config) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoadingModels = false
                switch result {
                case .success(let models):
                    self.installedModels = models.sorted()
                case .failure:
                    self.installedModels = []
                }
            }
        }
    }

    func testConnection() {
        if currentPreset?.isProxy == true {
            testOK = AccountStore.shared.isConnected
            testResult = AccountStore.shared.isConnected ? String(localized: "Сервер доступен через аккаунт") : String(localized: "Подключите аккаунт")
            return
        }

        let cleanURL = baseURL.trimmingCharacters(in: .whitespaces)
        let cleanModel = model.trimmingCharacters(in: .whitespaces)

        if cleanURL.isEmpty {
            testOK = false
            testResult = String(localized: "Заполните Base URL")
            return
        }
        if cleanModel.isEmpty {
            testOK = false
            testResult = String(localized: "Укажите модель")
            return
        }

        let trimmedURL = cleanURL.lowercased()
        if trimmedURL.hasPrefix("http://") && !allowInsecureHTTP {
            testOK = false
            testResult = String(localized: "HTTP запрещён. Включите разрешение HTTP или используйте HTTPS.")
            return
        }

        isTesting = true
        testResult = nil
        testOK = false
        AIService.shared.test(using: config) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isTesting = false
                switch result {
                case .success:
                    self.testOK = true
                    self.testResult = String(localized: "Подключено")
                    AppLogger.shared.info("AI", "Проверка подключения успешна", details: "\(self.baseURL) / \(self.model)")
                case .failure(let error):
                    self.testOK = false
                    self.testResult = error.localizedDescription
                    AppLogger.shared.warn("AI", "Проверка подключения не удалась", details: error.localizedDescription)
                }
            }
        }
    }
}

final class AIService {
    static let shared = AIService()

    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    private func buildUniversalPayload(
        messages: [AIChatMessage],
        config: AIProviderConfig,
        promptLength: Int?,
        stream: Bool,
        isFallback: Bool
    ) -> (data: Data?, debugDesc: String) {
        let userMaxTokens = config.maxTokens > 0 ? config.maxTokens : 4096
        let chars = promptLength ?? messages.reduce(0) { $0 + $1.content.count }
        let approxPromptTokens = max(64, chars / 4)
        let minTokensForOutput = approxPromptTokens + 512

        var payload: [String: Any] = [:]
        if !config.isProxy && !config.model.isEmpty {
            payload["model"] = config.model
        }

        let encodedMessages: [[String: String]] = messages.map { ["role": $0.role, "content": $0.content] }
        payload["messages"] = encodedMessages
        if stream {
            payload["stream"] = true
        }

        let modelLower = config.model.lowercased()
        let baseURLLower = config.baseURL.lowercased()
        let isOpenAI = baseURLLower.contains("api.openai.com")
        let isOpenAI_O_Series = isOpenAI && (modelLower.hasPrefix("o1") || modelLower.hasPrefix("o3") || modelLower.contains("-o1-") || modelLower.contains("-o3-"))
        let isDeepSeek = baseURLLower.contains("deepseek.com") || modelLower.contains("deepseek")
        let isNeuralDeep = baseURLLower.contains("neuraldeep")
        let isQwen = isNeuralDeep || modelLower.contains("qwen")
        let isOpenRouter = baseURLLower.contains("openrouter.ai")

        // 1. Fallback режим: чистый совместимый стандарт OpenAI
        if isFallback {
            payload["temperature"] = 0.3
            payload["max_tokens"] = userMaxTokens
            let data = try? JSONSerialization.data(withJSONObject: payload)
            return (data, "fallback=true, max_tokens=\(userMaxTokens)")
        }

        // 2. Расчет лимита токенов
        var maxTokensParam = userMaxTokens
        let isReasoningOff = (config.reasoningEffort == .off && config.thinkingBudgetMode == .off)

        if !isReasoningOff {
            switch config.thinkingBudgetMode {
            case .off:
                maxTokensParam = max(userMaxTokens, minTokensForOutput)
            case .fixed1024:
                let budget = 1024
                maxTokensParam = max(userMaxTokens, budget + minTokensForOutput)
            case .proportional:
                let budget = max(256, approxPromptTokens * 2)
                maxTokensParam = max(userMaxTokens, budget + minTokensForOutput)
            }
        }

        if isOpenAI_O_Series {
            payload["max_completion_tokens"] = maxTokensParam
        } else {
            payload["max_tokens"] = maxTokensParam
        }

        // 3. Температура
        if !isOpenAI_O_Series {
            if config.thinkingBudgetMode != .off && baseURLLower.contains("anthropic") {
                payload["temperature"] = 1.0
            } else {
                payload["temperature"] = 0.3
            }
        }

        // 4. Управление ризонингом
        if isReasoningOff {
            // Гарантированное выключение
            if isQwen {
                payload["chat_template_kwargs"] = ["enable_thinking": false]
            }
            if isDeepSeek {
                payload["thinking"] = ["type": "disabled"]
            }
            if isOpenRouter {
                payload["reasoning"] = ["max_tokens": 0]
            }
        } else {
            // Включение ризонинга по контрактам провайдеров
            if isOpenAI_O_Series {
                payload["reasoning_effort"] = config.reasoningEffort.rawValue
            } else if isDeepSeek {
                payload["thinking"] = ["type": "enabled"]
                let effortStr = (config.reasoningEffort == .low) ? "low" : "high"
                payload["reasoning_effort"] = effortStr
            } else if isQwen {
                payload["chat_template_kwargs"] = ["enable_thinking": true]
            } else if isOpenRouter {
                payload["reasoning"] = ["effort": config.reasoningEffort.rawValue]
            }

            if config.thinkingBudgetMode != .off {
                let budget: Int
                switch config.thinkingBudgetMode {
                case .off: budget = 0
                case .fixed1024: budget = 1024
                case .proportional: budget = max(256, approxPromptTokens * 2)
                }
                if budget > 0 {
                    payload["thinking"] = ["type": "enabled", "budget_tokens": budget]
                    payload["max_thinking_tokens"] = budget
                }
            }
        }

        let data = try? JSONSerialization.data(withJSONObject: payload)
        let desc = "reasoningOff=\(isReasoningOff), max_tokens=\(maxTokensParam)"
        return (data, desc)
    }

    @discardableResult
    func chatStream(
        messages: [AIChatMessage],
        using config: AIProviderConfig,
        promptLength: Int? = nil,
        isFallback: Bool = false,
        onChunk: @escaping (String, String?) -> Void,
        completion: @escaping (Result<String, AIError>) -> Void
    ) -> URLSessionDataTask? {
        guard let url = url(config.baseURL, path: "chat/completions") else {
            completion(.failure(.invalidURL))
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        addProxyHeaders(&request, config: config)

        let payloadInfo = buildUniversalPayload(
            messages: messages,
            config: config,
            promptLength: promptLength,
            stream: true,
            isFallback: isFallback
        )
        guard let data = payloadInfo.data else {
            completion(.failure(.parse("кодирование запроса")))
            return nil
        }
        request.httpBody = data

        AppLogger.shared.info("AI", isFallback ? "Стриминг-запрос (fallback)" : "Стриминг-запрос к модели", details: "\(config.baseURL) / \(config.model), \(payloadInfo.debugDesc)")

        let allowReasoning = (config.reasoningEffort != .off || config.thinkingBudgetMode != .off)

        return SSEStreamManager.shared.startStream(
            with: request,
            allowReasoning: allowReasoning,
            onChunk: onChunk
        ) { [weak self] result in
            switch result {
            case .failure(let error):
                if case .http(let code, let msg) = error, code == 400, !isFallback {
                    AppLogger.shared.warn("AI", "Стриминг вернул HTTP 400, выполняем повтор с чистым fallback payload", details: msg)
                    _ = self?.chatStream(
                        messages: messages,
                        using: config,
                        promptLength: promptLength,
                        isFallback: true,
                        onChunk: onChunk,
                        completion: completion
                    )
                    return
                }

                // Проверяем автоматический Failover на резервного провайдера
                if let backup = AIProviderStore.shared.failoverConfig, backup.baseURL != config.baseURL || backup.model != config.model {
                    if self?.shouldTriggerFailover(for: error) == true {
                        AppLogger.shared.warn("AI", "Основной провайдер недоступен, автоматическое переключение на резервный (Failover)", details: "\(backup.baseURL) / \(backup.model)")
                        _ = self?.chatStream(
                            messages: messages,
                            using: backup,
                            promptLength: promptLength,
                            isFallback: false,
                            onChunk: onChunk,
                            completion: completion
                        )
                        return
                    }
                }

                completion(.failure(error))
            case .success(let val):
                completion(.success(val))
            }
        }
    }

    @discardableResult
    func chat(
        messages: [AIChatMessage],
        using config: AIProviderConfig,
        promptLength: Int? = nil,
        isFallback: Bool = false,
        completion: @escaping (Result<String, AIError>) -> Void
    ) -> URLSessionDataTask? {
        guard let url = url(config.baseURL, path: "chat/completions") else {
            completion(.failure(.invalidURL))
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        addProxyHeaders(&request, config: config)

        let payloadInfo = buildUniversalPayload(
            messages: messages,
            config: config,
            promptLength: promptLength,
            stream: false,
            isFallback: isFallback
        )
        guard let data = payloadInfo.data else {
            completion(.failure(.parse("кодирование запроса")))
            return nil
        }
        request.httpBody = data

        AppLogger.shared.info("AI", isFallback ? "Запрос к модели (fallback)" : "Запрос к модели", details: "\(config.baseURL) / \(config.model), \(payloadInfo.debugDesc)")

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            if let error {
                if (error as NSError).code == NSURLErrorCancelled {
                    AppLogger.shared.info("AI", "Запрос к модели отменён пользователем")
                    return
                }
                let aiError = AIError.network(error.localizedDescription)
                if let backup = AIProviderStore.shared.failoverConfig, backup.baseURL != config.baseURL || backup.model != config.model {
                    if self?.shouldTriggerFailover(for: aiError) == true {
                        AppLogger.shared.warn("AI", "Основной провайдер недоступен (тайм-аут/сеть), переключение на резервный (Failover)", details: "\(backup.baseURL) / \(backup.model)")
                        _ = self?.chat(messages: messages, using: backup, promptLength: promptLength, completion: completion)
                        return
                    }
                }
                completion(.failure(aiError))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.network("нет HTTP-ответа")))
                return
            }
            guard let data else {
                completion(.failure(.emptyResponse))
                return
            }
            if !(200..<300).contains(http.statusCode) {
                let errDetail = Self.extractError(from: data) ?? "HTTP \(http.statusCode)"
                if http.statusCode == 400 && !isFallback {
                    AppLogger.shared.warn("AI", "Провайдер вернул HTTP 400, выполняем повтор с чистым fallback payload", details: errDetail)
                    _ = self?.chat(
                        messages: messages,
                        using: config,
                        promptLength: promptLength,
                        isFallback: true,
                        completion: completion
                    )
                    return
                }

                let httpErr = AIError.http(http.statusCode, errDetail)
                // Failover при 401, 403, 404, 429, 5xx
                if let backup = AIProviderStore.shared.failoverConfig, backup.baseURL != config.baseURL || backup.model != config.model {
                    if self?.shouldTriggerFailover(for: httpErr) == true {
                        AppLogger.shared.warn("AI", "Сбой основного провайдера (\(http.statusCode)), переключение на резервный (Failover)", details: "\(backup.baseURL) / \(backup.model)")
                        _ = self?.chat(messages: messages, using: backup, promptLength: promptLength, completion: completion)
                        return
                    }
                }

                completion(.failure(httpErr))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(.parse("не JSON")))
                return
            }
            guard let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String,
                  !content.isEmpty else {
                completion(.failure(.emptyResponse))
                return
            }
            completion(.success(content))
        }
        task.resume()
        return task
    }

    private func shouldTriggerFailover(for error: AIError) -> Bool {
        switch error {
        case .network:
            return true
        case .http(let code, _):
            return code == 401 || code == 403 || code == 404 || code == 429 || code >= 500
        case .emptyResponse, .invalidURL, .notConfigured:
            return true
        case .parse:
            return false
        }
    }

    func test(using config: AIProviderConfig, completion: @escaping (Result<Void, AIError>) -> Void) {
        guard let url = url(config.baseURL, path: "models") else {
            completion(.failure(.invalidURL))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        addProxyHeaders(&request, config: config)
        session.dataTask(with: request) { [weak self] data, response, error in
            if let error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.network("нет HTTP-ответа")))
                return
            }
            if (200..<300).contains(http.statusCode) {
                completion(.success(()))
            } else if http.statusCode == 404 {
                // Если сервер/прокси (например, CPAMP / Chained Model Proxy) не реализует GET /models,
                // проверяем доступность через легковесный POST /chat/completions с 1 токеном
                self?.testViaChatCompletions(using: config, completion: completion)
            } else {
                let message = (data.flatMap { Self.extractError(from: $0) }) ?? "HTTP \(http.statusCode)"
                completion(.failure(.http(http.statusCode, message)))
            }
        }.resume()
    }

    private func testViaChatCompletions(using config: AIProviderConfig, completion: @escaping (Result<Void, AIError>) -> Void) {
        guard let url = url(config.baseURL, path: "chat/completions") else {
            completion(.failure(.invalidURL))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        addProxyHeaders(&request, config: config)

        let testPayload: [String: Any] = [
            "model": config.model.isEmpty ? "default" : config.model,
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 1
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: testPayload)

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.network("нет HTTP-ответа")))
                return
            }
            if (200..<300).contains(http.statusCode) {
                completion(.success(()))
            } else {
                let message = (data.flatMap { Self.extractError(from: $0) }) ?? "HTTP \(http.statusCode)"
                completion(.failure(.http(http.statusCode, message)))
            }
        }.resume()
    }

    func listModels(using config: AIProviderConfig, completion: @escaping (Result<[String], AIError>) -> Void) {
        guard let url = url(config.baseURL, path: "models") else {
            completion(.failure(.invalidURL))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        addProxyHeaders(&request, config: config)
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else {
                completion(.failure(.emptyResponse))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(.parse("не JSON")))
                return
            }
            var names: [String] = []
            if let dataArr = json["data"] as? [[String: Any]] {
                names = dataArr.compactMap { $0["id"] as? String }
            }
            if names.isEmpty, let models = json["models"] as? [[String: Any]] {
                names = models.compactMap { $0["name"] as? String }
            }
            completion(.success(names))
        }.resume()
    }

    private func url(_ base: String, path: String) -> URL? {
        URL(string: "\(base.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")))/\(path)")
    }

    private func addProxyHeaders(_ request: inout URLRequest, config: AIProviderConfig) {
        guard config.isProxy else { return }
        request.setValue(Telemetry.shared.deviceID, forHTTPHeaderField: "X-Device-ID")
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            request.setValue(version, forHTTPHeaderField: "X-App-Version")
        }
        request.setValue(ProcessInfo.processInfo.operatingSystemVersionString, forHTTPHeaderField: "X-OS-Version")
    }

    static func extractError(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let error = json["error"] as? String {
            return error
        }
        return nil
    }
}

final class SSEStreamManager: NSObject, URLSessionDataDelegate {
    static let shared = SSEStreamManager()

    private class TaskContext {
        var buffer = ""
        var fullContent = ""
        var fullReasoning = ""
        var isInThinkTag = false
        var hasCompleted = false
        var httpStatusCode: Int?
        var errorData: Data?
        let allowReasoning: Bool
        let onChunk: (String, String?) -> Void
        let completion: (Result<String, AIError>) -> Void

        init(allowReasoning: Bool, onChunk: @escaping (String, String?) -> Void, completion: @escaping (Result<String, AIError>) -> Void) {
            self.allowReasoning = allowReasoning
            self.onChunk = onChunk
            self.completion = completion
        }
    }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private var contexts: [Int: TaskContext] = [:]
    private let lock = NSLock()

    func startStream(
        with request: URLRequest,
        allowReasoning: Bool = true,
        onChunk: @escaping (String, String?) -> Void,
        completion: @escaping (Result<String, AIError>) -> Void
    ) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        let context = TaskContext(allowReasoning: allowReasoning, onChunk: onChunk, completion: completion)
        lock.lock()
        contexts[task.taskIdentifier] = context
        lock.unlock()
        task.resume()
        return task
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let ctx = contexts[dataTask.taskIdentifier]
        lock.unlock()

        if let http = response as? HTTPURLResponse {
            ctx?.httpStatusCode = http.statusCode
            if !(200..<300).contains(http.statusCode) {
                ctx?.errorData = Data()
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let ctx = contexts[dataTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        lock.unlock()

        if let status = ctx.httpStatusCode, !(200..<300).contains(status) {
            ctx.errorData?.append(data)
            return
        }

        guard let text = String(data: data, encoding: .utf8) else { return }
        ctx.buffer.append(text)

        var lines: [String] = []
        while let range = ctx.buffer.range(of: "\n") {
            let line = String(ctx.buffer[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            ctx.buffer.removeSubrange(..<range.upperBound)
            if !line.isEmpty {
                lines.append(line)
            }
        }

        for line in lines {
            if line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" {
                    completeTask(dataTask.taskIdentifier, with: .success(ctx.fullContent))
                    return
                }
                guard let jsonData = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let firstChoice = choices.first,
                      let delta = firstChoice["delta"] as? [String: Any] else {
                    continue
                }

                let rawContent = delta["content"] as? String
                let rawReasoning = ctx.allowReasoning ? ((delta["reasoning_content"] as? String) ?? (delta["thinking"] as? String)) : nil

                var contentChunk: String? = nil
                var reasoningChunk: String? = nil

                if let rawReasoning, !rawReasoning.isEmpty {
                    reasoningChunk = rawReasoning
                }

                if var text = rawContent, !text.isEmpty {
                    if text.contains("<think>") {
                        ctx.isInThinkTag = true
                        text = text.replacingOccurrences(of: "<think>", with: "")
                    }
                    if ctx.isInThinkTag {
                        if text.contains("</think>") {
                            ctx.isInThinkTag = false
                            let parts = text.components(separatedBy: "</think>")
                            let thinkPart = parts.first ?? ""
                            let cleanPart = parts.dropFirst().joined(separator: "</think>")
                            if ctx.allowReasoning && !thinkPart.isEmpty {
                                reasoningChunk = (reasoningChunk ?? "") + thinkPart
                            }
                            if !cleanPart.isEmpty {
                                contentChunk = cleanPart
                            }
                        } else {
                            if ctx.allowReasoning {
                                reasoningChunk = (reasoningChunk ?? "") + text
                            }
                        }
                    } else {
                        contentChunk = text
                    }
                }

                if let contentChunk, !contentChunk.isEmpty {
                    ctx.fullContent.append(contentChunk)
                }
                if let reasoningChunk, !reasoningChunk.isEmpty {
                    ctx.fullReasoning.append(reasoningChunk)
                }

                if (contentChunk != nil && !contentChunk!.isEmpty) || (reasoningChunk != nil && !reasoningChunk!.isEmpty) {
                    DispatchQueue.main.async {
                        ctx.onChunk(contentChunk ?? "", reasoningChunk)
                    }
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskID = task.taskIdentifier
        lock.lock()
        guard let ctx = contexts[taskID] else {
            lock.unlock()
            return
        }
        lock.unlock()

        if let error = error as NSError? {
            if error.code == NSURLErrorCancelled {
                AppLogger.shared.info("AI", "Стриминг остановлен пользователем", details: "длина текста: \(ctx.fullContent.count)")
                if !ctx.fullContent.isEmpty {
                    completeTask(taskID, with: .success(ctx.fullContent))
                } else {
                    removeTask(taskID)
                }
                return
            }
            completeTask(taskID, with: .failure(.network(error.localizedDescription)))
            return
        }

        if let status = ctx.httpStatusCode, !(200..<300).contains(status) {
            let errorMsg = ctx.errorData.flatMap { AIService.extractError(from: $0) } ?? "HTTP \(status)"
            completeTask(taskID, with: .failure(.http(status, errorMsg)))
            return
        }

        if !ctx.fullContent.isEmpty {
            completeTask(taskID, with: .success(ctx.fullContent))
        } else {
            completeTask(taskID, with: .failure(.emptyResponse))
        }
    }

    private func completeTask(_ id: Int, with result: Result<String, AIError>) {
        lock.lock()
        guard let ctx = contexts[id], !ctx.hasCompleted else {
            lock.unlock()
            return
        }
        ctx.hasCompleted = true
        contexts.removeValue(forKey: id)
        lock.unlock()

        DispatchQueue.main.async {
            ctx.completion(result)
        }
    }

    private func removeTask(_ id: Int) {
        lock.lock()
        contexts.removeValue(forKey: id)
        lock.unlock()
    }
}
