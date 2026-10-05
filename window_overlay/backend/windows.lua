-- Windows 后端：分层窗口颜色键透明 + User32 窗口样式。
-- NOTE: 已在 Windows 10 验证（洋红颜色键背景可完全透明）。
--
-- 透明原理：给窗口加 WS_EX_LAYERED，再用 SetLayeredWindowAttributes 把
-- 某个「颜色键」设为全透明。应用需要把背景清成同一个颜色键，这样只有
-- 绘制的图案保留，其余部分透出桌面。
-- 旧的 DwmEnableBlurBehindWindow 空区域技巧自 Windows 8 起不再产生透明，
-- 故弃用。
local windows = {}

local ffi = require "ffi"

local user32 = ffi.load("user32.dll")

pcall(ffi.cdef, [[
typedef void *HWND;
typedef int BOOL;
typedef unsigned int UINT;
typedef unsigned char BYTE;
typedef short SHORT;
typedef long LONG;
typedef struct { LONG x; LONG y; } POINT;
typedef struct { LONG left; LONG top; LONG right; LONG bottom; } RECT;

LONG GetWindowLongA(HWND hWnd, int nIndex);
LONG SetWindowLongA(HWND hWnd, int nIndex, LONG dwNewLong);
BOOL SetWindowPos(HWND hWnd, HWND hWndInsertAfter, int X, int Y, int cx, int cy, UINT uFlags);
BOOL SetLayeredWindowAttributes(HWND hWnd, unsigned int crKey, BYTE bAlpha, UINT dwFlags);
HWND GetForegroundWindow(void);
BOOL GetWindowRect(HWND hWnd, RECT *lpRect);
BOOL GetCursorPos(POINT *lpPoint);
SHORT GetAsyncKeyState(int vKey);
unsigned long __stdcall GetLastError(void);
void __stdcall SetLastError(unsigned long dwErrCode);
]])

windows.capabilities = {
    transparency = true,
    on_top = true,
    click_through = true,
    transparent_click_through = true,
    skip_taskbar = true,
}

-- 颜色键。COLORREF 为 0x00BBGGRR：洋红（R=255,G=0,B=255），
-- 归一化后即 {1, 0, 1}。选洋红是因为它极少出现在素材里；
-- 应用需把背景清成此色才能让背景透明。
windows.transparency_color = {1, 0, 1}
local TRANSPARENCY_COLORREF = 0x00FF00FF

local GWL_STYLE = -16
local GWL_EXSTYLE = -20
local WS_POPUP = 0x80000000
local WS_CAPTION_MASK = 0x00cf0000
local WS_EX_LAYERED = 0x00080000
local WS_EX_TRANSPARENT = 0x00000020
local WS_EX_TOOLWINDOW = 0x00000080
local WS_EX_NOACTIVATE = 0x08000000
local HWND_TOPMOST = -1
local LWA_COLORKEY = 0x00000001
local LWA_ALPHA = 0x00000002
local VK_LBUTTON = 0x01
-- 移动窗口用的 SetWindowPos 标志：不改大小、不改 z 序（保留置顶）、不激活。
local SWP_MOVE_FLAGS = bit.bor(0x0001, 0x0004, 0x0010)

local function set_ex_style_bits(hwnd, bits, enabled)
    local ex = ffi.C.GetWindowLongA(hwnd, GWL_EXSTYLE)
    if enabled then
        ex = bit.bor(ex, bits)
    else
        ex = bit.band(ex, bit.bnot(bits))
    end
    -- SetWindowLongA returns the PREVIOUS value, so a successful set whose
    -- previous value was 0 must not be reported as failure. Reset last-error
    -- first, then treat "0 error" as success.
    ffi.C.SetLastError(0)
    local result = ffi.C.SetWindowLongA(hwnd, GWL_EXSTYLE, ex)
    local err = ffi.C.GetLastError()
    if result ~= 0 or err == 0 then return true end
    return false, err
end

