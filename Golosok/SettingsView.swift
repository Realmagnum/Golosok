import SwiftUI

struct SettingsView: View {
    @ObservedObject var audioCapture = AudioCapture.shared
    @ObservedObject var permissions = PermissionManager.shared
    @ObservedObject var language = LanguageSettings.shared
    @ObservedObject var models = ModelStore.shared
    @ObservedObject var hotKey = HotKeySettings.shared
    @ObservedObject var techTerms = TechTermStore.shared
    @ObservedObject var promptStore = PromptStore.shared
    @State private var showingClearHistoryAlert = false
    @State private var showingAboutSheet = false
    @State private var showingLogsSheet = false
    @State private var showingTechTermsSheet = false
    @State private var showingAddInferenceSheet = false
    @State private var showingPromptManagerSheet = false
    
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 20) {
                
                // РАЗДЕЛ 0: ЯЗЫК
                UICard {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Язык приложения")
                                .font(UIStyleFont.body(size: 13, weight: .medium))
                                .foregroundColor(.uiInk)
                            Text("Приложение перезапустится автоматически")
                                .font(UIStyleFont.body(size: 11, weight: .regular))
                                .foregroundColor(.uiMidGray)
                        }
                        Spacer()
                        UIDropdownPicker(selection: Binding(
                            get: { language.current },
                            set: { language.select($0) }
                        ), options: [
                            .init("Система", value: AppLanguage.system),
                            .init("Русский", value: AppLanguage.ru),
                            .init("English", value: AppLanguage.en)
                        ], width: 140)
                    }
                }
                
                // РАЗДЕЛ 1: ОСНОВНЫЕ
                UICard {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("ОСНОВНЫЕ")
                            .font(UIStyleFont.body(size: 11, weight: .bold))
                            .tracking(1.0)
                            .foregroundColor(.uiMidGray)
                        
                        // 1. Автозапуск
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Запуск при входе")
                                    .font(UIStyleFont.body(size: 13, weight: .medium))
                                    .foregroundColor(.uiInk)
                                Text("Автоматически открывать в строке меню")
                                    .font(UIStyleFont.body(size: 11, weight: .regular))
                                    .foregroundColor(.uiMidGray)
                            }
                            Spacer()
                            Toggle("", isOn: $audioCapture.launchAtLoginEnabled)
                                .labelsHidden()
                                .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#10B981")))
                        }
                        
                        Divider().background(Color.uiHairline)
                        
                        // 2. Авто-вставка
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Авто-вставка текста")
                                        .font(UIStyleFont.body(size: 13, weight: .medium))
                                        .foregroundColor(.uiInk)
                                    
                                    if !permissions.isAccessibilityGranted {
                                        Text("Разрешите доступ")
                                            .font(UIStyleFont.body(size: 10, weight: .bold))
                                            .foregroundColor(.uiWarn)
                                    }
                                }
                                
                                Text(permissions.isAccessibilityGranted ?
                                     LocalizedStringKey("Печатать расшифровку прямо в место курсора") :
                                     LocalizedStringKey("Выдайте доступ в Универсальном доступе macOS"))
                                    .font(UIStyleFont.body(size: 11, weight: .regular))
                                    .foregroundColor(.uiMidGray)
                            }
                            Spacer()
                            
                            if permissions.isAccessibilityGranted {
                                Toggle("", isOn: $audioCapture.autoPasteEnabled)
                                    .labelsHidden()
                                    .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#10B981")))
                            } else {
                                UIOutlineButton(title: "Настройки") {
                                    permissions.requestAccessibilityPermission()
                                }
                            }
                        }
                        
                        Divider().background(Color.uiHairline)
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Сразу открывать в истории")
                                    .font(UIStyleFont.body(size: 13, weight: .medium))
                                    .foregroundColor(.uiInk)
                                Text("Автоматически открывать свежую заметку по завершении расшифровки")
                                    .font(UIStyleFont.body(size: 11, weight: .regular))
                                    .foregroundColor(.uiMidGray)
                            }
                            Spacer()
                            Toggle("", isOn: $audioCapture.autoOpenNoteEnabled)
                                .labelsHidden()
                                .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#10B981")))
                        }
                        
                        Divider().background(Color.uiHairline)
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Делиться аналитикой")
                                    .font(UIStyleFont.body(size: 13, weight: .medium))
                                    .foregroundColor(.uiInk)
                                Text("Автоматическая отправка анонимных метрик производительности")
                                    .font(UIStyleFont.body(size: 11, weight: .regular))
                                    .foregroundColor(.uiMidGray)
                            }
                            Spacer()
                            Toggle("", isOn: $audioCapture.analyticsEnabled)
                                .labelsHidden()
                                .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#10B981")))
                        }
                        
                        Divider().background(Color.uiHairline)
                        
                        // 4. Звуки
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Системные звуки")
                                    .font(UIStyleFont.body(size: 13, weight: .medium))
                                    .foregroundColor(.uiInk)
                                Text("Акустический отклик при активации, копировании и ошибках")
                                    .font(UIStyleFont.body(size: 11, weight: .regular))
                                    .foregroundColor(.uiMidGray)
                            }
                            Spacer()
                            Toggle("", isOn: $audioCapture.soundEnabled)
                                .labelsHidden()
                                .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#10B981")))
                        }
                    }
                }
                
                // РАЗДЕЛ 2: УПРАВЛЕНИЕ
                UICard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("УПРАВЛЕНИЕ")
                            .font(UIStyleFont.body(size: 11, weight: .bold))
                            .tracking(1.0)
                            .foregroundColor(.uiMidGray)
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Горячая клавиша")
                                    .font(UIStyleFont.body(size: 13, weight: .medium))
                                    .foregroundColor(.uiInk)
                                if hotKey.isCapturing {
                                    Text(LocalizedStringKey("HotKey.Capture"))
                                        .font(UIStyleFont.body(size: 11, weight: .regular))
                                        .foregroundColor(.uiMidGray)
                                } else if hotKey.isTaken {
                                    Text(LocalizedStringKey("HotKey.Taken"))
                                        .font(UIStyleFont.body(size: 11, weight: .regular))
                                        .foregroundColor(.uiWarn)
                                }
                            }
                            Spacer()
                            if hotKey.isCapturing {
                                UIBadge(text: "…")
                            } else {
                                UIBadge(text: hotKey.hotKeyName)
                            }
                            UIOutlineButton(title: hotKey.isCapturing ? LocalizedStringKey("Отмена") : LocalizedStringKey("Изменить")) {
                                if hotKey.isCapturing { hotKey.endCapture() } else { hotKey.beginCapture() }
                            }
                        }
                        
                        Divider().background(Color.uiHairline)
                        
                        HStack {
                            Text("Режим диктовки")
                                .font(UIStyleFont.body(size: 13, weight: .medium))
                                .foregroundColor(.uiInk)
                            Spacer()
                            UIDropdownPicker(selection: $hotKey.mode, options: [
                                .init(LocalizedStringKey("HotKey.ModeToggle"), value: HotKeyMode.toggle),
                                .init(LocalizedStringKey("HotKey.ModePushToTalk"), value: HotKeyMode.pushToTalk)
                            ], width: 160)
                        }
                        
                        Divider().overlay(Color.uiHairline)
                        
                        HStack {
                            Text("Отмена записи")
                                .font(UIStyleFont.body(size: 13, weight: .medium))
                                .foregroundColor(.uiInk)
                            Spacer()
                            UIBadge(text: "ESC")
                        }

                        Divider().overlay(Color.uiHairline)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LocalizedStringKey("ИИ-обработка выделения"))
                                    .font(UIStyleFont.body(size: 13, weight: .medium))
                                    .foregroundColor(.uiInk)
                                if hotKey.isCapturingSelection {
                                    Text(LocalizedStringKey("HotKey.Capture"))
                                        .font(UIStyleFont.body(size: 11, weight: .regular))
                                        .foregroundColor(.uiMidGray)
                                } else if hotKey.isSelectionTaken {
                                    Text(LocalizedStringKey("HotKey.Taken"))
                                        .font(UIStyleFont.body(size: 11, weight: .regular))
                                        .foregroundColor(.uiWarn)
                                } else {
                                    Text(LocalizedStringKey("Замена выделенного текста по промпту ИИ"))
                                        .font(UIStyleFont.body(size: 11, weight: .regular))
                                        .foregroundColor(.uiMidGray)
                                }
                            }
                            Spacer()
                            if hotKey.isCapturingSelection {
                                UIBadge(text: "…")
                            } else {
                                UIBadge(text: hotKey.selectionHotKeyName)
                            }
                            UIOutlineButton(title: hotKey.isCapturingSelection ? LocalizedStringKey("Отмена") : LocalizedStringKey("Изменить")) {
                                if hotKey.isCapturingSelection { hotKey.endCaptureSelection() } else { hotKey.beginCaptureSelection() }
                            }
                        }
                    }
                }
                
                // РАЗДЕЛ 3: ДВИЖОК
                UICard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("ДВИЖОК И УСКОРЕНИЕ")
                            .font(UIStyleFont.body(size: 11, weight: .bold))
                            .tracking(1.0)
                            .foregroundColor(.uiMidGray)
                        
                        HStack {
                            Text("Языковая модель")
                                .font(UIStyleFont.body(size: 13, weight: .medium))
                                .foregroundColor(.uiInk)
                            Spacer()
                            UIDropdownPicker(selection: Binding(
                                get: { models.activeModelID },
                                set: { models.activeModelID = $0 }
                            ), options: models.allModels.map { m in
                                if m.isCustom {
                                    return UIDropdownOption(m.name, value: m.id)
                                } else {
                                    return UIDropdownOption(LocalizedStringKey(m.name), value: m.id)
                                }
                            }, width: 200)

                            UIOutlineButton(title: "+ Инференс") {
                                showingAddInferenceSheet = true
                            }
                        }
                        .sheet(isPresented: $showingAddInferenceSheet) {
                            AddCustomInferenceSheet()
                        }

                        ActiveModelStatusRow()
                            .padding(.vertical, 4)

                        Divider().background(Color.uiHairline)

                        HStack {
                            Text("Аппаратное ускорение")
                                .font(UIStyleFont.body(size: 13, weight: .medium))
                                .foregroundColor(.uiInk)
                            Spacer()
                            Text("Apple Metal (MTL0)")
                                .font(UIStyleFont.body(size: 12, weight: .regular))
                                .foregroundColor(.uiMidGray)
                        }
                        
                        Divider().background(Color.uiHairline)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("IT-термины и автозамена")
                                    .font(UIStyleFont.body(size: 13, weight: .medium))
                                    .foregroundColor(.uiInk)
                                Text("Компенсация искажений англоязычных терминов")
                                    .font(UIStyleFont.body(size: 11, weight: .regular))
                                    .foregroundColor(.uiMidGray)
                            }
                            Spacer()
                            Toggle("", isOn: $techTerms.isReplacementEnabled)
                                .labelsHidden()
                                .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#10B981")))

                            UIOutlineButton(title: "Словарь") {
                                showingTechTermsSheet = true
                            }
                        }
                        .sheet(isPresented: $showingTechTermsSheet) {
                            TechTermManagerView()
                        }

                        if techTerms.isReplacementEnabled && audioCapture.autoAIProcessEnabled {
                            Divider().background(Color.uiHairline)

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Автопополнение словаря из правок ИИ")
                                        .font(UIStyleFont.body(size: 13, weight: .medium))
                                        .foregroundColor(.uiInk)
                                    Text("Добавление исключений и терминов при исправлении текста моделью")
                                        .font(UIStyleFont.body(size: 11, weight: .regular))
                                        .foregroundColor(.uiMidGray)
                                }
                                Spacer()
                                Toggle("", isOn: $techTerms.isAutoLearnEnabled)
                                    .labelsHidden()
                                    .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#10B981")))
                            }
                        }

                        Divider().background(Color.uiHairline)

                        HStack {
                            Text("О программе Golosok")
                                .font(UIStyleFont.body(size: 13, weight: .medium))
                                .foregroundColor(.uiInk)
                            Spacer()
                            UIOutlineButton(title: "Открыть") {
                                showingAboutSheet = true
                            }
                        }
                        .sheet(isPresented: $showingAboutSheet) {
                            AboutView()
                        }

                        Divider().background(Color.uiHairline)

                        HStack {
                            Text("Логи приложения")
                                .font(UIStyleFont.body(size: 13, weight: .medium))
                                .foregroundColor(.uiInk)
                            Spacer()
                            UIOutlineButton(title: "Открыть") {
                                showingLogsSheet = true
                            }
                        }
                        .sheet(isPresented: $showingLogsSheet) {
                            LogsView()
                        }
                    }
                }
                
                // РАЗДЕЛ 3.4: АВТОМАТИЧЕСКАЯ ИИ-ОБРАБОТКА
                UICard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("АВТОМАТИЧЕСКАЯ ИИ-ОБРАБОТКА")
                            .font(UIStyleFont.body(size: 11, weight: .bold))
                            .tracking(1.0)
                            .foregroundColor(.uiMidGray)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Применять ИИ-шаблон к каждой записи")
                                    .font(UIStyleFont.body(size: 13, weight: .medium))
                                    .foregroundColor(.uiInk)
                                Text("Автоматическая обработка текста сразу после распознавания речи")
                                    .font(UIStyleFont.body(size: 11, weight: .regular))
                                    .foregroundColor(.uiMidGray)
                            }
                            Spacer()
                            Toggle("", isOn: $audioCapture.autoAIProcessEnabled)
                                .labelsHidden()
                                .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#10B981")))
                        }

                        if audioCapture.autoAIProcessEnabled {
                            Divider().background(Color.uiHairline)

                            HStack {
                                Text("Выбранный шаблон")
                                    .font(UIStyleFont.body(size: 13, weight: .medium))
                                    .foregroundColor(.uiInk)
                                Spacer()
                                UIDropdownPicker(selection: $audioCapture.autoAIProcessTemplateID, options: promptStore.templates.map { t in
                                    let isBuiltin = AIPromptDefaults.builtinIDs.contains(t.id)
                                    let text = (!t.isCustom || isBuiltin) ? String(localized: String.LocalizationValue(t.title)) : t.title
                                    return UIDropdownOption(text, icon: t.icon, value: t.id)
                                }, width: 220)
                            }
                        }

                        Divider().background(Color.uiHairline)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Управлять промптами")
                                    .font(UIStyleFont.body(size: 13, weight: .medium))
                                    .foregroundColor(.uiInk)
                                Text("Создавайте, редактируйте и удаляйте ИИ-промпты под свои задачи")
                                    .font(UIStyleFont.body(size: 11, weight: .regular))
                                    .foregroundColor(.uiMidGray)
                            }
                            Spacer()
                            UIOutlineButton(title: "Открыть") {
                                showingPromptManagerSheet = true
                            }
                        }
                        .sheet(isPresented: $showingPromptManagerSheet) {
                            PromptManagerView()
                        }
                    }
                }

                // РАЗДЕЛ 3.5: ИИ-ПРОВАЙДЕР
                AIProviderSection()

                // РАЗДЕЛ 3.6: АККАУНТ
                AccountSection()
                    .id("account")

                // РАЗДЕЛ 4: ДАННЫЕ
                UICard {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Стереть историю")
                                .font(UIStyleFont.body(size: 13, weight: .bold))
                                .foregroundColor(.uiEmber)
                            Text("Безвозвратное удаление ВСЕХ заметок на устройстве")
                                .font(UIStyleFont.body(size: 11, weight: .regular))
                                .foregroundColor(.uiMidGray)
                        }
                        Spacer()
                        UIDestructiveButton(title: "Очистить") {
                            showingClearHistoryAlert = true
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color.uiCanvas)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ScrollToAccount"))) { _ in
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("account", anchor: .top) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refreshPermissions()
        }
        .alert("Стереть всю историю?", isPresented: $showingClearHistoryAlert) {
            Button("Отмена", role: .cancel) { }
            Button("Стереть", role: .destructive) {
                audioCapture.clearAllHistory()
            }
        } message: { Text("Все сохраненные транскрипции будут удалены безвозвратно. Это действие нельзя отменить.") }
        }
    }
}

