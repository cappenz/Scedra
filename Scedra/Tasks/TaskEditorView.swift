import SwiftUI

enum TaskEditorSession: Identifiable {
    case create(ScedraTask)
    case edit(ScedraTask)

    var id: UUID { task.id }

    var task: ScedraTask {
        switch self {
        case .create(let task), .edit(let task):
            return task
        }
    }

    var isNew: Bool {
        if case .create = self { return true }
        return false
    }
}

/// Starter rows for the empty Tasks tab. Titles become stored text once she saves.
enum TaskExample: String, CaseIterable, Identifiable {
    case callDentist
    case chemistryHomework
    case buyGroceries

    var id: String { rawValue }

    func makeTask() -> ScedraTask {
        switch self {
        case .callDentist:
            ScedraTask(
                title: ScedraString("Call dentist"),
                estimatedDurationMinutes: 10,
                allowedOverlaps: Set(TaskOverlapKind.compatibleHosts)
            )
        case .chemistryHomework:
            ScedraTask(
                title: ScedraString("Finish chemistry homework"),
                estimatedDurationMinutes: 45,
                allowedOverlaps: [],
                category: ScedraString("homework")
            )
        case .buyGroceries:
            ScedraTask(
                title: ScedraString("Buy groceries"),
                estimatedDurationMinutes: 30,
                location: ScedraString("grocery"),
                requiresTravel: true,
                allowedOverlaps: []
            )
        }
    }
}

