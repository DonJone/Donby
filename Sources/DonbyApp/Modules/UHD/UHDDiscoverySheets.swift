#if canImport(DonbyUHDModule)
import SwiftUI
import DonbyCore
import DonbyUHDModule

// MARK: - Anime Calendar Sheet

public struct UHDAnimeCalendarSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    public let server: EmbyServerConfig

    @State private var days: [UHDAnimeCalendarDay] = (1...7).map { UHDAnimeCalendarDay(weekday: $0, total: 0) }
    @State private var selectedWeekday: Int = UHDAnimeCalendarDay.todayShanghaiWeekday()
    @State private var entries: [UHDAnimeCalendarEntry] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil

    public init(server: EmbyServerConfig) {
        self.server = server
    }

    public var body: some View {
        let appearance = appState.cardAppearance
        let todayWD = UHDAnimeCalendarDay.todayShanghaiWeekday()
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("追番日历")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    Text("近期播出排期")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }
                Spacer()
                ToolbarVectorButton(tooltip: "关闭", action: { dismiss() }) { hovered in
                    let col = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.35)) : (hovered ? .white : Color(white: 0.72))
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(col)
                }
            }

            HStack(spacing: 6) {
                ForEach(days) { day in
                    let isSelected = (day.weekday == selectedWeekday)
                    let isToday = (day.weekday == todayWD)
                    Button {
                        selectedWeekday = day.weekday
                    } label: {
                        VStack(spacing: 2) {
                            Text(isToday ? "\(day.shortTitle)·今" : day.shortTitle)
                                .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                            Text("\(day.total)")
                                .font(.system(size: 10, design: .monospaced))
                                .opacity(0.75)
                        }
                        .foregroundStyle(isSelected ? appState.accentTextColor : DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isSelected ? appState.accentColor : DonbyGlassPalette.cardBackground(isLight: appState.isLightMode))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(isSelected ? appState.accentColor : DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.6)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.vertical, 8)
            } else if isLoading && entries.isEmpty {
                VStack { Spacer(); ProgressView(); Spacer() }
                    .frame(maxWidth: .infinity, minHeight: 340)
            } else if entries.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "calendar")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    Text("当天暂无排期")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 340)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 146, maximum: 165), spacing: 14)], alignment: .leading, spacing: 16) {
                        ForEach(entries) { entry in
                            ZStack(alignment: .topTrailing) {
                                PosterCardView(
                                    item: entry.item,
                                    width: 148,
                                    appearance: appearance,
                                    onSelect: {
                                        dismiss()
                                        appState.openDetail(for: entry.item)
                                    },
                                    onPlay: {
                                        dismiss()
                                        Task { await appState.startPlayback(item: entry.item) }
                                    }
                                )
                                .equatable()

                                Text(entry.schedule.badgeText)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2.5)
                                    .background(Color.black.opacity(0.72))
                                    .clipShape(Capsule())
                                    .padding(6)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 360, maxHeight: 480)
            }
        }
        .padding(22)
        .frame(width: 780)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
        .task {
            if let fetchedDays = try? await UHDStreamClient.shared.fetchAnimeCalendarDays(server: server), !fetchedDays.isEmpty {
                days = fetchedDays
            }
        }
        .task(id: selectedWeekday) {
            isLoading = true
            errorMessage = nil
            defer { isLoading = false }
            do {
                entries = try await UHDStreamClient.shared.fetchAnimeCalendarItems(server: server, weekday: selectedWeekday)
            } catch {
                errorMessage = "加载失败: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Favorites Browser Sheet

public struct UHDFavoritesSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    public let server: EmbyServerConfig

    private enum FavTab: String, CaseIterable, Identifiable {
        case movie = "电影"
        case tv = "剧集"
        case person = "人物"
        var id: String { rawValue }
        var apiType: String {
            switch self {
            case .movie: return "movie"
            case .tv: return "tv"
            case .person: return "person"
            }
        }
    }

    @State private var tab: FavTab = .movie
    @State private var mediaItems: [EmbyItem] = []
    @State private var persons: [UHDPersonDetail] = []
    @State private var totalCount: Int = 0
    @State private var nextCursor: String? = nil
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false

    public init(server: EmbyServerConfig) {
        self.server = server
    }

    public var body: some View {
        let appearance = appState.cardAppearance
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 8) {
                    Text("我的收藏")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    if totalCount > 0 {
                        Text("\(totalCount)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    }
                }
                Spacer()
                DonbySegmentedControl(
                    options: FavTab.allCases,
                    selection: $tab,
                    isLightMode: appState.isLightMode,
                    accentColor: appState.accentColor,
                    accentTextColor: appState.accentTextColor,
                    fontSize: 12,
                    horizontalPadding: 13,
                    verticalPadding: 5,
                    title: { $0.rawValue }
                )

                ToolbarVectorButton(tooltip: "关闭", action: { dismiss() }) { hovered in
                    let col = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.35)) : (hovered ? .white : Color(white: 0.72))
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(col)
                }
            }

            Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

            if isLoading && mediaItems.isEmpty && persons.isEmpty {
                VStack { Spacer(); ProgressView(); Spacer() }
                    .frame(maxWidth: .infinity, minHeight: 360)
            } else if tab == .person {
                if persons.isEmpty {
                    emptyPlaceholder("暂无收藏人物")
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105, maximum: 125), spacing: 16)], alignment: .leading, spacing: 16) {
                            ForEach(persons) { p in
                                let embyPerson = EmbyPerson(id: p.id, name: p.name, role: nil, type: "Actor", primaryImageTag: nil, uhdImageURL: p.imageURL)
                                Button {
                                    dismiss()
                                    UHDModuleManager.shared.activePersonSheet = UHDPersonSheetTarget(server: server, person: embyPerson)
                                } label: {
                                    VStack(spacing: 7) {
                                        PersonAvatarView(server: server, person: embyPerson, width: 88, height: 112, accentColor: appState.accentColor)
                                        Text(p.name)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                            .lineLimit(1)
                                    }
                                    .frame(width: 100)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                        loadMoreFooter
                    }
                    .frame(minHeight: 360, maxHeight: 470)
                }
            } else {
                if mediaItems.isEmpty {
                    emptyPlaceholder("暂无收藏\(tab.rawValue)")
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 146, maximum: 165), spacing: 14)], alignment: .leading, spacing: 16) {
                            ForEach(mediaItems) { item in
                                PosterCardView(
                                    item: item,
                                    width: 148,
                                    appearance: appearance,
                                    onSelect: {
                                        dismiss()
                                        appState.openDetail(for: item)
                                    },
                                    onPlay: {
                                        dismiss()
                                        Task { await appState.startPlayback(item: item) }
                                    }
                                )
                                .equatable()
                            }
                        }
                        .padding(.vertical, 4)
                        loadMoreFooter
                    }
                    .frame(minHeight: 360, maxHeight: 470)
                }
            }
        }
        .padding(22)
        .frame(width: 780)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
        .task(id: tab) {
            await loadPage(reset: true)
        }
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if let nextCursor, !nextCursor.isEmpty {
            HStack {
                Spacer()
                Button {
                    Task { await loadPage(reset: false) }
                } label: {
                    HStack(spacing: 6) {
                        if isLoadingMore { ProgressView().controlSize(.small) }
                        Text("加载更多")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .donbyLiquidGlassCapsule()
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isLoadingMore)
                Spacer()
            }
            .padding(.top, 10)
        }
    }

    private func emptyPlaceholder(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "heart")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            Text(msg)
                .font(.system(size: 13))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 340)
    }

    private func loadPage(reset: Bool) async {
        if reset {
            isLoading = true
            nextCursor = nil
        } else {
            guard !isLoadingMore, nextCursor != nil else { return }
            isLoadingMore = true
        }
        defer {
            isLoading = false
            isLoadingMore = false
        }
        if tab == .person {
            if let res = try? await UHDStreamClient.shared.fetchFavoritePersons(server: server, limit: 40, cursor: reset ? nil : nextCursor) {
                if reset { persons = res.items } else { persons.append(contentsOf: res.items) }
                totalCount = res.total
                nextCursor = res.nextCursor
            }
        } else {
            if let res = try? await UHDStreamClient.shared.fetchFavorites(server: server, type: tab.apiType, limit: 36, cursor: reset ? nil : nextCursor) {
                if reset { mediaItems = res.items } else { mediaItems.append(contentsOf: res.items) }
                totalCount = res.total
                nextCursor = res.nextCursor
            }
        }
    }
}