function windows.set_transparent(hwnd, enabled)
    if enabled then
        local style = ffi.C.GetWindowLongA(hwnd, GWL_STYLE)
        style = bit.band(style, bit.bnot(WS_CAPTION_MASK))
        style = bit.bor(style, WS_POPUP)
        ffi.C.SetWindowLongA(hwnd, GWL_STYLE, style)

        -- WS_EX_LAYERED is a prerequisite for LWA_COLORKEY.
        set_ex_style_bits(hwnd, WS_EX_LAYERED, true)
        local result = ffi.C.SetLayeredWindowAttributes(hwnd, TRANSPARENCY_COLORREF, 0, LWA_COLORKEY)
        if result ~= 0 then return true end
        return false, ffi.C.GetLastError()
    else
        -- Drop the color key and make the layered window fully opaque again.
        local result = ffi.C.SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA)
        set_ex_style_bits(hwnd, WS_EX_LAYERED, false)
        if result ~= 0 then return true end
        return false, ffi.C.GetLastError()
    end
end

function windows.set_on_top(hwnd, enabled)
    local insert_after = enabled and ffi.cast("HWND", HWND_TOPMOST) or ffi.cast("HWND", -2)
    -- SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE
    local result = ffi.C.SetWindowPos(hwnd, insert_after, 0, 0, 0, 0, 0x0013)
    if result ~= 0 then return true end
    return false, ffi.C.GetLastError()
end

function windows.set_click_through(hwnd, enabled)
    if enabled then
        -- WS_EX_LAYERED is kept because the transparency color key needs it.
        set_ex_style_bits(hwnd, WS_EX_LAYERED, true)
        return set_ex_style_bits(hwnd, WS_EX_TRANSPARENT, true)
    end
    -- Only remove the click-through bit so transparency stays intact.
    return set_ex_style_bits(hwnd, WS_EX_TRANSPARENT, false)
end

-- 仅让「透明（颜色键命中的）像素」穿透鼠标。分层窗口的命中测试本身就是逐像素的：
-- 颜色键命中的像素会让鼠标消息穿透，但一旦设置了 WS_EX_TRANSPARENT 就会整窗穿透。
-- 因此这里只需确保 WS_EX_LAYERED 存在并清除 WS_EX_TRANSPARENT；需要先开启
-- transparency 提供颜色键，透明才有意义。
function windows.set_transparent_click_through(hwnd, enabled)
    if enabled then
        set_ex_style_bits(hwnd, WS_EX_LAYERED, true)
        return set_ex_style_bits(hwnd, WS_EX_TRANSPARENT, false)
    end
    -- 颜色键透明天然是逐像素命中的，无法单独关闭；保持现状。
    return true
end

-- 查询窗口当前是否为前台（焦点）窗口，供门面的置顶重申守卫使用。
function windows.is_focused(hwnd)
    return ffi.C.GetForegroundWindow() == hwnd
end

function windows.set_skip_taskbar(hwnd, enabled)
    return set_ex_style_bits(hwnd, bit.bor(WS_EX_TOOLWINDOW, WS_EX_NOACTIVATE), enabled)
end

-- 窗口拖动：轮询全局光标/按键状态并用 SetWindowPos 移动，避免依赖鼠标消息。
-- 后台且逐像素命中的窗口（WS_EX_NOACTIVATE + 颜色键）在光标移出可见区域后收不到
-- mousemove，事件式拖动会卡住；轮询不受影响，且移动用 SWP_NOZORDER 保留置顶。
local drag_offset = nil -- { x, y }：按下时「光标 − 窗口左上角」，物理像素

function windows.begin_drag(hwnd)
    local pt = ffi.new("POINT[1]")
    local rect = ffi.new("RECT[1]")
    if ffi.C.GetCursorPos(pt) == 0 then return false end
    if ffi.C.GetWindowRect(hwnd, rect) == 0 then return false end
    drag_offset = { x = pt[0].x - rect[0].left, y = pt[0].y - rect[0].top }
    return true
end

function windows.update_drag(hwnd)
    if drag_offset == nil then return false end
    if bit.band(ffi.C.GetAsyncKeyState(VK_LBUTTON), 0x8000) == 0 then
        drag_offset = nil
        return false
    end
    local pt = ffi.new("POINT[1]")
    if ffi.C.GetCursorPos(pt) == 0 then return false end
    local result = ffi.C.SetWindowPos(
        hwnd, nil, pt[0].x - drag_offset.x, pt[0].y - drag_offset.y, 0, 0, SWP_MOVE_FLAGS)
    if result ~= 0 then return true end
    return false, ffi.C.GetLastError()
end

function windows.end_drag(hwnd)
    drag_offset = nil
    return true
end

