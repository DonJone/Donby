import SwiftUI
import AppKit
import DonbyCore
import DonbyNetwork
import DonbyKernelC
import DonbyMetalRenderer

public struct NativePlayerSurface: View {
    public let playerHandle: OpaquePointer?

    public init(playerHandle: OpaquePointer?) {
        self.playerHandle = playerHandle
    }

    public var body: some View {
        DKMetalVideoView(playerHandle: playerHandle)
            .ignoresSafeArea()
    }
}
