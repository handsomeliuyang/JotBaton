import Foundation

/// NSTextInputClient uses UTF-16 ranges, including for Chinese composition and
/// emoji. These edits stay outside annotation history until the label is saved.
package struct AnnotationTextInputBuffer {
    private(set) var string = ""
    private(set) var selection = NSRange(location: 0, length: 0)
    private(set) var marked = NSRange(location: NSNotFound, length: 0)
    package var hasMarkedText: Bool { marked.location != NSNotFound && marked.length > 0 }
    package var length: Int { (string as NSString).length }

    package func clamped(_ range: NSRange) -> NSRange {
        guard range.location != NSNotFound else { return NSRange(location: length, length: 0) }
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    private func replacement(_ range: NSRange) -> NSRange {
        range.location == NSNotFound ? (hasMarkedText ? marked : selection) : clamped(range)
    }

    package mutating func insert(_ text: String, replacing range: NSRange) {
        let target = replacement(range)
        string = (string as NSString).replacingCharacters(in: target, with: text)
        selection = NSRange(location: target.location + (text as NSString).length, length: 0)
        unmark()
    }

    package mutating func setMarked(_ text: String, selectedRange: NSRange, replacing range: NSRange) {
        let target = replacement(range)
        let count = (text as NSString).length
        string = (string as NSString).replacingCharacters(in: target, with: text)
        marked = count > 0 ? NSRange(location: target.location, length: count)
            : NSRange(location: NSNotFound, length: 0)
        let offset = selectedRange.location == NSNotFound ? count : min(selectedRange.location, count)
        selection = NSRange(location: target.location + offset,
                            length: min(selectedRange.length, count - offset))
    }

    package mutating func unmark() { marked = NSRange(location: NSNotFound, length: 0) }

    package mutating func deleteBackward() {
        let target: NSRange
        if selection.length > 0 { target = selection }
        else if selection.location > 0 {
            target = (string as NSString).rangeOfComposedCharacterSequence(at: selection.location - 1)
        } else { return }
        insert("", replacing: target)
    }

    package mutating func deleteForward() {
        guard selection.length > 0 || selection.location < length else { return }
        let target = selection.length > 0 ? selection
            : (string as NSString).rangeOfComposedCharacterSequence(at: selection.location)
        insert("", replacing: target)
    }

    package mutating func move(_ direction: Int) {
        let location: Int
        if direction < 0 {
            location = selection.length > 0 ? selection.location : (selection.location > 0
                ? (string as NSString).rangeOfComposedCharacterSequence(at: selection.location - 1).location : 0)
        } else {
            location = selection.length > 0 ? NSMaxRange(selection) : (selection.location < length
                ? NSMaxRange((string as NSString).rangeOfComposedCharacterSequence(at: selection.location)) : length)
        }
        select(NSRange(location: location, length: 0))
    }

    package mutating func select(_ range: NSRange) { selection = clamped(range) }
}