-- ============================================================================
-- 系统托盘（Shell_NotifyIcon）：常驻图标 + 右键弹出原生菜单。
-- 通过一个隐藏的顶层窗口接收托盘回调；该窗口在 LÖVE 主线程创建，其消息由
-- LÖVE/SDL 每帧的消息泵派发到下面的 WndProc。文本统一转 UTF-16 以支持中文。
-- ============================================================================

pcall(ffi.cdef, [[
typedef void *HINSTANCE;
typedef void *HMENU;
typedef void *HICON;
typedef void *HBITMAP;
typedef void *HBRUSH;
typedef void *HCURSOR;
typedef void *HDC;
typedef unsigned short ATOM;
typedef long HRESULT;
typedef intptr_t WPARAM;
typedef intptr_t LPARAM;
typedef intptr_t LRESULT;

typedef LRESULT (*WNDPROC)(HWND, unsigned int, WPARAM, LPARAM);
typedef struct {
  unsigned int style;
  WNDPROC      lpfnWndProc;
  int          cbClsExtra;
  int          cbWndExtra;
  HINSTANCE    hInstance;
  HICON        hIcon;
  HCURSOR      hCursor;
  HBRUSH       hbrBackground;
  const char  *lpszMenuName;
  const char  *lpszClassName;
} WNDCLASSA;

typedef struct { unsigned long Data1; unsigned short Data2; unsigned short Data3; unsigned char Data4[8]; } GUID;
typedef struct {
  unsigned long  cbSize;
  HWND           hWnd;
  unsigned int   uID;
  unsigned int   uFlags;
  unsigned int   uCallbackMessage;
  HICON          hIcon;
  unsigned short szTip[128];
  unsigned long  dwState;
  unsigned long  dwStateMask;
  unsigned short szInfo[256];
  unsigned int   uVersion;
  unsigned short szInfoTitle[64];
  unsigned long  dwInfoFlags;
  GUID           guidItem;
  HICON          hBalloonIcon;
} NOTIFYICONDATAW;
typedef struct { unsigned long cbSize; HWND hWnd; unsigned int uID; GUID guidItem; } NOTIFYICONIDENTIFIER;

typedef struct {
  unsigned int   biSize;
  int            biWidth;
  int            biHeight;
  unsigned short biPlanes;
  unsigned short biBitCount;
  unsigned int   biCompression;
  unsigned int   biSizeImage;
  int            biXPelsPerMeter;
  int            biYPelsPerMeter;
  unsigned int   biClrUsed;
  unsigned int   biClrImportant;
} BITMAPINFOHEADER;
typedef struct { BITMAPINFOHEADER bmiHeader; unsigned int bmiColors[1]; } BITMAPINFO;
typedef struct { int fIcon; int xHotspot; int yHotspot; HBITMAP hbmMask; HBITMAP hbmColor; } ICONINFO;

ATOM RegisterClassA(const WNDCLASSA *lpWndClass);
HWND CreateWindowExA(unsigned long dwExStyle, const char *lpClassName, const char *lpWindowName,
  unsigned long dwStyle, int X, int Y, int nWidth, int nHeight,
  HWND hWndParent, HMENU hMenu, HINSTANCE hInstance, void *lpParam);
LRESULT DefWindowProcA(HWND hWnd, unsigned int Msg, WPARAM wParam, LPARAM lParam);
BOOL DestroyWindow(HWND hWnd);
HINSTANCE GetModuleHandleA(const char *lpModuleName);
BOOL SetForegroundWindow(HWND hWnd);
BOOL PostMessageA(HWND hWnd, unsigned int Msg, WPARAM wParam, LPARAM lParam);
int MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags, const char *lpMultiByteStr,
  int cbMultiByte, unsigned short *lpWideCharStr, int cchWideChar);
HICON LoadIconA(HINSTANCE hInstance, const char *lpIconName);
BOOL DestroyIcon(HICON hIcon);
HBITMAP CreateDIBSection(HDC hdc, const BITMAPINFO *pbmi, unsigned int usage, void **ppvBits, void *hSection, unsigned long dwOffset);
HBITMAP CreateBitmap(int nWidth, int nHeight, unsigned int nPlanes, unsigned int nBitCount, const void *lpBits);
HICON CreateIconIndirect(const ICONINFO *piconinfo);
BOOL DeleteObject(void *hObject);
BOOL Shell_NotifyIconW(unsigned long dwMessage, NOTIFYICONDATAW *lpData);
HRESULT Shell_NotifyIconGetRect(const NOTIFYICONIDENTIFIER *identifier, RECT *iconLocation);
HMENU CreatePopupMenu(void);
BOOL AppendMenuW(HMENU hMenu, unsigned int uFlags, unsigned long uIDNewItem, const unsigned short *lpNewItem);
BOOL DestroyMenu(HMENU hMenu);
int TrackPopupMenu(HMENU hMenu, unsigned int uFlags, int x, int y, int nReserved, HWND hWnd, const RECT *prcRect);
]])

