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

One scheme: `sftp`. Compared case-insensitively.

`ssh` and `scp` are out. They are shell targets rather than things a file browser copies, and the
narrower list cannot surprise anyone.

`http`/`https` are out for a stronger reason: they are the two schemes `ClipboardItem.contentType`
promotes to a `.url` item, and stripping one would turn a Link card into a meaningless path.

`ftp` and `ftps` were in this list and were taken out. The reasoning that admitted them — "file
transfer schemes, and they do not overlap with the web" — was simply wrong. They are ordinary
resource locators that appear on download pages and in documentation, and `contentType` does *not*
promote them, so `ftp://ftp.gnu.org/gnu/emacs/emacs-29.1.tar.gz` arrived as plain text and was
rewritten to `/gnu/emacs/emacs-29.1.tar.gz`. Unrecoverably: the rewrite replaces the pasteboard and
the history keeps only the stripped form.

`sftp://` carries no such traffic. It is what a file browser puts on the clipboard and essentially
nothing else, which is the whole reason it can be rewritten without a preference to turn off.

| Input | Output |
| --- | --- |
| `sftp://10.0.0.5/home/www` | `/home/www` |
| `sftp://user@10.0.0.5:2222/home/www` | `/home/www` |
| `SFTP://Host/Path` | `/Path` |
| `sftp://h/th%C6%B0%20m%E1%BB%A5c` | `/thư mục` |
| `sftp://10.0.0.5/` | `/` |
| `sftp://10.0.0.5` | *unchanged* |
| `ssh://h/a`, `http://h/a` | *unchanged* |
| `ftp://h/a`, `ftps://h/a` | *unchanged* |
| `sftp:h/a` (opaque, relative) | *unchanged* |
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

### The result is an absolute path

A URL without `//` is opaque: `sftp:h/a` has scheme `sftp` and the *relative* path `h/a`. The
scheme-prefix early-out only examines the first line, so such a line reaches the parser whenever it
sits in a block behind a well-formed one — and a relative fragment on the clipboard points
somewhere else entirely from the path that was copied. The parser therefore requires the path to
begin with `/`, which subsumes the older "not empty" check: `sftp://host` alone yields no path and
falls out by the same guard.

Found by `RemotePathPropertyTests` rather than by anyone thinking of it, which is why that file
exists.

The check compares grapheme clusters. A combining mark immediately after the slash forms one
cluster with it, so `%CC%88` decodes to a path whose first *scalar* is `/` while its first
*character* is not, and it is refused. That is the safe direction, and it is pinned by a test:
rewriting the guard as a scalar comparison — which reads like a tidy-up after the CRLF lesson
below — would let it through instead.

### What decoding can produce

Percent-decoding is what makes `%C6%B0` readable, and it will just as happily produce a control
character. `%0A` decodes to a real newline, from a URL that otherwise looks ordinary — and since
the result of a strip is one path per line, a path carrying a line break comes back as two, which
inside a block is indistinguishable from its neighbours. A line whose decoded path holds one is
refused, and takes its block with it.

The forbidden set is **derived from `CharacterSet.newlines`**, not listed by hand, because that is
the set `strip` splits its own input with — the two cannot be allowed to drift. The hand-written
version listed LF, CR and NUL, and so missed VT, FF, NEL, LS and PS, every one of them reachable
from an ordinary-looking `%0B`, `%0C`, `%C2%85`, `%E2%80%A8` or `%E2%80%A9`. NUL is added on its own
account: no POSIX path may contain one, and it would travel into the pasteboard and the store as a
string nothing downstream expects. A tab is in neither set and is left alone — the rule is about
what the output can represent, not about control characters at large.

The check walks unicode scalars rather than characters. Swift treats `\r\n` as a single grapheme
cluster, so a `Character` comparison against `"\n"` or `"\r"` matches neither and CRLF walks
straight through — which is how `%0D%0A` got past the first version of this guard.

A tab breaks neither the contract nor the string, so it is left alone. The rule is about what the
output can represent, not about control characters at large.

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

**Deciding is separated from doing, and the never-store filter runs between them.** A pattern is a
"hands off this content" instruction, and it has to bind the rewrite as much as the write to disk:
rewriting the clipboard of something the user forbade storing is still touching it, and the
original would then be in neither the pasteboard nor the history. So `remotePathRewrite` computes
the replacement with no side effects at all, the filter runs, and only then does
`applyingRemotePath` write. Anything the filter catches reaches neither disk nor pasteboard.

The filter is offered both strings, because either can be the one the pattern was written against.
`10.0.0.5` — a natural way to say "never keep my server paths" — appears only in what was copied.
Percent-decoding runs the other way: `/home/bí mật` appears only in the rewrite, never in the
`%62%C3%AD…` that was on the clipboard.

**The pasteboard write is skipped if the board moved, but the item is still stored stripped.**
`poll` reads the change count and then spends real time in `ClipboardItem.from` and
`PasteboardPayload.capture`. A copy another app makes inside that window would be destroyed by
`clearContents`, and — because the write that follows is claimed — never captured on the next tick
either. Reading is harmless to race with; this write is the one place `poll` became destructive.

Only the write is skipped. Dropping the item, or storing it in its un-stripped form, would both
break the history's own rule — that what it keeps is the stripped path — and the race has nothing
to do with that rule. The user still gets `/home/www` in the history; the other application still
gets to keep the clipboard it just claimed.

The check narrows the window rather than closing it. `NSPasteboard` offers no compare-and-set, so a
copy landing between the check and the `clearContents` is still lost. What remains is microseconds
against the milliseconds of capture the guard was written for, and no API would close it.

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

The prefix check is itself bounded. Its search for the first non-whitespace character runs before
the size bound, so the bound cannot protect it, and an unbounded search walks the whole string:
4MB of leading whitespace measured at **180ms** on the main thread, inside a 100ms poll. A region
of empty spreadsheet cells is exactly that shape. The scheme may therefore sit behind at most 32
characters of whitespace; past that the text is refused, which is the safe direction since nothing
is then written. The same input now measures **0.0021ms**.

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
