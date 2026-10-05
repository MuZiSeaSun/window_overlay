-- macOS 后端：Objective-C runtime 操作 NSWindow + 可选 SDL2 跨平台 API。
-- NOTE: not verified on real hardware.
local macos = {}

local ffi = require "ffi"

local ok_objc, objc = pcall(ffi.load, "/usr/lib/libobjc.dylib")
local ok_sdl, sdl = pcall(ffi.load, "libSDL2-2.0.0.dylib")

pcall(ffi.cdef, [[
typedef void *id;
typedef void *SEL;
id objc_msgSend(id self, SEL op, ...);
id objc_getClass(const char *name);
SEL sel_registerName(const char *name);
]])

if ok_sdl then
    pcall(ffi.cdef, [[
      int SDL_SetWindowAlwaysOnTop(void *window, int on);
      int SDL_SetWindowHitTest(void *window, void *callback, void *callback_data);
    ]])
end

macos.capabilities = {
    transparency = ok_objc,
    on_top = ok_objc,
    click_through = ok_objc,
    transparent_click_through = false,
    skip_taskbar = ok_objc,
}

local function sel(name)
    return objc.sel_registerName(name)
end

-- 零参数 selector。
local function msg0(id_obj, selector)
    return objc.objc_msgSend(id_obj, sel(selector))
end

-- 需要一个 C int/BOOL 参数的 selector。
-- 变参调用中 Lua number 会以 double 传入，必须显式 cast，否则 ABI 不匹配。
local function msg_bool(id_obj, selector, value)
    return objc.objc_msgSend(id_obj, sel(selector), ffi.cast("int", value and 1 or 0))
end

-- 需要一个 C long 的 selector（如 setLevel: 的 NSInteger）。
local function msg_long(id_obj, selector, value)
    return objc.objc_msgSend(id_obj, sel(selector), ffi.cast("long", value))
end

-- 通过 LÖVE 暴露的 NSWindow 指针（由门面 getNativeHandle 提供）
local function ns_window(hwnd)
    -- hwnd 已经是 NSWindow*（门面已转换）
    return ffi.cast("id", hwnd)
end

function macos.set_transparent(hwnd, enabled)
    if not ok_objc then return false, "no Objective-C runtime" end
    local win = ns_window(hwnd)
    msg_bool(win, "setOpaque:", not enabled)
    if enabled then
        -- objc_getClass 取得 NSColor 类对象（不能把 Lua string 直接当作 id 传参）。
        local ns_color_class = objc.objc_getClass("NSColor")
        local clear = msg0(ns_color_class, "clearColor")
        objc.objc_msgSend(win, sel("setBackgroundColor:"), clear)
    end
    return true
end

function macos.set_on_top(hwnd, enabled)
    if not ok_objc then return false, "no Objective-C runtime" end
    -- kCGFloatingWindowLevel = 3
    -- 注意：hwnd 是 NSWindow*，不能传给期望 SDL_Window* 的 SDL API。
    msg_long(ns_window(hwnd), "setLevel:", enabled and 3 or 0)
    return true
end

function macos.set_click_through(hwnd, enabled)
    if not ok_objc then return false, "no Objective-C runtime" end
    msg_bool(ns_window(hwnd), "setIgnoresMouseEvents:", enabled)
    return true
end

function macos.set_skip_taskbar(hwnd, enabled)
    -- 运行时只能尽力而为：真正隐藏 Dock 图标需要在打包时设置 LSUIElement。
    if not ok_objc then return false, "no Objective-C runtime" end
    msg_long(ns_window(hwnd), "setLevel:", enabled and 3 or 0)
    return true
end

function macos.set_transparent_click_through(hwnd, enabled)
    -- 逐像素命中测试需要 SDL_SetWindowHitTest 及回调，当前未实现。
    return false, "transparent click-through is not implemented on macOS"
end

return macos
