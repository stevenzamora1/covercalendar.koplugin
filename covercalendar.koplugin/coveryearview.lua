--[[
    coveryearview.lua  (v3)

    Year-in-books overview for the CoverCalendar plugin, in the same flat
    design language as the monthly calendar.

    v3 changes:
      - UNIFORM row heights (dynamic heights removed): every visible month
        row gets an equal share of the vertical space.
      - Page layouts: show all 12 months, 6 at a time, or 4 at a time.
        The "12M/6M" button (top-right, next to Back) cycles the layout
        in-place; the default layout comes from settings. Fewer months per
        page = taller rows = bigger covers.
      - ‹ › arrows (and swipes) page through month chunks and ROLL ACROSS
        YEARS: paging forward from Jul–Dec lands on Jan–Jun of next year.
        In 12-month layout that degenerates to plain year navigation.
      - Opens on the chunk containing the month the calendar was showing.
      - Per-year data cache: the DB query + sidecar "finished" scans run
        once per year per view session, not on every page flip.
      - Two time-read formats available as separate stats:
        "time" = hours+minutes, "time_days" = days+hours.

    Finished detection lives in coverutil.lua (sidecar completion date
    first; otherwise only MEANINGFUL sessions — ≥5 min or ≥5 pages — can
    set the finish month, so briefly reopening a finished book never
    re-files it).
--]]

local Blitbuffer      = require("ffi/blitbuffer")
local Button          = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local Screen          = Device.screen
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local logger          = require("logger")
local _ = require("gettext")

local CoverUtil = require("coverutil")

-- ── Constants (mirrors covercalendarview.lua) ─────────────────────────────────
local YEAR_BIG_SIZE  = 30
local YEAR_LBL_SIZE  = 12
local STAT_VAL_SIZE  = 21
local STAT_LBL_SIZE  = 9
local MONTH_LBL_SIZE = 12
local CHIP_SIZE      = 8
local COVER_ASPECT   = 0.68   -- cover width as a fraction of its height

local LAYOUTS = { [12]=true, [6]=true }
local NEXT_LAYOUT = { [12]=6, [6]=12 }

-- ── DB: whole-year aggregates + per-book session lists ────────────────────────
-- Same lua-ljsqlite3 binding + column-major result handling as the monthly
-- view (see covercalendarview.lua for the full rationale).
local function loadYearData(db_path, year)
    local agg = {
        total_secs = 0,
        total_pages = 0,
        days = {},          -- set of "YYYY-MM-DD"
        books = {},         -- [book_id] = {title, authors, pages,
                            --   total_read_pages, sessions={ {ds,dur,pages_today}, ...asc }}
    }

    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok or not SQ3 then
        logger.warn("CoverCalendar(year): require('lua-ljsqlite3/init') failed")
        return agg
    end
    local ok2, conn = pcall(SQ3.open, db_path)
    if not ok2 or not conn then
        logger.warn("CoverCalendar(year): SQ3.open failed for", db_path)
        return agg
    end

    local t0 = os.time{year=year,   month=1, day=1, hour=0,  min=0,  sec=0}
    local t1 = os.time{year=year+1, month=1, day=0, hour=23, min=59, sec=59}

    local sql = string.format([[
        SELECT
            strftime('%%Y-%%m-%%d', psd.start_time, 'unixepoch', 'localtime') AS ds,
            b.id AS book_id,
            b.title AS title,
            b.authors AS authors,
            b.pages AS pages,
            b.total_read_pages AS total_read_pages,
            SUM(psd.duration) AS dur,
            COUNT(DISTINCT psd.page) AS pages_today
        FROM page_stat_data psd
        JOIN book b ON b.id = psd.id_book
        WHERE psd.start_time >= %d AND psd.start_time <= %d
        GROUP BY b.id, ds
        ORDER BY ds ASC
    ]], t0, t1)

    local ok3, res = pcall(function() return conn:exec(sql) end)
    if not ok3 or not res then
        local sql2 = sql:gsub("page_stat_data", "page_stat")
        ok3, res = pcall(function() return conn:exec(sql2) end)
    end
    if not ok3 or not res or not res[1] then
        pcall(function() conn:close() end)
        return agg
    end

    -- column-major: 1=ds 2=book_id 3=title 4=authors 5=pages
    --               6=total_read_pages 7=dur 8=pages_today
    local n_rows = #res[1]
    logger.info("CoverCalendar(year): loadYearData got", n_rows, "rows for", year)
    for i = 1, n_rows do
        local ds  = res[1][i]
        local bid = tostring(res[2][i])
        local dur = tonumber(res[7] and res[7][i]) or 0
        local pt  = tonumber(res[8] and res[8][i]) or 0
        agg.days[ds] = true
        agg.total_secs  = agg.total_secs + dur
        agg.total_pages = agg.total_pages + pt
        local bk = agg.books[bid]
        if not bk then
            bk = {
                title   = res[3][i],
                authors = res[4] and res[4][i] or "",
                pages   = tonumber(res[5] and res[5][i]) or 0,
                total_read_pages = tonumber(res[6] and res[6][i]) or 0,
                sessions = {},
            }
            agg.books[bid] = bk
        else
            local trp = tonumber(res[6] and res[6][i])
            if trp and trp > (bk.total_read_pages or 0) then
                bk.total_read_pages = trp
            end
        end
        -- rows are ordered by ds, so sessions arrive already ascending
        table.insert(bk.sessions, {ds=ds, dur=dur, pages_today=pt})
    end

    pcall(function() conn:close() end)
    return agg
