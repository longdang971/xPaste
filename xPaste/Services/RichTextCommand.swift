import AppKit

/// One formatting change, applied to a text storage.
///
/// Apart from the toolbar so that every command is exercised without a window: the arguments are a
/// storage, a range and the caret's typing attributes, all of which a test builds directly.
enum RichTextCommand {
    case bold
    case italic
    case underline
    case strikethrough
    case clearFormatting

    /// Applies to `storage` over `range`, and answers with the typing attributes the caret should
    /// adopt.
    ///
    /// With an empty `range` nothing in the storage changes and only the answer matters. That is
    /// what makes pressing B and then typing produce bold text, the way TextEdit behaves — and
    /// leaving it out is the one thing that would make the whole toolbar feel broken.
    @discardableResult
    func apply(to storage: NSTextStorage,
               range: NSRange,
               typing: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        let turnOn = shouldTurnOn(in: storage, range: range, typing: typing)
        if range.length > 0 {
            storage.beginEditing()
            storage.enumerateAttributes(in: range, options: []) { attrs, runRange, _ in
                storage.setAttributes(transform(attrs, turnOn: turnOn), range: runRange)
            }
            storage.endEditing()
        }
        return transform(typing, turnOn: turnOn)
    }

    // MARK: - Which way a toggle goes

    /// A toggle turns off only when it is already on everywhere. A mixed selection therefore turns
    /// fully on, which is what every other editor does and what the eye expects.
    private func shouldTurnOn(in storage: NSTextStorage,
                              range: NSRange,
                              typing: [NSAttributedString.Key: Any]) -> Bool {
        switch self {
        case .bold, .italic, .underline, .strikethrough:
            return !isOnEverywhere(in: storage, range: range, typing: typing)
        case .clearFormatting:
            return true
        }
    }

    private func isOnEverywhere(in storage: NSTextStorage,
                                range: NSRange,
                                typing: [NSAttributedString.Key: Any]) -> Bool {
        guard range.length > 0 else { return isOn(typing) }
        var everywhere = true
        storage.enumerateAttributes(in: range, options: []) { attrs, _, stop in
            if !isOn(attrs) {
                everywhere = false
                stop.pointee = true
            }
        }
        return everywhere
    }

    private func isOn(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
        let traits = (attrs[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
        switch self {
        case .bold:            return traits.contains(.boldFontMask)
        case .italic:          return traits.contains(.italicFontMask)
        case .underline:       return (attrs[.underlineStyle] as? Int ?? 0) != 0
        case .strikethrough:   return (attrs[.strikethroughStyle] as? Int ?? 0) != 0
        case .clearFormatting: return false
        }
    }

    // MARK: - The change itself

    private func transform(_ attrs: [NSAttributedString.Key: Any],
                           turnOn: Bool) -> [NSAttributedString.Key: Any] {
        var out = attrs
        let manager = NSFontManager.shared
        let current = (attrs[.font] as? NSFont) ?? ItemEdit.plainFont
        switch self {
        case .bold:
            // Through NSFontManager rather than a symbolic trait, so a family with no real bold
            // face is given its nearest one instead of a synthesised smear.
            out[.font] = turnOn ? manager.convert(current, toHaveTrait: .boldFontMask)
                                : manager.convert(current, toNotHaveTrait: .boldFontMask)
        case .italic:
            out[.font] = turnOn ? manager.convert(current, toHaveTrait: .italicFontMask)
                                : manager.convert(current, toNotHaveTrait: .italicFontMask)
        case .underline:
            out[.underlineStyle] = turnOn ? NSUnderlineStyle.single.rawValue : 0
        case .strikethrough:
            out[.strikethroughStyle] = turnOn ? NSUnderlineStyle.single.rawValue : 0
        case .clearFormatting:
            out = ItemEdit.plainDefaults
        }
        return out
    }
}
