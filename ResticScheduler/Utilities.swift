import AppKit
import Foundation
import SwiftUI

extension String {
    func droppingPrefix(_ prefix: String) -> String {
        if !hasPrefix(prefix) {
            return self
        }

        return String(dropFirst(prefix.count))
    }

    func inserting<C>(contentsOf newElements: C, at i: Index) -> String where C: Collection, Character == C.Element {
        var string = String(stringLiteral: self)
        string.insert(contentsOf: newElements, at: i)
        return string
    }
}

protocol _Optional {
    static var wrappedType: Any.Type { get }

    var isNil: Bool { get }
}

extension Optional: _Optional {
    static var wrappedType: Any.Type { Wrapped.self }

    var isNil: Bool { self == nil }
}

func isNil(_ value: some Any) -> Bool {
    (value as? _Optional)?.isNil == true
}

extension Binding {
    static func optional(_ binding: Binding<Value?>, didSet action: @escaping (() -> Void) = {}) -> Binding<Value> where Value == String {
        Binding {
            binding.wrappedValue ?? ""
        } set: { newValue in
            binding.wrappedValue = !newValue.isEmpty ? newValue : nil
            action()
        }
    }
}

extension NSAlert {
    enum MessageText: CustomStringConvertible {
        case logNotFound(logURL: URL)
        case backupFailure(repository: String)

        var description: String {
            switch self {
            case let .logNotFound(logURL): "The log “\(logURL.path(percentEncoded: false))” could not be opened. The file doesn’t exist."
            case let .backupFailure(repository): "Restic Scheduler couldn’t complete the backup to “\(formatRepository(repository))”"
            }
        }
    }

    static func showError(_ messageText: MessageText, informativeText: String = "") {
        let alert = NSAlert()
        alert.messageText = messageText.description
        if !informativeText.isEmpty {
            switch messageText {
            case .backupFailure:
                alert.accessoryView = scrollableTextView(for: informativeText)
            default:
                alert.informativeText = informativeText
            }
        }
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func scrollableTextView(for text: String) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: scrollView.bounds)
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        return scrollView
    }
}