end

-- ── All-time streaks (duplicated from covercalendarview to stay standalone) ──
local function loadAllTimeStreaks(db_path)
    local result = { current = 0, longest = 0 }

    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok or not SQ3 then return result end
    local ok2, conn = pcall(SQ3.open, db_path)
    if not ok2 or not conn then return result end

    local sql = [[
        SELECT DISTINCT
            strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime') AS ds
        FROM page_stat_data
        ORDER BY ds ASC
    ]]
    local ok3, res = pcall(function() return conn:exec(sql) end)
    if not ok3 or not res then
        local sql2 = sql:gsub("page_stat_data", "page_stat")
        ok3, res = pcall(function() return conn:exec(sql2) end)
    end
    if not ok3 or not res or not res[1] then
        pcall(function() conn:close() end)
        return result
    end

    local days = res[1]
    local n = #days
    if n == 0 then
        pcall(function() conn:close() end)
        return result
    end

    local function toTimestamp(ds)
        local y, m, d = ds:match("(%d+)-(%d+)-(%d+)")
        if not y then return nil end
        return os.time{year=tonumber(y), month=tonumber(m), day=tonumber(d),
                       hour=0, min=0, sec=0}
    end

    local longest = 1
    local current_run = 1
    local prev_ts = toTimestamp(days[1])
    for i = 2, n do
        local ts = toTimestamp(days[i])
        if not ts or not prev_ts then break end
        local diff_days = math.floor((ts - prev_ts) / 86400 + 0.5)
        if diff_days == 1 then
            current_run = current_run + 1
            if current_run > longest then longest = current_run end
        else
            current_run = 1
        end
        prev_ts = ts
    end
    result.longest = longest

    local today_d = os.date("*t")
    local today_ts = os.time{year=today_d.year, month=today_d.month,
                             day=today_d.day, hour=0, min=0, sec=0}
    local streak = 0
    for i = n, 1, -1 do
        local ts = toTimestamp(days[i])
        if not ts then break end
        local diff = math.floor((today_ts - ts) / 86400 + 0.5)
        if diff == streak then
            streak = streak + 1
        elseif diff == streak + 1 and streak == 0 then
            streak = 1
        else
            break
        end
    end
    result.current = streak

    pcall(function() conn:close() end)
    return result
end

-- ── Month row widget ─────────────────────────────────────────────────────────
-- Flat white row: month label on the left, then the covers of books finished
-- that month, left-aligned. No bars, no borders — clear background like the
-- calendar grid.
local MonthRow = InputContainer:extend{
    width=0, height=0,
    month=1, label="",
    books=nil,           -- { {title=..., path=...}, ... } finished this month
    skip_covers=false,
    label_w=0,
    on_tap=nil,          -- function(month)
}

