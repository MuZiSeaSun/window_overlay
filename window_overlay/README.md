# window_overlay

桌面覆盖层窗口能力小库：让 LÖVE 窗口透明、置顶、鼠标穿透（整窗或仅透明区）、隐藏任务栏。

## 依赖

- LuaJIT（`ffi`）
- LÖVE（用于获取原生窗口句柄）

无其它依赖。

## 用法

```lua
local overlay = require "window_overlay"

function love.load()
    overlay.init()
    overlay.set_transparent(true)
    overlay.set_on_top(true)
    -- 只让透明区域穿透鼠标；精灵（不透明像素）保持可点击。
    overlay.set_transparent_click_through(true)
    overlay.set_skip_taskbar(true)

    -- Windows 用「分层窗口颜色键」实现透明，需把背景清成该键色，
    -- 否则背景会显示为洋红。非颜色键平台返回 nil。
    local key = overlay.get_transparency_color()
    if key then
        love.graphics.setBackgroundColor(key[1], key[2], key[3])
    end
end
```

开启 `set_transparent_click_through(true)` 后，透明像素穿透到下层窗口，不透明像素仍由本窗口接收点击；据此可用 `set_drag_region` 指定一个区域来拖动窗口（见后文与 `main.lua` 的 `on_mousepressed/on_mousereleased/on_update`）。若用 `set_click_through(true)` 则整窗穿透，精灵也无法点击。

## API

| 函数 | 说明 |
|---|---|
| `overlay.init() -> bool` | 检测平台并绑定当前窗口，返回是否成功 |
| `overlay.set_transparent(bool) -> bool` | 背景透明 |
| `overlay.set_on_top(bool) -> bool` | 置顶 |
| `overlay.set_click_through(bool) -> bool` | 整窗鼠标穿透（设置 `WS_EX_TRANSPARENT`） |
| `overlay.set_transparent_click_through(bool) -> bool` | 仅透明（颜色键命中的）像素穿透鼠标，其余像素仍可点击/拖动；需先开启 `set_transparent` |
| `overlay.set_skip_taskbar(bool) -> bool` | 隐藏任务栏/Dock/Alt-Tab |
| `overlay.is_supported(name) -> bool` | 查询平台能力 |
| `overlay.get_config() -> table` | 获取当前配置（拷贝） |
| `overlay.get_transparency_color() -> table\|nil` | 透明颜色键 `{r,g,b}`（0..1）；应用需把背景清成此色。非颜色键平台返回 `nil` |
| `overlay.set_config(t) -> bool` | 批量应用 |
| `overlay.get_last_error() -> string|nil` | 最近一次失败原因 |
| `overlay.get_handle()` | 原生窗口句柄 |
| `overlay.reassert_on_top() -> bool` | 立即重申置顶（`on_focus` 的底层实现） |
| `overlay.set_drag_region(x, y, w, h) -> bool` | 设置拖动区域（窗口坐标）；只有按在该矩形内才拖动 |
| `overlay.set_draw_debug_border(bool) -> bool` | 调试：在最外围绘制 5px 边框（红 `{1,0,0,1}`，四条填充矩形） |
| `overlay.tray_show(opts) -> bool` | 常驻系统托盘图标（仅 Windows）。`opts = { icon = {w,h,rgba}, tooltip = string, menu = { { id, label }, ... } }` |
| `overlay.tray_poll() -> string\|nil` | 取出托盘菜单被选中的动作 `id` |
| `overlay.tray_is_visible() -> bool` | 托盘图标当前是否已显示 |

生命周期钩子（在对应的 `love.*` 回调中调用）：

| 钩子 | 说明 |
|---|---|
| `overlay.on_update(dt)` | 置顶守卫 + 拖动跟随（在 `love.update` 中调用） |
| `overlay.on_draw()` | 绘制调试内容（调试边框；在 `love.draw` 末尾调用） |
| `overlay.on_focus(f)` | 焦点变化后立即重申置顶（在 `love.focus` 中调用） |
| `overlay.on_mousepressed(x, y, button)` | 命中拖动区域才开始拖动（在 `love.mousepressed` 中调用） |
| `overlay.on_mousereleased(x, y, button)` | 结束拖动（在 `love.mousereleased` 中调用） |
| `overlay.on_quit()` | 清理（移除托盘图标）；固定返回 `false`，勿让 `love.quit` 返回 `true`（会取消退出） |

