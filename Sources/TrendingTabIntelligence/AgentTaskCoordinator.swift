import Foundation

/// One interactive and one automatic task can run concurrently; each lane is FIFO.
public actor AgentTaskCoordinator {
    public enum Lane: Sendable { case foreground, background }
    public struct Permit: Hashable, Sendable { fileprivate let id: UUID }
    private struct Waiter {
        let id: UUID
        let lane: Lane
        let continuation: CheckedContinuation<Permit, Error>
    }
    private var active: [UUID: Lane] = [:]
    private var waiting: [Waiter] = []

    public init() {}

    public func acquire(_ lane: Lane) async throws -> Permit {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if !active.values.contains(where: { $0 == lane }) {
                    active[id] = lane
                    continuation.resume(returning: Permit(id: id))
                } else {
                    waiting.append(Waiter(id: id, lane: lane, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }

    public func release(_ permit: Permit) {
        guard let lane = active.removeValue(forKey: permit.id),
              let index = waiting.firstIndex(where: { $0.lane == lane }) else { return }
        let next = waiting.remove(at: index)
        active[next.id] = next.lane
        next.continuation.resume(returning: Permit(id: next.id))
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