function MonthRow:init()
    local W = self.width
    local H = self.height
    local books = self.books or {}

    local LBL_W = self.label_w > 0 and self.label_w or Screen:scaleBySize(52)
    local INNER = Screen:scaleBySize(4)
    local cover_h = math.max(8, H - Screen:scaleBySize(6))
    local cover_w = math.max(8, math.floor(cover_h * COVER_ASPECT))

    local lbl_face  = Font:getFace("cfont", MONTH_LBL_SIZE)
    local chip_face = Font:getFace("cfont", CHIP_SIZE)

    local row_content = HorizontalGroup:new{ overlap=false }

    if not self.skip_covers and #books > 0 and cover_h > 12 then
        local avail = W - LBL_W - INNER
        local per = cover_w + INNER
        local max_covers = math.max(1, math.floor(avail / per))
        local shown = #books
        local plus_n = 0
        if #books > max_covers then
            shown = math.max(1, max_covers - 1)
            plus_n = #books - shown
        end

        for i = 1, shown do
            local b = books[i]
            local widget = b.path and CoverUtil.getCoverWidget(b.path, cover_w, cover_h)
            local boxed
            if widget then
                local ok_sz, sz = pcall(function() return widget:getSize() end)
                local ah = cover_h
                if ok_sz and sz and sz.h and sz.h > 0 then
                    ah = math.min(sz.h, cover_h)
                end
                boxed = FrameContainer:new{
                    padding=0, bordersize=0,
                    width=cover_w, height=cover_h,
                    CenterContainer:new{
                        dimen=Geom:new{w=cover_w, h=cover_h},
                        CenterContainer:new{
                            dimen=Geom:new{w=cover_w, h=ah},
                            widget,
                        },
                    },
                }
            else
                -- Fallback chip: abbreviated title (covers deleted books too)
                boxed = FrameContainer:new{
                    padding=2, bordersize=1, radius=Screen:scaleBySize(3),
                    width=cover_w, height=cover_h,
                    background=Blitbuffer.COLOR_WHITE,
                    CenterContainer:new{
                        dimen=Geom:new{w=cover_w-4, h=cover_h-4},
                        TextWidget:new{
                            text=b.title:sub(1, 8), face=chip_face,
                            fgcolor=Blitbuffer.COLOR_BLACK,
                        },
                    },
                }
            end
            table.insert(row_content, boxed)
            table.insert(row_content, HorizontalSpan:new{width=INNER})
        end

        if plus_n > 0 then
            table.insert(row_content, TextWidget:new{
                text="+" .. plus_n, bold=true,
                face=Font:getFace("cfont", MONTH_LBL_SIZE),
                fgcolor=Blitbuffer.COLOR_BLACK,
            })
        end
    end

    self[1] = FrameContainer:new{
        width=W, height=H, padding=0, bordersize=0,
        background=Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{ overlap=false,
            CenterContainer:new{
                dimen=Geom:new{w=LBL_W, h=H},
                TextWidget:new{
                    text=self.label, bold=true, face=lbl_face,
                    fgcolor=Blitbuffer.COLOR_BLACK,
                },
            },
            LeftContainer:new{
                dimen=Geom:new{w=W - LBL_W, h=H},
                row_content,
            },
        },
    }

    -- Same eager-dimen + closure-range pattern as DayCell (see
    -- covercalendarview.lua for why this is required pre-first-paint).
    self.dimen = Geom:new{x=0, y=0, w=W, h=H}
    local self_ref = self
    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges="tap",
                range=function() return self_ref.dimen end,
            }
        }
    }
end

function MonthRow:onTap()
    if self.on_tap then self.on_tap(self.month) end
    return true
end

