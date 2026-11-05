import Foundation

public struct WidgetNavigationTarget: Equatable, Sendable {
    public var itemID: String?
    public var eventID: UUID?
    public var tabID: UUID?

    public init(itemID: String? = nil, eventID: UUID? = nil, tabID: UUID? = nil) {
        self.itemID = itemID
        self.eventID = eventID
        self.tabID = tabID
    }

    public init?(url: URL) {
        guard url.scheme == "trendingtab", url.host == "item" || url.host == "tab",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = components.queryItems ?? []
        itemID = query.first { $0.name == "item" }?.value?.trimmedNonEmpty()
        eventID = query.first { $0.name == "event" }?.value.flatMap(UUID.init(uuidString:))
        tabID = query.first { $0.name == "tab" }?.value.flatMap(UUID.init(uuidString:))
        guard url.host == "tab" || itemID != nil || eventID != nil else { return nil }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "trendingtab"
        components.host = itemID == nil && eventID == nil ? "tab" : "item"
        var query: [URLQueryItem] = []
        if let itemID { query.append(URLQueryItem(name: "item", value: itemID)) }
        if let eventID { query.append(URLQueryItem(name: "event", value: eventID.uuidString)) }
        if let tabID { query.append(URLQueryItem(name: "tab", value: tabID.uuidString)) }
        components.queryItems = query
        return components.url!
    }
}
