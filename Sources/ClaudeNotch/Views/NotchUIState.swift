import Combine
import Foundation

/// Shared expansion/selection state, so the SwiftUI content and the AppKit
/// window controller stay in sync without callback chains.
final class NotchUIState: ObservableObject {
    @Published var isHovering = false
    /// Set when the user clicks into the panel, keeping it open while they read.
    @Published var isPinned = false
    @Published var selectedSessionId: String?
    @Published var showingAlwaysAllowRules = false

    var isExpanded: Bool { isHovering || isPinned }

    func close() {
        isPinned = false
        isHovering = false
        selectedSessionId = nil
        showingAlwaysAllowRules = false
    }
}
