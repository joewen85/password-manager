import SwiftUI

struct DuoToolbarAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var role: ButtonRole? = nil
    let perform: () -> Void
}

struct DuoActionBarLayout {
    static let maximumVisibleActions = 4

    let visibleActions: [DuoToolbarAction]
    let overflowActions: [DuoToolbarAction]

    init(actions: [DuoToolbarAction]) {
        visibleActions = Array(actions.prefix(Self.maximumVisibleActions))
        overflowActions = Array(actions.dropFirst(Self.maximumVisibleActions))
    }
}