struct TaskEditorView: View {
    let session: TaskEditorSession
    var busy: [TaskBusyBlock] = []
    var onSave: (ScedraTask) -> Void
    var onDelete: ((ScedraTask) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var draft: ScedraTask
    @State private var hasDeadline: Bool
    @State private var hasSchedule: Bool
    @State private var confirmDelete = false
    @State private var overlapAlert = false

    private enum Field: Hashable {
        case title, notes, location, category
    }

    init(
        session: TaskEditorSession,
        busy: [TaskBusyBlock] = [],
        onSave: @escaping (ScedraTask) -> Void,
        onDelete: ((ScedraTask) -> Void)? = nil
    ) {
        self.session = session
        self.busy = busy
        self.onSave = onSave
        self.onDelete = onDelete
        let task = session.task
        _draft = State(initialValue: task)
        _hasDeadline = State(initialValue: task.deadline != nil)
        _hasSchedule = State(initialValue: task.isPlaced)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScedraTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        basicsCard
                        timingCard
                        placeCard
                        overlapCard
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .scedraDismissesKeyboard($focusedField)
            .scedraUsesSelectedTheme()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                editorHeader
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                saveFooter
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                        ScedraKeyboard.resign()
                    }
                }
            }
            .alert("Delete this task?", isPresented: $confirmDelete) {
                Button("Delete task", role: .destructive) {
                    onDelete?(draft)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes “\(draft.title)” from Scedra.")
            }
            .alert("That time is taken", isPresented: $overlapAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("It overlaps another task or event. Nothing else will be moved. Pick a different time.")
            }
        }
    }

    private var editorHeader: some View {
        HStack(alignment: .center) {
            Text(session.isNew ? "New task" : "Edit task")
                .font(.system(size: 30, weight: .regular, design: .serif))
                .foregroundStyle(ScedraTheme.purple)
            Spacer()
            Button("Cancel") { dismiss() }
                .font(.body.weight(.medium))
                .foregroundStyle(ScedraTheme.purple)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(ScedraTheme.background.ignoresSafeArea(edges: .top))
    }

    private var basicsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledField("Title", text: $draft.title, field: .title, prompt: "What needs doing")
            labeledField("Notes", text: $draft.notes, field: .notes, prompt: "Notes (optional)", lines: 3...6)
            durationRow
            labeledField("Category", text: $draft.category, field: .category, prompt: "Category (optional)")
            Toggle("Completed", isOn: $draft.isCompleted)
                .tint(ScedraTheme.purple)
                .font(.body.weight(.medium))
                .foregroundStyle(ScedraTheme.deepPurple)
        }
        .scedraCard()
    }

    private var timingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Deadline", isOn: $hasDeadline)
                .tint(ScedraTheme.purple)
                .onChange(of: hasDeadline) { _, on in
                    if on, draft.deadline == nil {
                        draft.deadline = Date()
                    }
                    if !on { draft.deadline = nil }
                }
            if hasDeadline {
                DatePicker(
                    "Deadline",
                    selection: deadlineBinding,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .tint(ScedraTheme.purple)
            }

            Toggle("Scheduled time", isOn: $hasSchedule)
                .tint(ScedraTheme.purple)
                .onChange(of: hasSchedule) { _, on in
                    if on {
                        if draft.scheduledStart == nil {
                            let start = Date().addingTimeInterval(TaskPlacementLeadTime.interval)
                            draft.applyPlacement(start: start)
                        }
                    } else {
                        draft.clearPlacementTimes()
                    }
                }
            if hasSchedule {
                DatePicker(
                    "Starts",
                    selection: scheduleStartBinding,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .tint(ScedraTheme.purple)
                DatePicker(
                    "Ends",
                    selection: scheduleEndBinding,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .tint(ScedraTheme.purple)
                Text("Changing this parks the task here. Scedra will not move anything else.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if scheduledSlotConflicts {
                    Text("That time overlaps another task or event. Leave 10 minutes on both sides.")
                        .font(.caption)
                        .foregroundStyle(ScedraTheme.conflict)
                }
            }
        }
        .font(.body.weight(.medium))
        .foregroundStyle(ScedraTheme.deepPurple)
        .scedraCard()
    }

    private var placeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledField("Location", text: $draft.location, field: .location, prompt: "Location (optional)")
            Toggle("Requires travel", isOn: $draft.requiresTravel)
                .tint(ScedraTheme.purple)
                .font(.body.weight(.medium))
                .foregroundStyle(ScedraTheme.deepPurple)
        }
        .scedraCard()
    }

    private var overlapCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Can do during")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ScedraTheme.deepPurple)
            Text("Only driving, walking, waiting, or transit. Not class or a meeting.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(TaskOverlapKind.compatibleHosts) { kind in
                    overlapChip(kind)
                }
            }
        }
        .scedraCard()
    }

    private var durationRow: some View {
        HStack {
            Text("Duration")
                .font(.body.weight(.medium))
                .foregroundStyle(ScedraTheme.deepPurple)
            Spacer()
            Stepper(value: $draft.estimatedDurationMinutes, in: 5...480, step: 5) {
                Text("\(draft.estimatedDurationMinutes) min")
                    .font(.body.weight(.medium))
                    .foregroundStyle(ScedraTheme.deepPurple)
                    .monospacedDigit()
            }
        }
        .onChange(of: draft.estimatedDurationMinutes) { _, _ in
            if hasSchedule, let start = draft.scheduledStart {
                draft.applyPlacement(start: start)
            }
        }
    }

    private func labeledField(
        _ title: LocalizedStringKey,
        text: Binding<String>,
        field: Field,
        prompt: LocalizedStringKey,
        lines: ClosedRange<Int> = 1...1
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ScedraTheme.purple)
            TextField(title, text: text, prompt: Text(prompt), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(lines)
                .focused($focusedField, equals: field)
                .submitLabel(.done)
                .onSubmit {
                    focusedField = nil
                    ScedraKeyboard.resign()
                }
                .padding(12)
                .background(ScedraTheme.blush, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func overlapChip(_ kind: TaskOverlapKind) -> some View {
        let selected = draft.allowedOverlaps.contains(kind)
        return Button {
            if selected {
                draft.allowedOverlaps.remove(kind)
            } else {
                draft.allowedOverlaps.insert(kind)
            }
        } label: {
            Text(kind.title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(selected ? ScedraTheme.purple : ScedraTheme.lavender.opacity(0.55), in: Capsule())
                .foregroundStyle(selected ? Color.white : ScedraTheme.deepPurple)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var saveFooter: some View {
        VStack(spacing: 10) {
            Button(action: save) {
                Text("Save task")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canSave ? ScedraTheme.purple : ScedraTheme.lavender, in: Capsule())
                    .foregroundStyle(canSave ? Color.white : ScedraTheme.deepPurple.opacity(0.5))
            }
            .disabled(!canSave)

            if !session.isNew, onDelete != nil {
                Button("Delete task", role: .destructive) {
                    confirmDelete = true
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(ScedraTheme.background.ignoresSafeArea(edges: .bottom))
    }

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var deadlineBinding: Binding<Date> {
        Binding(
            get: { draft.deadline ?? Date() },
            set: { draft.deadline = $0 }
        )
    }

    private func save() {
        var next = draft
        next.title = next.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.title.isEmpty else { return }
        if !hasDeadline { next.deadline = nil }
        if !hasSchedule {
            next.clearPlacementTimes()
        } else if let start = next.scheduledStart {
            if !TaskPlacement.manualSlotFits(next, start: start, busy: busy) {
                overlapAlert = true
                return
            }
            next.applyPlacement(start: start)
        }
        onSave(next)
        dismiss()
    }

    private var scheduledSlotConflicts: Bool {
        guard hasSchedule, let start = draft.scheduledStart else { return false }
        return !TaskPlacement.manualSlotFits(draft, start: start, busy: busy)
    }

    private var scheduleStartBinding: Binding<Date> {
        Binding(
            get: { draft.scheduledStart ?? Date() },
            set: { draft.applyPlacement(start: $0) }
        )
    }

    private var scheduleEndBinding: Binding<Date> {
        Binding(
            get: { draft.scheduledEnd ?? Date().addingTimeInterval(draft.scheduledDuration) },
            set: { newEnd in
                let start = draft.scheduledStart ?? Date()
                guard newEnd > start else { return }
                let minutes = max(1, Int(newEnd.timeIntervalSince(start) / 60))
                draft.estimatedDurationMinutes = minutes
                draft.applyPlacement(start: start)
            }
        )
    }
}