struct ActiveModelStatusRow: View {
    @ObservedObject var models = ModelStore.shared

    var body: some View {
        if let active = models.model(named: models.activeModelID), !active.isBundled {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(active.isCustom ? active.name : String(localized: String.LocalizationValue(active.name)))
                        .font(UIStyleFont.body(size: 13, weight: .medium))
                        .foregroundColor(.uiInk)
                    Text(active.isCustom ? (active.endpointURL ?? "HTTP API") : "\(active.sizeMB) МБ — Apple Metal")
                        .font(UIStyleFont.body(size: 11, weight: .regular))
                        .foregroundColor(.uiMidGray)
                }
                Spacer()
                if active.isCustom {
                    UIOutlineButton(title: "Удалить") { models.removeCustomModel(id: active.id) }
                } else if models.downloadingID == active.id {
                    ProgressView(value: models.downloadProgress)
                        .frame(width: 90)
                    Text(LocalizedStringKey(models.downloadStatus))
                        .font(UIStyleFont.body(size: 11, weight: .regular))
                        .foregroundColor(.uiMidGray)
                    UIOutlineButton(title: "Отмена") { models.cancel() }
                } else if models.isDownloaded(active.id) {
                    Text(LocalizedStringKey("RecognitionModel.Installed"))
                        .font(UIStyleFont.body(size: 11, weight: .regular))
                        .foregroundColor(.uiMidGray)
                    UIOutlineButton(title: "Удалить") { models.remove(active.id) }
                } else {
                    UIOutlineButton(title: "Скачать") { models.download(active.id) }
                }
            }
        }
    }
}

