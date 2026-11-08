import SwiftUI

// MARK: - Менеджер промптов (список / удалить / редактировать / создать)

struct PromptManagerView: View {
    @ObservedObject private var store = PromptStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var editing: AIPromptTemplate?
    @State private var creating = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.uiHairline)
            list
            Divider().background(Color.uiHairline)
            footer
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 420, idealHeight: 560)
        .background(Color.uiPaper)
        .sheet(item: $editing) { prompt in
            PromptEditorView(prompt: prompt)
        }
        .sheet(isPresented: $creating) {
            PromptEditorView(prompt: nil)
        }
    }

    private var header: some View {
        HStack {
            Text("Промпты")
                .font(UIStyleFont.display(size: 15, weight: .bold))
                .foregroundColor(.uiInk)
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

    private var sortedTemplates: [AIPromptTemplate] {
        // Системные защищенные промпты всегда наверху списка
        store.templates.sorted { a, b in
            if a.isProtected != b.isProtected {
                return a.isProtected && !b.isProtected
            }
            return false
        }
    }

    private var list: some View {
        List {
            ForEach(sortedTemplates) { prompt in
                row(prompt)
                    .contextMenu {
                        if !prompt.isProtected {
                            Button(role: .destructive) {
                                store.delete(id: prompt.id)
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

    @ViewBuilder
    private func row(_ prompt: AIPromptTemplate) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.uiCanvas)
                        .frame(width: 30, height: 30)
                    Image(systemName: prompt.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.uiInk)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if prompt.isCustom {
                            Text(prompt.title)
                                .font(UIStyleFont.body(size: 13, weight: .medium))
                                .foregroundColor(.uiInk)
                        } else {
                            Text(LocalizedStringKey(prompt.title))
                                .font(UIStyleFont.body(size: 13, weight: .medium))
                                .foregroundColor(.uiInk)
                        }

                        if prompt.isProtected {
                            HStack(spacing: 3) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 8, weight: .bold))
                                Text("Системный")
                                    .font(UIStyleFont.body(size: 9, weight: .bold))
                            }
                            .foregroundColor(Color.uiMidGray)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.uiCanvas)
                            .cornerRadius(5)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.uiHairline, lineWidth: 1))
                        }
                    }
                    Text(prompt.system)
                        .font(UIStyleFont.body(size: 11, weight: .regular))
                        .foregroundColor(.uiMidGray)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture { editing = prompt }

            if prompt.isProtected {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.uiMidGray.opacity(0.7))
                    .help("Этот промпт системный: его можно редактировать, но нельзя удалить")
            } else {
                Button(action: { store.delete(id: prompt.id) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.uiMidGray)
                        .frame(width: 26, height: 26)
                        .background(Color.uiCanvas)
                        .clipShape(Circle())
                }
                .buttonStyle(TactileButtonStyle())
                .help("Удалить")
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(action: { creating = true }) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Новый промпт")
                        .font(UIStyleFont.body(size: 13, weight: .medium))
                }
                .foregroundColor(.uiInk)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(Color.uiSidebar)
                .cornerRadius(18)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.uiHairline, lineWidth: 1))
            }
            .buttonStyle(TactileButtonStyle())
            Spacer()
            Text("\(store.templates.count)")
                .font(UIStyleFont.body(size: 12, weight: .regular))
                .foregroundColor(.uiMidGray)
        }
        .padding(20)
    }
}

// MARK: - Редактор/создание промпта

struct PromptEditorView: View {
    let prompt: AIPromptTemplate?
    @ObservedObject private var store = PromptStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var icon: String = "sparkles"
    @State private var system: String = ""

    @State private var showingResetAlert = false
    @State private var previousStateTitle: String?
    @State private var previousStateSystem: String?

    private static let palette: [String] = [
        "sparkles", "wrench.and.screwdriver", "briefcase", "pencil.and.outline",
        "text.quote", "checklist", "doc.text", "character.cursor.ibeam",
        "globe", "waveform", "bolt.fill", "tag",
        "lightbulb", "target", "envelope", "questionmark"
    ]

    private var isEditingExisting: Bool { prompt != nil }
    private var isBuiltin: Bool { prompt.map { AIPromptDefaults.builtinIDs.contains($0.id) } ?? false }

