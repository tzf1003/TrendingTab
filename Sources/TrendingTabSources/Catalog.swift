import Foundation
import TrendingTabCore

public enum SourceCatalog {
    public static func providers(customFeeds: [FeedSource] = []) -> [any SourceProvider] {
        let feeds = customFeeds.isEmpty ? [BuiltInFeeds.linuxDo, BuiltInFeeds.landian, BuiltInFeeds.poJie, BuiltInFeeds.wechat] : customFeeds
        return [
            HotSearchProviders.weibo, HotSearchProviders.douyin, BaiduSourceProvider(), HotSearchProviders.zhihu, HotSearchProviders.toutiao,
            NewsAndVideoProviders.netease, NewsAndVideoProviders.thepaper, NewsAndVideoProviders.qqNews,
            NewsAndVideoProviders.bilibili, CommunityProviders.kr36, CommunityProviders.juejin,
            CommunityProviders.tieba, CommunityProviders.hupu,
        ] + feeds.map(RSSSourceProvider.init)
    }

    public static func provider(id: String, customFeeds: [FeedSource] = []) -> (any SourceProvider)? {
        providers(customFeeds: customFeeds).first { $0.descriptor.id == id }
    }
}
