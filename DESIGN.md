# Thiết kế: `agy-profile` — Chuyển đổi tài khoản (profile) cho Antigravity CLI

> Tài liệu thiết kế cho bộ script Windows (`agy-profile.cmd` + `agy-profile.ps1`) giúp lưu và
> chuyển đổi nhanh **tài khoản đăng nhập** của Antigravity CLI (`agy.exe`), trong khi
> **giữ nguyên toàn bộ dữ liệu còn lại** (settings, knowledge, skills, MCP config...) dùng chung.

---

## 1. Khảo sát thực tế (trên máy này, 2026-07-22)

### 1.1 Trạng thái CLI nằm ở đâu

```
%USERPROFILE%\.gemini\
├── antigravity-cli\              ← ★ thư mục trạng thái của agy.exe (CLI)
│   ├── settings.json             ← theme, trustedWorkspaces        → DÙNG CHUNG
│   ├── jetski_state.pbtxt        ← onboarding, migrations (KHÔNG chứa token)
│   ├── installation_id           ← id máy                          → DÙNG CHUNG
│   ├── conversation_summaries.db ← index hội thoại                 (xem mục 5.3)
│   ├── cache\
│   │   ├── default_project_id.txt     ← gắn với tài khoản          → THEO PROFILE
│   │   ├── conversation_metadata.json ← metadata hội thoại         (xem mục 5.3)
│   │   └── onboarding.json
│   ├── conversations\  brain\  knowledge\  builtin\skills\  ...   → DÙNG CHUNG
├── antigravity\                  ← trạng thái phía IDE-agent (KHÔNG đụng tới)
├── antigravity-ide\              ← trạng thái IDE (KHÔNG đụng tới)
└── config\                       ← hạ tầng chung (KHÔNG đụng tới)
```

### 1.2 Đăng nhập lưu ở đâu — phát hiện quan trọng nhất

Token đăng nhập **không nằm trong file nào** ở `.gemini`. Nó nằm trong
**Windows Credential Manager**:

```
Target : LegacyGeneric:target=gemini:antigravity
User   : antigravity
Type   : Generic (persistence: Local machine)
```

→ **Đổi tài khoản = đổi credential blob này** (+ vài file cache nhỏ gắn với tài khoản).
Không cần copy/di chuyển thư mục nào cả.

## 2. Yêu cầu

- **Chỉ chuyển đổi danh tính đăng nhập.** Mọi thứ khác — settings, trustedWorkspaces,
  knowledge, skills, MCP config, brain — dùng chung giữa các profile.
- 1 lệnh để lưu tài khoản hiện tại, 1 lệnh để chuyển: `agy-profile save work`,
  `agy-profile switch personal`
- Không cần quyền Admin, không sửa `agy.exe`
- Token lưu trên đĩa phải được **mã hóa DPAPI** (chỉ user hiện tại trên máy này giải mã được)

**Ngoài phạm vi:** profile cho Antigravity IDE; đồng bộ profile giữa nhiều máy
(DPAPI chủ đích chặn việc này).

## 3. Cơ chế cốt lõi: Swap credential trong Credential Manager

```
                    ┌──────────────────────────────────────────┐
                    │  Windows Credential Manager               │
   switch work ───► │  gemini:antigravity  = <blob của "work">  │ ◄── agy.exe đọc
                    └──────────────────────────────────────────┘
                                      ▲
                                      │ CredWrite (ghi đè)
        %USERPROFILE%\.gemini\agy-profiles\
        ├── _active.txt
        ├── work\
        │   ├── credential.dpapi        ← blob CredRead, mã hóa DPAPI
        │   └── default_project_id.txt  ← bản sao cache gắn tài khoản
        └── personal\
            ├── credential.dpapi
            └── default_project_id.txt
```

- **`save <name>`**: `CredRead("gemini:antigravity")` → mã hóa DPAPI
  (`ProtectedData.Protect`, scope `CurrentUser`) → ghi `credential.dpapi`;
  đồng thời sao lưu `cache\default_project_id.txt` của tài khoản đó.
- **`switch <name>`**: giải mã `credential.dpapi` → `CredWrite` ghi đè
  `gemini:antigravity`; chép trả `default_project_id.txt`; cập nhật `_active.txt`.
- Các file dùng chung **không bị đụng tới** — đúng yêu cầu "giữ những thông tin khác".

### Vì sao không dùng junction swap cả thư mục (thiết kế cũ)?

Bản nháp đầu đề xuất junction-swap toàn bộ thư mục trạng thái. Bị loại vì: (1) token vốn
không nằm trong thư mục nên swap thư mục **không đổi được tài khoản**; (2) trái yêu cầu
dùng chung settings/knowledge; (3) phức tạp và rủi ro hơn nhiều so với swap 1 credential.

## 4. Giao diện lệnh

```
agy-profile <command> [args]

  save <name>       Lưu tài khoản đang đăng nhập thành profile <name>
                    (ghi đè nếu đã tồn tại, có xác nhận)
  switch <name>     Chuyển sang tài khoản của profile <name>
  list              Liệt kê profile, đánh dấu (*) profile active
  current           Tên profile active (+ cảnh báo nếu credential thực tế
                    đã bị đổi ngoài script, xem 5.2)
  delete <name>     Xóa profile đã lưu (không ảnh hưởng tài khoản đang đăng nhập)
  logout            Xóa credential hiện tại (CredDelete) → agy quay về trạng thái chưa đăng nhập
  help              Hướng dẫn
```

### Luồng thiết lập lần đầu

