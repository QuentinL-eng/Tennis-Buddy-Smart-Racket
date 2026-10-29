import SwiftData
import SwiftUI

/// What the coach remembers about the active player across sessions. The player can add, edit and delete notes,
/// and turn off Muse's access to them.
struct MemoryView: View {
    @Query(sort: \CoachNote.updatedAt, order: .reverse) private var allNotes: [CoachNote]
    @Environment(AppModel.self) private var model
    @Environment(CoachModel.self) private var coach
    @Environment(\.modelContext) private var context
    @State private var draft = ""
    @State private var category = CoachNote.Category.technique
    @State private var editing: CoachNote?

    private var notes: [CoachNote] { allNotes.filter { $0.playerID == model.activePlayerID } }
    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        @Bindable var coach = coach
        List {
            Section {
                Toggle("Let Muse use these notes", isOn: $coach.memoryEnabled)
            } footer: {
                Text(coach.memoryEnabled
                     ? "When Muse answers, it can read these notes and add new ones. They're sent to Meta with your question, including any injury notes. Notes sync through your iCloud."
                     : "Notes stay on your devices. Muse can't read or add them.")
            }
            Section("Add a note about \(model.activePlayer?.name ?? "you")") {
                TextField("e.g. Rushes the backhand when tired", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                Picker("Category", selection: $category) {
                    ForEach(CoachNote.Category.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                Button("Remember", systemImage: "plus.circle.fill", action: add)
                    .disabled(trimmed.count < 3 || trimmed.count > CoachMemory.maxNoteLength)
            }
            if notes.isEmpty {
                Section {
                    ContentUnavailableView("Nothing remembered yet", systemImage: "brain",
                        description: Text("Add habits, goals or past injuries, and the coach will take them into account."))
                }
            }
            ForEach(CoachNote.Category.allCases) { cat in
                let group = notes.filter { $0.category == cat }
                if !group.isEmpty {
                    Section {
                        ForEach(group) { note in
                            Button { editing = note } label: { row(note) }
                                .buttonStyle(.plain)
                        }
                        .onDelete { offsets in offsets.map { group[$0] }.forEach(context.delete) }
                    } header: { Label(cat.label, systemImage: cat.symbol) }
                }
            }
        }
        .navigationTitle("Memory")
        .sheet(item: $editing) { NoteEditor(note: $0) }
    }

    private func row(_ note: CoachNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.text)
            HStack(spacing: 6) {
                Text(note.updatedAt.formatted(date: .abbreviated, time: .omitted))
                if note.addedByCoach { Label("Added by coach", systemImage: "sparkles") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private func add() {
        context.insert(CoachNote(playerID: model.activePlayerID, text: trimmed, category: category))
        draft = ""
    }
}

private struct NoteEditor: View {
    @Bindable var note: CoachNote
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var text = ""
    @State private var category = CoachNote.Category.technique

    var body: some View {
        NavigationStack {
            Form {
                TextField("Note", text: $text, axis: .vertical).lineLimit(2...6)
                Picker("Category", selection: $category) {
                    ForEach(CoachNote.Category.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                if note.addedByCoach {
                    Text("Added by the coach on \(note.createdAt.formatted(date: .abbreviated, time: .omitted)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Delete note", role: .destructive) { context.delete(note); dismiss() }
            }
            .navigationTitle("Edit note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    Button("Save") {
                        note.text = t
                        note.category = category
                        note.updatedAt = Date()
                        dismiss()
                    }
                    .disabled(t.count < 3 || t.count > CoachMemory.maxNoteLength)
                }
            }
            .onAppear { text = note.text; category = note.category }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 260)
        #endif
    }
}
