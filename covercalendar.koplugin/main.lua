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
local Updater = require("updater")

local PLUGIN_VERSION = "2.0.1"

local CoverCalendar = WidgetContainer:extend{
    name = "covercalendar",
}

-- ── Stat slot options (shared by the monthly header and yearly overview) ──────
-- "Books finished" uses the shared detection in coverutil.lua (sidecar
-- completion date first, else last meaningful session in the period).
-- "Books read" is simply every book with any reading session in the period.
local STAT_OPTIONS = {
    { id = "books",          label = _("Books finished") },
    { id = "books_read",     label = _("Books read") },
    { id = "pages",          label = _("Pages") },
    { id = "pages_per_day",  label = _("Pages/day") },
    { id = "time",           label = _("Time read (h/m)") },
    { id = "time_days",      label = _("Time read (d/h)") },
    { id = "avg_time",       label = _("Avg min/day") },
    { id = "days_active",    label = _("Days active") },
    { id = "current_streak", label = _("Current streak") },
    { id = "longest_streak", label = _("Longest streak") },
}

local function statPickerSubmenu(setting_key, default_id)
    local items = {}
    for _, opt in ipairs(STAT_OPTIONS) do
        table.insert(items, {
            text = opt.label,
            checked_func = function()
                return (G_reader_settings:readSetting(setting_key) or default_id) == opt.id
            end,
            callback = function(touchmenu_instance)
                G_reader_settings:saveSetting(setting_key, opt.id)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
            keep_menu_open = true,
        })
    end
    return items
end

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
    -- Install a previously-downloaded update FIRST: at this point the new
    -- files are not loaded yet, so overwriting them is safe (see updater.lua
    -- for why this cannot be done at download time). Guarded so a failure
    -- here can never stop the plugin from loading.
    if not CoverCalendar._update_checked then
        CoverCalendar._update_checked = true
        local ok, installed = pcall(Updater.applyStagedUpdate)
        if ok and installed then
            UIManager:nextTick(function()
                UIManager:show(InfoMessage:new{
                    text = string.format(
                        _("Cover Calendar updated to %s.\n\nRestart KOReader once more to load it."),
                        tostring(installed)),
                })
            end)
        end
    end

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

-- Handler for the Dispatcher-registered "OpenCoverCalendar" event.
function CoverCalendar:onOpenCoverCalendar()
    self:openCalendar()
end

-- ── Main-menu entry ───────────────────────────────────────────────────────────

