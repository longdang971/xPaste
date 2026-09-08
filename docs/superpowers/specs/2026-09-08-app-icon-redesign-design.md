# App icon redesign

## Why

The old icon was a teal-to-blue rounded square carrying a white **x** with a small pill above it. Three things were wrong with it:

- At 16 and 32 pixels the pill disappeared and the centred **x** read as a close or delete button — the opposite of what an app that keeps a history of what you copied should say.
- Teal-to-blue on a diagonal is the most common gradient on the App Store, and both ends sat at a similar saturation, so it looked flat rather than deep.
- The shadow was baked into the artwork at a strength no macOS icon uses, and the corner radius did not sit on Apple's grid.

## What it is now

A clipboard board with a card tipped out of it, the card carrying the xPaste **x**. The board says *clipboard*, the card sliding out says *paste*, and the **x** is the mark. This came out of comparing four ways to make a stack of cards read as a clipboard; a plain stack read as "layers" or "photos" and said nothing about the pasteboard.

## Colour

Amber, sampled from the Paste icon at the user's request, so the two apps read as the same category. Values were measured off a screenshot rather than guessed:

| Position | Value |
| --- | --- |
| Top of the field | `#FFC47B` |
| 50% down | `#F8B04F` |
| 66% down and below | `#F5A946` |

Two measured facts drive the rendering:

1. **The gradient stops changing two thirds of the way down** and stays flat to the bottom edge. Running it linearly to the bottom makes the lower half too heavy.
2. **No pixel in the reference is darker than `#F4A946`.** The icon lives in a narrow band of amber and white does all the contrast work. An earlier attempt kept a dark board (`#E1912F`) and a dark clip (`#B9690C`) — both darker than anything in the reference — and that, not the background hex, was what broke the family resemblance.

So the board is warm white `#FFF4E3`, the card is `#FFFFFF`, and the clip and the **x** are the amber itself.

The outer shadow matches the reference too: measured against the wallpaper behind it, the ground darkens about 3% beside and above the icon and about 12% directly beneath. Anything heavier reads as a halo.

## Sizes

`Tools/GenerateAppIcon.swift` draws every PNG the asset catalog asks for. Artwork is authored in a 200×200 space that maps onto the rounded square; the square is then inset on Apple's macOS grid — 824 of 1024, 100 in from each side, 90 from the top, 110 from the bottom.

Three detail levels, because the full drawing does not survive being shrunk:

| Level | Sizes | What changes |
| --- | --- | --- |
| `full` | 64+ | Everything as authored |
| `reduced` | 32 | No notch inside the clip, deeper board, thicker **x** |
| `minimal` | 16 | No clip, no shadows, larger board and card, **x** at double weight |

At 16 the rounded square is about 13 pixels across, which leaves the clip under two pixels wide and the **x** roughly one pixel thick. The minimal layout trades those details for a silhouette that still resolves.

## Menu bar icon

`Tools/GenerateMenuBarIcon.swift` draws the 18 and 36 pixel status-bar glyph: the same two cards, without the rounded square around them.

It is a template image, so only alpha survives — macOS paints it black or white to suit the menu bar. That rules out telling the two cards apart by colour, so the front card is separated from the board by a cleared ring, and the **x** is knocked out of the card rather than drawn on it. That is the same relationship the full-colour icon has, where the **x** is the amber field showing through white.

The proportions are not the app icon's. Dropping the outer square costs the **x** about half its width, because it now has to fit inside the front card instead of the whole frame, and at 18 points the **x** is the only part anyone reads. So the front card grows to fill nearly the whole square and the board is reduced to a sliver behind it — enough to say "there are more of these", not enough to compete.

Two variants were tried and dropped:

- **outline** — both cards as strokes. At 18 points the **x** collides with the card's own outline and the whole thing turns to noise.
- **clipped** — the solid layout plus the clipboard's clip. The clip is under two pixels wide there and reads as a lump on the board's shoulder, not as a clip.

## Notes for later

macOS 26 wants layered `.icon` bundles authored in Icon Composer, which get the system's own shape, shadow and dark/clear/tinted variants. This redesign stays on `appiconset` PNGs, which macOS still renders as-is. Moving to `.icon` is a separate piece of work and needs a GUI tool.
