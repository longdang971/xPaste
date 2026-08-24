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
    /// nil returns to the editor's own face, the system font.
    case family(String?)
    case weight(NSFont.Weight)
    case size(CGFloat)
    /// nil returns to `labelColor`.
    case foreground(NSColor?)
    /// nil removes the highlight.
    case background(NSColor?)
    /// nil removes the link.
    case link(URL?)
    case clearFormatting

    /// The colour a highlight pins default-coloured text to.
    ///
    /// `labelColor` is white in dark mode and every highlight in the palette is a light wash, so
    /// text left dynamic would vanish into its own highlight. Pinning it to the colour it shows in
    /// light mode is what keeps a highlight readable in both.
    static let pinnedBlack = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

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
        case .family, .weight, .size, .foreground, .background, .link, .clearFormatting:
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
        case .family, .weight, .size, .foreground, .background, .link, .clearFormatting:
            return false
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
        case .family(let name):
            let traits = manager.traits(of: current)
            if let name {
                out[.font] = manager.font(withFamily: name,
                                          traits: traits,
                                          weight: manager.weight(of: current),
                                          size: current.pointSize) ?? current
            } else {
                out[.font] = manager.convert(NSFont.systemFont(ofSize: current.pointSize),
                                             toHaveTrait: traits)
            }
        case .weight(let weight):
            if RichTextHTML.isSystemFace(current) {
                // The system family cannot be looked up by name — `.AppleSystemUIFont` is private —
                // so it takes the one API that does understand it, and italic is put back by hand.
                var face = NSFont.systemFont(ofSize: current.pointSize, weight: weight)
                if manager.traits(of: current).contains(.italicFontMask) {
                    face = manager.convert(face, toHaveTrait: .italicFontMask)
                }
                out[.font] = face
            } else if let family = current.familyName {
                out[.font] = manager.font(withFamily: family,
                                          traits: manager.traits(of: current)
                                              .subtracting(.boldFontMask),
                                          weight: RichTextCommand.managerWeight(for: weight),
                                          size: current.pointSize) ?? current
            } else {
                // No family to look the weight up under (a face with a nil familyName, which is not
                // reachable through this file's own commands but is not guaranteed by NSFont either):
                // fall back to leaving the face untouched, the same way every other unresolvable case
                // in this switch does, rather than silently dropping the command.
                out[.font] = current
            }
        case .size(let points):
            out[.font] = manager.convert(current, toSize: points)
        case .foreground(let colour):
            out[.foregroundColor] = colour ?? NSColor.labelColor
        case .background(let colour):
            if let colour {
                out[.backgroundColor] = colour
                if (attrs[.foregroundColor] as? NSColor ?? .labelColor) == .labelColor {
                    out[.foregroundColor] = RichTextCommand.pinnedBlack
                }
            } else {
                out.removeValue(forKey: .backgroundColor)
                if (attrs[.foregroundColor] as? NSColor) == RichTextCommand.pinnedBlack {
                    out[.foregroundColor] = NSColor.labelColor
                }
            }
        case .link(let url):
            if let url {
                out[.link] = url
                out[.underlineStyle] = NSUnderlineStyle.single.rawValue
                out[.foregroundColor] = NSColor.linkColor
            } else {
                out.removeValue(forKey: .link)
                out[.underlineStyle] = 0
                out[.foregroundColor] = NSColor.labelColor
            }
        case .clearFormatting:
            out = ItemEdit.plainDefaults
        }
        return out
    }

    /// `NSFontManager`'s 0–15 scale, for the four weights the toolbar offers.
    private static func managerWeight(for weight: NSFont.Weight) -> Int {
        switch weight {
        case .light:    return 3
        case .semibold: return 8
        case .bold:     return 9
        default:        return 5
        }
    }
}

/// The face under a selection, as `RichTextState.family` reports it.
///
/// A plain `String?` used to stand in for this and could not tell two very different situations
/// apart: the face is the system one (unnameable — `.AppleSystemUIFont` is private) versus the
/// selection mixing two or more named families. Both collapsed to `nil`, and the toolbar read that
/// `nil` as "System" — so a selection spanning Helvetica and Times, neither of them the system face,
/// was reported as the system face. Giving the two cases their own enum cases makes that conflation
/// impossible to reintroduce.
enum RichTextFamily: Equatable {
    /// The editor's own face. Has no name to show — `.AppleSystemUIFont` is private API.
    case system
    /// Every run in the selection shares this one named family.
    case named(String)
    /// The selection spans two or more different faces (named, system, or both).
    case mixed
}