    private var canSave: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = system.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !s.isEmpty
    }

    private var titleKey: LocalizedStringKey {
        isEditingExisting ? "Редактировать промпт" : "Новый промпт"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.uiHairline)
            content
            Divider().background(Color.uiHairline)
            footer
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 520, idealHeight: 580)
        .background(Color.uiPaper)
        .onAppear { seed() }
        .alert(isBuiltin ? "Восстановить исходный промпт?" : "Восстановить прошлое состояние?", isPresented: $showingResetAlert) {
            Button("Отмена", role: .cancel) { }
            Button("Восстановить", role: .destructive) {
                if isBuiltin {
                    if let id = prompt?.id {
                        store.reset(id: id)
                        seed()
                    }
                } else if let prevTitle = previousStateTitle, let prevSys = previousStateSystem {
                    title = prevTitle
                    system = prevSys
                }
            }
        } message: {
            if isBuiltin {
                Text("Все ваши правки этого системного промпта будут сброшены к оригинальной заводской инструкции.")
            } else {
                Text("Вернуть текст заголовка и инструкции к состоянию на момент открытия окна.")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.uiCanvas).frame(width: 32, height: 32)
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundColor(.uiInk)
            }
            Text(titleKey)
                .font(UIStyleFont.display(size: 15, weight: .bold))
                .foregroundColor(.uiInk)
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
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Заголовок
            VStack(alignment: .leading, spacing: 6) {
                Text("Заголовок")
                    .font(UIStyleFont.body(size: 11, weight: .medium))
                    .foregroundColor(.uiMidGray)
                TextField("Например: Краткий пересказ", text: $title)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(UIStyleFont.body(size: 13, weight: .regular))
                    .foregroundColor(.uiInk)
                    .frame(height: 22)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.uiCanvas)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))
            }

            // Иконка
            VStack(alignment: .leading, spacing: 8) {
                Text("Иконка")
                    .font(UIStyleFont.body(size: 11, weight: .medium))
                    .foregroundColor(.uiMidGray)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(Self.palette, id: \.self) { symbol in
                        Button {
                            icon = symbol
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(icon == symbol ? Color.uiPaper : Color.uiInk)
                                .frame(height: 34)
                                .frame(maxWidth: .infinity)
                                .background(icon == symbol ? AnyShapeStyle(Color.uiInk) : AnyShapeStyle(Color.uiCanvas))
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(icon == symbol ? Color.uiInk : Color.uiHairline, lineWidth: 1))
                        }
                        .buttonStyle(TactileButtonStyle())
                    }
                }
            }

            // Инструкция
            VStack(alignment: .leading, spacing: 6) {
                Text("Инструкция")
                    .font(UIStyleFont.body(size: 11, weight: .medium))
                    .foregroundColor(.uiMidGray)
                TextEditor(text: $system)
                    .font(UIStyleFont.body(size: 13, weight: .regular))
                    .foregroundColor(.uiInk)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140, maxHeight: 180)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(Color.uiCanvas)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.uiHairline, lineWidth: 1))
                Text("Опишите задачу: что ИИ должен сделать с расшифрованным текстом.")
                    .font(UIStyleFont.body(size: 10, weight: .regular))
                    .foregroundColor(.uiMidGray)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if isBuiltin {
                UIOutlineButton(title: "Восстановить исходный") {
                    showingResetAlert = true
                }
            } else if isEditingExisting {
                UIOutlineButton(title: "Откатить правки") {
                    showingResetAlert = true
                }
            }
            Spacer()
            UIOutlineButton(title: "Отмена") { dismiss() }
            UIPrimaryButton(title: "Сохранить") { save() }
                .disabled(!canSave)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Private

    private func seed() {
        guard let p = prompt else { return }
        title = p.title
        icon = p.icon
        system = p.system
        previousStateTitle = p.title
        previousStateSystem = p.system
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = system.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !s.isEmpty else { return }
        if let p = prompt {
            var updated = p
            updated.title = t
            updated.icon = icon
            updated.system = s
            store.update(updated)
        } else {
            store.create(title: t, icon: icon, system: s)
        }
        dismiss()
    }
}