# Card tệp: hiển thị một tệp và nhiều tệp

*22/09/2026*

## Vấn đề

Card `.file` / `.folder` hiện vẽ *tệp đầu tiên* của item và chỉ có thế: ảnh thu nhỏ của nó
trong phần xem trước, đường dẫn của nó ở chân card. Với một item gồm nhiều tệp, card đó nói dối
— nó tự nhận mình **là** tệp đầu tiên, còn những tệp kia không có gì trên card nói rằng chúng tồn
tại. Paste vẽ cùng loại item theo cách khác, và đó là cách đúng.

Cách *dán* không đổi: việc này chỉ chạm tới phần vẽ.

## Thiết kế

### Nhiều tệp (`fileURLs.count > 1`)

**Xem trước:** hai icon chung xếp chồng — icon trang giấy trắng của hệ thống
(`NSWorkspace.icon(for: .data)`) cho `.file`, icon thư mục cho `.folder`. Tờ sau lệch lên-trái,
tờ trước có đổ bóng nên hai tờ tách nhau. Không còn ảnh thu nhỏ của tệp đầu tiên: một bức ảnh
trong số năm tệp là câu trả lời sai cho câu hỏi "card này chứa gì".

**Chân card:** `Multiple files` / `Multiple folders`, căn giữa — đây là chú thích về card, cùng
hạng với "12 KB", chứ không phải nội dung của nó. Huy hiệu ⌘-số phủ lên bên phải chứ không nằm
cùng hàng, đúng như `defaultFooter` làm, để nó không đẩy nhãn lệch khỏi tâm khi ⌘ được nhấn.

**Tiêu đề:** giữ nguyên `N files` / `N folders`.

### Một tệp (`fileURLs.count == 1`) và item text là đường dẫn

**Xem trước:** giữ nguyên — ảnh thu nhỏ, rồi phần đầu nội dung nếu là tệp văn bản, rồi icon
hệ thống của tệp.

**Chân card:** đường dẫn **đầy đủ**, căn trái, tối đa **2 dòng**, cắt ở **cuối**. Chân card cao
lên theo nội dung (sàn là `PanelLayout.cardFooterHeight`), nên phần xem trước ngắn lại đúng bằng
phần chân card lấy thêm — card vẫn là hình vuông 232pt.

Trước đây chân card là một dòng cắt ở giữa. Một dòng không đủ cho đường dẫn thật:
`/Users/pikalong/Downloads/Ảnh màn hình 2026-09-22 lúc 09.29.41.png` rụng mất đúng cái phần
phân biệt nó với tệp bên cạnh. Hai dòng đọc được tên tệp; cắt ở cuối vì đường dẫn đọc từ trái
sang phải và phần gốc (`/Users/pikalong/Downloads/`) là phần đoán được.

**Huy hiệu ⌘-số** nằm cùng hàng, đáy khớp dòng cuối, trong một ô rộng tối thiểu 24pt. Ô cố định
là cần thiết: huy hiệu chỉ hiện khi giữ ⌘, và nếu bề rộng cột chữ đổi theo nó thì một đường dẫn
vừa đủ một dòng sẽ tụt xuống hai dòng ngay lúc ⌘ xuống — chân card cao lên, ảnh thu nhỏ co lại,
card giật ngay dưới ngón tay.

### Số ít / số nhiều

Giữ ngữ pháp đúng của xPaste: `1 file`, `2 files`, `1 folder`, `2 folders`. Paste ghi `1 files`
cho mọi thứ kể cả thư mục; đó là lỗi của Paste, không phải thứ đáng chép lại.

## Phạm vi

Không chạm: cách dán, cách kéo-thả, `ClipboardItem`, kho lưu trữ, tìm kiếm.

## Kiểm thử

Các hàm tĩnh thuần — `showsMultipleFiles(for:)` và `fileFooterLabel(for:)` — mang toàn bộ quyết
định và được kiểm bằng unit test trong `LinkPreviewCardTests`: nhiều tệp, nhiều thư mục, một tệp,
item text là đường dẫn, và item không có đường dẫn nào. Phần dựng hình còn lại là bố cục SwiftUI,
xác nhận bằng mắt trên panel thật.
