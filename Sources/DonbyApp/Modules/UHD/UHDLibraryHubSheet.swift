#if canImport(DonbyUHDModule)
import SwiftUI
import DonbyCore
import DonbyUHDModule

// MARK: - Iconic Library Hall Vector Icons

/// Iconic vector mark for Normal Hall (cinema film frame with centered play glyph).
public struct UHDNormalHallVectorIcon: View {
    public var size: CGFloat = 15
    public var color: Color = Color(white: 0.90)

    public init(size: CGFloat = 15, color: Color = Color(white: 0.90)) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let lw = max(1.35, w * 0.095)

            // Outer cinema frame
            let frameRect = CGRect(x: w * 0.10, y: h * 0.17, width: w * 0.80, height: h * 0.66)
            let framePath = Path(roundedRect: frameRect, cornerRadius: w * 0.16)
            context.stroke(framePath, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))

            // Side sprocket rails
            var rails = Path()
            let leftRailX = w * 0.27
            let rightRailX = w * 0.73
            rails.move(to: CGPoint(x: leftRailX, y: h * 0.18))
            rails.addLine(to: CGPoint(x: leftRailX, y: h * 0.82))
            rails.move(to: CGPoint(x: rightRailX, y: h * 0.18))
            rails.addLine(to: CGPoint(x: rightRailX, y: h * 0.82))
            // Sprocket ticks
            for yf in [0.39, 0.61] {
                rails.move(to: CGPoint(x: w * 0.11, y: h * yf))
                rails.addLine(to: CGPoint(x: leftRailX, y: h * yf))
                rails.move(to: CGPoint(x: rightRailX, y: h * yf))
                rails.addLine(to: CGPoint(x: w * 0.89, y: h * yf))
            }
            context.stroke(rails, with: .color(color), style: StrokeStyle(lineWidth: max(1.1, lw * 0.82), lineCap: .round))

            // Centered play triangle
            var play = Path()
            play.move(to: CGPoint(x: w * 0.44, y: h * 0.38))
            play.addLine(to: CGPoint(x: w * 0.61, y: h * 0.50))
            play.addLine(to: CGPoint(x: w * 0.44, y: h * 0.62))
            play.closeSubpath()
            context.fill(play, with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

/// Iconic vector mark for Anime Hall (twin-antenna cute retro anime TV with expressive eyes).
public struct UHDAnimeHallVectorIcon: View {
    public var size: CGFloat = 15
    public var color: Color = Color(white: 0.90)

    public init(size: CGFloat = 15, color: Color = Color(white: 0.90)) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let lw = max(1.35, w * 0.095)

            // Twin V-shaped antennas (signature anime TV silhouette)
            var antennas = Path()
            antennas.move(to: CGPoint(x: w * 0.28, y: h * 0.10))
            antennas.addLine(to: CGPoint(x: w * 0.43, y: h * 0.27))
            antennas.move(to: CGPoint(x: w * 0.72, y: h * 0.10))
            antennas.addLine(to: CGPoint(x: w * 0.57, y: h * 0.27))
            context.stroke(antennas, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))

            // Antenna tip bulbs
            let tipR = max(0.85, w * 0.055)
            context.fill(
                Path(ellipseIn: CGRect(x: w * 0.28 - tipR, y: h * 0.10 - tipR, width: tipR * 2, height: tipR * 2)),
                with: .color(color)
            )
            context.fill(
                Path(ellipseIn: CGRect(x: w * 0.72 - tipR, y: h * 0.10 - tipR, width: tipR * 2, height: tipR * 2)),
                with: .color(color)
            )

            // Rounded CRT TV body
            let bodyRect = CGRect(x: w * 0.11, y: h * 0.27, width: w * 0.78, height: h * 0.56)
            let bodyPath = Path(roundedRect: bodyRect, cornerRadius: w * 0.18)
            context.stroke(bodyPath, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))

            // Expressive anime eyes inside screen (tilted playful arcs)
            var eyes = Path()
            eyes.move(to: CGPoint(x: w * 0.30, y: h * 0.53))
            eyes.addQuadCurve(to: CGPoint(x: w * 0.43, y: h * 0.53), control: CGPoint(x: w * 0.365, y: h * 0.43))
            eyes.move(to: CGPoint(x: w * 0.57, y: h * 0.53))
            eyes.addQuadCurve(to: CGPoint(x: w * 0.70, y: h * 0.53), control: CGPoint(x: w * 0.635, y: h * 0.43))
            // Subtle cheerful mouth curve
            eyes.move(to: CGPoint(x: w * 0.45, y: h * 0.65))
            eyes.addQuadCurve(to: CGPoint(x: w * 0.55, y: h * 0.65), control: CGPoint(x: w * 0.50, y: h * 0.71))
            context.stroke(eyes, with: .color(color), style: StrokeStyle(lineWidth: max(1.25, lw * 0.92), lineCap: .round, lineJoin: .round))

            // Two little stub feet
            var feet = Path()
            feet.move(to: CGPoint(x: w * 0.30, y: h * 0.84))
            feet.addLine(to: CGPoint(x: w * 0.27, y: h * 0.91))
            feet.move(to: CGPoint(x: w * 0.70, y: h * 0.84))
            feet.addLine(to: CGPoint(x: w * 0.73, y: h * 0.91))
            context.stroke(feet, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

public struct UHDLibraryModeIcon: View {
    public let mode: UHDLibraryMode
    public var size: CGFloat = 15
    public var color: Color = Color(white: 0.90)

    public init(mode: UHDLibraryMode, size: CGFloat = 15, color: Color = Color(white: 0.90)) {
        self.mode = mode
        self.size = size
        self.color = color
    }

    public var body: some View {
        switch mode {
        case .normal:
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: max(12, size * 0.9), weight: .medium))
                .foregroundStyle(color)
        case .anime:
            UHDAnimeHallVectorIcon(size: size, color: color)
        }
    }
}

