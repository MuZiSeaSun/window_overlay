local fake = {}
fake.capabilities = {
    transparency = true,
    on_top = true,
    click_through = true,
    transparent_click_through = true,
    skip_taskbar = true,
}
fake.calls = {}
fake.fail_on = nil   -- capability name causing failure
fake.throw_on = nil  -- capability name causing throw
fake.transparency_color = {1, 0, 1}
fake.focused = false -- whether is_focused() reports the window as focused
fake.drag_active = false -- whether update_drag() reports an ongoing drag
fake.tray_action = nil -- value returned by tray_poll()
fake.tray_visible = false -- value returned by tray_is_visible()

local function record(name, enabled)
    table.insert(fake.calls, {name = name, enabled = enabled})
end

local function handle(cap, enabled)
    record(cap, enabled)
    if fake.throw_on == cap then error("boom:" .. cap) end
    if fake.fail_on == cap then return false, "failed:" .. cap end
    return true
end

function fake.set_transparent(hwnd, enabled) return handle("transparency", enabled) end
function fake.set_on_top(hwnd, enabled) return handle("on_top", enabled) end
function fake.set_click_through(hwnd, enabled) return handle("click_through", enabled) end
function fake.set_transparent_click_through(hwnd, enabled) return handle("transparent_click_through", enabled) end
function fake.set_skip_taskbar(hwnd, enabled) return handle("skip_taskbar", enabled) end

function fake.is_focused(hwnd) return fake.focused end

function fake.begin_drag(hwnd)
    table.insert(fake.calls, {name = "begin_drag"})
    return true
end

function fake.update_drag(hwnd)
    table.insert(fake.calls, {name = "update_drag"})
    return fake.drag_active
end

function fake.end_drag(hwnd)
    table.insert(fake.calls, {name = "end_drag"})
    return true
end

function fake.tray_show(opts)
    table.insert(fake.calls, {name = "tray_show"})
    return true
end

function fake.tray_hide()
    table.insert(fake.calls, {name = "tray_hide"})
    return true
end

function fake.tray_poll()
    local action = fake.tray_action
    fake.tray_action = nil
    return action
end

function fake.tray_is_visible()
    return fake.tray_visible
end

function fake.reset()
    fake.calls = {}
    fake.fail_on = nil
    fake.throw_on = nil
    fake.focused = false
    fake.drag_active = false
    fake.tray_action = nil
    fake.tray_visible = false
end

return fake