// MARK: - Модальное окно добавления кастомного инференса

struct AddCustomInferenceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var models = ModelStore.shared

    @State private var name: String = ""
    @State private var endpointURL: String = "http://100.64.0.6:9292/v1/audio/transcriptions"
    @State private var modelIdentifier: String = "vibevoice-asr-gpu"
    @State private var apiKey: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Новый инференс распознавания")
                .font(UIStyleFont.display(size: 15, weight: .bold))
                .foregroundColor(.uiInk)

            Text("Подключение внешнего ASR-сервера (OpenAI-совместимый API /audio/transcriptions, llama-swap, vLLM, Whisper server).")
                .font(UIStyleFont.body(size: 11, weight: .regular))
                .foregroundColor(.uiMidGray)

            VStack(alignment: .leading, spacing: 6) {
                Text("Название профиля")
                    .font(UIStyleFont.body(size: 12, weight: .medium))
                    .foregroundColor(.uiMidGray)
                TextField("например: VibeVoice Remote GPU", text: $name)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.uiSidebar)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Endpoint URL")
                    .font(UIStyleFont.body(size: 12, weight: .medium))
                    .foregroundColor(.uiMidGray)
                TextField("http://host:port/v1/audio/transcriptions", text: $endpointURL)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.uiSidebar)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Идентификатор модели (model param)")
                    .font(UIStyleFont.body(size: 12, weight: .medium))
                    .foregroundColor(.uiMidGray)
                TextField("например: vibevoice-asr-gpu или whisper-1", text: $modelIdentifier)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.uiSidebar)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("API Ключ (опционально)")
                    .font(UIStyleFont.body(size: 12, weight: .medium))
                    .foregroundColor(.uiMidGray)
                SecureField("Bearer token, если требуется", text: $apiKey)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.uiSidebar)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))
            }

            HStack {
                Spacer()
                UIOutlineButton(title: "Отмена") {
                    dismiss()
                }
                UIPrimaryButton(title: "Сохранить") {
                    models.addCustomModel(
                        name: name,
                        endpointURL: endpointURL,
                        modelIdentifier: modelIdentifier,
                        apiKey: apiKey
                    )
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || endpointURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 480)
        .background(Color.uiPaper)
    }
}
