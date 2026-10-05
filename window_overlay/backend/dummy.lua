-- dummy backend: 用于不支持 FFI 或未知平台，所有能力都不支持。
local dummy = {}

dummy.capabilities = {
    transparency = false,
    on_top = false,
    click_through = false,
    transparent_click_through = false,
    skip_taskbar = false,
}

local function unsupported()
    return false, "unsupported on this platform"
end

function dummy.set_transparent(hwnd, enabled) return unsupported() end
function dummy.set_on_top(hwnd, enabled) return unsupported() end
function dummy.set_click_through(hwnd, enabled) return unsupported() end
function dummy.set_transparent_click_through(hwnd, enabled) return unsupported() end
function dummy.set_skip_taskbar(hwnd, enabled) return unsupported() end

return dummy
