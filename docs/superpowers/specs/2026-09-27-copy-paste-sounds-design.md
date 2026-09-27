# Âm thanh copy / paste — thiết kế

## Mục tiêu
Phát một tiếng ngắn khi xPaste ghi nhận một lần copy mới, và một tiếng khác khi người dùng paste từ panel.

## Âm thanh
Tự tổng hợp, user đã duyệt bằng tai (27/09/2026):
- **copy** — "paper snap": nhiễu lọc dải quanh 3.2 kHz tắt nhanh + nốt 2.6→2.1 kHz, ~0.3 s kể cả vang.
- **paste** — "double snap": hai tiếng snap 3.0 kHz rồi 3.9 kHz cách nhau 45 ms.

Đóng kèm app dạng `.caf` trong `xPaste/Resources/Sounds/` (`xpaste-copy.caf`, `xpaste-paste.caf`).

## Khi nào kêu
- **Copy**: mỗi khi `ClipboardMonitor` thực sự chuyển một item cho `ClipboardStore.add` — tức là đã qua
  mọi bộ lọc (app bị loại trừ, ConcealedType, TransientType, mẫu loại trừ). Không kêu cho thay đổi xPaste
  tự ghi (`markNextChangeAsOwn`/`writeOwned`), nên paste từ panel không kêu tiếng copy. Không kêu cho item
  do perf harness bơm vào (`AppDelegate` gọi thẳng `add`).
- **Paste**: trong `AppDelegate.handlePasteItem` — điểm hội tụ của mọi đường paste từ panel (Enter,
  double-click, plain text, transform, dán hàng loạt), nên dán hàng loạt kêu đúng 1 lần. Không kêu khi
  thiếu quyền Trợ năng (lúc đó không paste gì cả).

## Cài đặt
Settings › General: công tắc **Play sounds** (`UserDefaults` key `playSounds`), **mặc định bật**, tắt cả hai tiếng.

## Thành phần
`Services/SoundEffects.swift` — `enum SoundEffects { static func play(_: Sound) }`: đọc cờ, nạp `NSSound`
một lần rồi giữ lại, `stop()` trước `play()` để copy liên tiếp phát lại từ đầu thay vì bị bỏ qua. Chỉ gọi
trên main thread.

## Kiểm thử
- Unit: cờ `playSounds` mặc định true khi chưa đặt; cả hai file âm có trong bundle và nạp được thành `NSSound`.
- Tay: copy ở app khác → tiếng copy; paste từ panel → tiếng paste, không kèm tiếng copy; tắt công tắc → im.

## Cập nhật 27/09/2026
User nghe thử rồi **bỏ tiếng paste**, chỉ giữ tiếng copy. Đã gỡ `xpaste-paste.caf`, case `.paste` và lời gọi
trong `handlePasteItem`; công tắc Play sounds giờ chỉ điều khiển tiếng copy.
