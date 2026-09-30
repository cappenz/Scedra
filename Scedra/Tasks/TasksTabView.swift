import SwiftUI

struct TasksTabView: View {
    var calendar: CalendarStore
    var tasks: TaskRepository

    @State private var editor: TaskEditorSession?
    @State private var pendingDelete: ScedraTask?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                ScedraTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        addButton
                        if tasks.openTasks.isEmpty && tasks.completedTasks.isEmpty {
                            emptyCard
                            examplesCard
                        } else {
                            openSection
                            if !tasks.completedTasks.isEmpty {
                                completedSection
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .scedraUsesSelectedTheme()
            .safeAreaInset(edge: .top, spacing: 0) {
                ScedraScreenHeader(title: "Tasks") {
                    showSettings = true
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 6)
                .background(ScedraTheme.background.ignoresSafeArea(edges: .top))
            }
            .task {
                tasks.reconcile()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    tasks.reconcile()
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(item: $editor) { session in
                TaskEditorView(
                    session: session,
                    busy: tasks.occupancy(excluding: session.task, calendar: calendar),
                    onSave: { task in
                        Task {
                            await tasks.placeAndSave(
                                task,
                                calendar: calendar,
                                honorSchedule: task.isPlaced
                            )
                        }
                    },
                    onDelete: session.isNew ? nil : { task in
                        Task { await tasks.delete(task, from: calendar) }
                    }
                )
            }
            .alert("Delete this task?", isPresented: deleteAlertPresented) {
                Button("Delete task", role: .destructive) {
                    if let pendingDelete {
                        Task { await tasks.delete(pendingDelete, from: calendar) }
                    }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDelete = nil
                }
            } message: {
                if let pendingDelete {
                    Text("Removes “\(pendingDelete.title)” from Scedra.")
                } else {
                    Text("Removes this task from Scedra.")
                }
            }
        }
    }

    private var deleteAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var addButton: some View {
        Button {
            editor = .create(ScedraTask(title: ""))
        } label: {
            Label("Add task", systemImage: "plus")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(ScedraTheme.purple, in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No open tasks")
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .foregroundStyle(ScedraTheme.deepPurple)
            Text("Add one and Scedra will find a time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scedraCard()
    }

    private var examplesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Try one of these")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ScedraTheme.deepPurple)
            ForEach(TaskExample.allCases) { example in
                let sample = example.makeTask()
                Button {
                    editor = .create(sample)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sample.title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(ScedraTheme.deepPurple)
                            Text(exampleCaption(example))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ScedraTheme.purple)
                    }
                    .padding(12)
                    .background(ScedraTheme.blush, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .scedraCard()
    }

    private func exampleCaption(_ example: TaskExample) -> String {
        switch example {
        case .callDentist:
            ScedraString("10 min · OK while driving")
        case .chemistryHomework:
            ScedraString("45 min · needs focus")
        case .buyGroceries:
            ScedraString("30 min · grocery, travel")
        }
    }

    private var openSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open")
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .foregroundStyle(ScedraTheme.deepPurple)
            if tasks.openTasks.isEmpty {
                Text("No open tasks")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scedraCard()
            } else {
                // ScrollView, not List: swipe-to-delete never lands. Visible trash, like Today.
                VStack(spacing: 0) {
                    ForEach(Array(tasks.openTasks.enumerated()), id: \.element.id) { index, task in
                        if index > 0 {
                            Divider().opacity(0.35)
                        }
                        taskRow(task)
                    }
                }
                .scedraCard()
            }
        }
    }

    private var completedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Completed")
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .foregroundStyle(ScedraTheme.deepPurple)
            VStack(spacing: 0) {
                ForEach(Array(tasks.completedTasks.enumerated()), id: \.element.id) { index, task in
                    if index > 0 {
                        Divider().opacity(0.35)
                    }
                    taskRow(task)
                }
            }
            .scedraCard()
        }
    }

    private func taskRow(_ task: ScedraTask) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                tasks.setCompleted(task, isCompleted: !task.isCompleted)
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.isCompleted ? ScedraTheme.purple : ScedraTheme.purple.opacity(0.45))
                    .frame(minWidth: 44, minHeight: 44, alignment: .top)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isCompleted ? ScedraString("Mark not complete") : ScedraString("Mark complete"))

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(ScedraTheme.deepPurple)
                    .strikethrough(task.isCompleted, color: ScedraTheme.purple.opacity(0.55))
                Text(detailLine(for: task))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let window = scheduledLine(for: task) {
                    Text(window)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ScedraTheme.purple)
                } else if !task.isCompleted {
                    Text("Not placed yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                editor = .edit(task)
            }

            Button(role: .destructive) {
                pendingDelete = task
            } label: {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundStyle(ScedraTheme.conflict)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ScedraString("Delete \(task.title)"))
        }
        .padding(.vertical, 4)
    }

    private func detailLine(for task: ScedraTask) -> String {
        var parts: [String] = [ScedraString("\(task.estimatedDurationMinutes) min")]
        let place = task.location.trimmingCharacters(in: .whitespacesAndNewlines)
        if !place.isEmpty {
            parts.append(place)
        }
        if task.requiresTravel {
            parts.append(ScedraString("travel"))
        }
        if let deadline = task.deadline {
            parts.append(ScedraString("Deadline \(deadline.scedraDisplay(date: .abbreviated, time: .shortened))"))
        }
        return parts.joined(separator: " · ")
    }

    private func scheduledLine(for task: ScedraTask) -> String? {
        guard let start = task.scheduledStart, let end = task.scheduledEnd else { return nil }
        let window = "\(start.scedraDisplay(date: .abbreviated, time: .shortened)) – \(end.scedraDisplay(date: .omitted, time: .shortened))"
        return ScedraString("Scheduled \(window)")
    }
}
