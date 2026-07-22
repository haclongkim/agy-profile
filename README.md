# agy-profile

> **Switch between Google accounts for the Antigravity CLI (`agy`) on Windows with a single command.**
> Công cụ chuyển đổi nhanh tài khoản đăng nhập cho Antigravity CLI trên Windows.

`agy` không hỗ trợ nhiều profile — muốn đổi tài khoản phải logout/login thủ công mỗi lần.
`agy-profile` giải quyết việc đó: **lưu tài khoản một lần, chuyển đổi bằng một lệnh**,
trong khi settings, trustedWorkspaces, knowledge, skills, MCP config... vẫn dùng chung.

```cmd
agy-profile save personal      # lưu tài khoản đang đăng nhập
agy-profile switch work        # đổi sang tài khoản khác ngay lập tức
```

## Nguyên lý hoạt động

Token đăng nhập của `agy` không nằm trong file cấu hình mà nằm trong
**Windows Credential Manager** (mục `gemini:antigravity`). `agy-profile` đọc/ghi
credential đó qua Win32 API, lưu mỗi profile thành một bản sao **mã hóa DPAPI** tại
`%USERPROFILE%\.gemini\agy-profiles\<tên>\`. Chuyển profile = swap đúng 1 credential —
không copy thư mục, không đụng vào dữ liệu nào khác.

Chi tiết kiến trúc và các quyết định thiết kế: xem [DESIGN.md](DESIGN.md).

## Yêu cầu

- Windows 10/11
- Windows PowerShell 5.1 (có sẵn trong Windows) hoặc PowerShell 7+
- [Antigravity CLI](https://antigravity.google/) (`agy`) đã cài đặt
- **Không cần quyền Administrator**

## Cài đặt

```powershell
git clone https://github.com/<your-username>/agy-profile.git
cd agy-profile
.\install.cmd
```

Installer sẽ copy tool vào `%LOCALAPPDATA%\agy-profile` và thêm vào `PATH` của user.
Mở terminal **mới** rồi kiểm tra:

```
agy-profile help
```

Tùy chọn khác:

```powershell
.\install.cmd -Dir D:\tools\agy-profile   # cài vào thư mục tùy chọn
.\install.cmd -Uninstall                  # gỡ cài đặt (giữ nguyên các profile đã lưu)
```

**Cập nhật phiên bản mới:** `git pull` rồi chạy lại `.\install.cmd`.

<details>
<summary>Cài đặt thủ công (không dùng installer)</summary>

Copy 2 file `agy-profile.cmd` + `agy-profile.ps1` vào bất kỳ thư mục nào có trong
`PATH` (2 file phải nằm cùng chỗ). Ví dụ nhanh nhất là `%LOCALAPPDATA%\agy\bin`
(thư mục của chính `agy`, đã có sẵn trong PATH) — nhưng lưu ý `agy update` có thể
dọn thư mục này trong tương lai.
</details>

## Bắt đầu sử dụng (ví dụ 2 tài khoản)

```cmd
:: Đang đăng nhập tài khoản cá nhân trong agy
agy-profile save personal

:: Đăng xuất, rồi đăng nhập tài khoản công việc
agy-profile logout
agy                          &:: agy sẽ yêu cầu đăng nhập → dùng tài khoản công việc
agy-profile save work

:: Từ nay chuyển qua lại chỉ cần 1 lệnh
agy-profile switch personal
agy-profile switch work