/// Iconic vector mark for Account & Traffic (clean geometric membership ID card, distinct from watch party & route icons).
public struct UHDAccountVectorIcon: View {
    public var size: CGFloat = 15
    public var color: Color = Color(white: 0.90)

    public init(size: CGFloat = 15, color: Color = Color(white: 0.90)) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let lw = max(1.3, w * 0.092)

            // Outer rounded membership card
            let cardRect = CGRect(x: w * 0.09, y: h * 0.18, width: w * 0.82, height: h * 0.64)
            let cardPath = Path(roundedRect: cardRect, cornerRadius: w * 0.16)
            context.stroke(cardPath, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))

            // Left portrait head
            let headR = w * 0.088
            let headRect = CGRect(x: w * 0.31 - headR, y: h * 0.41 - headR, width: headR * 2, height: headR * 2)
            context.fill(Path(ellipseIn: headRect), with: .color(color))

            // Left portrait shoulders arc
            var shoulders = Path()
            shoulders.move(to: CGPoint(x: w * 0.19, y: h * 0.66))
            shoulders.addQuadCurve(
                to: CGPoint(x: w * 0.43, y: h * 0.66),
                control: CGPoint(x: w * 0.31, y: h * 0.51)
            )
            context.stroke(shoulders, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))

            // Right subscription & traffic bars
            var bars = Path()
            bars.move(to: CGPoint(x: w * 0.54, y: h * 0.41))
            bars.addLine(to: CGPoint(x: w * 0.78, y: h * 0.41))
            bars.move(to: CGPoint(x: w * 0.54, y: h * 0.60))
            bars.addLine(to: CGPoint(x: w * 0.73, y: h * 0.60))
            context.stroke(bars, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Library Hub Sheet (Iconic Mode Switch + Collection Order)

public struct UHDLibraryHubSheet: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var uhd = UHDModuleManager.shared
    @Environment(\.dismiss) private var dismiss
    public let server: EmbyServerConfig

    @State private var selectedMode: UHDLibraryMode = .normal
    @State private var settings: UHDLibrarySettings? = nil
    @State private var orderedCollections: [UHDLibraryCollectionOption] = []
    @State private var visibleIds: Set<String> = []
    @State private var isLoadingSettings: Bool = false
    @State private var isSaving: Bool = false
    @State private var hasOrderEdits: Bool = false
    @State private var errorMessage: String? = nil

    public init(server: EmbyServerConfig) {
        self.server = server
    }

    private var savedDefaultMode: UHDLibraryMode? {
        settings?.preferences.mode ?? uhd.librarySettingsByServer[server.id]?.preferences.mode
    }

    public var body: some View {
        let isLight = appState.isLightMode
        VStack(alignment: .leading, spacing: 16) {
            headerBar(isLight: isLight)

            modeSwitchSection(isLight: isLight)

            collectionsSection(isLight: isLight)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(DonbyGlassPalette.canvas(isLight: isLight))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DonbyGlassPalette.separator(isLight: isLight), lineWidth: 0.8)
        )
        .task {
            selectedMode = uhd.currentLibraryMode(for: server.id)
            if let cached = uhd.librarySettingsByServer[server.id] {
                settings = cached
                rebuildCollectionDraft(from: cached, mode: selectedMode)
            }
            await loadSettings()
        }
    }

    // MARK: - Header

    private func headerBar(isLight: Bool) -> some View {
        HStack(spacing: 10) {
            Text("馆别")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLight))

            Spacer()

            if let savedDefaultMode {
                if savedDefaultMode == selectedMode {
                    HStack(spacing: 4) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("账号默认：\(savedDefaultMode.displayTitle)")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLight))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(DonbyGlassPalette.cardBackground(isLight: isLight))
                    )
                } else {
                    Button {
                        Task { await persistDefaultMode(selectedMode) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "pin")
                                .font(.system(size: 10, weight: .semibold))
                            Text("设为账户默认")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(appState.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(appState.accentColor.opacity(0.12))
                        )
                        .overlay(
                            Capsule().strokeBorder(appState.accentColor.opacity(0.35), lineWidth: 0.6)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
                }
            }

            ToolbarVectorButton(tooltip: "关闭", action: { dismiss() }) { hovered in
                let col = isLight ? (hovered ? Color.black : Color(white: 0.35)) : (hovered ? .white : Color(white: 0.72))
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(col)
            }
        }
    }

    // MARK: - Iconic Dual Library Mode Cards

    private func modeSwitchSection(isLight: Bool) -> some View {
        HStack(spacing: 10) {
            ForEach(UHDLibraryMode.allCases) { mode in
                let isSelected = (mode == selectedMode)
                let isAccountDefault = (savedDefaultMode == mode)
                ZStack(alignment: .topTrailing) {
                    Button {
                        guard mode != selectedMode else { return }
                        Task { await selectMode(mode) }
                    } label: {
                        HStack(spacing: 12) {
                            UHDLibraryModeIcon(
                                mode: mode,
                                size: 22,
                                color: isSelected ? appState.accentTextColor : appState.accentColor
                            )
                            .frame(width: 40, height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(isSelected ? Color.white.opacity(0.18) : appState.accentColor.opacity(0.12))
                            )

                            Text(mode.displayTitle)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(isSelected ? appState.accentTextColor : DonbyGlassPalette.primaryText(isLight: isLight))

                            Spacer(minLength: 28)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(isSelected ? appState.accentColor : DonbyGlassPalette.cardBackground(isLight: isLight))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(isSelected ? appState.accentColor : DonbyGlassPalette.separator(isLight: isLight), lineWidth: 0.7)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving)

                    // Visual pin affordance to view / set account default hall
                    Button {
                        guard !isAccountDefault else { return }
                        Task { await persistDefaultMode(mode) }
                    } label: {
                        Image(systemName: isAccountDefault ? "pin.fill" : "pin")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(
                                isSelected
                                    ? appState.accentTextColor.opacity(isAccountDefault ? 0.95 : 0.55)
                                    : (isAccountDefault ? appState.accentColor : DonbyGlassPalette.secondaryText(isLight: isLight).opacity(0.55))
                            )
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isAccountDefault ? "账号默认" : "设为默认")
                    .disabled(isSaving || isAccountDefault)
                    .padding(8)
                }
            }
        }
    }

    // MARK: - Collection Visibility & Ordering

    private func collectionsSection(isLight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("集合")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(DonbyGlassPalette.primaryText(isLight: isLight))

                if !orderedCollections.isEmpty {
                    Text("\(visibleIds.count)/\(orderedCollections.count)")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLight))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DonbyGlassPalette.cardBackground(isLight: isLight)))
                }

                Spacer()

                if isLoadingSettings {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    if !orderedCollections.isEmpty {
                        Button {
                            resetToSystemDefaultOrder()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLight))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("恢复默认")
                        .disabled(isSaving)
                    }

                    if hasOrderEdits {
                        Button {
                            Task { await saveCollectionOrder() }
                        } label: {
                            HStack(spacing: 4) {
                                if isSaving {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10.5, weight: .bold))
                                }
                                Text("保存")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(appState.accentTextColor)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4.5)
                            .background(Capsule().fill(appState.accentColor))
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
                    }
                }
            }

            if orderedCollections.isEmpty && !isLoadingSettings {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLight).opacity(0.6))
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(DonbyGlassPalette.cardBackground(isLight: isLight))
                )
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 5) {
                        ForEach(Array(orderedCollections.enumerated()), id: \.element.id) { index, col in
                            collectionRow(col: col, index: index, total: orderedCollections.count, isLight: isLight)
                        }
                    }
                    .padding(7)
                }
                .frame(minHeight: 180, maxHeight: 270)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(DonbyGlassPalette.cardBackground(isLight: isLight))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(DonbyGlassPalette.separator(isLight: isLight), lineWidth: 0.6)
                )
            }
        }
    }

    private func collectionRow(col: UHDLibraryCollectionOption, index: Int, total: Int, isLight: Bool) -> some View {
        let isVisible = visibleIds.contains(col.id)
        return HStack(spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { visibleIds.contains(col.id) },
                    set: { newValue in
                        if newValue {
                            visibleIds.insert(col.id)
                        } else {
                            visibleIds.remove(col.id)
                        }
                        hasOrderEdits = true
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(
                DonbySwitchToggleStyle(
                    isLightMode: isLight,
                    accentColor: appState.accentColor,
                    accentTextColor: appState.accentTextColor
                )
            )

            Image(systemName: col.mediaType == "movie" ? "film" : "tv")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DonbyGlassPalette.secondaryText(isLight: isLight).opacity(isVisible ? 0.85 : 0.45))
                .frame(width: 16)

            Text(col.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    isVisible
                        ? DonbyGlassPalette.primaryText(isLight: isLight)
                        : DonbyGlassPalette.secondaryText(isLight: isLight)
                )
                .lineLimit(1)

            Spacer()

            HStack(spacing: 2) {
                Button {
                    guard index > 0 else { return }
                    orderedCollections.swapAt(index, index - 1)
                    hasOrderEdits = true
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(index > 0 ? DonbyGlassPalette.primaryText(isLight: isLight) : DonbyGlassPalette.secondaryText(isLight: isLight).opacity(0.3))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(index == 0)

                Button {
                    guard index + 1 < total else { return }
                    orderedCollections.swapAt(index, index + 1)
                    hasOrderEdits = true
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(index + 1 < total ? DonbyGlassPalette.primaryText(isLight: isLight) : DonbyGlassPalette.secondaryText(isLight: isLight).opacity(0.3))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(index + 1 >= total)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isVisible ? DonbyGlassPalette.canvas(isLight: isLight).opacity(0.55) : Color.clear)
        )
    }

    // MARK: - Actions & Sync

    private func loadSettings() async {
        isLoadingSettings = true
        errorMessage = nil
        defer { isLoadingSettings = false }
        do {
            let fetched = try await uhd.refreshLibrarySettings(server: server)
            settings = fetched
            rebuildCollectionDraft(from: fetched, mode: selectedMode)
        } catch {
            errorMessage = "加载失败: \(error.localizedDescription)"
        }
    }

    private func rebuildCollectionDraft(from current: UHDLibrarySettings, mode: UHDLibraryMode) {
        let candidates = current.candidateCollections(for: mode)
        let savedIds = current.preferences.collectionIds(for: mode)
        if let savedIds {
            let byId = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
            var ordered: [UHDLibraryCollectionOption] = []
            var seen: Set<String> = []
            for id in savedIds {
                if let col = byId[id], seen.insert(id).inserted {
                    ordered.append(col)
                }
            }
            for col in candidates where !seen.contains(col.id) {
                ordered.append(col)
            }
            orderedCollections = ordered
            visibleIds = Set(savedIds.filter { byId[$0] != nil })
        } else {
            orderedCollections = candidates
            visibleIds = Set(candidates.map(\.id))
        }
        hasOrderEdits = false
    }

    private func resetToSystemDefaultOrder() {
        guard let current = settings else { return }
        let candidates = current.candidateCollections(for: selectedMode)
        orderedCollections = candidates
        visibleIds = Set(candidates.map(\.id))
        hasOrderEdits = true
    }

    private func selectMode(_ mode: UHDLibraryMode) async {
        selectedMode = mode
        if let current = settings {
            rebuildCollectionDraft(from: current, mode: mode)
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await uhd.switchLibraryMode(mode, persistDefault: false, server: server, appState: appState)
            appState.showToast("已切换至\(mode.displayTitle)", icon: "checkmark.circle.fill")
        } catch {
            errorMessage = "切换失败: \(error.localizedDescription)"
        }
    }

    private func persistDefaultMode(_ mode: UHDLibraryMode) async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await uhd.switchLibraryMode(mode, persistDefault: true, server: server, appState: appState)
            selectedMode = mode
            if let updated = uhd.librarySettingsByServer[server.id] {
                settings = updated
                rebuildCollectionDraft(from: updated, mode: mode)
            }
            appState.showToast("已将\(mode.displayTitle)设为默认", icon: "pin.fill")
        } catch {
            errorMessage = "保存失败: \(error.localizedDescription)"
        }
    }

    private func saveCollectionOrder() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let orderedVisible = orderedCollections.map(\.id).filter { visibleIds.contains($0) }
        do {
            let saved = try await uhd.saveLibraryCollections(
                mode: selectedMode,
                collectionIds: orderedVisible,
                server: server,
                appState: appState
            )
            if let existing = settings {
                let updated = UHDLibrarySettings(preferences: saved, collections: existing.collections)
                settings = updated
                selectedMode = saved.mode
                rebuildCollectionDraft(from: updated, mode: saved.mode)
            } else {
                hasOrderEdits = false
            }
            appState.showToast("已保存\(selectedMode.displayTitle)集合", icon: "checkmark.circle.fill")
        } catch {
            errorMessage = "保存失败: \(error.localizedDescription)"
        }
    }
}
#endif
