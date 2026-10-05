-- Linux 后端：X11 (XShape / EWMH) + 可选 SDL2 跨平台 API。
-- NOTE: not verified on real hardware. 纯 Wayland 下这些 X11 调用无效。
local linux = {}

local ffi = require "ffi"

local ok_x11, x11 = pcall(ffi.load, "libX11.so.6")
local ok_xext, xext = pcall(ffi.load, "libXext.so.6")
local ok_sdl, sdl = pcall(ffi.load, "libSDL2-2.0.0.so.0")

pcall(ffi.cdef, [[
typedef unsigned long Window;
typedef unsigned long Atom;
typedef struct { int x, y; } XPoint;
typedef struct { int x, y; unsigned int width, height; } XRectangle;
typedef void *Display;

int XChangeProperty(Display *d, Window w, Atom property, Atom type, int format,
    int mode, const unsigned char *data, int nelements);
Atom XInternAtom(Display *d, const char *name, int only_if_exists);
int XFlush(Display *d);
int XShapeCombineRectangles(Display *d, Window dest, int kind, int x_off, int y_off,
    XRectangle *rects, int n_rects, int op, int ordering);
]])

if ok_sdl then
    pcall(ffi.cdef, [[
      int SDL_SetWindowAlwaysOnTop(void *window, int on);
      int SDL_SetWindowHitTest(void *window, void *callback, void *callback_data);
    ]])
end

-- 门面传入的 hwnd 是 X11 Window（XID），Display 通过 LÖVE/SDL 无法直接拿到，
-- 因此 EWMH 部分需要调用方或后续补一个 Display 获取途径；此处按占位实现。
linux.capabilities = {
    transparency = false, -- 依赖 compositor，且需要 Display，暂标记不支持
    on_top = false, -- 门面传入的是 X11 XID，不是 SDL_Window*，SDL 无法使用
    click_through = false, -- 需要 Display 做 XShape，暂标记不支持
    transparent_click_through = false, -- 需要 XShape 输入区域，暂标记不支持
    skip_taskbar = false,
}

function linux.set_transparent(hwnd, enabled)
    -- 透明由窗口创建时的 ARGB visual 决定，运行时切换不可靠。
    return false, "transparency is set at window creation on Linux"
end

function linux.set_on_top(hwnd, enabled)
    -- 门面传入的是 X11 XID，无法当作 SDL_Window* 传给 SDL。能力声明为 false。
    return false, "on_top requires an SDL_Window* handle"
end

function linux.set_click_through(hwnd, enabled)
    return false, "click-through requires XShape with a Display handle"
end

function linux.set_skip_taskbar(hwnd, enabled)
    return false, "skip-taskbar requires the X11 Display handle"
end

function linux.set_transparent_click_through(hwnd, enabled)
    return false, "transparent click-through requires XShape input regions"
end

return linux