local shell32 = ffi.load("shell32.dll")
local gdi32 = ffi.load("gdi32.dll")
local kernel32 = ffi.load("kernel32.dll")

local WM_TRAY = 0x8000 + 1 -- WM_APP + 1
local WM_NULL = 0x0000
local WM_CONTEXTMENU = 0x007B
local NIM_ADD = 0x0
local NIM_DELETE = 0x2
local NIM_SETVERSION = 0x4
local NOTIFYICON_VERSION_4 = 4
local NIF_MESSAGE = 0x1
local NIF_ICON = 0x2
local NIF_TIP = 0x4
local MF_STRING = 0x0
local TPM_RIGHTBUTTON = 0x0002
local TPM_BOTTOMALIGN = 0x0020
local TPM_NONOTIFY = 0x0080
local TPM_RETURNCMD = 0x0100
local CP_UTF8 = 65001
local DIB_RGB_COLORS = 0
local IDI_APPLICATION = 32512

local tray = {
    window = nil,
    wndproc = nil,
    icon = nil,
    nid = nil,
    added = false,
    menu = nil,
    pending = {},
}

-- UTF-8 -> UTF-16LE（含结尾 0）；返回不超过 cap 个 wchar 的缓冲区。
local function to_utf16(s, cap)
    local buf = ffi.new("unsigned short[?]", cap)
    local n = ffi.C.MultiByteToWideChar(CP_UTF8, 0, s, -1, buf, cap)
    if n == 0 then return nil end
    return buf
end

-- 由原始 RGBA8（LÖVE ImageData:getString）生成 HICON。
local function hicon_from_rgba(w, h, rgba)
    if w <= 0 or h <= 0 or #rgba < w * h * 4 then return nil end
    local bi = ffi.new("BITMAPINFO[1]")
    bi[0].bmiHeader.biSize = ffi.sizeof("BITMAPINFOHEADER")
    bi[0].bmiHeader.biWidth = w
    bi[0].bmiHeader.biHeight = -h -- 负高度 = 自上而下
    bi[0].bmiHeader.biPlanes = 1
    bi[0].bmiHeader.biBitCount = 32
    bi[0].bmiHeader.biCompression = 0 -- BI_RGB
    local bits_ptr = ffi.new("void*[1]")
    local dib = gdi32.CreateDIBSection(nil, bi, DIB_RGB_COLORS, bits_ptr, nil, 0)
    if dib == nil then return nil end
    local bits = ffi.cast("unsigned char *", bits_ptr[0])
    for i = 0, w * h - 1 do
        local o = i * 4
        bits[o + 0] = rgba:byte(o + 3) -- B
        bits[o + 1] = rgba:byte(o + 2) -- G
        bits[o + 2] = rgba:byte(o + 1) -- R
        bits[o + 3] = rgba:byte(o + 4) -- A
    end
    local mask = gdi32.CreateBitmap(w, h, 1, 1, nil)
    local ii = ffi.new("ICONINFO[1]")
    ii[0].fIcon = 1
    ii[0].hbmMask = mask
    ii[0].hbmColor = dib
    local icon = ffi.C.CreateIconIndirect(ii)
    gdi32.DeleteObject(dib)
    gdi32.DeleteObject(mask)
    return icon
end

-- 右键时弹出原生菜单；选中项把其 id 入队。
function windows._tray_show_menu(hwnd)
    local menu = ffi.C.CreatePopupMenu()
    if menu == nil then return end
    local items = tray.menu or {}
    for index, item in ipairs(items) do
        local label = to_utf16(item.label or item.id or "?", 256)
        if label ~= nil then
            ffi.C.AppendMenuW(menu, MF_STRING, index, label)
        end
    end
    local pt = ffi.new("POINT[1]")
    ffi.C.GetCursorPos(pt)
    ffi.C.SetForegroundWindow(hwnd)
    local cmd = ffi.C.TrackPopupMenu(menu,
        bit.bor(TPM_RIGHTBUTTON, TPM_BOTTOMALIGN, TPM_NONOTIFY, TPM_RETURNCMD),
        pt[0].x, pt[0].y, 0, hwnd, nil)
    ffi.C.PostMessageA(hwnd, WM_NULL, 0, 0)
    ffi.C.DestroyMenu(menu)
    if cmd ~= 0 and items[cmd] ~= nil then
        table.insert(tray.pending, items[cmd].id)
    end
