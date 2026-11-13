import SwiftUI
import TrendingTabCore

struct MajorEventDetailView: View {
    let event: EventCluster
    let reports: [StoredItem]
    let sourceNames: [String: String]
    let diagnostic: EventDiagnostic?
    let openSource: (StoredItem) -> Void
    let openAnalysis: () -> Void

    private var overview: String? {
        nonEmpty(event.brief?.overview) ?? nonEmpty(event.summary)
    }

    private var importanceAnalysis: String? {
        nonEmpty(event.brief?.importanceAnalysis) ?? nonEmpty(event.assessmentReason)
    }

    private var platformCount: Int {
        var seenURLs = Set<String>()
        return Set(reports.compactMap { report -> String? in
            let canonical = NormalizedItem.canonical(report.item.url)
            guard seenURLs.insert(canonical).inserted else { return nil }
            return report.item.sourceID
        }).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                overviewCard
                content
                sourceEvidence
                analysisBasis
            }
            .padding(.horizontal, 26)
            .padding(.top, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("major-event-detail")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                StatusPill(title: "重大事件")
                if let category = nonEmpty(event.category) {
                    StatusPill(title: category, color: .secondary)
                }
                Spacer(minLength: 0)
                Text((event.assessedAt ?? event.updatedAt).trendingRelativeText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Text(event.title)
                .font(.system(size: 31, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { eventFacts }.fixedSize()
                VStack(alignment: .leading, spacing: 6) { eventFacts }
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)

            Button(action: openAnalysis) {
                Label("深入分析", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("围绕该事件的全部来源材料提问")
        }
    }

    @ViewBuilder
    private var eventFacts: some View {
        Label("\(reports.count) 篇报道", systemImage: "newspaper")
        Label("\(platformCount) 个报道平台", systemImage: "rectangle.3.group")
        Label("更新于 \(event.updatedAt.formatted(.dateTime.month().day().hour().minute()))", systemImage: "clock")
    }

    private var overviewCard: some View {
        CardSurface(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(title: "发生了什么", detail: evidenceDetail)
                if let overview {
                    Text(overview)
                        .font(.system(size: 16))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label(overviewFallback, systemImage: "clock")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let importanceAnalysis {
            VStack(alignment: .leading, spacing: 9) {
                SectionHeading(title: "为什么重要", detail: "AI 根据当前材料的判断")
                Text(importanceAnalysis)
                    .font(.system(size: 16))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let questions = event.brief?.openQuestions.filter({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), !questions.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                SectionHeading(title: "待确认信息", detail: "当前材料尚未确认")
                ForEach(questions, id: \.self) { question in
                    Label(question, systemImage: "questionmark.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var sourceEvidence: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeading(title: "来源证据", detail: "打开任一来源可阅读原文，随后可返回此事件")
            ForEach(reports) { report in
                sourceCard(report)
            }
        }
    }

    private func sourceCard(_ report: StoredItem) -> some View {
        let cited = Set(event.assessmentEvidenceIDs ?? event.brief?.evidenceIDs ?? []).contains(report.id)
        return Button { openSource(report) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(sourceNames[report.item.sourceID] ?? report.item.sourceID)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                    if cited { StatusPill(title: "判断引用") }
                    Spacer(minLength: 0)
                    Text((report.item.publishedAt ?? report.lastSeenAt).trendingRelativeText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .accessibilityHidden(true)
                }
                Text(report.item.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                if let summary = nonEmpty(report.item.summary) {
                    Text(summary)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(SelectableButtonStyle())
        .accessibilityLabel("打开来源：\(report.item.title)")
    }

    private var analysisBasis: some View {
        DisclosureGroup("分析依据") {
            VStack(alignment: .leading, spacing: 8) {
                if let importance = event.importance {
                    Text("重要度：\(importance) / 100")
                }
                if let confidence = event.confidence {
                    Text("模型置信度：\(Int((confidence * 100).rounded()))%")
                }
                Text("材料范围：\(event.evidenceLevel)")
                if let diagnostic {
                    Text("处理状态：\(diagnostic.message)")
                    if let groupingReason = diagnostic.groupingReason {
                        Text("归并依据：\(groupingReason)")
                    }
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.top, 6)
        }
        .font(.system(size: 15, weight: .medium))
        .accessibilityHint("显示事件的评分、材料范围和处理状态")
    }

    private var evidenceDetail: String {
        if let diagnostic, diagnostic.stage == "pending-analysis" {
            return "正在根据 \(reports.count) 篇当前报道整理"
        }
        return "综合 \(reports.count) 篇当前报道"
    }

    private var overviewFallback: String {
        if diagnostic?.stage == "pending-analysis" { return "正在汇总当前事件的材料。" }
        return "来源尚未提供可用摘要，可从下方打开报道阅读。"
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
