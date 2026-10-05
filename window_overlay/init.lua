-- window_overlay: 桌面覆盖层窗口能力库（单例）。
-- 只做四件事：透明、置顶、鼠标穿透、隐藏任务栏。
-- 详见 lib/window_overlay/README.md
local overlay = {}

overlay._config = {
    transparent = false,
    on_top = false,
    click_through = false,
    transparent_click_through = false,
    skip_taskbar = false,
}

overlay._handle = nil
overlay._backend = nil
overlay._last_error = nil
overlay._topmost_timer = 0
overlay._dragging = false
overlay._drag_region = nil
overlay._draw_debug_border = false

overlay._capability_to_setter = {
    transparency = "set_transparent",
    on_top = "set_on_top",
    click_through = "set_click_through",
    transparent_click_through = "set_transparent_click_through",
    skip_taskbar = "set_skip_taskbar",
}

function overlay._set_backend_for_test(backend)
    overlay._backend = backend
end

function overlay._detect_backend()
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi then return require("window_overlay.backend.dummy") end
    local os_name = ffi.os
    local module_by_os = {
        Windows = "window_overlay.backend.windows",
        OSX = "window_overlay.backend.macos",
        Linux = "window_overlay.backend.linux",
    }
    local mod = module_by_os[os_name]
    if mod == nil then return require("window_overlay.backend.dummy") end
    local ok, backend = pcall(require, mod)
    if not ok or type(backend) ~= "table" then
        return require("window_overlay.backend.dummy")
    end
    return backend
end

function overlay._get_handle()
    -- Guarded: on a build without LuaJIT this must degrade (init -> false) and
    -- never throw. _detect_backend() already guards its require("ffi").
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi then return nil end
    if ffi.os == "Windows" then
        -- Prefer the SDL window of THIS process over GetActiveWindow(), which
        -- can return an unrelated window (e.g. the attached console) when LÖVE
        -- does not hold focus at load time. Each declaration is guarded so a
        -- redeclaration elsewhere does not abort the rest of the block.
        pcall(ffi.cdef, "typedef void* HWND;")
        pcall(ffi.cdef, "typedef unsigned long DWORD;")
        pcall(ffi.cdef, "typedef int BOOL;")
        pcall(ffi.cdef, "typedef int (*WNDENUMPROC)(HWND, long);")
        pcall(ffi.cdef, "DWORD GetCurrentProcessId(void);")
        pcall(ffi.cdef, "DWORD GetWindowThreadProcessId(HWND hWnd, DWORD *lpdwProcessId);")
        pcall(ffi.cdef, "int GetClassNameA(HWND hWnd, char *lpClassName, int nMaxCount);")
        pcall(ffi.cdef, "BOOL EnumWindows(WNDENUMPROC lpEnumFunc, long lParam);")
        pcall(ffi.cdef, "HWND GetActiveWindow(void);")

        local ok_find, found = pcall(function()
            local user32 = ffi.load("user32.dll")
            local kernel32 = ffi.load("kernel32.dll")
            local target_pid = kernel32.GetCurrentProcessId()
            local pidbuf = ffi.new("DWORD[1]")
            local namebuf = ffi.new("char[256]")
            local result = nil
            local cb = ffi.cast("WNDENUMPROC", function(hwnd, _)
                if result ~= nil then return 0 end
                user32.GetWindowThreadProcessId(hwnd, pidbuf)
                if pidbuf[0] == target_pid then
                    local n = user32.GetClassNameA(hwnd, namebuf, 256)
                    if n > 0 and ffi.string(namebuf, n) == "SDL_app" then
                        result = hwnd
                        return 0
                    end
                end
                return 1
            end)
            user32.EnumWindows(cb, 0)
            cb:free()
            return result
        end)
        if ok_find and found ~= nil then return found end

        -- Fallback for the unlikely case the class name differs.
        local ok, handle = pcall(function() return ffi.C.GetActiveWindow() end)
        if ok and handle ~= nil and handle ~= ffi.NULL then return handle end
        return nil
    end
    -- macOS / Linux: acquire the native window via SDL2 (loaded by LÖVE).
    -- Research skeleton only: obtaining the SDL_Window* reliably is
    -- version-dependent. Returning nil is acceptable (init -> false, no throw).
    local lib = ffi.os == "OSX" and "libSDL2-2.0.0.dylib" or "libSDL2-2.0.0.so.0"
    local ok, sdl = pcall(ffi.load, lib)
    if ok then
        pcall(ffi.cdef, [[
          typedef struct SDL_SysWMinfo { unsigned char _opaque[256]; } SDL_SysWMinfo;
          int SDL_GetWindowWMInfo(void *window, SDL_SysWMinfo *info);
        ]])
    end
    return nil
