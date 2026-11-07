import SwiftUI
import Combine
import DonbyCore
import DonbyNetwork

public struct MainCarouselView: View {
    @EnvironmentObject private var appState: AppState
    public let items: [EmbyItem]
    public let onPlay: (EmbyItem) -> Void
    public let onSelectDetail: (EmbyItem) -> Void

    @State private var currentIndex: Int = 0
    @State private var isHovering: Bool = false

    private let timer = Timer.publish(every: 6.0, on: .main, in: .common).autoconnect()

    public init(
        items: [EmbyItem],
        onPlay: @escaping (EmbyItem) -> Void,
        onSelectDetail: @escaping (EmbyItem) -> Void
    ) {
        self.items = items
        self.onPlay = onPlay
        self.onSelectDetail = onSelectDetail
    }

    private var currentItem: EmbyItem? {
        guard !items.isEmpty else { return nil }
        let safeIdx = max(0, min(currentIndex, items.count - 1))
        return items[safeIdx]
    }

    public var body: some View {
        if let item = currentItem {
            ZStack(alignment: .bottomLeading) {
                MediaArtworkView(
                    server: appState.activeServer,
                    item: item,
                    kind: .backdrop,
                    maxWidth: 1600
                )
                .id(item.id)
                .frame(maxWidth: .infinity)
                .frame(height: 365)
                .clipped()
                .transition(.opacity)

                LinearGradient(
                    colors: [Color.black.opacity(0.85), Color.black.opacity(0.40), Color.clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.35), Color.black.opacity(0.90)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        if let res = item.resolutionBadge {
                            Text(res)
                                .font(.system(size: 11, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(appState.accentColor)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        if let audioTag = item.audioSummaryTag {
                            Text(audioTag)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.92))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.16))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        if let rating = item.communityRating, rating > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.yellow)
                                Text(String(format: "%.1f", rating))
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.black.opacity(0.45)).clipShape(Capsule())
                        }
                        if let year = item.productionYear {
                            Text(String(year)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.82))
                        }
                        if let genres = item.genres, !genres.isEmpty {
                            Text(genres.prefix(2).joined(separator: " · "))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let tagline = item.taglines?.first, !tagline.isEmpty {
                            Text(tagline).font(.system(size: 13, weight: .semibold)).foregroundStyle(appState.accentColor).lineLimit(1)
                        }
                    }

                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.84))
                            .lineLimit(2)
                            .frame(maxWidth: 580, alignment: .leading)
                    }

                    HStack(spacing: 12) {
                        Button { onPlay(item) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "play.fill").font(.system(size: 13, weight: .bold))
                                Text(item.resumePositionSeconds > 0 ? "继续播放" : "立即播放").font(.system(size: 14, weight: .bold))
                            }
                            .foregroundStyle(.white).padding(.horizontal, 22).padding(.vertical, 10)
                            .background(appState.accentColor).clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button { onSelectDetail(item) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle.fill").font(.system(size: 13))
                                Text("详情").font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundStyle(.white).padding(.horizontal, 18).padding(.vertical, 10)
                            .background(.ultraThinMaterial).clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                .padding(.trailing, 160) // reserve room for indicators
            }
            .frame(height: 365)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                HStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, _ in
                        Capsule()
                            .fill(idx == currentIndex ? Color.white : Color.white.opacity(0.32))
                            .frame(width: idx == currentIndex ? 22 : 7, height: 7)
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { currentIndex = idx } }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.black.opacity(0.40)).clipShape(Capsule())
                .padding(.trailing, 24)
                .padding(.bottom, 24),
                alignment: .bottomTrailing
            )
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .onHover { h in withAnimation(.easeInOut(duration: 0.2)) { isHovering = h } }
            .onReceive(timer) { _ in
                guard !isHovering && items.count > 1 else { return }
                withAnimation(.easeInOut(duration: 0.3)) { currentIndex = (currentIndex + 1) % items.count }
            }
        }
    }
}
