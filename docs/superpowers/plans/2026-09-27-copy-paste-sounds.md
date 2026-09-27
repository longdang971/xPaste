# Âm thanh copy / paste — plan

Spec: `docs/superpowers/specs/2026-09-27-copy-paste-sounds-design.md`

1. Chuyển 2 file WAV đã duyệt sang `.caf` (`afconvert -f caff -d LEI16`) vào `xPaste/Resources/Sounds/`; `xcodegen`.
2. Test trước (`xPasteTests/SoundEffectsTests.swift`): `isEnabled` mặc định true / tôn trọng false; `NSSound` nạp được cho cả hai.
3. `Services/SoundEffects.swift`: enum `Sound { copy, paste }`, `isEnabled(defaults:)`, `play(_:)` cache NSSound, stop rồi play.
4. `ClipboardMonitor.poll`: gọi `SoundEffects.play(.copy)` cạnh 2 chỗ `ClipboardStore.shared.add(item)` (trong block main async).
5. `AppDelegate.handlePasteItem`: `SoundEffects.play(.paste)` sau guard quyền Trợ năng.
6. `SettingsView` General: Row "Play sounds" sau "Always paste as Plain Text".
7. Build + chạy test; chạy Debug để user nghe thử; merge vào main.