end

function overlay.init()
    overlay._backend = overlay._detect_backend()
    overlay._last_error = nil
    overlay._handle = overlay._get_handle()
    overlay._topmost_timer = 0
    overlay._dragging = false
    -- init() (re-)binds the library to the current native window. After a window
    -- recreation the freshly bound handle has none of the styles, so reset the
    -- cached config to "nothing applied yet": otherwise the idempotent setters
    -- would skip the backend call and the new window would lose its styles.
    overlay._config = {
        transparent = false,
        on_top = false,
        click_through = false,
        transparent_click_through = false,
        skip_taskbar = false,
    }
    if overlay._handle == nil then
        overlay._last_error = "no window handle"
        return false
    end
    return true
end

function overlay.is_supported(capability)
    if overlay._backend == nil then return false end
    local caps = overlay._backend.capabilities
    if caps == nil then return false end
    return caps[capability] == true
end

function overlay.get_last_error()
    return overlay._last_error
end

function overlay.get_handle()
    return overlay._handle
end

function overlay.get_config()
    local copy = {}
    for k, v in pairs(overlay._config) do copy[k] = v end
    return copy
end

-- Returns the color (r, g, b in 0..1) that the app must clear its background
-- to for the transparency color key to work, or nil on platforms that don't
-- use a color key.
function overlay.get_transparency_color()
    if overlay._backend == nil then return nil end
    local c = overlay._backend.transparency_color
    if c == nil then return nil end
    return { c[1], c[2], c[3] }
end

local function call_backend(capability, value)
    if overlay._backend == nil then
        overlay._last_error = "not initialized: call init() first"
        return false
    end
    if overlay._handle == nil then
        overlay._last_error = "no window handle"
        return false
    end
    if overlay.is_supported(capability) ~= true then
        overlay._last_error = "unsupported on this platform"
        return false
    end
    local setter_name = overlay._capability_to_setter[capability]
    local ok, result, err = pcall(overlay._backend[setter_name], overlay._handle, value)
    if not ok then
        overlay._last_error = tostring(result)
        return false
    end
    if result ~= true then
        overlay._last_error = err or ("failed to set " .. capability)
        return false
    end
    overlay._last_error = nil
    return true
end

