import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Модальное окно управления словарем технических терминов

struct TechTermManagerView: View {
    @ObservedObject private var store = TechTermStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var editingRule: TechTermRule?
    @State private var creatingRule = false
    @State private var showingResetAlert = false
    @State private var importResultMessage: String?
    @State private var showingImportAlert = false

    private var allEnabled: Bool {
        !store.rules.isEmpty && store.rules.allSatisfy { $0.isEnabled }
    }

    private var noneEnabled: Bool {
        store.rules.allSatisfy { !$0.isEnabled }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.uiHairline)
            actionToolbar
            Divider().background(Color.uiHairline)
            list
            Divider().background(Color.uiHairline)
            footer
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 480, idealHeight: 600)
        .background(Color.uiPaper)
        .sheet(item: $editingRule) { rule in
            TechTermEditorView(rule: rule)
        }
        .sheet(isPresented: $creatingRule) {
            TechTermEditorView(rule: nil)
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

    private var actionToolbar: some View {
        HStack(spacing: 12) {
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
            ForEach(store.rules) { rule in
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