:: Hoặc xoay vòng / ngẫu nhiên khi có nhiều profile
agy-profile next
agy-profile random
```

## Các lệnh

| Lệnh | Chức năng |
|---|---|
| `agy-profile save <tên>` | Lưu tài khoản đang đăng nhập thành profile `<tên>` |
| `agy-profile switch <tên>` | Chuyển sang tài khoản của profile `<tên>` |
| `agy-profile next` | Chuyển sang profile **kế tiếp** (vòng tròn, theo thứ tự A-Z) |
| `agy-profile random` | Chuyển **ngẫu nhiên** sang một profile khác profile hiện tại |
| `agy-profile list` | Liệt kê profile; dấu `*` = trùng tài khoản đang đăng nhập |
| `agy-profile current` | Cho biết đang ở profile nào; cảnh báo nếu tài khoản hiện tại chưa được lưu |
| `agy-profile delete <tên>` | Xóa bản lưu của profile (không ảnh hưởng tài khoản đang đăng nhập) |
| `agy-profile logout` | Đăng xuất — lần chạy `agy` tới sẽ yêu cầu đăng nhập lại |
| `agy-profile help` | Hướng dẫn |
| Cờ `-Force` | Bỏ qua câu hỏi xác nhận và kiểm tra `agy` đang chạy |

Tên profile chỉ được chứa chữ không dấu, số, `-` và `_`.

## Cơ chế an toàn tích hợp sẵn

- **Mã hóa DPAPI**: file `credential.dpapi` chỉ giải mã được bởi đúng user Windows trên
  đúng máy đã tạo ra nó — copy sang máy/user khác là vô dụng. Không có token dạng
  văn bản thuần nào được ghi ra đĩa.
- **Chống mất tài khoản**: nếu `switch`/`logout` khi đang đăng nhập một tài khoản
  **chưa save**, script tự backup nó vào `_unsaved-<thời gian>\` trước khi ghi đè.
  Khôi phục: đổi tên thư mục đó (bỏ tiền tố `_`) rồi `agy-profile switch <tên mới>`.
- **Chặn switch khi `agy` đang chạy**: tránh việc agy refresh token đè lên profile
  khác giữa chừng. Dùng `-Force` nếu chắc chắn muốn bỏ qua.
- **Phát hiện lệch trạng thái**: `current`/`list` so sánh hash SHA-256 của credential
  thực tế với bản lưu — nếu bạn login tay ngoài script, sẽ có cảnh báo nhắc `save` lại.

## Câu hỏi thường gặp

**`current` cảnh báo "CHƯA khớp profile nào" dù tôi không đổi tài khoản?**
`agy` có thể đã tự refresh token (nội dung credential thay đổi → hash thay đổi).
Chạy `agy-profile save <tên đang dùng> -Force` để cập nhật bản lưu.

**Lịch sử hội thoại có tách theo profile không?**
Không — theo thiết kế, dữ liệu hội thoại/knowledge dùng chung giữa các profile.
Hội thoại của tài khoản khác vẫn hiện trong danh sách nhưng server sẽ không cho
resume nếu không thuộc tài khoản đang đăng nhập. Muốn tách riêng: xem mục 5.3
trong [DESIGN.md](DESIGN.md).

**Có dùng được cho Antigravity IDE không?**
Không. Tool này chỉ quản lý đăng nhập của **CLI** (`agy.exe`). IDE lưu trạng thái riêng.

**Version mới của `agy` đổi cách lưu token thì sao?**
Cred target là hằng số ở đầu `agy-profile.ps1` (`$CRED_TARGET`) — nếu Google đổi tên
mục credential, chỉ cần sửa 1 dòng. Lệnh `current` sẽ là nơi phát hiện sớm
("không tìm thấy credential").

## Cấu trúc repo

```
agy-profile/
├── agy-profile.cmd   # entry point — gõ `agy-profile ...` từ CMD/PowerShell
├── agy-profile.ps1   # toàn bộ logic (CredRead/CredWrite, DPAPI, hash-guard)
├── install.cmd       # installer — copy vào %LOCALAPPDATA%\agy-profile + thêm PATH
├── install.ps1       # logic của installer (hỗ trợ -Dir, -Uninstall)
├── DESIGN.md         # tài liệu thiết kế & khảo sát cơ chế lưu trữ của agy
└── README.md
```

## Miễn trừ trách nhiệm

Dự án cá nhân, không liên kết với Google. Cơ chế lưu credential của Antigravity CLI
có thể thay đổi ở các phiên bản sau. Đã kiểm thử trên Windows 11 + Windows PowerShell 5.1
(07/2026). Sử dụng với tài khoản của chính bạn.
