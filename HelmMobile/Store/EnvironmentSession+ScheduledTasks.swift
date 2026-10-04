import Foundation

/// Scheduled tasks on one Mac (`scheduledTasks.*`). The list streams: a snapshot on subscribe,
/// then the whole list again after every change, so the screen never refetches by hand.
extension EnvironmentSession {
    func scheduledTasks() throws -> AsyncThrowingStream<[ScheduledTask], Error> {
        let source = try stream("scheduledTasks.subscribe", [:])
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in source { continuation.yield(ScheduledTask.list(value)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @discardableResult
    func upsertScheduledTask(_ payload: JSON) async throws -> ScheduledTask {
        try Self.task(from: await call("scheduledTasks.upsert", payload))
    }

    func setScheduledTask(_ id: String, enabled: Bool) async throws {
        _ = try await call("scheduledTasks.setEnabled", ["id": .string(id), "enabled": .bool(enabled)])
    }

    func deleteScheduledTask(_ id: String) async throws {
        _ = try await call("scheduledTasks.delete", ["id": .string(id)])
    }

    /// Starts a run now, whatever the schedule says (this one really runs the agent).
    func runScheduledTaskNow(_ id: String) async throws {
        _ = try await call("scheduledTasks.runNow", ["id": .string(id)])
    }

    private static func task(from result: JSON) throws -> ScheduledTask {
        guard let task = result["task"].flatMap(ScheduledTask.init(json:)) else { throw RPCError.defect("No task in the answer") }
        return task
    }
}