-- ── Yearly overview view ─────────────────────────────────────────────────────
local CoverYearView = InputContainer:extend{
    db_path        = "",
    year           = 0,
    month          = 0,     -- month the calendar was showing (picks first chunk)
    title_path_map = nil,
    year_stats     = nil,   -- {stat_id, stat_id, stat_id}
    months_per_page = 12,   -- 12 or 6 (default from settings; legacy 4 → 12)
    read_min_secs  = 300,   -- Read-mode minimum time per month (settings)
    on_month_tap   = nil,   -- function(year, month)
}

function CoverYearView:init()
    local now = os.date("*t")
    self.year = (self.year ~= 0) and self.year or now.year
    local m0 = (self.month and self.month ~= 0) and self.month or now.month
    if not LAYOUTS[self.months_per_page] then self.months_per_page = 12 end
    self.show_mode = "finished"   -- "finished" | "read"; always opens on Finished
    if type(self.read_min_secs) ~= "number" or self.read_min_secs < 0 then
        self.read_min_secs = 300
    end
    -- Open on the chunk containing the month the calendar was showing
    self.page = math.ceil(m0 / self.months_per_page)
    self.year_stats = self.year_stats or {"books", "pages", "time"}
    self.title_path_map = self.title_path_map or CoverUtil.buildTitlePathMap()

    -- Per-session caches: the year bundle (DB query + sidecar scans) is
    -- computed once per year, and the all-time streak scan once total.
    self._year_cache = {}
    self._streaks = nil

    self.ges_events = {
        Swipe = {
            GestureRange:new{
                ges="swipe",
                range=Geom:new{x=0, y=0,
                    w=Screen:getWidth(), h=Screen:getHeight()},
            }
        },
    }

    -- Same two-phase strategy as the monthly view: when opened from the
    -- calendar the cover cache is normally already warm, so this almost
    -- always takes the single direct-build path.
    self._covers_loaded = false
    if CoverUtil.isCoverCacheWarm and CoverUtil.isCoverCacheWarm() then
        self._covers_loaded = true
        self:_build()
    else
        self:_build()
        local self_ref = self
        UIManager:tickAfterNext(function()
            if self_ref._covers_loaded == false then
                self_ref._covers_loaded = true
                self_ref:_build()
            end
        end)
    end
end

-- DB query + book classification, cached per year for this view session so
-- page flips and mode/layout toggles don't re-read sidecars.
-- Produces BOTH row sources:
--   months[m]      — books FINISHED in month m (sidecar date, else last
--                    meaningful session; see coverutil.lua)
--   read_months[m] — ALL books (finished or not) whose reading time WITHIN
--                    month m is at least read_min_secs. A book appears in
--                    every month it hits the minimum, so a brief peek can't
--                    put a book into a month.
function CoverYearView:_getYearBundle(year)
    local b = self._year_cache[year]
    if b then return b end

    local agg = loadYearData(self.db_path, year)

    local range_start = string.format("%04d-01-01", year)
    local range_end   = string.format("%04d-12-31", year)
    local months = {}
    local read_months = {}
    for m = 1, 12 do months[m] = {}; read_months[m] = {} end
    local books_finished, books_read = 0, 0

    for _, bk in pairs(agg.books) do
        books_read = books_read + 1

        -- Per-month reading time + last session day per month
        local month_dur, month_last_ds = {}, {}
        for _, s in ipairs(bk.sessions) do
            local mm = tonumber(s.ds:match("%d+-(%d+)-"))
            if mm then
                month_dur[mm] = (month_dur[mm] or 0) + (s.dur or 0)
                month_last_ds[mm] = s.ds   -- sessions are ascending
            end
        end

        local finished, path, sd = CoverUtil.getFinishedInfo(self.title_path_map, bk)

        -- Read mode: every book — finished or not — appears in each month
        -- where its in-month reading time meets the minimum.
        for mm = 1, 12 do
            if (month_dur[mm] or 0) >= self.read_min_secs then
                table.insert(read_months[mm], {
                    title = bk.title,
                    path  = path,
                    sort_ds = month_last_ds[mm],
                })
            end
        end

        if finished then
            -- Date the finish within this year, following the same rules as
            -- CoverUtil.finishedDateInRange (sidecar date is authoritative;
            -- otherwise the last MEANINGFUL session).
            local fds
            if sd then
                if sd >= range_start and sd <= range_end then fds = sd end
            else
                for i = #bk.sessions, 1, -1 do
                    local s = bk.sessions[i]
                    if (s.dur or 0) >= CoverUtil.MEANINGFUL_SECS
                       or (s.pages_today or 0) >= CoverUtil.MEANINGFUL_PAGES then
                        fds = s.ds
                        break
                    end
                end
            end
            if fds then
                local mm = tonumber(fds:match("%d+-(%d+)-"))
                if mm and months[mm] then
                    table.insert(months[mm], {
                        title = bk.title,
                        path  = path,
                        sort_ds = fds,
                    })
                    books_finished = books_finished + 1
                end
            end
        end
    end
    for m = 1, 12 do
        table.sort(months[m], function(x, y) return x.sort_ds < y.sort_ds end)
        table.sort(read_months[m], function(x, y) return x.sort_ds < y.sort_ds end)
    end

    local days_active = 0
    for _ in pairs(agg.days) do days_active = days_active + 1 end

    b = {
        agg = agg,
        months = months,
        read_months = read_months,
        books_finished = books_finished,
        books_read = books_read,
        days_active = days_active,
    }
    self._year_cache[year] = b
    return b