// MARK: - Person Detail & Works Sheet

public struct UHDPersonDetailSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    public let target: UHDPersonSheetTarget

    @State private var detail: UHDPersonDetail? = nil
    @State private var works: [EmbyItem] = []
    @State private var nextCursor: String? = nil
    @State private var mediaTypeFilter: String = ""
    @State private var sortBy: String = "release_date"
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var isTogglingFav: Bool = false

    public init(target: UHDPersonSheetTarget) {
        self.target = target
    }

    public var body: some View {
        let appearance = appState.cardAppearance
        let isFav = detail?.favorite ?? false
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                PersonAvatarView(
                    server: target.server,
                    person: target.person,
                    width: 60,
                    height: 78,
                    accentColor: appState.accentColor
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(detail?.name ?? target.person.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))

                    let personMeta: String = {
                        var parts: [String] = []
                        if let tmdb = detail?.tmdbId, !tmdb.isEmpty { parts.append("TMDB \(tmdb)") }
                        if let imdb = detail?.imdbId, !imdb.isEmpty { parts.append("IMDb \(imdb)") }
                        parts.append("\(works.count)\(nextCursor != nil ? "+" : "") 部作品")
                        return parts.joined(separator: " · ")
                    }()
                    Text(personMeta)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                }

                Spacer()

                Button {
                    guard !isTogglingFav else { return }
                    Task {
                        isTogglingFav = true
                        defer { isTogglingFav = false }
                        let nextFav = !isFav
                        if (try? await UHDStreamClient.shared.setPersonFavorite(server: target.server, personId: target.person.id, isFavorite: nextFav)) != nil {
                            if var d = detail {
                                d.favorite = nextFav
                                detail = d
                            } else {
                                detail = UHDPersonDetail(id: target.person.id, name: target.person.name, imageURL: target.person.uhdImageURL, favorite: nextFav)
                            }
                            appState.showToast(nextFav ? "已收藏 \(target.person.name)" : "已取消收藏", icon: nextFav ? "heart.fill" : "heart.slash")
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isFav ? "heart.fill" : "heart")
                            .foregroundStyle(isFav ? appState.accentColor : DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                        Text(isFav ? "已收藏" : "收藏")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .donbyLiquidGlassCapsule()
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                ToolbarVectorButton(tooltip: "关闭", action: { dismiss() }) { hovered in
                    let col = appState.isLightMode ? (hovered ? Color.black : Color(white: 0.35)) : (hovered ? .white : Color(white: 0.72))
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(col)
                }
            }

            HStack(spacing: 10) {
                DonbySegmentedControl(
                    options: ["", "movie", "tv"],
                    selection: $mediaTypeFilter,
                    isLightMode: appState.isLightMode,
                    accentColor: appState.accentColor,
                    accentTextColor: appState.accentTextColor,
                    fontSize: 12,
                    horizontalPadding: 12,
                    verticalPadding: 5,
                    title: { key in
                        switch key {
                        case "movie": return "电影"
                        case "tv": return "剧集"
                        default: return "全部"
                        }
                    }
                )

                Spacer()

                Picker("排序", selection: $sortBy) {
                    Text("发行日期").tag("release_date")
                    Text("热门").tag("hot")
                    Text("评分").tag("rating")
                    Text("最新").tag("asset_updated_at")
                    Text("名称").tag("title")
                }
                .frame(width: 140)
            }

            Divider().opacity(appState.isLightMode ? 0.30 : 0.12)

            if isLoading && works.isEmpty {
                VStack { Spacer(); ProgressView(); Spacer() }
                    .frame(maxWidth: .infinity, minHeight: 330)
            } else if works.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("暂无相关作品")
                        .font(.system(size: 13))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: appState.isLightMode))
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 330)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 146, maximum: 165), spacing: 14)], alignment: .leading, spacing: 16) {
                        ForEach(works) { item in
                            PosterCardView(
                                item: item,
                                width: 148,
                                appearance: appearance,
                                onSelect: {
                                    dismiss()
                                    appState.openDetail(for: item)
                                },
                                onPlay: {
                                    dismiss()
                                    Task { await appState.startPlayback(item: item) }
                                }
                            )
                            .equatable()
                        }
                    }
                    .padding(.vertical, 4)

                    if let cursor = nextCursor, !cursor.isEmpty {
                        HStack {
                            Spacer()
                            Button {
                                Task { await loadWorks(reset: false) }
                            } label: {
                                HStack(spacing: 6) {
                                    if isLoadingMore { ProgressView().controlSize(.small) }
                                    Text("加载更多")
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: appState.isLightMode))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 7)
                                .donbyLiquidGlassCapsule()
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoadingMore)
                            Spacer()
                        }
                        .padding(.top, 10)
                    }
                }
                .frame(minHeight: 340, maxHeight: 450)
            }
        }
        .padding(22)
        .frame(width: 780)
        .background(DonbyGlassPalette.canvas(isLight: appState.isLightMode))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: appState.isLightMode), lineWidth: 0.8)
        )
        .task {
            if let fetched = try? await UHDStreamClient.shared.fetchPersonDetail(server: target.server, personId: target.person.id) {
                detail = fetched
            }
        }
        .task(id: "\(mediaTypeFilter)|\(sortBy)") {
            await loadWorks(reset: true)
        }
    }

    private func loadWorks(reset: Bool) async {
        if reset {
            isLoading = true
            nextCursor = nil
        } else {
            guard !isLoadingMore, nextCursor != nil else { return }
            isLoadingMore = true
        }
        defer {
            isLoading = false
            isLoadingMore = false
        }
        let order = (sortBy == "title") ? "asc" : "desc"
        if let res = try? await UHDStreamClient.shared.fetchPersonWorks(
            server: target.server,
            personId: target.person.id,
            mediaType: mediaTypeFilter.isEmpty ? nil : mediaTypeFilter,
            sortBy: sortBy,
            sortOrder: order,
            limit: 36,
            cursor: reset ? nil : nextCursor
        ) {
            if reset {
                works = res.items
            } else {
                works.append(contentsOf: res.items)
            }
            nextCursor = res.nextCursor
        }
    }
}
#endif
