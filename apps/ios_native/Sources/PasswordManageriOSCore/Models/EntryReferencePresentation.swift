import Foundation

struct EntryReferencePresentation: Equatable, Sendable {
    let text: String
    let actionTitle: String
    let isError: Bool
    let canOpenTarget: Bool
}

func entryReferencePresentation(
    _ resolution: EntryReferenceResolution?
) -> EntryReferencePresentation {
    switch resolution?.status {
    case .empty, nil:
        EntryReferencePresentation(
            text: "No entry selected.",
            actionTitle: "Select",
            isError: false,
            canOpenTarget: false
        )
    case .resolved:
        EntryReferencePresentation(
            text: resolution?.target.map {
                [$0.label.isEmpty ? "Untitled" : $0.label, $0.category.isEmpty ? "Uncategorized" : $0.category]
                    .joined(separator: " - ")
            } ?? "Referenced entry is missing.",
            actionTitle: "Replace",
            isError: resolution?.target == nil,
            canOpenTarget: resolution?.target != nil
        )
    case .missing:
        EntryReferencePresentation(
            text: "Referenced entry is missing.",
            actionTitle: "Repair",
            isError: true,
            canOpenTarget: false
        )
    case .deleted:
        EntryReferencePresentation(
            text: "Referenced entry was deleted.",
            actionTitle: "Repair",
            isError: true,
            canOpenTarget: false
        )
    case .categoryMismatch:
        EntryReferencePresentation(
            text: "Referenced entry is outside the target category.",
            actionTitle: "Repair",
            isError: true,
            canOpenTarget: false
        )
    }
}
