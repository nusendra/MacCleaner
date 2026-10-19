import Foundation

public struct JunkScanProgress: Sendable {
    public var finishedTasks: Int
    public var totalTasks: Int
    public var currentTitle: String

    public var fraction: Double { totalTasks == 0 ? 1 : Double(finishedTasks) / Double(totalTasks) }
}

/// Runs scan tasks concurrently, each under its own timeout, and merges results by group.
public struct JunkScanner: Sendable {
    public var tasks: [any JunkScanTask]

    public init(tasks: [any JunkScanTask] = JunkScanTasks.all()) {
        self.tasks = tasks
    }

    public func scan(
        context: ScanContext = ScanContext(),
        progress: @escaping @Sendable (JunkScanProgress) -> Void = { _ in }
    ) async -> JunkScanResult {
        var outputs: [Int: [JunkSubgroup]] = [:]
        var failures: [String: String] = [:]
        var finished = 0

        await withTaskGroup(of: (Int, Result<[JunkSubgroup], Error>).self) { group in
            for (index, task) in tasks.enumerated() {
                group.addTask {
                    (index, await Self.run(task, context: context))
                }
            }
            for await (index, result) in group {
                finished += 1
                switch result {
                case .success(let subgroups): outputs[index] = subgroups
                case .failure(let error): failures[tasks[index].title] = error.localizedDescription
                }
                progress(JunkScanProgress(finishedTasks: finished, totalTasks: tasks.count, currentTitle: tasks[index].title))
            }
        }

        // Keep task order: groups appear in the order their first task was declared.
        var groups: [JunkGroup] = []
        for (index, task) in tasks.enumerated() {
            let subgroups = (outputs[index] ?? []).filter { !$0.items.isEmpty }
            guard !subgroups.isEmpty else { continue }
            if let existing = groups.firstIndex(where: { $0.id == task.group }) {
                groups[existing].subgroups += subgroups
            } else {
                groups.append(JunkGroup(id: task.group, subgroups: subgroups))
            }
        }
        return JunkScanResult(groups: groups, failures: failures)
    }

    /// Races the task against its timeout; the loser is cancelled.
    private static func run(_ task: any JunkScanTask, context: ScanContext) async -> Result<[JunkSubgroup], Error> {
        await withTaskGroup(of: Result<[JunkSubgroup], Error>?.self) { group in
            group.addTask {
                do { return .success(try await task.scan(context)) } catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(for: task.timeout)
                return Task.isCancelled ? nil : .failure(JunkScanTimeout(task: task.title, timeout: task.timeout))
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(CancellationError())
        }
    }
}

public struct JunkScanTimeout: LocalizedError {
    var task: String
    var timeout: Duration

    public var errorDescription: String? { "\(task) took longer than \(timeout.components.seconds) seconds and was stopped." }
}
