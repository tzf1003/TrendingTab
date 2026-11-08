import Foundation
import SwiftUI

/// A transport description of the loaded page, separate from site login status.
struct BrowserSiteInformation: Equatable {
    enum Connection: Equatable {
        case empty, loading, failed, encrypted, mixedContent, unencrypted, unavailable

        var title: String {
            switch self {
            case .empty: "尚未打开网页"
            case .loading: "正在建立页面连接"
            case .failed: "页面加载失败"
            case .encrypted: "连接已加密"
            case .mixedContent: "页面包含未加密内容"
            case .unencrypted: "连接未加密"
            case .unavailable: "连接信息暂不可用"
            }
        }

        var symbol: String {
            switch self {
            case .encrypted: "lock"
            case .failed, .mixedContent, .unencrypted: "exclamationmark.shield"
            default: "info.circle"
            }
        }
    }

    let host: String
    let connection: Connection

    init(url: URL?, loading: Bool, finished: Bool, navigationFailed: Bool, onlySecureContent: Bool) {
        host = url?.host ?? "新标签"
        if navigationFailed { connection = .failed }
        else if loading { connection = .loading }
        else if url == nil || url?.absoluteString == "about:blank" { connection = .empty }
        else if !finished { connection = .unavailable }
        else if url?.scheme?.lowercased() == "http" { connection = .unencrypted }
        else if url?.scheme?.lowercased() == "https" {
            connection = onlySecureContent ? .encrypted : .mixedContent
        } else { connection = .unavailable }
    }
}

struct BrowserSiteInformationView: View {
    let information: BrowserSiteInformation
    let owner: BrowserWorkspace.Owner
    let userTookControl: Bool
    let httpStatus: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("站点信息").font(.headline)
            Text(information.host).font(.title3.weight(.semibold)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Label(information.connection.title, systemImage: information.connection.symbol)
            if let httpStatus, httpStatus >= 400 {
                Text("网页返回 HTTP \(httpStatus)").foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("浏览器身份").font(.subheadline.weight(.semibold))
                Text("用户标签与 AI 标签共用 TrendingTab 内的站点登录。登录是否有效由网站确认。")
                Text("可在“设置 → 浏览器”中管理和清除站点数据。")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(owner == .user ? "用户标签" : (userTookControl ? "AI 标签 · 已由你接管" : "AI 标签 · 可自主浏览"),
                      systemImage: owner == .user ? "person" : "sparkles")
                    .font(.subheadline.weight(.semibold))
                Text(owner == .user
                     ? "AI 读取或操作此标签时，需获得本轮任务授权。"
                     : (userTookControl ? "AI 已停止操作此页，可在新的 AI 标签中继续研究。"
                        : "预览此页可保持 AI 操作；在网页内点击、输入或滚动会接管此页。"))
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: 330, alignment: .leading)
    }
}
