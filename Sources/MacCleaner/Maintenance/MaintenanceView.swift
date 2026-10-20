import AppKit
import JunkCleanup
import Maintenance
import SwiftUI

@MainActor
final class MaintenanceViewModel: ObservableObject {
    enum Phase {
        case choosing
        case running(current: String)
        case finished([MaintenanceResult])
    }

    @Published private(set) var tasks = MaintenanceTask.available()
    @Published var selected: Set<MaintenanceTask.ID> = Set(MaintenanceTask.available().filter(\.recommended).map(\.id))
    @Published private(set) var phase: Phase = .choosing
    @Published private(set) var memory = MemoryStats.current()
    let hasFullDiskAccess = Permissions.hasFullDiskAccess

    var selectedTasks: [MaintenanceTask] { tasks.filter { selected.contains($0.id) } }
    var needsPassword: Bool { selectedTasks.contains(where: \.needsAdmin) }

    func toggle(_ task: MaintenanceTask) {
        if selected.remove(task.id) == nil { selected.insert(task.id) }
    }

    func run() {
        let tasks = selectedTasks
        phase = .running(current: tasks.first?.title ?? "")
        Task {
            let results = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let results = MaintenanceRunner.run(tasks, isAppRunning: { id in
                        !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
                    }) { task in
                        Task { @MainActor [weak self] in self?.phase = .running(current: task.title) }
                    }
                    continuation.resume(returning: results)
                }
            }
            memory = MemoryStats.current()
            phase = .finished(results)
        }
    }

    func reset() {
        phase = .choosing
        memory = MemoryStats.current()
    }
}

struct MaintenanceView: View {
    @StateObject private var viewModel = MaintenanceViewModel()

    var body: some View {
        Group {
            switch viewModel.phase {
            case .choosing: chooser
            case .running(let current):
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Running \(current)…").font(.headline)
                    if viewModel.needsPassword {
                        Text("Enter your administrator password if macOS asks for it.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .finished(let results): MaintenanceResults(results: results) { viewModel.reset() }
            }
        }
        .navigationTitle("Maintenance")
    }

    private var chooser: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Maintenance").font(.largeTitle.weight(.bold))
                        Text("Run routines that keep macOS responsive. Pick what you need; nothing runs until you press Run.")
                            .foregroundStyle(.secondary)
                    }
                    if let memory = viewModel.memory {
                        Label("Memory: \(memory.used.formattedMemory) used of \(memory.total.formattedMemory)", systemImage: "memorychip")
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 10) {
                        ForEach(viewModel.tasks) { task in
                            MaintenanceRow(task: task, isSelected: viewModel.selected.contains(task.id)) { viewModel.toggle(task) }
                        }
                    }
                    if !viewModel.hasFullDiskAccess {
                        Label("Speed Up Mail appears once \(FullDiskAccessTarget.name) has Full Disk Access.", systemImage: "lock.shield")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(28)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                if viewModel.needsPassword {
                    Label("macOS will ask for your administrator password once.", systemImage: "key")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Run \(viewModel.selected.count) \(viewModel.selected.count == 1 ? "Task" : "Tasks")") { viewModel.run() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.selected.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .frame(height: 64)
        }
    }
}

private struct MaintenanceRow: View {
    let task: MaintenanceTask
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CheckBox(state: isSelected ? .on : .off, label: "Select \(task.title)", action: toggle)
            Image(systemName: task.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.title).font(.headline)
                    if task.needsAdmin {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            .help("Needs your administrator password")
                            .accessibilityLabel("Needs administrator password")
                    }
                }
                Text(task.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(lastRunText).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.18)))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: toggle)
    }

    private var lastRunText: String {
        guard let date = MaintenanceHistory.lastRun(of: task.id) else { return "Never run from MacCleaner" }
        return "Last run \(date.formatted(.relative(presentation: .named)))"
    }
}

private struct MaintenanceResults: View {
    let results: [MaintenanceResult]
    let onDone: () -> Void

    var body: some View {
        let failed = results.filter { !$0.succeeded }
        VStack(spacing: 18) {
            Image(systemName: failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(failed.isEmpty ? Color.green : Color.orange)
                .accessibilityHidden(true)
            Text(failed.isEmpty ? "Maintenance complete" : "Some tasks did not finish").font(.title.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(results) { result in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: result.succeeded ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(result.succeeded ? Color.green : Color.red)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.task.title).font(.headline)
                            if let text = result.error ?? result.detail {
                                Text(text).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            Button("Done", action: onDone).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Int64 {
    var formattedMemory: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .memory) }
}
