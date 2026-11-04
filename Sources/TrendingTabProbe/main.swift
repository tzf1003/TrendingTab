import Foundation
import TrendingTabNetworking
import TrendingTabSources

struct ProbeReport: Codable {
    var sourceID: String
    var boardID: String
    var state: String
    var count: Int
    var message: String
}

let providers = SourceCatalog.providers()
var reports: [ProbeReport] = []
for provider in providers {
    let boards = (try? await provider.boards()) ?? []
    guard let board = boards.first else { continue }
    do {
        let result = try await provider.fetch(board: board.id, context: FetchContext(transport: URLSessionTransport(), now: Date()))
        reports.append(ProbeReport(sourceID: provider.descriptor.id, boardID: board.id, state: result.items.isEmpty ? "empty" : "success", count: result.items.count, message: provider.descriptor.availability.rawValue))
    } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        reports.append(ProbeReport(sourceID: provider.descriptor.id, boardID: board.id, state: "failed", count: 0, message: message))
    }
}
let data = try JSONEncoder().encode(reports)
FileHandle.standardOutput.write(data)