/// The formatting under the selection, as the toolbar needs to show it.
///
/// A trait reads as on only when it is on throughout, so a lit button always matches what pressing
/// it again would do. `RichTextFamily.mixed` and a `nil` size mean the same thing for their
/// respective properties — the selection mixes them — and the menu shows no tick rather than picking
/// a winner.
struct RichTextState: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    /// `.mixed` when the selection spans more than one face; never conflated with `.system`.
    var family: RichTextFamily = .system
    /// nil when the selection mixes sizes.
    var size: CGFloat?
    var link: URL?

    static func read(from storage: NSTextStorage,
                     range: NSRange,
                     typing: [NSAttributedString.Key: Any]) -> RichTextState {
        var runs: [[NSAttributedString.Key: Any]] = []
        if range.length > 0 {
            storage.enumerateAttributes(in: range, options: []) { attrs, _, _ in runs.append(attrs) }
        } else if storage.length > 0 {
            // At a caret the storage still has the last word: the run it sits in is what the eye
            // reads as "here". Typing attributes only win when they have actually been armed, which
            // is what `typing` carries in.
            let index = min(max(range.location, 0), storage.length - 1)
            runs.append(storage.attributes(at: index, effectiveRange: nil))
        }
        if runs.isEmpty { runs = [typing] }

        func everywhere(_ test: ([NSAttributedString.Key: Any]) -> Bool) -> Bool {
            runs.allSatisfy(test)
        }
        func traits(_ attrs: [NSAttributedString.Key: Any]) -> NSFontTraitMask {
            (attrs[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
        }
        func single<T: Equatable>(_ value: ([NSAttributedString.Key: Any]) -> T?) -> T? {
            let all = runs.map(value)
            guard let first = all.first, all.allSatisfy({ $0 == first }) else { return nil }
            return first
        }
        func family(_ attrs: [NSAttributedString.Key: Any]) -> RichTextFamily {
            guard let font = attrs[.font] as? NSFont, !RichTextHTML.isSystemFace(font) else {
                return .system
            }
            return .named(font.familyName ?? "")
        }

        let typingTraits = (typing[.font] as? NSFont)
            .map { NSFontManager.shared.traits(of: $0) } ?? []
        let armed = range.length == 0

        return RichTextState(
            bold: armed ? typingTraits.contains(.boldFontMask)
                        : everywhere { traits($0).contains(.boldFontMask) },
            italic: armed ? typingTraits.contains(.italicFontMask)
                          : everywhere { traits($0).contains(.italicFontMask) },
            underline: armed ? (typing[.underlineStyle] as? Int ?? 0) != 0
                             : everywhere { ($0[.underlineStyle] as? Int ?? 0) != 0 },
            strikethrough: armed ? (typing[.strikethroughStyle] as? Int ?? 0) != 0
                                 : everywhere { ($0[.strikethroughStyle] as? Int ?? 0) != 0 },
            // Armed, the caret's own run in `runs` is still the storage run it sits in (see the
            // comment above), so it has to be bypassed the same way the traits bypass `everywhere`
            // above — otherwise a just-armed size or family would keep reporting the old one.
            // `single` answers nil when the runs disagree, which is exactly what `.mixed` means.
            family: armed ? family(typing) : (single { family($0) as RichTextFamily? } ?? .mixed),
            size: armed ? (typing[.font] as? NSFont)?.pointSize
                        : single { ($0[.font] as? NSFont)?.pointSize },
            // `link` deliberately keeps reading from the storage run even when armed: NSTextView
            // never carries `.link` in typingAttributes (so typing after a link does not extend it),
            // so `typing` can never answer this. Reading the storage run is also what lets the link
            // button pre-fill from the caret's surrounding link, which is the whole point of this.
            link: single { $0[.link] as? URL ?? ($0[.link] as? String).flatMap(URL.init(string:)) }
        )
    }
}
