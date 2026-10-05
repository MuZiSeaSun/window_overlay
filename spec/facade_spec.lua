-- 门面逻辑测试（使用假后端，不需要真实窗口 / 平台后端）。
-- 运行：在 lib/window_overlay 目录下执行 `busted`。
local overlay = require "window_overlay"
local fake = require "support.fake_backend"

describe("window_overlay facade", function()
    before_each(function()
        fake.reset()
        overlay._config = {
            transparent = false,
            on_top = false,
            click_through = false,
            transparent_click_through = false,
            skip_taskbar = false,
        }
        overlay._last_error = nil
        overlay._backend = nil
        overlay._handle = nil
        overlay._topmost_timer = 0
        overlay._dragging = false
        overlay._drag_region = nil
        overlay._draw_debug_border = false
    end)

    describe("dummy backend (unsupported platform)", function()
        before_each(function()
            overlay._set_backend_for_test(require "window_overlay.backend.dummy")
        end)

        it("reports no capabilities", function()
            assert.is_falsy(overlay.is_supported("transparency"))
        end)

        it("never sets a capability and returns false", function()
            assert.is_falsy(overlay.set_transparent(true))
            assert.is_falsy(overlay.set_on_top(true))
            assert.is_falsy(overlay.set_click_through(true))
            assert.is_falsy(overlay.set_transparent_click_through(true))
            assert.is_falsy(overlay.set_skip_taskbar(true))
        end)

        it("records an error and leaves config unchanged", function()
            overlay.set_transparent(true)
            assert.is_not_nil(overlay.get_last_error())
            assert.is_falsy(overlay.get_config().transparent)
        end)

        it("has no transparency color key", function()
            assert.is_nil(overlay.get_transparency_color())
        end)
    end)

    describe("with a capable fake backend and a handle", function()
        before_each(function()
            overlay._set_backend_for_test(fake)
            overlay._handle = require("ffi").cast("void*", 1)
        end)

        it("forwards a set to the backend and updates config", function()
            assert.is_true(overlay.set_transparent(true))
            assert.are.equal(1, #fake.calls)
            assert.are.equal("transparency", fake.calls[1].name)
            assert.is_true(overlay.get_config().transparent)
        end)

        it("forwards transparent_click_through and updates config", function()
            assert.is_true(overlay.set_transparent_click_through(true))
            assert.are.equal(1, #fake.calls)
            assert.are.equal("transparent_click_through", fake.calls[1].name)
            assert.is_true(overlay.get_config().transparent_click_through)
        end)

        it("exposes the transparency color key as a copy", function()
            local c = overlay.get_transparency_color()
            assert.are.same({1, 0, 1}, c)
            c[1] = 0
            assert.are.same({1, 0, 1}, fake.transparency_color)
        end)

        it("is idempotent: same value does not call the backend again", function()
            overlay.set_transparent(true)
            overlay.set_transparent(true)
            assert.are.equal(1, #fake.calls)
        end)

        it("force bypasses idempotency and re-applies to the backend", function()
            overlay.set_on_top(true)
            assert.are.equal(1, #fake.calls)
            assert.is_true(overlay.set_on_top(true, true))
            assert.are.equal(2, #fake.calls)
            assert.are.equal("on_top", fake.calls[2].name)
        end)

        it("returns false and propagates the backend error on failure", function()
            fake.fail_on = "on_top"
            assert.is_falsy(overlay.set_on_top(true))
            assert.are.equal("failed:on_top", overlay.get_last_error())
        end)

        it("catches a throwing backend and returns false", function()
            fake.throw_on = "skip_taskbar"
            assert.is_falsy(overlay.set_skip_taskbar(true))
            assert.is_truthy(overlay.get_last_error():find("boom"))
        end)

        it("set_config applies known keys and calls the backend per key", function()
            assert.is_true(overlay.set_config({ click_through = true, on_top = true }))
            assert.are.equal(2, #fake.calls)
        end)

        it("set_config accepts transparent_click_through", function()
            assert.is_true(overlay.set_config({ transparent_click_through = true }))
            assert.are.equal(1, #fake.calls)
            assert.are.equal("transparent_click_through", fake.calls[1].name)
            assert.is_true(overlay.get_config().transparent_click_through)
        end)

        it("set_config accepts capability names", function()
            overlay.set_transparent(false)
            fake.reset()
            assert.is_true(overlay.set_config({ transparency = true }))
            assert.are.equal(1, #fake.calls)
            assert.are.equal("transparency", fake.calls[1].name)
            assert.is_true(overlay.get_config().transparent)
        end)
    end)

    describe("topmost re-assert guard", function()
        before_each(function()
            overlay._set_backend_for_test(fake)
            overlay._handle = require("ffi").cast("void*", 1)
        end)

        it("on_update is a no-op when on_top is disabled", function()
            overlay.on_update(1.0)
            assert.are.equal(0, #fake.calls)
        end)

        it("on_focus is a no-op when on_top is disabled", function()
            assert.is_falsy(overlay.on_focus())
            assert.are.equal(0, #fake.calls)
        end)

        it("on_focus re-asserts on_top through the backend", function()
            overlay._config.on_top = true
            assert.is_true(overlay.on_focus())
            assert.are.equal(1, #fake.calls)
            assert.are.equal("on_top", fake.calls[1].name)
            assert.is_true(fake.calls[1].enabled)
        end)

        it("on_update does not re-assert while the window is focused", function()
            overlay._config.on_top = true
            fake.focused = true
            overlay.on_update(1.0)
            assert.are.equal(0, #fake.calls)
        end)

        it("on_update re-asserts after the interval once unfocused", function()
            overlay._config.on_top = true
            fake.focused = false
            overlay.on_update(0.3)
            assert.are.equal(0, #fake.calls)
            overlay.on_update(0.3)
            assert.are.equal(1, #fake.calls)
            assert.are.equal("on_top", fake.calls[1].name)
        end)
    end)

    describe("window drag (lifecycle)", function()
        before_each(function()
            overlay._set_backend_for_test(fake)
            overlay._handle = require("ffi").cast("void*", 1)
            overlay.set_drag_region(0, 0, 10, 10)
        end)

        it("on_mousepressed inside the region begins a drag", function()
            overlay.on_mousepressed(5, 5, 1)
            assert.are.equal(1, #fake.calls)
            assert.are.equal("begin_drag", fake.calls[1].name)
            assert.is_true(overlay._dragging)
        end)

        it("on_mousepressed outside the region does nothing", function()
            overlay.on_mousepressed(50, 50, 1)
            assert.are.equal(0, #fake.calls)
            assert.is_falsy(overlay._dragging)
        end)

        it("on_mousepressed with a non-left button does nothing", function()
            overlay.on_mousepressed(5, 5, 2)
            assert.are.equal(0, #fake.calls)
            assert.is_falsy(overlay._dragging)
        end)

        it("on_update follows the drag, and ends it when the backend reports release", function()
            overlay.on_mousepressed(5, 5, 1)
            fake.reset()
            fake.drag_active = true
            overlay.on_update(0.016)
            assert.are.equal("update_drag", fake.calls[1].name)
            assert.is_true(overlay._dragging)
            fake.drag_active = false
            overlay.on_update(0.016)
            assert.is_falsy(overlay._dragging)
        end)

        it("on_mousereleased ends the drag", function()
            overlay.on_mousepressed(5, 5, 1)
            fake.reset()
            overlay.on_mousereleased(5, 5, 1)
            assert.are.equal(1, #fake.calls)
            assert.are.equal("end_drag", fake.calls[1].name)
            assert.is_falsy(overlay._dragging)
        end)
    end)

    describe("window drag on dummy backend", function()
        before_each(function()
            overlay._set_backend_for_test(require "window_overlay.backend.dummy")
            overlay._handle = require("ffi").cast("void*", 1)
            overlay.set_drag_region(0, 0, 10, 10)
        end)

        it("never starts a drag and does not throw", function()
            overlay.on_mousepressed(5, 5, 1)
            assert.is_falsy(overlay._dragging)
            overlay.on_update(0.016)
            overlay.on_mousereleased(5, 5, 1)
        end)
    end)

    describe("system tray", function()
        before_each(function()
            overlay._set_backend_for_test(fake)
        end)

        it("forwards tray_show to the backend", function()
            assert.is_true(overlay.tray_show({ tooltip = "t" }))
            assert.are.equal(1, #fake.calls)
            assert.are.equal("tray_show", fake.calls[1].name)
        end)

        it("on_quit hides the tray icon and returns false", function()
            overlay.tray_show({})
            fake.reset()
            assert.is_false(overlay.on_quit())
            assert.are.equal(1, #fake.calls)
            assert.are.equal("tray_hide", fake.calls[1].name)
        end)

        it("tray_poll returns the queued action", function()
            fake.tray_action = "close"
            assert.are.equal("close", overlay.tray_poll())
            assert.is_nil(overlay.tray_poll())
        end)

        it("tray_is_visible reflects the backend", function()
            fake.tray_visible = true
            assert.is_true(overlay.tray_is_visible())
        end)
    end)

    describe("system tray on dummy backend", function()
        before_each(function()
            overlay._set_backend_for_test(require "window_overlay.backend.dummy")
        end)

        it("is unsupported and returns false/nil without throwing", function()
            assert.is_falsy(overlay.tray_show({}))
            assert.is_nil(overlay.tray_poll())
            assert.is_falsy(overlay.tray_is_visible())
            assert.is_false(overlay.on_quit())
        end)
    end)

    describe("debug border", function()
        before_each(function()
            overlay._set_backend_for_test(fake)
            overlay._handle = require("ffi").cast("void*", 1)
        end)

        after_each(function()
            _G.love = nil
        end)

        it("set_draw_debug_border toggles the flag", function()
            assert.is_true(overlay.set_draw_debug_border(true))
            assert.is_true(overlay._draw_debug_border)
            assert.is_true(overlay.set_draw_debug_border(false))
            assert.is_falsy(overlay._draw_debug_border)
        end)

        it("on_draw is a no-op without love.graphics", function()
            _G.love = nil
            overlay.set_draw_debug_border(true)
            assert.is_falsy(overlay.on_draw())
        end)

        it("on_draw draws four filled rects when enabled", function()
            local rects = {}
            _G.love = {
                graphics = {
                    getWidth = function() return 500 end,
                    getHeight = function() return 500 end,
                    getColor = function() return 1, 1, 1, 1 end,
                    setColor = function() end,
                    rectangle = function(mode, x, y, w, h)
                        table.insert(rects, { mode = mode, x = x, y = y, w = w, h = h })
                    end,
                },
            }
            overlay.set_draw_debug_border(true)
            assert.is_true(overlay.on_draw())
            assert.are.equal(4, #rects)
            for _, r in ipairs(rects) do
                assert.are.equal("fill", r.mode)
            end
        end)

        it("on_draw does nothing when disabled", function()
            local rects = 0
            _G.love = {
                graphics = {
                    getWidth = function() return 500 end,
                    getHeight = function() return 500 end,
                    getColor = function() return 1, 1, 1, 1 end,
                    setColor = function() end,
                    rectangle = function() rects = rects + 1 end,
                },
            }
            overlay.set_draw_debug_border(false)
            assert.is_falsy(overlay.on_draw())
            assert.are.equal(0, rects)
        end)
    end)

    describe("input validation", function()
        before_each(function()
            overlay._set_backend_for_test(fake)
            overlay._handle = require("ffi").cast("void*", 1)
        end)

        it("set_config(nil) returns false and sets an error", function()
            assert.is_falsy(overlay.set_config(nil))
            assert.is_not_nil(overlay.get_last_error())
        end)

        it("set_config({}) returns false with a no-recognized-keys error", function()
            assert.is_falsy(overlay.set_config({}))
            assert.are.equal("set_config: no recognized keys", overlay.get_last_error())
        end)

        it("set_config with unknown keys returns false", function()
            assert.is_falsy(overlay.set_config({ bogus = true }))
            assert.are.equal("set_config: no recognized keys", overlay.get_last_error())
        end)
    end)

    describe("handle acquisition failure", function()
        local real_get_handle

        before_each(function()
            real_get_handle = overlay._get_handle
            overlay._get_handle = function() return nil end
        end)
        after_each(function()
            overlay._get_handle = real_get_handle
        end)

        it("init returns false and setters return false with no window handle", function()
            assert.is_falsy(overlay.init())
            -- Force the fake AFTER init (init re-detects the backend) so a backend
            -- call would be recorded if the no-handle guard failed.
            overlay._set_backend_for_test(fake)
            fake.reset()
            assert.is_falsy(overlay.set_transparent(true))
            assert.are.equal("no window handle", overlay.get_last_error())
            assert.are.equal(0, #fake.calls)
        end)
    end)

    describe("no-FFI platform", function()
        it("degrades to false without throwing", function()
            local real_require = require
            _G.require = function(name)
                if name == "ffi" then error("ffi unavailable (simulated no-FFI platform)") end
                return real_require(name)
            end
            local pcall_ok, init_result = pcall(overlay.init)
            _G.require = real_require

            assert.is_true(pcall_ok)
            assert.is_falsy(init_result)
            assert.are.equal("no window handle", overlay.get_last_error())
            assert.is_falsy(overlay.set_transparent(true))
            assert.are.equal("no window handle", overlay.get_last_error())
        end)
    end)
end)
