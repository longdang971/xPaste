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

**Stripping precedes the exclusion filter.** The filter decides what may reach disk, and it should
judge what will actually be stored. Running it second also means the host is already gone before
anything is written, which is the safer order and not the riskier one.

## What is deliberately left alone

An app on the `ignoredAppBundleIDs` list still gets no attention at all. `poll()` returns before
any of this, and that stays true: asking xPaste to keep out of an app means out, not out except
for rewriting its clipboard.

The `Paste as…` menu gains no entry. Since the history stores the stripped text, there is no
longer a host in any stored item for such a command to remove.

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
cases and the "nothing changed" returns.

`xPasteTests/ClipboardMonitorTests.swift` gains cases for the integration: that a rewrite is
claimed (no duplicate item), and that the resulting item's payload carries the stripped text rather
than the original. The file already builds a scratch `NSPasteboard` and injects it through
`ClipboardMonitor(pasteboard:)`, so none of this touches the real clipboard.