end

local function tray_wndproc(hwnd, msg, wparam, lparam)
    if msg == WM_TRAY then
        if bit.band(lparam, 0xFFFF) == WM_CONTEXTMENU then
            windows._tray_show_menu(hwnd)
        end
        return 0
    end
    return ffi.C.DefWindowProcA(hwnd, msg, wparam, lparam)
end

local function ensure_tray_window()
    if tray.window ~= nil then return true end
    if tray.wndproc == nil then
        tray.wndproc = ffi.cast("WNDPROC", tray_wndproc)
    end
    local wc = ffi.new("WNDCLASSA[1]")
    wc[0].lpfnWndProc = tray.wndproc
    wc[0].hInstance = kernel32.GetModuleHandleA(nil)
    wc[0].lpszClassName = "window_overlay_tray"
    ffi.C.RegisterClassA(wc) -- 已注册时返回 0，忽略即可
    local hwnd = ffi.C.CreateWindowExA(
        0, "window_overlay_tray", "window_overlay_tray",
        WS_POPUP, 0, 0, 0, 0, nil, nil, wc[0].hInstance, nil)
    if hwnd == nil then return false end
    tray.window = hwnd
    return true
end

function windows.tray_show(opts)
    if not ensure_tray_window() then return false, "could not create tray window" end
    opts = opts or {}
    tray.menu = opts.menu or { { id = "close", label = "关闭" } }

    local hicon = nil
    if opts.icon ~= nil then
        hicon = hicon_from_rgba(opts.icon[1], opts.icon[2], opts.icon[3])
    end
    if hicon == nil then
        hicon = ffi.C.LoadIconA(nil, ffi.cast("const char *", IDI_APPLICATION))
    end
    tray.icon = hicon

    local nid = ffi.new("NOTIFYICONDATAW[1]")
    nid[0].cbSize = ffi.sizeof("NOTIFYICONDATAW")
    nid[0].hWnd = tray.window
    nid[0].uID = 1
    nid[0].uFlags = bit.bor(NIF_MESSAGE, NIF_ICON, NIF_TIP)
    nid[0].uCallbackMessage = WM_TRAY
    nid[0].hIcon = hicon
    if opts.tooltip ~= nil then
        local tip = to_utf16(opts.tooltip, 128)
        if tip ~= nil then
            for i = 0, 127 do nid[0].szTip[i] = tip[i] end
        end
    end
    if shell32.Shell_NotifyIconW(NIM_ADD, nid) == 0 then
        return false, "Shell_NotifyIcon(NIM_ADD) failed"
    end
    nid[0].uVersion = NOTIFYICON_VERSION_4
    shell32.Shell_NotifyIconW(NIM_SETVERSION, nid)
    tray.nid = nid
    tray.added = true
    return true
end

function windows.tray_hide()
    if tray.added and tray.nid ~= nil then
        shell32.Shell_NotifyIconW(NIM_DELETE, tray.nid)
        tray.added = false
    end
    if tray.icon ~= nil then
        ffi.C.DestroyIcon(tray.icon)
        tray.icon = nil
    end
    if tray.window ~= nil then
        ffi.C.DestroyWindow(tray.window)
        tray.window = nil
    end
    tray.nid = nil
    return true
end

function windows.tray_poll()
    return table.remove(tray.pending, 1)
end

function windows.tray_is_visible()
    if not tray.added or tray.nid == nil then return false end
    local ident = ffi.new("NOTIFYICONIDENTIFIER[1]")
    ident[0].cbSize = ffi.sizeof("NOTIFYICONIDENTIFIER")
    ident[0].hWnd = tray.nid[0].hWnd
    ident[0].uID = tray.nid[0].uID
    local rect = ffi.new("RECT[1]")
    return shell32.Shell_NotifyIconGetRect(ident, rect) == 0
end

return windows