end

function CoverYearView:_build()
    local SW = Screen:getWidth()
    local SH = Screen:getHeight()

    local bundle = self:_getYearBundle(self.year)
    local agg    = bundle.agg
    local months = (self.show_mode == "read") and bundle.read_months
        or bundle.months

    -- ── Stats (always whole-year, independent of the visible chunk) ──────────
    local days_active = bundle.days_active
    local pages_per_day = (days_active > 0)
        and math.floor(agg.total_pages / days_active + 0.5) or 0
    local avg_mins = (days_active > 0)
        and math.floor(agg.total_secs / days_active / 60 + 0.5) or 0
    local hours = math.floor(agg.total_secs / 3600)
    local mins  = math.floor((agg.total_secs % 3600) / 60)
    local time_hm = (hours > 0)
        and string.format("%dh %dm", hours, mins)
        or  string.format("%dm", mins)
    -- days+hours variant; under a day it falls back to h/m ("0d" looks silly)
    local time_dh = (hours >= 24)
        and string.format("%dd %dh", math.floor(hours / 24), hours % 24)
        or  time_hm

    local slots = self.year_stats
    local needs_streaks = false
    for _, id in ipairs(slots) do
        if id == "current_streak" or id == "longest_streak" then
            needs_streaks = true
        end
    end
    if needs_streaks and not self._streaks then
        self._streaks = loadAllTimeStreaks(self.db_path)
    end
    local streaks = self._streaks or { current = 0, longest = 0 }

    local function statFor(id)
        if id == "books" then return tostring(bundle.books_finished), _("BOOKS")
        elseif id == "books_read" then return tostring(bundle.books_read), _("BOOKS READ")
        elseif id == "pages" then return tostring(agg.total_pages), _("PAGES")
        elseif id == "pages_per_day" then return tostring(pages_per_day), _("PAGES/DAY")
        elseif id == "time" then return time_hm, _("TIME READ")
        elseif id == "time_days" then return time_dh, _("TIME READ")
        elseif id == "avg_time" then return tostring(avg_mins) .. "m", _("MIN/DAY")
        elseif id == "days_active" then return tostring(days_active), _("DAYS ACTIVE")
        elseif id == "current_streak" then return tostring(streaks.current), _("STREAK")
        elseif id == "longest_streak" then return tostring(streaks.longest), _("BEST STREAK")
        end
        return "—", "?"
    end

    -- ── Visible chunk ────────────────────────────────────────────────────────
    local size = self.months_per_page
    local n_pages = math.floor(12 / size)
    if self.page < 1 then self.page = 1 end
    if self.page > n_pages then self.page = n_pages end
    local first_month = (self.page - 1) * size + 1
    local last_month  = first_month + size - 1

    local month_labels = {
        _("JAN"),_("FEB"),_("MAR"),_("APR"),_("MAY"),_("JUN"),
        _("JUL"),_("AUG"),_("SEP"),_("OCT"),_("NOV"),_("DEC"),
    }

    -- Small header label: "YEAR IN BOOKS" for the full year, or the visible
    -- month range ("JUL – DEC") when paging in 6/4-month layouts.
    local sub_label = (size == 12)
        and _("YEAR IN BOOKS")
        or  (month_labels[first_month] .. " – " .. month_labels[last_month])

    -- ── Header: small label over big year, arrows left, layout+Back right ────
    local LBL_H   = Screen:scaleBySize(20)
    local BIGY_H  = Screen:scaleBySize(44)
    local HDR_H   = LBL_H + BIGY_H + Screen:scaleBySize(8)
    local CORNER_H = LBL_H + Screen:scaleBySize(16)

    local header = OverlapGroup:new{
        dimen = Geom:new{w=SW, h=HDR_H},
        allow_mirroring = false,
        CenterContainer:new{
            dimen = Geom:new{w=SW, h=HDR_H},
            VerticalGroup:new{ overlap=false,
                CenterContainer:new{
                    dimen = Geom:new{w=SW, h=LBL_H},
                    TextWidget:new{
                        text=sub_label,
                        face=Font:getFace("cfont", YEAR_LBL_SIZE), bold=true,
                        fgcolor=Blitbuffer.COLOR_BLACK,
                    },
                },
                CenterContainer:new{
                    dimen = Geom:new{w=SW, h=BIGY_H},
                    TextWidget:new{
                        text=tostring(self.year),
                        face=Font:getFace("cfont", YEAR_BIG_SIZE), bold=true,
                        fgcolor=Blitbuffer.COLOR_BLACK,
                    },
                },
            },
        },
        -- Page-turn arrows top-left: previous / next chunk (rolls over years)
        FrameContainer:new{
            padding=0, padding_left=Screen:scaleBySize(6), bordersize=0,
            HorizontalGroup:new{ overlap=false,
                Button:new{
                    text="‹", bordersize=0,
                    padding=Screen:scaleBySize(8),
                    callback=function() self:_prevPage() end,
                },
                HorizontalSpan:new{width=Screen:scaleBySize(2)},
                Button:new{
                    text="›", bordersize=0,
                    padding=Screen:scaleBySize(8),
                    callback=function() self:_nextPage() end,
                },
            },
        },
        -- Top-right: Finished/Read toggle + layout toggle (12M ⇄ 6M) + Back
        RightContainer:new{
            dimen = Geom:new{w=SW - Screen:scaleBySize(6), h=CORNER_H},
            HorizontalGroup:new{ overlap=false,
                Button:new{
                    text=(self.show_mode == "read") and _("Read") or _("Finished"),
                    bordersize=0,
                    text_font_face="cfont",
                    text_font_size=16,
                    text_font_bold=true,
                    padding=Screen:scaleBySize(6),
                    callback=function() self:_toggleMode() end,
                },
                HorizontalSpan:new{width=Screen:scaleBySize(8)},
                Button:new{
                    text=tostring(size) .. "M", bordersize=0,
                    text_font_face="cfont",
                    text_font_size=16,
                    text_font_bold=true,
                    padding=Screen:scaleBySize(6),
                    callback=function() self:_cycleLayout() end,
                },
                HorizontalSpan:new{width=Screen:scaleBySize(8)},
                Button:new{
                    text=_("Back"), bordersize=0,
                    text_font_face="cfont",
                    text_font_size=16,
                    padding=Screen:scaleBySize(6),
                    callback=function() self:onClose() end,
                },
            },
        },
    }

    -- ── Stats row ────────────────────────────────────────────────────────────
    local val_face = Font:getFace("cfont", STAT_VAL_SIZE)
    local lbl_face = Font:getFace("cfont", STAT_LBL_SIZE)
    local VAL_H = Screen:scaleBySize(30)
    local SLBL_H = Screen:scaleBySize(15)
    local STATS_H = VAL_H + SLBL_H + Screen:scaleBySize(8)
    local col_w = math.floor(SW / 3)

    local function statBlock(val, lbl, w)
        return CenterContainer:new{
            dimen = Geom:new{w=w, h=STATS_H},
            VerticalGroup:new{ overlap=false,
                CenterContainer:new{
                    dimen = Geom:new{w=w, h=VAL_H},
                    TextWidget:new{
                        text=tostring(val), face=val_face, bold=true,
                        fgcolor=Blitbuffer.COLOR_BLACK,
                    },
                },
                CenterContainer:new{
                    dimen = Geom:new{w=w, h=SLBL_H},
                    TextWidget:new{
                        text=lbl, face=lbl_face, bold=true,
                        fgcolor=Blitbuffer.COLOR_BLACK,
                    },
                },
            },
        }
    end

    local stats_row = HorizontalGroup:new{ overlap=false }
    for i = 1, 3 do
        local w = (i == 3) and (SW - col_w*2) or col_w
        local val, lbl = statFor(slots[i])
        table.insert(stats_row, statBlock(val, lbl, w))
    end

    -- ── Month rows: UNIFORM heights across the visible chunk ─────────────────
    local GAP  = Screen:scaleBySize(4)
    local SIDE = Screen:scaleBySize(8)
    local LBL_W = Screen:scaleBySize(52)
    local rows_h = SH - HDR_H - GAP - STATS_H - GAP - GAP
    local row_h = math.floor(rows_h / size)
    local row_w = SW - SIDE * 2

    local self_ref = self
    local rows = VerticalGroup:new{ overlap=false }
    for m = first_month, last_month do
        table.insert(rows, MonthRow:new{
            width  = row_w,
            height = row_h,
            month  = m,
            label  = month_labels[m],
            label_w = LBL_W,
            books  = months[m],
            skip_covers = not self._covers_loaded,
            on_tap = function(month)
                local cb = self_ref.on_month_tap
                local y  = self_ref.year
                UIManager:close(self_ref, "full")
                if cb then cb(y, month) end
            end,
        })
    end

    -- ── Assemble ─────────────────────────────────────────────────────────────
    self[1] = FrameContainer:new{
        width=SW, height=SH, padding=0, bordersize=0,
        background=Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ overlap=false,
            header,
            VerticalSpan:new{height=GAP},
            stats_row,
            VerticalSpan:new{height=GAP},
            FrameContainer:new{
                padding=0, padding_left=SIDE, bordersize=0,
                rows,
            },
        },
    }

    if not self._covers_loaded then
        UIManager:setDirty(self, "full")
    else
        UIManager:setDirty(self, "ui")
    end
