import Foundation

/// The persistent selection belongs to a widget configuration and size.
/// Switchable copies of the same size use separate slots to browse independently.
public struct WidgetSelectionScope: Equatable, Sendable {
    public enum Size: String, Sendable {
        case small, medium, large
    }

    public var initialTabID: UUID?
    public var fixedBoard: Bool
    public var slot: String
    public var size: Size

    public init(initialTabID: UUID?, fixedBoard: Bool, slot: String, size: Size) {
        self.initialTabID = initialTabID
        self.fixedBoard = fixedBoard
        self.slot = slot
        self.size = size
    }

    public var storageKey: String {
        let board = initialTabID?.uuidString ?? "default"
        let mode = fixedBoard ? "fixed" : "switchable"
        return "widget-v2-\(size.rawValue)-\(mode)-\(board)-\(slot)"
    }

    public func resolvedTabID(
        available: [UUID],
        profileDefault: UUID?,
        remembered: WidgetSelection?
    ) -> UUID? {
        let preferred = fixedBoard
            ? [initialTabID, profileDefault]
            : [remembered?.tabID, initialTabID, profileDefault]
        return WidgetSelection.resolvedTabID(available: available, preferred: preferred)
    }
}
