import Foundation

struct AIPromptTemplate: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var icon: String
    var system: String
    var isProtected: Bool
    var isCustom: Bool          // false = built-in (локализуется по ключу), true = пользовательский (как есть)
    var createdAt: Date

    /// Служебные промпты (например, валидатор словаря кандидатов), которые не должны предлагаться
    /// как действие в меню трансформации текста заметок или выделения.
    var isInternalSystem: Bool {
        id == "techValidator"
    }

    init(id: String, title: String, icon: String, system: String,
         isProtected: Bool = false, isCustom: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.icon = icon
        self.system = system
        self.isProtected = isProtected
        self.isCustom = isCustom
        self.createdAt = createdAt
    }

    func messages(for text: String, dynamicTerms: [TechTermRule] = []) -> [AIChatMessage] {
        var effectiveSystem = self.system
        
        if !dynamicTerms.isEmpty {
            let hints = dynamicTerms.map { rule in
                let pats = rule.patterns.joined(separator: ", ")
                return "- '\(rule.canonical)' (возможные созвучные искажения: \(pats))"
            }.joined(separator: "\n")
            
            effectiveSystem += "\n\nКонтекстные подсказки по IT-терминам, которые могли прозвучать:\n\(hints)"
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let userPrompt = "Текст расшифровки:\n\n\"\"\"\n\(trimmed)\n\"\"\"\n\nВыполни задание. Сразу выведи готовый результат без вводных слов и без избыточных рассуждений."
        return [
            AIChatMessage(role: "system", content: effectiveSystem),
            AIChatMessage(role: "user", content: userPrompt)
        ]
    }
}

enum AIPromptDefaults {
    private static let commonRules = "Расшифровка сделана голосовой моделью и может содержать ошибки распознавания — исправляй очевидные опечатки по контексту. Отвечай сразу готовым результатом без вводных фраз, без избыточных рассуждений и без воды."

    /// Встроенные промпты при первом запуске. Один (polish) защищён от удаления.
    static let defaults: [AIPromptTemplate] = [
        // ТЕХНИЧЕСКАЯ РЕСТАВРАЦИЯ
        .init(id: "restoreTechTerms", title: "Восстановить IT-термины", icon: "terminal",
              system: "Ты — редактор технического текста и code-switching после голосовой модели GigaAM.\n\nПРАВИЛА:\n1. Текст надиктован на русском языке. Сохраняй русский язык как основной язык текста.\n2. Восстанавливай каноническое написание на латинице ТОЛЬКО для англоязычных IT-терминов, названий библиотек, утилит, технологий, брендов и аббревиатур, которые голосовая модель исказила в фонетический транслит или созвучные формы.\n3. Если слово изначально является естественным русским словом в контексте фразы — категорически запрещено переводить его на английский язык. Это исправление опечаток и транслита, а не переводчик.\n4. Исправь орфографию и пунктуацию. Не меняй структуру и стиль автора без необходимости.\n5. Отвечай строго готовым результатом без вводных слов, пояснений и оформления.",
              isProtected: true),
        .init(id: "techValidator", title: "Верификатор IT-терминов", icon: "shield.checkerboard",
              system: "Ты — специализированный верификатор словаря автозамены IT-терминов после голосовой модели GigaAM.\nОпредели для каждого пункта, является ли исходное слово фонетическим транслитом, созвучным написанием или ослышкой указанного термина в IT-контексте (например, 'сайт-бар' для 'sidebar', 'опен-код' для 'OpenCode', 'веп-н-код' для 'OpenCode', 'веб-ваут' для 'Vaultwarden' — это ВАЛИДНЫЕ искажения). Дефисные и транслитерационные формы являются нормой голосового распознавания и ДОЛЖНЫ одобряться.\n\nОтклоняй ТОЛЬКО очевидные смысловые галлюцинации и совершенно несвязанные русские слова (например: 'голосок' -> 'Vaultwarden', 'программа' -> 'OpenCode', 'кнопка' -> 'SSH' — это НЕТ).\n\nОтвечай ТОЛЬКО валидным JSON-объектом без пояснений в формате:\n{\"1\": true, \"2\": false, ...}",
              isProtected: true),
        // СТИЛЬ И РЕДАКТУРА
        .init(id: "polish", title: "Улучшить стиль", icon: "sparkles",
              system: "Ты — профессиональный редактор. \(commonRules) Перепиши текст, сохранив его смысл, но сделав его более связным, выразительным и лаконичным. Убери заикания, слова-паразиты и повторы. Пиши на русском.",
              isProtected: true),
        .init(id: "fixGrammar", title: "Исправить ошибки", icon: "wrench.and.screwdriver",
              system: "Ты — корректор. \(commonRules) Исправь все орфографические, пунктуационные и грамматические ошибки в тексте. Не меняй структуру и стиль автора без необходимости. Сразу выведи исправленный текст. Пиши на русском."),
        .init(id: "businessTone", title: "Деловой стиль", icon: "briefcase",
              system: "Ты — бизнес-копирайтер. \(commonRules) Перепиши данный текст в строгом деловом и корпоративном стиле. Подходит для рабочей переписки, отчетов и писем клиентам. Пиши на русском."),
        .init(id: "rewrite", title: "Переписать в пост/письмо", icon: "pencil.and.outline",
              system: "Ты — редактор. \(commonRules) Преврати сырую расшифровку в связный, отполированный текст, пригодный для поста или письма. Убери повторы, слова-паразиты и разговорные сбои. Сохрани смысл и тон автора. Пиши на русском."),
        // АНАЛИЗ И ВСТРЕЧИ
        .init(id: "summary", title: "Саммари и тезисы", icon: "text.quote",
              system: "Ты — ассистент для работы с расшифровками созвонов и голосовых заметок. \(commonRules) Составь краткое саммари: 3–6 пунктов с ключевыми тезисами и выводами. Пиши на русском."),
        .init(id: "actionItems", title: "Задачи и действия", icon: "checklist",
              system: "Ты — ассистент. \(commonRules) Выдели из расшифровки список задач и решений. Сгруппируй по разделам «Задачи», «Решения», «Сроки». Для каждой задачи укажи ответственного и срок, если они названы. Чего нет в тексте — не выдумывай. Пиши на русском."),
        .init(id: "minutes", title: "Протокол встречи", icon: "doc.text",
              system: "Ты — ассистент. \(commonRules) Составь структурированный протокол встречи: «Участники» (если понятно из текста), «Повестка», «Обсуждение» (по темам), «Решения», «Задачи» (с ответственным и сроком). Пиши на русском."),
        // СЕРВИСНЫЕ И ПЕРЕВОД
        .init(id: "title", title: "Придумать заголовок", icon: "character.cursor.ibeam",
              system: "Ты — ассистент. \(commonRules) Придумай короткий точный заголовок для заметки, максимум 8 слов. Верни только заголовок — без кавычек, без пояснений. На русском."),
        .init(id: "translate", title: "Перевод на английский", icon: "globe",
              system: "Ты — переводчик. \(commonRules) Переведи текст на английский язык, сохраняя смысл, структуру и термины. Верни только перевод.")
    ]

    /// Идентификаторы встроенных промптов (для локализации по ключу и сброса).
    static let builtinIDs: Set<String> = Set(defaults.map { $0.id })

    static func template(id: String) -> AIPromptTemplate? {
        defaults.first { $0.id == id }
    }
}