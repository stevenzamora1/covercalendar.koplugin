--[[
    CoverCalendar – a KOReader plugin
    Shows a monthly reading-stats calendar where each book span is represented
    by a mini cover image instead of a coloured title bar.

    Settings (stored in G_reader_settings):
        covercalendar_start_dow   (int)   – 1=Sun … 7=Sat  (default 2 = Mon)

    Accessible via:  Menu → Tools → Cover Calendar
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager        = require("ui/uimanager")
local InfoMessage      = require("ui/widget/infomessage")
local DataStorage      = require("datastorage")
local Dispatcher        = require("dispatcher")
local logger           = require("logger")
local _ = require("gettext")

local CoverCalendarView = require("covercalendarview")

local CoverCalendar = WidgetContainer:extend{
    name = "covercalendar",
}

-- ── Plugin lifecycle ──────────────────────────────────────────────────────────

-- IMPORTANT: SimpleUI's Quick Actions picker (and KOReader's own gesture /
-- profile / quick-menu pickers in general) pull their list of assignable
-- actions from the Dispatcher registry, NOT from addToMainMenu(). A plugin
-- that only calls registerToMainMenu() will show up fine in Menu → Tools,
-- but is structurally invisible to any "pick an action" UI elsewhere —
-- which is why Cover Calendar wasn't appearing as a Quick Action option.
-- This mirrors exactly how KOReader's own statistics.koplugin registers
-- its built-in calendar (see plugins/statistics.koplugin/main.lua).
function CoverCalendar:onDispatcherRegisterActions()
    Dispatcher:registerAction("covercalendar_open", {
        category = "none",
        event    = "OpenCoverCalendar",
        title    = _("Open Cover Calendar"),
        general  = true,
    })
end

function CoverCalendar:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

-- Handler for the Dispatcher-registered "OpenCoverCalendar" event.
function CoverCalendar:onOpenCoverCalendar()
    self:openCalendar()
end

-- ── Main-menu entry ───────────────────────────────────────────────────────────

function CoverCalendar:addToMainMenu(menu_items)
    menu_items.cover_calendar = {
        text = _("Cover Calendar"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Open Cover Calendar"),
                callback = function()
                    self:openCalendar()
                end,
            },
            {
                text = _("Calendar style"),
                sub_item_table = {
                    -- ── Cover size ───────────────────────────────────────
                    {
                        text = _("Cover size: Compact"),
                        checked_func = function()
                            return (G_reader_settings:readSetting("covercalendar_cover_size") or "compact") == "compact"
                        end,
                        callback = function(touchmenu_instance)
                            G_reader_settings:saveSetting("covercalendar_cover_size", "compact")
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Cover size: Cozy"),
                        checked_func = function()
                            return (G_reader_settings:readSetting("covercalendar_cover_size") or "compact") == "cozy"
                        end,
                        callback = function(touchmenu_instance)
                            G_reader_settings:saveSetting("covercalendar_cover_size", "cozy")
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        keep_menu_open = true,
                        separator = true,
                    },
                    -- ── Stacked covers ───────────────────────────────────
                    {
                        text_func = function()
                            local on = G_reader_settings:nilOrTrue("covercalendar_stack_covers")
                            return on and _("Stacked covers: ON") or _("Stacked covers: OFF")
                        end,
                        callback = function(touchmenu_instance)
                            local current = G_reader_settings:nilOrTrue("covercalendar_stack_covers")
                            G_reader_settings:saveSetting("covercalendar_stack_covers", not current)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        keep_menu_open = true,
                    },
                    -- ── Reading time on cells ────────────────────────────
                    {
                        text_func = function()
                            local on = G_reader_settings:isTrue("covercalendar_cell_time")
                            return on and _("Reading time on cells: ON") or _("Reading time on cells: OFF")
                        end,
                        callback = function(touchmenu_instance)
                            local current = G_reader_settings:isTrue("covercalendar_cell_time")
                            G_reader_settings:saveSetting("covercalendar_cell_time", not current)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        keep_menu_open = true,
                        separator = true,
                    },
                    -- ── Today's cell color ───────────────────────────────
                    {
                        text = _("Today color: None"),
                        checked_func = function()
                            return (G_reader_settings:readSetting("covercalendar_today_color") or "none") == "none"
                        end,
                        callback = function(touchmenu_instance)
                            G_reader_settings:saveSetting("covercalendar_today_color", "none")
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Today color: Orange"),
                        checked_func = function()
                            return G_reader_settings:readSetting("covercalendar_today_color") == "orange"
                        end,
                        callback = function(touchmenu_instance)
                            G_reader_settings:saveSetting("covercalendar_today_color", "orange")
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Today color: Red"),
                        checked_func = function()
                            return G_reader_settings:readSetting("covercalendar_today_color") == "red"
                        end,
                        callback = function(touchmenu_instance)
                            G_reader_settings:saveSetting("covercalendar_today_color", "red")
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Today color: Blue"),
                        checked_func = function()
                            return G_reader_settings:readSetting("covercalendar_today_color") == "blue"
                        end,
                        callback = function(touchmenu_instance)
                            G_reader_settings:saveSetting("covercalendar_today_color", "blue")
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Today color: Green"),
                        checked_func = function()
                            return G_reader_settings:readSetting("covercalendar_today_color") == "green"
                        end,
                        callback = function(touchmenu_instance)
                            G_reader_settings:saveSetting("covercalendar_today_color", "green")
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Today color: Gray"),
                        checked_func = function()
                            return G_reader_settings:readSetting("covercalendar_today_color") == "gray"
                        end,
                        callback = function(touchmenu_instance)
                            G_reader_settings:saveSetting("covercalendar_today_color", "gray")
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        keep_menu_open = true,
                        separator = true,
                    },
                },
            },
            {
                text = _("Month summary stats"),
                sub_item_table = {
                    {
                        text_func = function()
                            local on = G_reader_settings:isTrue("covercalendar_month_summary")
                            return on and _("Show summary header: ON") or _("Show summary header: OFF")
                        end,
                        callback = function(touchmenu_instance)
                            local current = G_reader_settings:isTrue("covercalendar_month_summary")
                            G_reader_settings:saveSetting("covercalendar_month_summary", not current)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        keep_menu_open = true,
                        separator = true,
                    },
                    {
                        text = _("Total hours read"),
                        checked_func = function()
                            return G_reader_settings:nilOrTrue("covercalendar_stat_hours")
                        end,
                        callback = function(touchmenu_instance)
                            local current = G_reader_settings:nilOrTrue("covercalendar_stat_hours")
                            G_reader_settings:saveSetting("covercalendar_stat_hours", not current)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Daily average"),
                        checked_func = function()
                            return G_reader_settings:nilOrTrue("covercalendar_stat_daily_avg")
                        end,
                        callback = function(touchmenu_instance)
                            local current = G_reader_settings:nilOrTrue("covercalendar_stat_daily_avg")
                            G_reader_settings:saveSetting("covercalendar_stat_daily_avg", not current)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Total pages read"),
                        checked_func = function()
                            return G_reader_settings:nilOrTrue("covercalendar_stat_pages")
                        end,
                        callback = function(touchmenu_instance)
                            local current = G_reader_settings:nilOrTrue("covercalendar_stat_pages")
                            G_reader_settings:saveSetting("covercalendar_stat_pages", not current)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Days active"),
                        checked_func = function()
                            return G_reader_settings:nilOrTrue("covercalendar_stat_days_active")
                        end,
                        callback = function(touchmenu_instance)
                            local current = G_reader_settings:nilOrTrue("covercalendar_stat_days_active")
                            G_reader_settings:saveSetting("covercalendar_stat_days_active", not current)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Current streak"),
                        checked_func = function()
                            return G_reader_settings:nilOrTrue("covercalendar_stat_current_streak")
                        end,
                        callback = function(touchmenu_instance)
                            local current = G_reader_settings:nilOrTrue("covercalendar_stat_current_streak")
                            G_reader_settings:saveSetting("covercalendar_stat_current_streak", not current)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = _("Longest streak"),
                        checked_func = function()
                            return G_reader_settings:nilOrTrue("covercalendar_stat_longest_streak")
                        end,
                        callback = function(touchmenu_instance)
                            local current = G_reader_settings:nilOrTrue("covercalendar_stat_longest_streak")
                            G_reader_settings:saveSetting("covercalendar_stat_longest_streak", not current)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        keep_menu_open = true,
                    },
                },
            },
            {
                text = _("Week starts on Monday"),
                checked_func = function()
                    local dow = G_reader_settings:readSetting("covercalendar_start_dow") or 2
                    return dow == 2
                end,
                callback = function(touchmenu_instance)
                    G_reader_settings:saveSetting("covercalendar_start_dow", 2)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                keep_menu_open = true,
            },
            {
                text = _("Week starts on Sunday"),
                checked_func = function()
                    local dow = G_reader_settings:readSetting("covercalendar_start_dow") or 2
                    return dow == 1
                end,
                callback = function(touchmenu_instance)
                    G_reader_settings:saveSetting("covercalendar_start_dow", 1)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                keep_menu_open = true,
            },
        },
    }
