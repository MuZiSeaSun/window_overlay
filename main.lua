local overlay = require "window_overlay"

local image
local handle

-- 拖动区域：使用者自定义的任意矩形（窗口坐标）。这里把 res/drag_handle.png
-- 按原大小（1x）绘制（相对窗口中心偏 (+80, -80)），并把该矩形交给库作为拖动区域。
-- 注意区域必须落在不透明像素上（颜色键透明区会把点击穿透）。
local function drag_rect()
    local hw, hh = handle:getDimensions()
    local x = (love.graphics.getWidth() - hw) / 2 + 80
    local y = (love.graphics.getHeight() - hh) / 2 - 80
    return x, y, hw, hh
end

function love.load()

    overlay.init()
    overlay.set_transparent(true)
    overlay.set_on_top(true)
    -- 只让透明（颜色键命中的）区域穿透鼠标；精灵保持可点击。
    overlay.set_transparent_click_through(true)
    overlay.set_skip_taskbar(true)

    -- Windows 用分层窗口颜色键实现透明：把背景清成该键色，
    -- 平滑透明才会生效（非颜色键平台 key 为 nil）。
    local key = overlay.get_transparency_color()
    if key then
        love.graphics.setBackgroundColor(key[1], key[2], key[3])
    end

    image = love.graphics.newImage("res/flower.png")
    -- 整数倍放大（2x）用 nearest 过滤：避免线性插值在边缘产生半透明像素，
    -- 否则它们与颜色键背景混合会留下洋红描边。
    image:setFilter("nearest", "nearest")

    handle = love.graphics.newImage("res/drag_handle.png")

    -- 把拖动区域交给库；并打开调试边框（最外围 5px）。
    overlay.set_drag_region(drag_rect())
    overlay.set_draw_debug_border(true)

    -- 系统托盘：常驻图标（res/icon.png），右键弹菜单，菜单里只有「关闭」。
    local icon
    local ok_icon, icon_data = pcall(love.image.newImageData, "res/flower.png")
    if ok_icon and icon_data then
        local iw, ih = icon_data:getDimensions()
        icon = { iw, ih, icon_data:getString() }
    end
    overlay.tray_show{
        icon = icon,
        tooltip = "window_overlay",
        menu = { { id = "close", label = "关闭" } },
    }
end

function love.draw()
    local sx, sy = 2, 2
    local x = (love.graphics.getWidth() - image:getWidth() * sx) / 2
    local y = (love.graphics.getHeight() - image:getHeight() * sy) / 2
    love.graphics.draw(image, x, y, 0, sx, sy)

    -- 拖动把手：原大小绘制（相对中心偏 (+80, -80)）。
    local hx, hy = drag_rect()
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(handle, hx, hy)

    -- 库的调试绘制入口（调试边框）。
    overlay.on_draw()
end

function love.mousepressed(x, y, button)
    overlay.on_mousepressed(x, y, button)
end

function love.mousereleased(x, y, button)
    overlay.on_mousereleased(x, y, button)
end

-- 焦点变化（例如点击后方窗口使其激活）后重申置顶
function love.focus(f)
    overlay.on_focus(f)
end

-- 置顶守卫 + 拖动跟随由库统一处理。
function love.update(dt)
    overlay.on_update(dt)
    -- 处理托盘菜单动作（暂时保持现状）
    local action = overlay.tray_poll()
    if action == "close" then
        love.event.quit()
    end
end

function love.quit()
    overlay.on_quit()
end
