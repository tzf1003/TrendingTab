import SwiftUI
import TrendingTabCore
import TrendingTabCore
import TrendingTabKit
import TrendingTabPersistence
import TrendingTabSources

struct EventCenterView: View {
    @ObservedObject var model: TrendingAppModel
    @State private var selected: EventCluster?

    var body: some View {
        NavigationSplitView {
            List(model.events, selection: $selected) { event in
                VStack(alignment: .leading) {
                    Text(event.title).lineLimit(2)
                    Text("\(event.independentSourceCount) 个来源 · \(event.status)").font(.caption).foregroundStyle(.secondary)
                }
            }
        } detail: {
            if let selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(selected.title).font(.title2)
                        Text(selected.summary ?? "尚未生成摘要")
                        Text("证据级别：\(selected.evidenceLevel)").font(.caption)
                        ForEach(model.items.filter { selected.itemIDs.contains($0.id) }) { item in
                            Link(item.item.title, destination: item.item.url)
                        }
                        Button("深入分析") { Task { await model.analyzeEvent(selected) } }
                        Text(model.analysisText).textSelection(.enabled)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("选择一个事件", systemImage: "newspaper")
            }
        }
        .frame(minWidth: 860, minHeight: 560)
    }
}