`set_config(t)` 同时接受「能力名」和「配置键」，每个字段二选一即可：

| 能力名（推荐） | 等价配置键 |
|---|---|
| `transparency` | `transparent` |
| `on_top` | `on_top` |
| `click_through` | `click_through` |
| `transparent_click_through` | `transparent_click_through` |
| `skip_taskbar` | `skip_taskbar` |

若表中不含任何可识别的键（空表或未知键），`set_config` 返回 `false` 并设置
`get_last_error() == "set_config: no recognized keys"`，不会静默成功。

所有能力函数返回布尔值，永不抛错。无 FFI 的平台（`require("ffi")` 失败）会
回退到 dummy 后端，`init()` 返回 `false`，setter 均安全返回 `false`。

所有能力 setter 都接受可选的第二个参数 `force`：为 `true` 时跳过幂等缓存、强制再次应用到窗口。例如拖动窗口时 SDL 的 `setPosition` 会清掉 `WS_EX_TOPMOST`，可在移动后用 `overlay.set_on_top(true, true)` 重新置顶。

置顶守卫：系统/SDL 在切换焦点、移动窗口后可能清掉或改写窗口的置顶状态。把 `overlay.on_focus(f)` 接进 `love.focus`、把 `overlay.on_update(dt)` 接进 `love.update`，库会在焦点变化时立即、并在窗口失焦期间每 0.5s 重申一次置顶。失焦判定由后端 `is_focused()` 提供，目前仅 Windows 实现，其他平台该守卫为空操作。

```lua
function love.focus(f) overlay.on_focus(f) end
function love.update(dt) overlay.on_update(dt) end
```

窗口拖动：`set_drag_region(x,y,w,h)` 指定拖动区域（**由应用自定义**，通常是可见精灵图的矩形），`on_mousepressed` 命中该区域才开始拖动，`on_update` 用**轮询**（`GetCursorPos` + `GetAsyncKeyState` + `SetWindowPos`）跟随光标移动——快速拖动、光标移出窗口或落入颜色键透明区都不会中断；移动用 `SWP_NOZORDER`，不会清掉置顶。

```lua
overlay.set_drag_region(rx, ry, rw, rh) -- love.load 中，如把手精灵的矩形
function love.mousepressed(x, y, b)  overlay.on_mousepressed(x, y, b)  end
function love.mousereleased(x, y, b) overlay.on_mousereleased(x, y, b) end
```

注意拖动区域必须落在不透明像素上，否则点击会被颜色键穿透、收不到 `mousepressed`。仅 Windows 支持拖动，其它平台为空操作。

调试边框：`overlay.set_draw_debug_border(true)` 开启后，`overlay.on_draw()` 会在 love.draw 末尾用四条填充矩形在最外围画 5px 红框，用于定位窗口范围。跨平台；无 `love.graphics`（如 busted）时安全 no-op。边框颜色勿与透明颜色键（洋红）相同；Windows 上边框像素非颜色键色，会成为可见区域而不再穿透。

系统托盘（仅 Windows）：`tray_show` 常驻一个图标，右键弹出原生菜单；菜单选中项由 `tray_poll()` 取出（返回该项的 `id`），应用据此处理。图标用原始 RGBA8 传入（可由 `love.image.newImageData(path):getString()` 得到），省略则用系统通用图标。退出清理由 `on_quit()` 负责。

```lua
function love.load()
    local iw, ih, rgba
    local ok, data = pcall(love.image.newImageData, "res/icon.png")
    if ok and data then iw, ih = data:getDimensions(); rgba = data:getString() end
    overlay.tray_show{
        icon = rgba and { iw, ih, rgba } or nil,
        tooltip = "window_overlay",
        menu = { { id = "close", label = "关闭" } },
    }
end
function love.update(dt)
    overlay.on_update(dt)
    local action = overlay.tray_poll()
    if action == "close" then love.event.quit() end
end
function love.quit() overlay.on_quit() end
```

