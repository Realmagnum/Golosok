import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Варианты сортировки словаря терминов

enum TechTermSortOption: String, CaseIterable, Identifiable {
    case orderAdded = "По порядку добавления"
    case nameAsc = "По имени (A → Z)"
    case nameDesc = "По имени (Z → A)"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .orderAdded: return "clock"
        case .nameAsc: return "arrow.up.circle"
        case .nameDesc: return "arrow.down.circle"
        }
    }
}

// MARK: - Модальное окно управления словарем технических терминов

struct TechTermManagerView: View {
    @ObservedObject private var store = TechTermStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var sortOption: TechTermSortOption = .orderAdded

    @State private var editingRule: TechTermRule?
    @State private var creatingRule = false
    @State private var showingResetAlert = false
    @State private var showingCandidatesSheet = false
    @State private var importResultMessage: String?
    @State private var showingImportAlert = false

    private var allEnabled: Bool {
        !store.rules.isEmpty && store.rules.allSatisfy { $0.isEnabled }
    }

    private var noneEnabled: Bool {
        store.rules.allSatisfy { !$0.isEnabled }
    }

    /// Отфильтрованный и отсортированный список правил
    private var displayedRules: [TechTermRule] {
        var result = store.rules

        // 1. Поиск по всем вхождениям (в каноническом имени и во всех паттернах)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            result = result.filter { rule in
                if rule.canonical.lowercased().contains(query) { return true }
                for p in rule.patterns {
                    if p.lowercased().contains(query) { return true }
                }
                return false
            }
        }

        // 2. Сортировка: в порядке добавления (как есть) или по алфавиту A-Z / Z-A
        switch sortOption {
        case .orderAdded:
            break
        case .nameAsc:
            result.sort { $0.canonical.localizedCaseInsensitiveCompare($1.canonical) == .orderedAscending }
        case .nameDesc:
            result.sort { $0.canonical.localizedCaseInsensitiveCompare($1.canonical) == .orderedDescending }
        }

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.uiHairline)
            searchAndSortBar
            Divider().background(Color.uiHairline)
            actionToolbar
            Divider().background(Color.uiHairline)
            list
            Divider().background(Color.uiHairline)
            footer
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 640)
        .background(Color.uiPaper)
        .sheet(item: $editingRule) { rule in
            TechTermEditorView(rule: rule)
        }
        .sheet(isPresented: $creatingRule) {
            TechTermEditorView(rule: nil)
        }
        .sheet(isPresented: $showingCandidatesSheet) {
            TechTermCandidatesView()
        }
        .alert("Сбросить к базовому словарю?", isPresented: $showingResetAlert) {
            Button("Отмена", role: .cancel) { }
            Button("Сбросить", role: .destructive) {
                store.resetToDefaults()
            }
        } message: {
            Text("Все пользовательские термины будут заменены предустановленным набором IT-терминов.")
        }
        .alert("Импорт словаря", isPresented: $showingImportAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importResultMessage ?? "")
        }
    }

    // MARK: - Строка поиска и переключатель сортировки

    private var searchAndSortBar: some View {
        HStack(spacing: 12) {
            // Поле поиска по всем вхождениям
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.uiMidGray)
                    .font(.system(size: 12))

                TextField("Поиск по всем терминам и вариантам...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(UIStyleFont.body(size: 12))

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.uiMidGray)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.uiSidebar)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))

            // Меню / селектор сортировки
            Menu {
                ForEach(TechTermSortOption.allCases) { opt in
                    Button {
                        sortOption = opt
                    } label: {
                        HStack {
                            Text(opt.rawValue)
                            if sortOption == opt {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                    Text(sortOption.rawValue)
                        .font(UIStyleFont.body(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(.uiInk)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color.uiSidebar)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))
            }
            .menuStyle(BorderlessButtonMenuStyle())
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.uiPaper)
    }

    private var actionToolbar: some View {
        VStack(spacing: 10) {
            // Верхняя строка: переключатели с комфортными отступами
            HStack(spacing: 20) {
                // Переключатель Выбрать все / Снять все
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { allEnabled },
                        set: { store.setAllEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#10B981")))

                    Text(allEnabled ? "Снять выделение со всех" : "Выбрать все")
                        .font(UIStyleFont.body(size: 12, weight: .medium))
                        .foregroundColor(.uiInk)
                }

                // Автообучение из ИИ с бейджем кандидатов
                HStack(spacing: 8) {
                    Toggle("", isOn: $store.isAutoLearnEnabled)
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#10B981")))

                    HStack(spacing: 4) {
                        Text("Автообучение из ИИ")
                            .font(UIStyleFont.body(size: 12, weight: .regular))
                            .foregroundColor(.uiMidGray)

                        if !store.candidates.isEmpty {
                            Button(action: { showingCandidatesSheet = true }) {
                                HStack(spacing: 3) {
                                    Circle()
                                        .fill(Color.uiWarn)
                                        .frame(width: 5, height: 5)
                                    Text("\(store.candidates.count) на проверке")
                                        .font(UIStyleFont.body(size: 10, weight: .semibold))
                                        .foregroundColor(.uiWarn)
                                }
                                .padding(.vertical, 2)
                                .padding(.horizontal, 6)
                                .background(Color.uiWarn.opacity(0.12))
                                .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }

                Spacer()
            }

            // Нижняя строка: счетчик и кнопки импорта/экспорта
            HStack(spacing: 8) {
                Text("Показано: \(displayedRules.count) из \(store.rules.count)")
                    .font(UIStyleFont.mono(size: 11))
                    .foregroundColor(.uiMidGray)

                Spacer()

                // Кнопка Импорт
                Button(action: importDictionary) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 11, weight: .medium))
                        Text("Импорт")
                            .font(UIStyleFont.body(size: 12, weight: .medium))
                    }
                    .foregroundColor(.uiInk)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(Color.uiSidebar)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())

                // Кнопка Экспорт
                Button(action: exportDictionary) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .medium))
                        Text("Экспорт")
                            .font(UIStyleFont.body(size: 12, weight: .medium))
                    }
                    .foregroundColor(.uiInk)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(Color.uiSidebar)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.uiSidebar.opacity(0.4))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Словарь IT-терминов и автозамена")
                    .font(UIStyleFont.display(size: 15, weight: .bold))
                    .foregroundColor(.uiInk)
                Text("Автоматическая компенсация ошибок распознавания английских терминов")
                    .font(UIStyleFont.body(size: 11, weight: .regular))
                    .foregroundColor(.uiMidGray)
            }
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.uiMidGray)
                    .frame(width: 28, height: 28)
                    .background(Color.uiSidebar)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.uiHairline, lineWidth: 1))
            }
            .buttonStyle(TactileButtonStyle())
        }
        .padding(20)
        .padding(.bottom, 4)
    }

    private var list: some View {
        List {
            if displayedRules.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundColor(.uiMidGray.opacity(0.6))
                    Text(searchText.isEmpty ? "Словарь пуст" : "Ничего не найдено по запросу «\(searchText)»")
                        .font(UIStyleFont.body(size: 13, weight: .medium))
                        .foregroundColor(.uiMidGray)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ForEach(displayedRules) { rule in
                    row(rule)
                        .contextMenu {
                            Button {
                                editingRule = rule
                            } label: {
                                Label("Редактировать", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                store.delete(id: rule.id)
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func row(_ rule: TechTermRule) -> some View {
        HStack(spacing: 14) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { _ in store.toggle(id: rule.id) }
            ))
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#10B981")))

            VStack(alignment: .leading, spacing: 3) {
                Text(rule.canonical)
                    .font(UIStyleFont.body(size: 13, weight: .semibold))
                    .foregroundColor(rule.isEnabled ? .uiInk : .uiMidGray)

                Text(rule.patterns.joined(separator: ", "))
                    .font(UIStyleFont.mono(size: 11))
                    .foregroundColor(.uiMidGray)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: { editingRule = rule }) {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
                    .foregroundColor(.uiMidGray)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            Button("Сбросить к дефолтным") {
                showingResetAlert = true
            }
            .font(UIStyleFont.body(size: 12, weight: .regular))
            .foregroundColor(.uiMidGray)
            .buttonStyle(PlainButtonStyle())

            Spacer()

            if !store.candidates.isEmpty {
                UIOutlineButton(title: "Кандидаты ИИ (\(store.candidates.count))") {
                    showingCandidatesSheet = true
                }
            }

            UIPrimaryButton(title: "Добавить термин") {
                creatingRule = true
            }
        }
        .padding(20)
    }

    // MARK: - Действия Импорта и Экспорта

    private func importDictionary() {
        let panel = NSOpenPanel()
        panel.title = "Импорт словаря терминов"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let jsonType = UTType(filenameExtension: "json") {
            panel.allowedContentTypes = [jsonType]
        }

        if panel.runModal() == .OK, let url = panel.url {
            let res = store.importFromURL(url)
            if let err = res.error {
                importResultMessage = "Ошибка: \(err)"
            } else {
                importResultMessage = "Успешно импортировано \(res.imported) терминов."
            }
            showingImportAlert = true
        }
    }

    private func exportDictionary() {
        let panel = NSSavePanel()
        panel.title = "Экспорт словаря терминов"
        panel.nameFieldStringValue = "golosok_terms_dictionary.json"
        if let jsonType = UTType(filenameExtension: "json") {
            panel.allowedContentTypes = [jsonType]
        }

        if panel.runModal() == .OK, let url = panel.url {
            _ = store.exportToURL(url)
        }
    }
}

// MARK: - Редактор / создание правила термина

struct TechTermEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = TechTermStore.shared

    let existingRule: TechTermRule?

    @State private var canonical: String = ""
    @State private var patternsText: String = ""

    init(rule: TechTermRule?) {
        self.existingRule = rule
        _canonical = State(initialValue: rule?.canonical ?? "")
        _patternsText = State(initialValue: rule?.patterns.joined(separator: ", ") ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existingRule == nil ? "Новый термин" : "Редактировать термин")
                .font(UIStyleFont.display(size: 15, weight: .bold))
                .foregroundColor(.uiInk)

            VStack(alignment: .leading, spacing: 6) {
                Text("Правильное написание (каноническое)")
                    .font(UIStyleFont.body(size: 12, weight: .medium))
                    .foregroundColor(.uiMidGray)
                TextField("например: Tailscale", text: $canonical)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.uiSidebar)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Варианты ошибок распознавания (через запятую)")
                    .font(UIStyleFont.body(size: 12, weight: .medium))
                    .foregroundColor(.uiMidGray)
                TextField("например: stale skale, talescale, тейлскейл", text: $patternsText)
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
                    save()
                    dismiss()
                }
                .disabled(canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 440)
        .background(Color.uiPaper)
    }

    private func save() {
        let cleanCanonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = patternsText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !cleanCanonical.isEmpty, !patterns.isEmpty else { return }

        if let rule = existingRule {
            var updated = rule
            updated.canonical = cleanCanonical
            updated.patterns = patterns
            store.update(updated)
        } else {
            store.add(canonical: cleanCanonical, patterns: patterns)
        }
    }
}

// MARK: - Окно просмотра кандидатов автообучения (Staging Buffer)

struct TechTermCandidatesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = TechTermStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Кандидаты автообучения ИИ")
                        .font(UIStyleFont.display(size: 15, weight: .bold))
                        .foregroundColor(.uiInk)
                    Text("Новые созвучные варианты, обнаруженные ИИ. Проверяются автоматически или вручную.")
                        .font(UIStyleFont.body(size: 11, weight: .regular))
                        .foregroundColor(.uiMidGray)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.uiMidGray)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(PlainButtonStyle())
            }

            if store.candidates.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 28))
                        .foregroundColor(Color(hex: "#10B981"))
                    Text("Буфер кандидатов пуст")
                        .font(UIStyleFont.body(size: 13, weight: .medium))
                        .foregroundColor(.uiInk)
                    Text("Все распознанные искажения либо уже добавлены в словарь, либо отклонены.")
                        .font(UIStyleFont.body(size: 11, weight: .regular))
                        .foregroundColor(.uiMidGray)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                List {
                    ForEach(store.candidates) { c in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(c.canonical)
                                        .font(UIStyleFont.body(size: 13, weight: .semibold))
                                        .foregroundColor(.uiInk)
                                    Text("<- '\(c.pattern)'")
                                        .font(UIStyleFont.mono(size: 12))
                                        .foregroundColor(Color(hex: "#10B981"))
                                }
                                Text("Встретилось раз: \(c.occurrences) • \(timeAgo(c.lastSeen))")
                                    .font(UIStyleFont.body(size: 10))
                                    .foregroundColor(.uiMidGray)
                            }
                            Spacer()

                            HStack(spacing: 6) {
                                Button(action: { store.approveCandidate(c) }) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(Color(hex: "#10B981"))
                                        .frame(width: 26, height: 26)
                                        .background(Color(hex: "#10B981").opacity(0.12))
                                        .cornerRadius(6)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .help("Одобрить в словарь")

                                Button(action: { store.rejectCandidate(c) }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.uiEmber)
                                        .frame(width: 26, height: 26)
                                        .background(Color.uiEmber.opacity(0.12))
                                        .cornerRadius(6)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .help("Отклонить")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 240, maxHeight: 340)
            }

            HStack {
                if !store.candidates.isEmpty {
                    UIOutlineButton(title: "Очистить всё") {
                        store.clearCandidates()
                    }
                    UIOutlineButton(title: "Проверить через ИИ сейчас") {
                        store.triggerBatchVerificationIfNeeded(force: true)
                    }
                }

                Spacer()

                UIPrimaryButton(title: "Готово") {
                    dismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Color.uiPaper)
    }

    private func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
