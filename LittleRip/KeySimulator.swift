import Foundation
import SwiftUI
import CoreGraphics

// MARK: - Key Simulator

class KeySimulator {
    private static let keyCodeMap: [String: UInt16] = [
        "up": 126, "forward": 126,
        "down": 125, "backward": 125, "back": 125,
        "left": 123,
        "right": 124
    ]

    static func press(direction: String, duration: TimeInterval) async {
        guard let code = keyCodeMap[direction.lowercased()] else { return }

        let downEvent = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)

        downEvent?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        upEvent?.post(tap: .cghidEventTap)
    }

    static func keyCode(for direction: String) -> UInt16? {
        keyCodeMap[direction.lowercased()]
    }
}