end

-- ── Paging (rolls across years) and layout cycling ────────────────────────────
function CoverYearView:_prevPage()
    local n_pages = math.floor(12 / self.months_per_page)
    self.page = self.page - 1
    if self.page < 1 then
        self.year = self.year - 1
        self.page = n_pages
    end
    self._covers_loaded = true
    self:_build()
end

function CoverYearView:_nextPage()
    local n_pages = math.floor(12 / self.months_per_page)
    self.page = self.page + 1
    if self.page > n_pages then
        self.year = self.year + 1
        self.page = 1
    end
    self._covers_loaded = true
    self:_build()
end

function CoverYearView:_toggleMode()
    self.show_mode = (self.show_mode == "finished") and "read" or "finished"
    self._covers_loaded = true
    self:_build()
end

function CoverYearView:_cycleLayout()
    -- Keep the first currently-visible month on screen across the switch
    local first_month = (self.page - 1) * self.months_per_page + 1
    self.months_per_page = NEXT_LAYOUT[self.months_per_page] or 12
    self.page = math.ceil(first_month / self.months_per_page)
    self._covers_loaded = true
    self:_build()
end

function CoverYearView:onSwipe(_, ges)
    if ges.direction == "left"  then self:_nextPage(); return true end
    if ges.direction == "right" then self:_prevPage(); return true end
end

function CoverYearView:onClose()
    self._covers_loaded = true
    UIManager:close(self, "full")
end

function CoverYearView:onShow()
    UIManager:setDirty(self, "full")
end

return CoverYearView