## 平台支持

下表与各后端源码中的 `capabilities` 声明一致。

| 能力 | Windows | macOS | Linux(X11) |
|---|---|---|---|
| transparency | 完整（分层窗口颜色键，见下） | 完整（需 ObjC runtime） | 不支持（透明由创建窗口时的 ARGB visual 决定，运行时不可切换） |
| on_top | 完整 | 完整 | 不支持（需要 `SDL_Window*`，库只能拿到 X11 XID） |
| click_through | 完整 | 完整 | 不支持（需要 X11 `Display*` 做 XShape） |
| transparent_click_through | 完整（需先开启 transparency） | 不支持 | 不支持（需要 XShape 输入区域） |
| skip_taskbar | 完整 | 尽力（推荐打包时设置 `LSUIElement`） | 不支持（需要 X11 `Display*`） |

说明：

- Windows 的透明基于「分层窗口 + 颜色键」：`set_transparent(true)` 把颜色键（洋红 `0xFF00FF`，即 `{1,0,1}`）设为全透明，应用必须用 `overlay.get_transparency_color()` 取到该色并 `love.graphics.setBackgroundColor` 清成同一个颜色，透明才生效；否则背景会显示为洋红。旧的 `DwmEnableBlurBehindWindow` 空区域玻璃技巧自 Windows 8 起不再产生透明，已弃用。
- Windows 的两种穿透模式：`transparent_click_through` 依赖分层窗口的逐像素命中测试（颜色键命中的像素穿透），`set_transparent_click_through(true)` 只确保存在 `WS_EX_LAYERED` 且清除 `WS_EX_TRANSPARENT`；而 `click_through` 会设置 `WS_EX_TRANSPARENT`，使整窗（含精灵）都穿透——两者同时为 `true` 时以整窗穿透为准。`set_transparent_click_through(false)` 无法关闭颜色键自身的逐像素穿透，返回 `true`。
- macOS 的四项能力均以成功加载 Objective-C runtime（`ok_objc`）为前提；`skip_taskbar` 运行时只是尽力而为，真正隐藏 Dock 图标需在打包时设置 `LSUIElement`。
- Linux 的 `on_top` 需要 `SDL_Window*`，而库只能获得 X11 的 `Window`（XID），因此不可用；`click_through`/`skip_taskbar` 需要 X11 的 `Display*`。
- Linux/Wayland 注意：即使 X11 下 XShape 等能力可用，Wayland 会话下应用通常运行在 XWayland 中，合成器可能忽略这些原生样式请求，实际效果不保证。
- 不支持的平台（无 FFI 或未知系统）回退到 dummy 后端，所有能力均为 `false`，调用安全返回 `false` 而不会抛错。
- `_get_handle()` 在非 Windows 平台目前只是骨架（尚未绑定 SDL2 窗口），所以 mac/Linux 上即使后端声明了能力，`init()` 也会因为拿不到句柄而返回 `false`。
- `get_config()` 反映的是「已成功应用」的缓存配置。`init()`（含窗口重建后的重新绑定）会把缓存重置为全 `false`，在重新应用样式之前 `get_config()` 会显示全 `false`，这属于预期行为。

## 测试

### 门面逻辑测试（busted）

门面逻辑用 [busted](https://lunarmodules.github.io/busted/) 编写，不需要真实窗口：

```powershell
cd lib/window_overlay
busted
```

- 用例在 `spec/`：`spec/facade_spec.lua`（假后端，覆盖能力查询、幂等、错误传播、`set_config`、无句柄/无 FFI 降级）。
- `spec/spec_helper.lua` 负责把 `window_overlay` 映射到库根的 `init.lua`。
- 依赖：LuaJIT + busted（`luarocks --lua-version 5.1 --lua-dir <luajit> install busted`）。

### Windows 后端真机冒烟（LÖVE）

需要真实窗口，用 LÖVE 把它当游戏目录运行：

```powershell
lovec.exe <repo>/lib/window_overlay
```

- `main.lua` + `conf.lua` 创建窗口，`tests/backend_smoke.lua` 断言 Win32 样式位。
- 通过时打印 `BACKEND SMOKE PASSED`。
