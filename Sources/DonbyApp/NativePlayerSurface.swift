import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork
import DonbyKernelC
import DonbyMetalRenderer

public struct NativePlayerSurface: View {
    public let playerHandle: OpaquePointer?
    public let controlsOcclusionHeight: CGFloat
    public let subtitleHDRPeakNits: Float
    public let antiOcclusionEnabled: Bool

    public init(
        playerHandle: OpaquePointer?,
        controlsOcclusionHeight: CGFloat = 0,
        subtitleHDRPeakNits: Float = 203.0,
        antiOcclusionEnabled: Bool = true
    ) {
        self.playerHandle = playerHandle
        self.controlsOcclusionHeight = controlsOcclusionHeight
        self.subtitleHDRPeakNits = subtitleHDRPeakNits
        self.antiOcclusionEnabled = antiOcclusionEnabled
    }

    public var body: some View {
        DKMetalVideoView(
            playerHandle: playerHandle,
            controlsOcclusionHeight: controlsOcclusionHeight,
            subtitleHDRPeakNits: subtitleHDRPeakNits,
            antiOcclusionEnabled: antiOcclusionEnabled
        )
        .ignoresSafeArea()
    }
}