end

-- ── Open the calendar ─────────────────────────────────────────────────────────

function CoverCalendar:openCalendar()
    -- Make sure the statistics plugin DB is available
    local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local lfs = require("libs/libkoreader-lfs")
    if not lfs.attributes(db_path, "mode") then
        UIManager:show(InfoMessage:new{
            text = _("No reading statistics database found.\nPlease enable the Statistics plugin and read some books first."),
        })
        return
    end

    local start_dow     = G_reader_settings:readSetting("covercalendar_start_dow") or 2
    local cover_size    = G_reader_settings:readSetting("covercalendar_cover_size") or "compact"
    local stack_covers  = G_reader_settings:nilOrTrue("covercalendar_stack_covers")
    local month_summary = G_reader_settings:isTrue("covercalendar_month_summary")
    local cell_time     = G_reader_settings:isTrue("covercalendar_cell_time")
    local today_color_id  = G_reader_settings:readSetting("covercalendar_today_color") or "none"

    local stat_toggles = {
        hours       = G_reader_settings:nilOrTrue("covercalendar_stat_hours"),
        daily_avg   = G_reader_settings:nilOrTrue("covercalendar_stat_daily_avg"),
        pages       = G_reader_settings:nilOrTrue("covercalendar_stat_pages"),
        days_active = G_reader_settings:nilOrTrue("covercalendar_stat_days_active"),
        current_streak = G_reader_settings:nilOrTrue("covercalendar_stat_current_streak"),
        longest_streak = G_reader_settings:nilOrTrue("covercalendar_stat_longest_streak"),
    }

    local view = CoverCalendarView:new{
        db_path       = db_path,
        start_dow     = start_dow,
        cover_size    = cover_size,
        stack_covers  = stack_covers,
        month_summary = month_summary,
        cell_time     = cell_time,
        today_color_id  = today_color_id,
        stat_toggles  = stat_toggles,
    }
    UIManager:show(view)
end

return CoverCalendar
