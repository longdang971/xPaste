# Stripping the host off a remote path — design

**Date:** 2026-09-06

An SFTP client's "copy path" command puts `sftp://10.0.0.5/home/pikalong/www` on the clipboard.
What the path is wanted for — a terminal, a config file, a `cd` — never wants the `sftp://host`
in front of it, so it gets deleted by hand every time. xPaste rewrites the clipboard to
`/home/pikalong/www` as the copy is captured.

This runs always, for everyone. There is no preference and no per-app list: a string whose whole
content is an `sftp://` URL is a server path in every case worth naming, so a switch would only be
a switch nobody turns off.

## What counts as a remote path

Three schemes: `sftp`, `ftp`, `ftps`. Compared case-insensitively.

`ssh` and `scp` are deliberately out. They are shell targets rather than things a file browser
copies, and the narrower list cannot surprise anyone.

`http`/`https` are out for a stronger reason: they are the two schemes `ClipboardItem.contentType`
promotes to a `.url` item, and stripping one would turn a Link card into a meaningless path.

| Input | Output |
| --- | --- |
| `sftp://10.0.0.5/home/www` | `/home/www` |
| `sftp://user@10.0.0.5:2222/home/www` | `/home/www` |
| `SFTP://Host/Path` | `/Path` |
| `ftp://h/a`, `ftps://h/a` | `/a` |
| `sftp://h/th%C6%B0%20m%E1%BB%A5c` | `/thư mục` |
| `sftp://10.0.0.5/` | `/` |
| `sftp://10.0.0.5` | *unchanged* |
| `ssh://h/a`, `http://h/a` | *unchanged* |
| `Xem sftp://h/a nhé` | *unchanged* |
| `/home/www` | *unchanged* |

The user and port go with the host because they are part of the authority, not the path — and
`user@` in particular is a credential nobody means to paste into a shared config.

Percent-encoding is decoded, so a Vietnamese folder name comes back readable rather than as
`%C6%B0`. This is what the path *is*; the encoding belonged to the URL that no longer exists.

`sftp://host` alone yields no path, so there is nothing to rewrite to and the clipboard is left
as it was. `sftp://host/` yields `/` — the server's root, which is a real answer.

### Only a bare URL

The text must be a remote URL and nothing else, after trimming surrounding whitespace. A sentence
that merely mentions one is prose, and rewriting prose into a fragment of itself would be
destroying what was copied.

This is enforced by rejecting any line with whitespace in it, and that enforcement is the whole of
the rule. `URL(string:)` **accepts** unescaped spaces — measured, not assumed — so
`sftp://10.0.0.5/home/www is the folder` parses as a single URL whose path is
`/home/www is the folder`. Leaving the parser to refuse it, as the first draft did, meant a
sentence beginning with a server path was silently replaced by a fragment of itself.

It costs the path a client copied with a literal space in it. That is the right side of the trade:
a client encodes such a space as `%20`, and the cost of being wrong the other way is a clipboard
replaced with something that was never on it.

### Filenames that look like URL syntax

`#` and `?` are legal POSIX filename characters. A client copying `report#2.txt` unencoded hands
over a URL whose "fragment" is really the back half of the name, and taking `url.path` alone
truncates it to `/home/report` — unrecoverably, since the pasteboard is then replaced. The query
and fragment are appended back in the order a URL writes them. A properly encoded name (`%23`) has
neither component, so this does nothing to it.

### Several at once

Selecting three folders and copying gives one URL per line. When *every* non-empty line is a
strippable remote URL, each is stripped and the block is rewritten. One line that is not disowns
the whole block — a partial rewrite would leave a list where some entries had lost their host and
others had not, which is worse than either outcome.

## Where it happens

`ClipboardMonitor.poll()`, immediately after `ClipboardItem.from(pasteboard:)` has built a text
item and before the `excludedPatterns` filter runs.

The monitor rather than `ClipboardItem.from`, because the rewrite has to reach the system
pasteboard as well as the stored item, and the monitor is the only place that owns the pasteboard
handshake.

```swift
if item.type == .text, let text = item.text, let stripped = RemotePath.strip(text) {
    writeOwned { board in
        board.clearContents()
        board.setString(stripped, forType: .string)
    }
    item = ClipboardItem(type: .text, text: stripped)
    item.payload = PasteboardPayload.plainText(stripped)
}
```

Three things about those six lines, each of which is a bug if written the other way:

**`writeOwned`, not a bare `setString`.** An unclaimed write is a pasteboard change like any
other, and the next poll captures it as a second item — the history grows a duplicate for every
path copied. `writeOwned` writes first and claims after, which is the order its own comment exists
to defend.

**The payload is replaced, not kept.** Pasting from the panel reads the payload, not `item.text`.
Left alone, the payload still holds every representation the SFTP client offered, so the card
would read `/home/www` and paste `sftp://10.0.0.5/home/www`. `clearContents()` on the system
pasteboard is the same fix on the other side: it drops the alternative representations rather than
leaving a plain-text string sitting on top of them.

**Stripping precedes the exclusion filter, which then judges both texts.** Running the rewrite
first means the host is gone before anything can be written. But a never-store pattern is authored
against what the user watches themselves copy — `10.0.0.5` is a natural way to say "never keep my
server paths" — and after the rewrite the item no longer contains it. Matching only the stored text
would write to disk exactly what an explicit rule forbade. `exclusionCandidates` therefore offers
both the stored text and the captured one. The reverse direction is real too, if rarer:
percent-decoding puts `/home/bí mật` in the stored item when only `%62%C3%AD…` was ever copied.

**The rewrite is skipped if the pasteboard moved.** `poll` reads the change count and then spends
real time in `ClipboardItem.from` and `PasteboardPayload.capture`. A copy another app makes inside
that window would be destroyed by `clearContents`, and — because the write that follows is claimed
— never captured on the next tick either. Reading is harmless to race with; this rewrite is the one
place `poll` became destructive, so it checks that the board still holds what was captured.

## What is deliberately left alone

An app on the `ignoredAppBundleIDs` list still gets no attention at all. `poll()` returns before
any of this, and that stays true: asking xPaste to keep out of an app means out, not out except
for rewriting its clipboard.

The `Paste as…` menu gains no entry. Since the history stores the stripped text, there is no
longer a host in any stored item for such a command to remove.

## Cost of deciding "no"

`strip` runs on the main thread from the poll, for every text copy anyone makes, and the common
case is text that is not a path. Trimming and splitting the whole string into lines before looking
at the scheme measured **60ms to reject a 4MB paste** (Debug) — a visible hitch, on a verdict the
first seven characters had already settled.

Two guards run before anything is allocated: an exact scheme-prefix check (line one has to be a
remote URL for any of the block to qualify, so the first non-whitespace characters have to be one
of the schemes), and a 256KB bound so that even a string which does start with a scheme cannot cost
unboundedly much. The same 4MB paste now measures **0.0007ms**.

The bound is 256KB because that is what the other side of it costs: a block of nothing but URLs
right up against the limit is 5576 of them, and parsing them line by line measures **22ms** (Debug)
— a one-off, on the deliberate act of copying five thousand paths. `RemotePathPerformanceTests` holds
the assertion, relative rather than absolute in the manner of `HighlightBakePerformanceTests`.

## Latency

The rewrite lands within one poll interval — 100ms by default (`ClipboardMonitor.defaultInterval`).
A paste issued inside that window gets the unstripped text. Closing the window entirely would need
a hotkey or a `CGEventTap`, both of which were considered and rejected: the point of the feature is
that it costs no keystroke.

## Components

**`xPaste/Services/RemotePath.swift`** — `strip(_:) -> String?` and the scheme set. Pure
string-to-string, no AppKit, so the whole rule table is testable without a pasteboard or a running
app. Returns nil for "nothing to do", matching the convention `TextTransform.apply` already
established.

**`xPaste/Services/ClipboardMonitor.swift`** — the six lines above.

## Testing

`xPasteTests/RemotePathTests.swift` covers the rule table exactly as written, plus the multi-line
cases, the "nothing changed" returns, the size bound, prose beginning with a URL, and filenames
carrying `#` or `?`.

`xPasteTests/RemotePathPerformanceTests.swift` holds the cost of deciding "no" to a large paste.

`xPasteTests/ClipboardMonitorTests.swift` gains cases for the integration: that a rewrite is
claimed (no duplicate item), that the resulting item's payload carries the stripped text rather
than the original, that a copy landing mid-capture is left alone, and that a never-store pattern
naming the server still matches. The file already builds a scratch `NSPasteboard` and injects it through
`ClipboardMonitor(pasteboard:)`, so none of this touches the real clipboard.