function CoverCalendar:addToMainMenu(menu_items)
    -- Small radio-item helper to keep this menu readable: each entry is
    -- {value, label}; checked when the stored setting (or default) matches.
    local function radioItems(setting_key, default_val, entries)
        local items = {}
        for _, e in ipairs(entries) do
            table.insert(items, {
                text = e[2],
                checked_func = function()
                    local v = G_reader_settings:readSetting(setting_key)
                    if v == nil then v = default_val end
                    return v == e[1]
                end,
                callback = function(touchmenu_instance)
                    G_reader_settings:saveSetting(setting_key, e[1])
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                keep_menu_open = true,
            })
        end
        return items
    end

    menu_items.cover_calendar = {
        text = _("Cover Calendar"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Open Cover Calendar"),
                callback = function()
                    self:openCalendar()
                end,
                separator = true,
            },
            -- ── Everything about the monthly calendar in one place ─────────
            {
                text = _("Monthly calendar"),
                sub_item_table = {
                    {
                        text = _("Calendar style"),
                        sub_item_table = {
                            {
                                text = _("Cover size"),
                                sub_item_table = radioItems(
                                    "covercalendar_cover_size", "cozy", {
                                        {"compact", _("Compact")},
                                        {"cozy",    _("Cozy")},
                                    }),
                            },
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
                            {
                                text = _("Today color"),
                                sub_item_table = radioItems(
                                    "covercalendar_today_color", "none", {
                                        {"none",   _("None (default)")},
                                        {"orange", _("Orange")},
                                        {"red",    _("Red")},
                                        {"blue",   _("Blue")},
                                        {"green",  _("Green")},
                                        {"gray",   _("Gray")},
                                    }),
                            },
                        },
                    },
                    {
                        text = _("Stats"),
                        sub_item_table = {
                            {
                                text_func = function()
                                    local on = G_reader_settings:nilOrTrue("covercalendar_month_summary")
                                    return on and _("Show stats header: ON") or _("Show stats header: OFF")
                                end,
                                callback = function(touchmenu_instance)
                                    local current = G_reader_settings:nilOrTrue("covercalendar_month_summary")
                                    G_reader_settings:saveSetting("covercalendar_month_summary", not current)
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                                keep_menu_open = true,
                                separator = true,
                            },
                            {
                                text = _("First stat"),
                                sub_item_table = statPickerSubmenu("covercalendar_month_stat1", "books"),
                            },
                            {
                                text = _("Second stat"),
                                sub_item_table = statPickerSubmenu("covercalendar_month_stat2", "pages"),
                            },
                            {
                                text = _("Third stat"),
                                sub_item_table = statPickerSubmenu("covercalendar_month_stat3", "pages_per_day"),
                            },
                        },
                        separator = true,
                    },
                    {
                        text = _("Week starts on"),
                        sub_item_table = radioItems(
                            "covercalendar_start_dow", 2, {
                                {2, _("Monday")},
                                {1, _("Sunday")},
                            }),
                    },
                },
            },
            -- ── Everything about the yearly overview in one place ──────────
            {
                text = _("Yearly overview"),
                separator = true,
                sub_item_table = {
                    {
                        text = _("Stats"),
                        sub_item_table = {
                            {
                                text = _("First stat"),
                                sub_item_table = statPickerSubmenu("covercalendar_year_stat1", "books"),
                            },
                            {
                                text = _("Second stat"),
                                sub_item_table = statPickerSubmenu("covercalendar_year_stat2", "pages"),
                            },
                            {
                                text = _("Third stat"),
                                sub_item_table = statPickerSubmenu("covercalendar_year_stat3", "time"),
                            },
                        },
                        separator = true,
                    },
                    {
                        text = _("Default layout"),
                        sub_item_table = radioItems(
                            "covercalendar_year_layout", 12, {
                                {12, _("All 12 months")},
                                {6,  _("6 months at a time")},
                            }),
                    },
                    {
                        text = _("Read mode minimum time"),
                        help_text = _("In Read mode, a book appears in a month only if it was read at least this long within that month."),
                        sub_item_table = radioItems(
                            "covercalendar_read_min_secs", 300, {
                                {300,  _("5 minutes")},
                                {1800, _("30 minutes")},
                                {3600, _("1 hour")},
                            }),
                    },
                },
            },
            {
                text = _("About"),
                keep_menu_open = true,
                callback = function()
                    local ButtonDialog = require("ui/widget/buttondialog")
                    local Version = require("version")
                    local dialog
                    dialog = ButtonDialog:new{
                        title = string.format(
                            _("Cover Calendar %s\n\nA reading stats calendar that shows book covers instead of coloured title bars.\n\n%s\n\nKOReader %s"),
                            PLUGIN_VERSION,
                            Updater.RELEASE_URL,
                            tostring(Version:getCurrentRevision())),
                        title_align = "center",
                        buttons = {
                            {
                                {
                                    text = _("Check for updates"),
                                    callback = function()
                                        UIManager:close(dialog)
                                        Updater.checkForUpdates()
                                    end,
                                },
                            },
                            {
                                {
                                    text = _("Close"),
                                    callback = function()
                                        UIManager:close(dialog)
                                    end,
                                },
                            },
                        },
                    }
                    UIManager:show(dialog)
                end,
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
    local cover_size    = G_reader_settings:readSetting("covercalendar_cover_size") or "cozy"
    local stack_covers  = G_reader_settings:nilOrTrue("covercalendar_stack_covers")
    local month_summary = G_reader_settings:nilOrTrue("covercalendar_month_summary")
    local cell_time     = G_reader_settings:isTrue("covercalendar_cell_time")
    local today_color_id  = G_reader_settings:readSetting("covercalendar_today_color") or "none"


    local month_stats = {
        G_reader_settings:readSetting("covercalendar_month_stat1") or "books",
        G_reader_settings:readSetting("covercalendar_month_stat2") or "pages",
        G_reader_settings:readSetting("covercalendar_month_stat3") or "pages_per_day",
    }
    local year_layout = G_reader_settings:readSetting("covercalendar_year_layout") or 12
    if year_layout ~= 12 and year_layout ~= 6 then year_layout = 12 end
    local read_min_secs = G_reader_settings:readSetting("covercalendar_read_min_secs") or 300

    local year_stats = {
        G_reader_settings:readSetting("covercalendar_year_stat1") or "books",
        G_reader_settings:readSetting("covercalendar_year_stat2") or "pages",
        G_reader_settings:readSetting("covercalendar_year_stat3") or "time",
    }

    local view = CoverCalendarView:new{
        db_path       = db_path,
        start_dow     = start_dow,
        cover_size    = cover_size,
        stack_covers  = stack_covers,
        month_summary = month_summary,
        cell_time     = cell_time,
        today_color_id  = today_color_id,
        month_stats   = month_stats,
        year_stats    = year_stats,
        year_layout   = year_layout,
        read_min_secs = read_min_secs,
    }
    UIManager:show(view)
end

return CoverCalendar
