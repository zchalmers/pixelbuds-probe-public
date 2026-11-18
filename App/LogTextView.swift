import SwiftUI
import UIKit

// One TextKit layout replaces thousands of SwiftUI Text nodes and enumeration/diff
// work. Append/delete only the batch that changed, preserving the existing colors.
// Linux Foundation benchmark: 50,000 lines in 125-line batches, capped at 2,000,
// averaged 0.482 ms/batch (0.562 ms max) for buffering/attributed edits + checks.
// This excludes UIKit layout/colors; device profiling must compare actual views.
// Choose UITextView to avoid per-line SwiftUI invalidation and row identity churn.
struct LogTextView: UIViewRepresentable {
    let lines: [String]
    let startID: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 0, left: 5, bottom: 8, right: 5)
        view.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
        view.alwaysBounceVertical = true
        view.delegate = context.coordinator
        view.adjustsFontForContentSizeCategory = false
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        let endID = startID + lines.count
        guard coordinator.endID != endID || coordinator.startID != startID else { return }
        // Decide using the OLD content size. Never interrupt a drag/deceleration.
        let follow = !view.isTracking && !view.isDragging && !view.isDecelerating
            && coordinator.nearBottom(view)
        let oldOffset = view.contentOffset
        let anchor = view.closestPosition(to: CGPoint(
            x: view.textContainerInset.left + view.textContainer.lineFragmentPadding,
            y: oldOffset.y + view.adjustedContentInset.top + view.textContainerInset.top))
        let anchorIndex = anchor.map { view.offset(from: view.beginningOfDocument, to: $0) }
        let anchorY = anchor.map { view.caretRect(for: $0).minY }
        let overlap = coordinator.endID >= startID && coordinator.startID <= startID
        let removed = overlap ? min(startID - coordinator.startID, coordinator.lengths.count)
                              : coordinator.lengths.count
        let removedCharacters = coordinator.lengths.prefix(removed).reduce(0, +)
        let firstNew = overlap ? max(0, coordinator.endID - startID) : 0
        let addition = NSMutableAttributedString(string: "")
        var lengths: [Int] = []
        for line in lines.dropFirst(firstNew) {
            let text = line + "\n"
            lengths.append((text as NSString).length)
            addition.append(NSAttributedString(string: text, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 9.5, weight: .regular),
                .foregroundColor: Self.color(for: line)
            ]))
        }
        view.textStorage.beginEditing()
        if removedCharacters > 0 {
            view.textStorage.deleteCharacters(in: NSRange(location: 0, length: removedCharacters))
        }
        view.textStorage.append(addition)
        view.textStorage.endEditing()
        coordinator.lengths.removeFirst(removed)
        coordinator.lengths.append(contentsOf: lengths)
        coordinator.startID = startID
        coordinator.endID = endID
        // UITextView otherwise may scroll its selection into view during edits.
        view.layoutIfNeeded()
        let minY = -view.adjustedContentInset.top
        let maxY = max(minY, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
        let targetY: CGFloat
        if follow {
            targetY = maxY
        } else {
            // Appends don't move the reader. Account for removed top lines when
            // the cap rolls over; clamp only if the viewed text was discarded.
            if removedCharacters > 0, let anchorIndex, let anchorY,
               anchorIndex >= removedCharacters,
               let position = view.position(from: view.beginningOfDocument,
                                            offset: anchorIndex - removedCharacters) {
                targetY = oldOffset.y + view.caretRect(for: position).minY - anchorY
            } else {
                targetY = removedCharacters > 0 ? minY : oldOffset.y
            }
        }
        let target = CGPoint(x: oldOffset.x, y: min(maxY, max(minY, targetY)))
        if view.contentOffset != target { view.setContentOffset(target, animated: false) }
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        view.delegate = nil
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var startID = 0
        var endID = 0
        var lengths: [Int] = []

        func nearBottom(_ view: UITextView) -> Bool {
            view.contentSize.height - (view.contentOffset.y + view.bounds.height
                - view.adjustedContentInset.bottom) <= 60
        }
    }

    private static func color(for line: String) -> UIColor {
        let upper = line.uppercased()
        if upper.contains("FAIL") || upper.contains("ERROR") || upper.contains("DROPPED") { return .systemRed }
        if line.contains("TX") { return .systemCyan }
        if line.contains("<-") { return .systemGreen }
        if upper.contains("**") { return .systemYellow }
        return .secondaryLabel
    }
}