local function make_setter(capability, config_key)
    -- `force` bypasses the idempotency short-circuit and re-applies the value to
    -- the window. Needed when an external actor cleared a style behind our back
    -- (e.g. SDL's setPosition clears WS_EX_TOPMOST while moving the window).
    return function(value, force)
        value = not not value
        if not force and overlay._config[config_key] == value then
            local caps = overlay._backend and overlay._backend.capabilities or {}
            if caps[capability] ~= true or overlay._handle == nil then
                return call_backend(capability, value)
            end
            overlay._last_error = nil
            return true
        end
        local ok = call_backend(capability, value)
        if ok then
            overlay._config[config_key] = value
        end
        return ok
    end
end

overlay.set_transparent = make_setter("transparency", "transparent")
overlay.set_on_top = make_setter("on_top", "on_top")
overlay.set_click_through = make_setter("click_through", "click_through")
overlay.set_transparent_click_through = make_setter("transparent_click_through", "transparent_click_through")
overlay.set_skip_taskbar = make_setter("skip_taskbar", "skip_taskbar")

-- 置顶重申守卫。系统/SDL 在某些操作（移动窗口、切换焦点）后会清掉或改写
-- 窗口的置顶状态，统一由生命周期钩子处理：
--   * on_focus(f)  —— 在 love.focus 中调用，立即重申一次；
--   * on_update(dt)—— 在 love.update 中调用，窗口失焦时每 INTERVAL 秒重申一次。
-- 失焦判定由后端 is_focused 提供（仅 Windows 实现，其他平台为空操作）。
-- reassert_on_top() 是二者共用的立即重申实现。
local TOPMOST_REASSERT_INTERVAL = 0.5

function overlay.reassert_on_top()
    if overlay._config.on_top then
        return overlay.set_on_top(true, true)
    end
    return false
end

-- 内部步骤（原 tick）：失焦时定期重申置顶。
local function topmost_tick(dt)
    if not overlay._config.on_top then return false end
    if not (overlay._backend and overlay._backend.is_focused) then return false end
    if overlay._backend.is_focused(overlay._handle) then
        overlay._topmost_timer = 0
        return false
    end
    overlay._topmost_timer = overlay._topmost_timer + (dt or 0)
    if overlay._topmost_timer >= TOPMOST_REASSERT_INTERVAL then
        overlay._topmost_timer = 0
        return overlay.set_on_top(true, true)
    end
    return false
end

-- 生命周期钩子（在 love.focus 中调用）。
function overlay.on_focus(_focused)
    return overlay.reassert_on_top()
end

-- 窗口拖动：拖动区域由应用通过 set_drag_region 指定（通常是一个可见精灵图的
-- 矩形）。on_mousepressed 命中区域才开始拖动；on_update 轮询全局光标跟随移动
-- （快速拖动、光标移出窗口或落入颜色键透明区都不中断）；on_mousereleased 结束。
-- 移动用 SWP_NOZORDER，不会清掉置顶。
function overlay.set_drag_region(x, y, w, h)
    overlay._drag_region = { x = x, y = y, w = w, h = h }
    return true
end

local function drag_hit(x, y)
    local r = overlay._drag_region
    if r == nil then return false end
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

-- 内部步骤（原 begin_drag）。
local function drag_begin()
    if overlay._backend == nil or overlay._backend.begin_drag == nil or overlay._handle == nil then
        overlay._last_error = "drag unsupported or not initialized"
        return false
    end
    local ok, result = pcall(overlay._backend.begin_drag, overlay._handle)
    if not ok then
        overlay._last_error = tostring(result)
        return false
    end
    return result == true
end

-- 内部步骤（原 update_drag）。
local function drag_update()
    if overlay._backend == nil or overlay._backend.update_drag == nil or overlay._handle == nil then
        return false
    end
    local ok, result = pcall(overlay._backend.update_drag, overlay._handle)
    if not ok then
        overlay._last_error = tostring(result)
        return false
    end
    return result == true
end

-- 内部步骤（原 end_drag）。
local function drag_end()
    if overlay._backend == nil or overlay._backend.end_drag == nil or overlay._handle == nil then
        return false
    end
    local ok, result = pcall(overlay._backend.end_drag, overlay._handle)
    if not ok then
        overlay._last_error = tostring(result)
        return false
    end
    return result == true
end

-- 生命周期钩子（在 love.mousepressed 中调用）：左键命中拖动区域才拖动。
function overlay.on_mousepressed(x, y, button)
    if button == 1 and drag_hit(x, y) then
        overlay._dragging = drag_begin()
    end
end

-- 生命周期钩子（在 love.mousereleased 中调用）。
function overlay.on_mousereleased(_x, _y, button)
    if button == 1 then
        overlay._dragging = false
        drag_end()
    end
end

-- 生命周期钩子（在 love.update 中调用）：置顶守卫 + 拖动跟随。
function overlay.on_update(dt)
    topmost_tick(dt)
    if overlay._dragging and not drag_update() then
        overlay._dragging = false
    end
end

-- 系统托盘（Windows）。tray_show 常驻一个图标；右键弹出菜单，选中项由
-- tray_poll() 取出（返回菜单项的 id），应用据此处理（例如关闭）。
--   opts = { icon = { width, height, rgba8string }, tooltip = string,
--            menu = { { id = string, label = string }, ... } }
function overlay.tray_show(opts)
    if overlay._backend == nil or overlay._backend.tray_show == nil then
        overlay._last_error = "tray unsupported on this platform"
        return false
    end
    local ok, result, err = pcall(overlay._backend.tray_show, opts)
    if not ok then
        overlay._last_error = tostring(result)
        return false
    end
    if result ~= true then
        overlay._last_error = err or "tray_show failed"
        return false
    end
    overlay._last_error = nil
    return true
end

-- 内部步骤（原 tray_hide）。
local function tray_hide()
    if overlay._backend == nil or overlay._backend.tray_hide == nil then
        return false
    end
    local ok, result, err = pcall(overlay._backend.tray_hide)
    if not ok then
        overlay._last_error = tostring(result)
        return false
    end
    if result ~= true then
        overlay._last_error = err or "tray_hide failed"
        return false
    end
    overlay._last_error = nil
    return true
end

-- 取出一个待处理的托盘菜单动作 id；没有则返回 nil。
function overlay.tray_poll()
    if overlay._backend == nil or overlay._backend.tray_poll == nil then
        return nil
    end
    local ok, result = pcall(overlay._backend.tray_poll)
    if not ok then
        overlay._last_error = tostring(result)
        return nil
    end
    return result
end

function overlay.tray_is_visible()
    if overlay._backend == nil or overlay._backend.tray_is_visible == nil then
        return false
    end
    local ok, result = pcall(overlay._backend.tray_is_visible)
    if not ok then
        return false
    end
    return result == true
end

-- 生命周期钩子（在 love.quit 中调用）：移除托盘图标等清理。
-- 固定返回 false —— love.quit 返回 true 会取消退出。
function overlay.on_quit()
    tray_hide()
    return false
end

-- 调试：在最外围绘制窗口区域边框（宽 5、红 {1,0,0,1}）。跨平台，供开发期定位
-- 窗口范围；颜色不要与透明颜色键（洋红）相同，否则会被当作透明。
function overlay.set_draw_debug_border(enabled)
    overlay._draw_debug_border = not not enabled
    return true
end

-- 生命周期钩子（在 love.draw 末尾调用）：绘制所有调试内容（目前为边框）。
-- 无 love.graphics（如 busted）或未启用时安全返回 false。
function overlay.on_draw()
    local g = love and love.graphics
    if g == nil or not overlay._draw_debug_border then return false end
    local w, h = g.getWidth(), g.getHeight()
    local r, gg, b, a = g.getColor()
    g.setColor(1, 0, 0, 1)
    g.rectangle("fill", 0, 0, w, 5)
    g.rectangle("fill", 0, h - 5, w, 5)
    g.rectangle("fill", 0, 0, 5, h)
    g.rectangle("fill", w - 5, 0, 5, h)
    g.setColor(r, gg, b, a)
    return true
end

-- set_config accepts BOTH the documented capability vocabulary
-- (transparency/on_top/click_through/transparent_click_through/skip_taskbar) and the internal config keys
-- (transparent/...) so a consumer is never silently no-op'd. Unknown/empty
-- tables return false instead of pretending success.
function overlay.set_config(t)
    if type(t) ~= "table" then
        overlay._last_error = "set_config expects a table"
        return false
    end
    local recognized = false
    local result = true
    local transparent = t.transparency
    if transparent == nil then transparent = t.transparent end
    if transparent ~= nil then
        recognized = true
        result = overlay.set_transparent(transparent) and result
    end
    if t.on_top ~= nil then
        recognized = true
        result = overlay.set_on_top(t.on_top) and result
    end
    if t.click_through ~= nil then
        recognized = true
        result = overlay.set_click_through(t.click_through) and result
    end
    if t.transparent_click_through ~= nil then
        recognized = true
        result = overlay.set_transparent_click_through(t.transparent_click_through) and result
    end
    if t.skip_taskbar ~= nil then
        recognized = true
        result = overlay.set_skip_taskbar(t.skip_taskbar) and result
    end
    if not recognized then
        overlay._last_error = "set_config: no recognized keys"
        return false
    end
    return result
end

return overlay