```cmd
:: đang đăng nhập tài khoản cá nhân
agy-profile save personal

:: đăng nhập tài khoản công việc: xóa cred cũ rồi login lại trong agy
agy-profile logout
agy                          :: → agy yêu cầu đăng nhập → dùng tài khoản công việc
agy-profile save work

:: từ nay chuyển qua lại chỉ 1 lệnh
agy-profile switch personal
agy-profile switch work
```

## 5. Thiết kế kỹ thuật

### 5.1 Cấu trúc file: `.cmd` wrapper + `.ps1` lõi

CMD thuần **không gọi được** API `CredRead`/`CredWrite`/DPAPI, nên tách 2 file đặt cùng thư mục:

- **`agy-profile.cmd`** — entry point cho người dùng, chỉ làm một việc:
  ```bat
  @echo off
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0agy-profile.ps1" %*
  ```
- **`agy-profile.ps1`** — toàn bộ logic (~250 dòng):
  - `Add-Type` khối P/Invoke `advapi32.dll`: `CredRead`, `CredWrite`, `CredDelete`,
    `CredFree` (mẫu chuẩn, khoảng 60 dòng C# inline)
  - DPAPI qua `[System.Security.Cryptography.ProtectedData]::Protect/Unprotect`
    với scope `CurrentUser`
  - `param($Command, $Name)` + `switch ($Command)` để dispatch

Hằng số tập trung đầu file:

```powershell
$CRED_TARGET  = 'gemini:antigravity'
$CLI_DIR      = "$env:USERPROFILE\.gemini\antigravity-cli"
$PROFILES_DIR = "$env:USERPROFILE\.gemini\agy-profiles"
$PER_PROFILE_FILES = @('cache\default_project_id.txt')   # mở rộng được, xem 5.3
```

### 5.2 An toàn & tính đúng

| Rủi ro | Biện pháp |
|---|---|
| Token nằm trên đĩa dạng đọc được | Luôn mã hóa DPAPI scope `CurrentUser`; file `credential.dpapi` vô dụng nếu copy sang máy/user khác |
| Swap khi `agy` đang chạy (giữa phiên có thể refresh/ghi lại token) | Chặn bằng `Get-Process agy`; override bằng `-Force` |
| `_active.txt` nói dối (user tự login tài khoản khác ngoài script) | `save` lưu kèm SHA-256 của blob; `current`/`switch` so hash blob thực tế với profile active → cảnh báo "credential đã thay đổi, hãy `save` lại trước khi switch" |
| `switch` đè mất tài khoản chưa kịp lưu | Trước khi ghi đè, nếu blob hiện tại không khớp hash của bất kỳ profile nào → tự backup vào `_unsaved-<timestamp>\` rồi mới ghi |
| Tên profile không hợp lệ | Whitelist `^[a-zA-Z0-9_-]+$`, chặn path traversal |
| Version `agy` mới đổi tên cred target | Target là hằng số 1 chỗ; lệnh `current` báo rõ "không tìm thấy credential" thay vì lỗi khó hiểu |

### 5.3 Vấn đề mở: dữ liệu hội thoại có nên dùng chung?

`conversations\`, `conversation_summaries.db`, `cache\conversation_metadata.json` là dữ liệu
local nhưng **gắn với tài khoản phía server**. Dùng chung có thể khiến danh sách hội thoại
hiển thị lẫn giữa 2 tài khoản (vô hại về bảo mật local, nhưng gây nhiễu; server sẽ từ chối
resume hội thoại không thuộc tài khoản đang đăng nhập).

- **v1**: dùng chung tất cả (đúng yêu cầu hiện tại), quan sát hành vi thực tế.
- **Nếu thấy nhiễu**: thêm 3 mục trên vào `$PER_PROFILE_FILES` (cơ chế backup/restore
  per-profile đã có sẵn, chỉ cần thêm dòng cấu hình — không đổi kiến trúc).

## 6. Kiểm thử (test plan thủ công)

1. `save personal` → thấy `credential.dpapi` (nội dung nhị phân, không lộ token) + hash
2. `logout` → mở `agy` thấy yêu cầu đăng nhập lại → login tài khoản 2 → `save work`
3. `switch personal` → mở `agy` → đúng tài khoản 1, không phải login lại;
   `settings.json`/trustedWorkspaces/knowledge còn nguyên
4. `switch work` khi `agy` đang mở → bị chặn; với `-Force` thì cho qua
5. Login tay tài khoản 3 (không save) → `switch personal` → tài khoản 3 được tự backup
   vào `_unsaved-*`, có cảnh báo
6. Copy `credential.dpapi` sang user Windows khác → giải mã thất bại (DPAPI đúng thiết kế)
7. `delete work` → còn login hiện tại không đổi; `list` không còn `work`

## 7. Lộ trình

| Giai đoạn | Nội dung |
|---|---|
| **v1 (MVP)** | `save / switch / list / current / logout` + DPAPI + hash-guard + auto-backup unsaved |
| **v1.1** | `delete`, `-Force`, thông báo màu, kiểm tra `agy` process |
| **v2** | Tùy chọn `-WithConversations` (tách dữ liệu hội thoại theo profile, mục 5.3); alias `agyp work -- <lệnh agy>` chạy 1 lệnh dưới profile chỉ định rồi switch về |
| **Theo dõi** | Version `agy` mới có thể đổi cơ chế lưu token (đổi cred target, hoặc chuyển sang file) → lệnh `current` là chỗ phát hiện sớm |

---

*Khảo sát mục 1 thực hiện trực tiếp trên máy này ngày 2026-07-22 với `agy.exe` tại
`%LOCALAPPDATA%\agy\bin`. Thiết kế cũ (junction-swap toàn thư mục) đã bị thay thế — xem mục 3.*
