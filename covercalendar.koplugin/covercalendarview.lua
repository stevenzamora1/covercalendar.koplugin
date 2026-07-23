--[[
    covercalendarview.lua  (v4)

    Key fixes vs v3:
      - Cover lookup now delegates to SimpleUI's module_books_shared.getBookCover()
        (see coverutil.lua) since covers are embedded in the EPUBs themselves,
        not stored as sidecar files
      - DayCell takes a title->path map instead of title->cover-path map
      - Grid layout unchanged (already correct from v3)
--]]

local Blitbuffer      = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
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
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local Screen          = Device.screen
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Widget          = require("ui/widget/widget")
local logger          = require("logger")
local _ = require("gettext")

local CoverUtil = require("coverutil")

-- ── Constants ─────────────────────────────────────────────────────────────────
local PAD          = 2
local DAY_NUM_SIZE = 15
local TITLE_SIZE   = 8
local DOW_SIZE     = 11
local MONTH_SIZE   = 16       -- month/year picker dialog only
local MONTH_BIG_SIZE = 30     -- big month name in the header
local YEAR_SIZE      = 12     -- small year above the month name
local STAT_VAL_SIZE  = 21     -- big stat numbers (BOOKS / PAGES / PAGES/DAY)
local STAT_LBL_SIZE  = 9      -- small stat labels
local BORDER       = 1

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function daysInMonth(year, month)
    return os.date("*t", os.time{year=year, month=month+1, day=0}).day
end

local function firstWday(year, month)
    return os.date("*t", os.time{year=year, month=month, day=1}).wday  -- 1=Sun
end

local function wdayToCol(wday, start_dow)
    local offset = (start_dow == 2) and 1 or 0
    return (wday - 1 - offset + 7) % 7
end

-- ── DB ────────────────────────────────────────────────────────────────────────
-- KOReader's actual SQLite binding is lua-ljsqlite3 (require("lua-ljsqlite3/init")),
-- NOT luasql.sqlite3 or a generic "sqlite3" module — those don't exist on
-- stock KOReader, which is why every previous version of this function
-- silently returned an empty table. Confirmed against KOReader's own
-- statistics.koplugin/main.lua, which uses this exact same binding.
--
-- conn:exec(sql) returns a column-major result table: res[col_index] is an
-- array of values for that column, across all matched rows, plus res.nb
-- and res.ncol set on the returned table itself in some versions — so we
-- read row count from #res[1] (length of the first column's value array).
local function loadMonthData(db_path, year, month)
    local result = {}
    local logger = require("logger")

    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok or not SQ3 then
        logger.warn("CoverCalendar: require('lua-ljsqlite3/init') failed:", tostring(SQ3))
        return result
    end

    local ok2, conn = pcall(SQ3.open, db_path)
    if not ok2 or not conn then
        logger.warn("CoverCalendar: SQ3.open failed for", db_path, ":", tostring(conn))
        return result
    end

    -- One-time schema probe so we can see actual table/column names in
    -- crash.log if the main query below ever fails again.
    local ok_probe, probe = pcall(function()
        return conn:exec("SELECT name FROM sqlite_master WHERE type='table'")
    end)
    if ok_probe and probe and probe[1] then
        local names = {}
        for i = 1, #probe[1] do names[#names+1] = probe[1][i] end
        logger.info("CoverCalendar: DB tables found:", table.concat(names, ", "))
    end

    local t0 = os.time{year=year, month=month,   day=1,  hour=0,  min=0,  sec=0}
    local t1 = os.time{year=year, month=month+1, day=0,  hour=23, min=59, sec=59}

    local sql = string.format([[
        SELECT
            strftime('%%Y-%%m-%%d', psd.start_time, 'unixepoch', 'localtime') AS ds,
            b.title AS title,
            b.authors AS authors,
            b.series AS series,
            b.id AS book_id,
            SUM(psd.duration) AS dur,
            COUNT(DISTINCT psd.page) AS pages_today,
            b.pages AS pages,
            b.total_read_pages AS total_read_pages,
            MAX(psd.start_time) AS last_seen
        FROM page_stat_data psd
        JOIN book b ON b.id = psd.id_book
        WHERE psd.start_time >= %d AND psd.start_time <= %d
        GROUP BY b.id, ds
        ORDER BY ds, dur DESC
    ]], t0, t1)

    local ok3, res = pcall(function() return conn:exec(sql) end)
    if not ok3 or not res then
        logger.warn("CoverCalendar: query against page_stat_data failed:", tostring(res), "- trying page_stat view")
        local sql2 = sql:gsub("page_stat_data", "page_stat")
        ok3, res = pcall(function() return conn:exec(sql2) end)
    end

    if not ok3 or not res then
        logger.warn("CoverCalendar: both stats queries failed:", tostring(res))
        pcall(function() conn:close() end)
        return result
    end

    -- res is column-major: res[1]=ds, res[2]=title, res[3]=authors, res[4]=series,
    -- res[5]=book_id, res[6]=dur, res[7]=pages_today, res[8]=pages,
    -- res[9]=total_read_pages, res[10]=last_seen
    local n_rows = res[1] and #res[1] or 0
    logger.info("CoverCalendar: loadMonthData got", n_rows, "rows for", year, month)

    for i = 1, n_rows do
        local ds          = res[1][i]
        local title       = res[2][i]
        local authors     = res[3] and res[3][i] or ""
        local series_raw  = res[4] and res[4][i] or ""
        local series      = (series_raw == "N/A") and "" or series_raw
        local dur         = tonumber(res[6] and res[6][i]) or 0
        local pages_today = tonumber(res[7] and res[7][i]) or 0
        local pages       = tonumber(res[8] and res[8][i]) or 0
        local total_read_pages = tonumber(res[9] and res[9][i]) or 0
        if not result[ds] then result[ds] = {} end
        table.insert(result[ds], {
            title       = title,
            authors     = authors or "",
            series      = series or "",
            dur         = dur,
            pages_today = pages_today,
            pages       = pages,
            total_read_pages = total_read_pages,
        })
    end

    pcall(function() conn:close() end)
    return result
end

-- ── All-time streak calculation ───────────────────────────────────────────────
-- Queries every reading session ever recorded to find the true longest and
-- current streaks, not limited to the displayed month.
-- Returns { current = N, longest = N } where N is in days.
local function loadAllTimeStreaks(db_path)
    local result = { current = 0, longest = 0 }

    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok or not SQ3 then return result end

    local ok2, conn = pcall(SQ3.open, db_path)
    if not ok2 or not conn then return result end

    -- Get every distinct calendar day that had any reading, sorted ascending.
    -- Using page_stat_data; falls back to page_stat view if that fails.
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

    local days = res[1]   -- array of "YYYY-MM-DD" strings, sorted
    local n = #days
    if n == 0 then
        pcall(function() conn:close() end)
        return result
    end

    -- Walk the sorted day list and find runs of consecutive calendar days.
    -- "Consecutive" means the next day is exactly 1 day after the previous,
    -- regardless of month or year boundaries — this is the key improvement
    -- over the old month-scoped approach.
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

    -- Current streak: walk backwards from today and count consecutive days.
    local today_ts = os.time(os.date("*t"))
    -- Normalize to midnight local time.
    local today_d = os.date("*t", today_ts)
    today_ts = os.time{year=today_d.year, month=today_d.month, day=today_d.day,
                       hour=0, min=0, sec=0}

    local streak = 0
    for i = n, 1, -1 do
        local ts = toTimestamp(days[i])
        if not ts then break end
        local diff = math.floor((today_ts - ts) / 86400 + 0.5)
        if diff == streak then
            streak = streak + 1
        elseif diff == streak + 1 and streak == 0 then
            -- Yesterday counts as current streak too (you haven't read today yet)
            streak = 1
        else
            break
        end
    end
    result.current = streak

    pcall(function() conn:close() end)
    return result
end


local function makeEmptyCell(w, h)
    -- Flat design: empty cells are just blank space — no card borders.
    return FrameContainer:new{
        width=w, height=h, padding=0, bordersize=0,
        background=Blitbuffer.COLOR_WHITE,
        VerticalSpan:new{width=1, height=1},
    }
end

-- ── Day cell widget ───────────────────────────────────────────────────────────
local DayCell = InputContainer:extend{
    width=0, height=0, day=0, day_str="",
    books=nil, title_path_map=nil,
    is_today=false,
    cover_size="compact",
    stack_covers=true,
    in_streak=false,
    today_color_id="none",
    skip_covers=false,
    cell_time=false,
}

-- Cover fill ratio per size setting (fraction of the available vertical
-- space below the day number that the cover occupies).
local COVER_SIZE_RATIO = {
    compact = 0.65,
    cozy    = 0.86,
    large   = 1.0,
}

function DayCell:init()
    local W = self.width
    local H = self.height
    local books = self.books or {}

    local num_face   = Font:getFace("cfont", DAY_NUM_SIZE)
    local title_face = Font:getFace("cfont", TITLE_SIZE)

    -- ── Today tint (kept from the old design; default "none" = plain) ────────
    local has_color = Device:hasColorScreen() and
        (not G_reader_settings:has("color_rendering") or G_reader_settings:isTrue("color_rendering"))
    local ok_rgb, RGB32 = pcall(function() return Blitbuffer.ColorRGB32 end)

    local function resolvePresetColor(preset_id)
        local preset = CoverUtil.getColorPreset(preset_id)
        if preset.none then return Blitbuffer.COLOR_WHITE end
        if preset.rgb and has_color and ok_rgb and RGB32 then
            return RGB32(preset.rgb[1], preset.rgb[2], preset.rgb[3])
        end
        return Blitbuffer.COLOR_LIGHT_GRAY
    end

    local cell_bg = Blitbuffer.COLOR_WHITE
    if self.is_today then
        cell_bg = resolvePresetColor(self.today_color_id or "none")
    end

    local content = OverlapGroup:new{
        dimen = Geom:new{w=W, h=H},
        allow_mirroring = false,
    }

    local top = books[1]
    local extra = #books - 1
    -- The reference design's core rule: on a day with reading, the cover
    -- REPLACES the day number entirely; on a day without, a centred number
    -- is all there is. (Skeleton pass shows numbers everywhere.)
    local show_cover = (top ~= nil) and not self.skip_covers

    if not show_cover then
        -- ── No reading: centred day number only ──────────────────────────────
        local num_widget
        if self.is_today then
            num_widget = FrameContainer:new{
                padding=4, padding_left=8, padding_right=8,
                bordersize=0, radius=Screen:scaleBySize(10),
                background=Blitbuffer.COLOR_BLACK,
                TextWidget:new{
                    text=tostring(self.day), face=num_face, bold=true,
                    fgcolor=Blitbuffer.COLOR_WHITE,
                },
            }
        else
            num_widget = TextWidget:new{
                text=tostring(self.day), face=num_face, bold=true,
                fgcolor=Blitbuffer.COLOR_BLACK,
            }
        end
        table.insert(content, CenterContainer:new{
            dimen = Geom:new{w=W, h=H},
            num_widget,
        })
    else
        -- ── Reading day: the cover IS the cell ───────────────────────────────
        local size_ratio = COVER_SIZE_RATIO[self.cover_size] or COVER_SIZE_RATIO.compact
        local cover_h = math.max(0, math.floor((H - PAD*2) * size_ratio))
        local cover_w = math.max(0, math.floor((W - PAD*2) * size_ratio))

        local function resolveCoverWidget(book, w, h)
            local path = self.title_path_map and CoverUtil.findPathForTitle(self.title_path_map, book.title)
            if path then
                local img = CoverUtil.getCoverWidget(path, w, h)
                if img then
                    -- getCoverWidget preserves real aspect ratio, so measure the
                    -- actual rendered size and centre within it — never clip.
                    local ok_size, img_size = pcall(function() return img:getSize() end)
                    local actual_h = h
                    if ok_size and img_size and img_size.w and img_size.h
                       and img_size.w > 0 and img_size.h > 0 then
                        actual_h = math.min(img_size.h, h)
                    end
                    return FrameContainer:new{
                        padding=0, bordersize=0,
                        width=w, height=h,
                        CenterContainer:new{
                            dimen = Geom:new{w=w, h=h},
                            CenterContainer:new{
                                dimen = Geom:new{w=w, h=actual_h},
                                img,
                            },
                        },
                    }
                end
            end
            -- Fallback: abbreviated title chip when no cover can be found
            local abbr = book.title:sub(1, math.floor(w / (TITLE_SIZE * 0.6)))
            return FrameContainer:new{
                padding=2, bordersize=1, radius=Screen:scaleBySize(3),
                width=w, height=h,
                background=Blitbuffer.COLOR_LIGHT_GRAY,
                CenterContainer:new{
                    dimen=Geom:new{w=w-4, h=h-4},
                    TextWidget:new{
                        text=abbr, face=title_face,
                        fgcolor=Blitbuffer.COLOR_BLACK,
                    },
                },
            }
        end

        if cover_h > 8 and cover_w > 8 then
            local cover_block
            if self.stack_covers and extra > 0 then
                local FAN_OFFSET = math.max(4, math.floor(cover_w * 0.12))
                local stack_w = math.max(8, cover_w - FAN_OFFSET)
                cover_block = OverlapGroup:new{
                    dimen = Geom:new{w=cover_w, h=cover_h},
                    allow_mirroring = false,
                    FrameContainer:new{
                        padding=0, padding_left=FAN_OFFSET,
                        padding_top=math.floor(FAN_OFFSET/2), bordersize=0,
                        resolveCoverWidget(books[2], stack_w, cover_h),
                    },
                    FrameContainer:new{
                        padding=0, bordersize=0,
                        resolveCoverWidget(top, stack_w, cover_h),
                    },
                }
            else
                cover_block = resolveCoverWidget(top, cover_w, cover_h)
            end

            -- Centre the cover in the cell — no day number reserved above it.
            table.insert(content, CenterContainer:new{
                dimen = Geom:new{w=W, h=H},
                cover_block,
            })

            -- "+N" badge (bottom-right) when more books than we can show
            local remaining = (self.stack_covers and extra > 0) and (#books - 2) or extra
            if remaining and remaining > 0 then
                local badge_face = Font:getFace("cfont", TITLE_SIZE)
                table.insert(content, RightContainer:new{
                    dimen=Geom:new{w=W, h=H},
                    FrameContainer:new{
                        padding=1, bordersize=0, radius=Screen:scaleBySize(6),
                        background=Blitbuffer.COLOR_DARK_GRAY,
                        TextWidget:new{
                            text="+" .. remaining, face=badge_face,
                            fgcolor=Blitbuffer.COLOR_WHITE,
                        },
                    },
                })
            end
        end

        -- Optional reading-time pill, top-right (off by default; the
        -- reference design shows none)
        if self.cell_time then
            local total_secs = 0
            for _, b in ipairs(books) do total_secs = total_secs + (b.dur or 0) end
            local mins = math.floor(total_secs / 60)
            local time_str
            if mins >= 60 then
                time_str = math.floor(mins / 60) .. "h"
            elseif mins > 0 then
                time_str = mins .. "m"
            end
            if time_str then
                local time_face = Font:getFace("cfont", TITLE_SIZE + 2)
                table.insert(content, RightContainer:new{
                    dimen = Geom:new{w=W - PAD, h=DAY_NUM_SIZE + 10},
                    FrameContainer:new{
                        padding=3, padding_left=5, padding_right=5,
                        bordersize=0, radius=Screen:scaleBySize(7),
                        background=Blitbuffer.COLOR_LIGHT_GRAY,
                        TextWidget:new{
                            text=time_str, face=time_face, bold=true,
                            fgcolor=Blitbuffer.COLOR_BLACK,
                        },
                    },
                })
            end
        end
    end

    -- Flat, borderless cell — the reference design has no grid lines at all.
    self[1] = FrameContainer:new{
        width=W, height=H, padding=0, bordersize=0,
        background=cell_bg,
        content,
    }

    -- (See v4 notes: set dimen eagerly so parent layout containers can
    -- measure this cell before first paint.)
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

function DayCell:onTap()
    local books = self.books or {}
    if #books == 0 then return true end

    local self_cell = self
    local SW = Screen:getWidth()
    local SH = Screen:getHeight()
    local POPUP_PAD = Screen:scaleBySize(16)
    local popup_w   = math.min(SW - Screen:scaleBySize(60), Screen:scaleBySize(380))
    local inner_w   = popup_w - POPUP_PAD * 2
    local COVER_W   = Screen:scaleBySize(64)
    local COVER_H   = Screen:scaleBySize(88)

    -- Date (shared across all books for this day)
    local MN = {"January","February","March","April","May","June",
                 "July","August","September","October","November","December"}
    local DN = {"Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"}
    local py, pm, pd = self.day_str:match("(%d+)-(%d+)-(%d+)")
    local wday = os.date("*t", os.time{
        year=tonumber(py), month=tonumber(pm), day=tonumber(pd)}).wday
    local nice_date = DN[wday] .. ", " .. MN[tonumber(pm)] .. " " .. tonumber(pd)

    -- Shared fonts and layout helpers
    local date_face  = Font:getFace("cfont", 13)
    local title_face = Font:getFace("cfont", 14)
    local meta_face  = Font:getFace("cfont", 11)
    local val_face   = Font:getFace("cfont", 17)
    local lbl_face   = Font:getFace("cfont", 10)
    local x_face     = Font:getFace("cfont", 18)

    local SEP_W = Screen:scaleBySize(1)
    local SEP_H = Screen:scaleBySize(44)  -- taller sep = more room for stats centering
    local col_w = math.floor((inner_w - SEP_W * 2) / 3)
    local info_w = inner_w - COVER_W - Screen:scaleBySize(22)

    local function statBlock(val, lbl)
        return CenterContainer:new{
            dimen=Geom:new{w=col_w, h=SEP_H},
            VerticalGroup:new{ overlap=false,
                CenterContainer:new{
                    dimen=Geom:new{w=col_w, h=Screen:scaleBySize(24)},
                    TextWidget:new{
                        text=val, face=val_face, bold=true,
                        fgcolor=Blitbuffer.COLOR_BLACK,
                    },
                },
                CenterContainer:new{
                    dimen=Geom:new{w=col_w, h=Screen:scaleBySize(16)},
                    TextWidget:new{
                        text=lbl, face=lbl_face,
                        fgcolor=Blitbuffer.COLOR_BLACK,
                    },
                },
            },
        }
    end

    local function pipe()
        return CenterContainer:new{
            dimen=Geom:new{w=SEP_W, h=SEP_H},
            LineWidget:new{
                background=Blitbuffer.COLOR_LIGHT_GRAY, line_width=SEP_W,
                dimen=Geom:new{w=SEP_W, h=SEP_H},
            },
        }
    end

    -- Forward-declare showCard so buildCard's button callbacks can
    -- reference it as an upvalue even though showCard is defined later.
    local showCard

    -- Build the card content for book at index idx
    local function buildCard(idx)
        local book = books[idx]

        -- Per-book time read
        local book_secs = book.dur or 0
        local hrs  = math.floor(book_secs / 3600)
        local mins = math.floor((book_secs % 3600) / 60)
        local time_val = (hrs > 0)
            and string.format("%dh %dm", hrs, mins)
            or  (mins > 0 and string.format("%dm", mins) or "—")

        -- Per-book stats from sidecar
        local pct_val    = "—"
        local status_str = nil
        local pages_val  = (book.pages_today and book.pages_today > 0)
            and tostring(book.pages_today) or "—"

        if self_cell.title_path_map then
            local path = CoverUtil.findPathForTitle(self_cell.title_path_map, book.title)
            if path then
                local ok_ds, DocSettings = pcall(require, "docsettings")
                if ok_ds and DocSettings then
                    local ok_sd, sidecar = pcall(DocSettings.open, DocSettings, path)
                    if ok_sd and sidecar then
                        local pf = sidecar:readSetting("percent_finished")
                        if pf and type(pf) == "number" then
                            pct_val = math.floor(pf * 100) .. "%"
                        end
                        local summary = sidecar:readSetting("summary")
                        if summary and type(summary) == "table" then
                            local s = summary.status
                            if s == "complete" or s == "finished" then
                                status_str = "✓ Finished"
                            elseif s == "reading" then
                                status_str = "Reading"
                            elseif s == "abandoned" then
                                status_str = "Abandoned"
                            elseif s == "on_hold" or s == "onhold" then
                                status_str = "On hold"
                            elseif pct_val ~= "—" then
                                status_str = "Reading"
                            end
                        elseif pct_val ~= "—" then
                            status_str = "Reading"
                        end
                    end
                end
            end
        end
        if pct_val == "—" then
            if book.pages and book.pages > 0
               and book.total_read_pages and book.total_read_pages > 0 then
                pct_val = math.min(100,
                    math.floor(book.total_read_pages / book.pages * 100)) .. "%"
            end
        end

        -- Cover
        local cover_widget = nil
        if self_cell.title_path_map then
            local path = CoverUtil.findPathForTitle(self_cell.title_path_map, book.title)
            if path then
                local ok_bim, BIM = pcall(require, "bookinfomanager")
                if ok_bim and BIM then
                    local ok_bi, bi = pcall(BIM.getBookInfo, BIM, path, true)
                    if ok_bi and bi and bi.cover_bb then
                        local sf
                        local ok2, _, _, csf = pcall(
                            BIM.getCachedCoverSize, BIM, bi.cover_w, bi.cover_h,
                            COVER_W, COVER_H)
                        if ok2 and csf then sf = csf else
                            sf = math.min(COVER_W/(bi.cover_w or COVER_W),
                                          COVER_H/(bi.cover_h or COVER_H))
                        end
                        local ok_iw, IW = pcall(require, "ui/widget/imagewidget")
                        if ok_iw then
                            local ok_cp, bb_copy = pcall(function()
                                return bi.cover_bb:copy() end)
                            if ok_cp and bb_copy then
                                local ok_img, img = pcall(IW.new, IW, {
                                    image=bb_copy, scale_factor=sf,
                                    image_disposable=true,
                                })
                                if ok_img and img then
                                    local ok_sz, img_sz = pcall(function()
                                        return img:getSize() end)
                                    local ah = COVER_H
                                    if ok_sz and img_sz and img_sz.h > 0 then
                                        ah = math.min(img_sz.h, COVER_H)
                                    end
                                    cover_widget = FrameContainer:new{
                                        padding=0, bordersize=0,
                                        width=COVER_W, height=COVER_H,
                                        BottomContainer:new{
                                            dimen=Geom:new{w=COVER_W, h=COVER_H},
                                            CenterContainer:new{
                                                dimen=Geom:new{w=COVER_W, h=ah},
                                                img,
                                            },
                                        },
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end
        if not cover_widget then
            cover_widget = FrameContainer:new{
                padding=4, bordersize=1, radius=Screen:scaleBySize(4),
                width=COVER_W, height=COVER_H,
                background=Blitbuffer.COLOR_LIGHT_GRAY,
                CenterContainer:new{
                    dimen=Geom:new{w=COVER_W-8, h=COVER_H-8},
                    TextWidget:new{
                        text=book.title:sub(1,6), face=lbl_face,
                        fgcolor=Blitbuffer.COLOR_BLACK,
                    },
                },
            }
        end

        -- Book info column — use max_width on TextWidget so KOReader's own
        -- glyph renderer handles truncation correctly rather than our rough
        -- character-count estimate which overflows on wide characters/fonts.
        local book_col = VerticalGroup:new{ overlap=false,
            TextWidget:new{
                text=book.title, face=title_face, bold=true,
                max_width=info_w,
                fgcolor=Blitbuffer.COLOR_BLACK,
            },
        }
        local author_str = (book.authors and book.authors ~= "") and book.authors or nil
        if author_str then
            table.insert(book_col, VerticalSpan:new{height=Screen:scaleBySize(3)})
            table.insert(book_col, TextWidget:new{
                text=author_str, face=meta_face, max_width=info_w,
                fgcolor=Blitbuffer.COLOR_BLACK,
            })
        end
        local series_str = (book.series and book.series ~= "" and book.series ~= "N/A")
            and book.series or nil
        if series_str then
            table.insert(book_col, VerticalSpan:new{height=Screen:scaleBySize(2)})
            table.insert(book_col, TextWidget:new{
                text=series_str, face=meta_face, max_width=info_w,
                fgcolor=Blitbuffer.COLOR_BLACK,
            })
        end
        if status_str then
            table.insert(book_col, VerticalSpan:new{height=Screen:scaleBySize(5)})
            table.insert(book_col, FrameContainer:new{
                padding=3, padding_left=7, padding_right=7,
                bordersize=1, radius=Screen:scaleBySize(6),
                TextWidget:new{
                    text=status_str, face=Font:getFace("cfont", 10), bold=true,
                    fgcolor=Blitbuffer.COLOR_BLACK,
                },
            })
        end

        local top_row = HorizontalGroup:new{ overlap=false,
            HorizontalSpan:new{width=Screen:scaleBySize(8)},
            cover_widget,
            HorizontalSpan:new{width=Screen:scaleBySize(14)},
            CenterContainer:new{
                dimen=Geom:new{w=info_w, h=COVER_H},
                book_col,
            },
        }

        -- Book-specific stats (pages + percent) with total time shared
        local stats_row = HorizontalGroup:new{ overlap=false,
            statBlock(time_val, "time read"),
            pipe(),
            statBlock(pages_val, "pages"),
            pipe(),
            statBlock(pct_val, "of book"),
        }

        -- Navigation row: ‹ dots › — only shown when multiple books
        local nav_row = nil
        if #books > 1 then
            local arrow_face = Font:getFace("cfont", 22)
            local dot_face   = Font:getFace("cfont", 11)
            local prev_idx = ((idx - 2) % #books) + 1
            local next_idx = (idx % #books) + 1

            local dots_group = HorizontalGroup:new{ overlap=false }
            for i = 1, #books do
                table.insert(dots_group, TextWidget:new{
                    text  = (i == idx) and "●" or "○",
                    face  = dot_face,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                })
                if i < #books then
                    table.insert(dots_group,
                        HorizontalSpan:new{width=Screen:scaleBySize(6)})
                end
            end

            local NAV_H = Screen:scaleBySize(44)
            nav_row = OverlapGroup:new{
                dimen=Geom:new{w=inner_w, h=NAV_H},
                allow_mirroring=false,
                -- left arrow — bigger tap target
                FrameContainer:new{
                    padding=0, bordersize=0,
                    Button:new{
                        text="‹", face=arrow_face,
                        bordersize=0,
                        padding=Screen:scaleBySize(8),
                        callback=function()
                            showCard(prev_idx)
                        end,
                    },
                },
                -- dots centred
                CenterContainer:new{
                    dimen=Geom:new{w=inner_w, h=NAV_H},
                    dots_group,
                },
                -- right arrow — bigger tap target
                RightContainer:new{
                    dimen=Geom:new{w=inner_w, h=NAV_H},
                    FrameContainer:new{
                        padding=0, bordersize=0,
                        Button:new{
                            text="›", face=arrow_face,
                            bordersize=0,
                            padding=Screen:scaleBySize(8),
                            callback=function()
                                showCard(next_idx)
                            end,
                        },
                    },
                },
            }
        end

        -- Assemble
        local content = VerticalGroup:new{ overlap=false,
            -- Header
            OverlapGroup:new{
                dimen=Geom:new{w=inner_w, h=Screen:scaleBySize(26)},
                allow_mirroring=false,
                CenterContainer:new{
                    dimen=Geom:new{w=inner_w, h=Screen:scaleBySize(26)},
                    TextWidget:new{
                        text=nice_date, face=date_face, bold=true,
                        fgcolor=Blitbuffer.COLOR_BLACK,
                    },
                },
                RightContainer:new{
                    dimen=Geom:new{w=inner_w, h=Screen:scaleBySize(26)},
                    TextWidget:new{
                        text="✕", face=x_face, bold=true,
                        fgcolor=Blitbuffer.COLOR_BLACK,
                    },
                },
            },
            VerticalSpan:new{height=Screen:scaleBySize(8)},
            LineWidget:new{
                background=Blitbuffer.COLOR_BLACK, line_width=1,
                dimen=Geom:new{w=inner_w, h=1},
            },
            CenterContainer:new{
                dimen=Geom:new{w=inner_w, h=COVER_H + Screen:scaleBySize(32)},
                top_row,
            },
            LineWidget:new{
                background=Blitbuffer.COLOR_LIGHT_GRAY, line_width=1,
                dimen=Geom:new{w=inner_w, h=1},
            },
            CenterContainer:new{
                dimen=Geom:new{w=inner_w, h=SEP_H + Screen:scaleBySize(20)},
                stats_row,
            },
        }

        if nav_row then
            table.insert(content, LineWidget:new{
                background=Blitbuffer.COLOR_LIGHT_GRAY, line_width=1,
                dimen=Geom:new{w=inner_w, h=1},
            })
            table.insert(content, nav_row)
        else
            table.insert(content, VerticalSpan:new{height=Screen:scaleBySize(6)})
        end

        return FrameContainer:new{
            padding=POPUP_PAD, bordersize=2,
            radius=Screen:scaleBySize(12),
            background=Blitbuffer.COLOR_WHITE,
            content,
        }
    end

    local current_idx = 1
    local overlay

    showCard = function(idx)
        if overlay then UIManager:close(overlay, "ui") end

        local popup = buildCard(idx)

        overlay = InputContainer:new{
            dimen = Geom:new{x=0, y=0, w=SW, h=SH},
            CenterContainer:new{
                dimen=Geom:new{w=SW, h=SH},
                popup,
            },
        }

        overlay:registerTouchZones({
            {
                id = "cc_popup_tap",
                ges = "tap",
                screen_zone = {
                    ratio_x=0, ratio_y=0,
                    ratio_w=1, ratio_h=1,
                },
                handler = function(_ges)
                    UIManager:close(overlay, "ui")
                    return true
                end,
            },
        })

        function overlay:onShow()
            UIManager:setDirty(self, "ui")
        end

        UIManager:show(overlay)
    end

    showCard(1)
    return true
end

-- ── Main calendar view ────────────────────────────────────────────────────────
local CoverCalendarView = InputContainer:extend{
    db_path       = "",
    start_dow     = 2,
    year          = 0,
    month         = 0,
    cover_size    = "compact",
    stack_covers  = true,
    month_summary = false,
    cell_time     = false,
    today_color_id  = "none",
    stat_toggles  = nil,
    month_stats   = nil,   -- {stat_id, stat_id, stat_id} for the header slots
    year_stats    = nil,   -- same, for the yearly overview
    year_layout   = 12,    -- default months-per-page for the yearly overview
    read_min_secs = 300,   -- Read-mode minimum per-month time (yearly overview)
}

function CoverCalendarView:init()
    local now    = os.date("*t")
    self.year    = (self.year  ~= 0) and self.year  or now.year
    self.month   = (self.month ~= 0) and self.month or now.month
    self._today  = now
    self.stat_toggles = self.stat_toggles or {}
    self.month_stats  = self.month_stats or {"books", "pages", "pages_per_day"}
    self.year_stats   = self.year_stats  or {"books", "pages", "time"}
    self._title_path_map = CoverUtil.buildTitlePathMap()

    self.ges_events = {
        Swipe = {
            GestureRange:new{
                ges="swipe",
                range=Geom:new{x=0,y=0,
                    w=Screen:getWidth(),h=Screen:getHeight()},
            }
        },
    }

    -- Two-phase loading strategy:
    -- On the FIRST open (cold cache): show a skeleton immediately so the
    -- screen isn't black while BookInfoManager opens EPUBs, then load
    -- covers after the skeleton paints.
    -- On SUBSEQUENT navigations: BookInfoManager's SQLite cache makes
    -- cover loading near-instant, so we just do one build with covers
    -- directly — no skeleton pass, no double refresh, no flash.
    self._covers_loaded = false
    if CoverUtil.isCoverCacheWarm and CoverUtil.isCoverCacheWarm() then
        -- Cache is warm — covers load fast, build once directly
        self._covers_loaded = true
        self:_build()
    else
        -- Cold cache — show skeleton first, then covers after repaint
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

function CoverCalendarView:_build()
    local SW = Screen:getWidth()
    local SH = Screen:getHeight()

    -- ── Header: small year over a big month name (reference design) ──────────
    local month_names = {
        _("January"),_("February"),_("March"),_("April"),
        _("May"),_("June"),_("July"),_("August"),
        _("September"),_("October"),_("November"),_("December"),
    }

    local YEAR_H  = Screen:scaleBySize(20)
    local MONTH_H = Screen:scaleBySize(44)
    local HDR_H   = YEAR_H + MONTH_H + Screen:scaleBySize(8)
    local CORNER_H = YEAR_H + Screen:scaleBySize(16)

    local header = OverlapGroup:new{
        dimen = Geom:new{w=SW, h=HDR_H},
        allow_mirroring = false,
        CenterContainer:new{
            dimen = Geom:new{w=SW, h=HDR_H},
            VerticalGroup:new{ overlap=false,
                CenterContainer:new{
                    dimen = Geom:new{w=SW, h=YEAR_H},
                    TextWidget:new{
                        text=tostring(self.year),
                        face=Font:getFace("cfont", YEAR_SIZE), bold=true,
                        fgcolor=Blitbuffer.COLOR_BLACK,
                    },
                },
                -- The big month name doubles as the month/year-picker button.
                CenterContainer:new{
                    dimen = Geom:new{w=SW, h=MONTH_H},
                    Button:new{
                        text=month_names[self.month]:upper(),
                        bordersize=0,
                        text_font_face="cfont",
                        text_font_size=MONTH_BIG_SIZE,
                        text_font_bold=true,
                        callback=function() self:_pickMonthYear() end,
                    },
                },
            },
        },
        -- Page-turn arrows pinned top-left, plus a "Today" jump that only
        -- appears when a different month than the current one is displayed
        (function()
            local now = os.date("*t")
            local nav = HorizontalGroup:new{ overlap=false,
                Button:new{
                    text="‹", bordersize=0,
                    padding=Screen:scaleBySize(8),
                    callback=function() self:_prevMonth() end,
                },
                HorizontalSpan:new{width=Screen:scaleBySize(2)},
                Button:new{
                    text="›", bordersize=0,
                    padding=Screen:scaleBySize(8),
                    callback=function() self:_nextMonth() end,
                },
            }
            if self.year ~= now.year or self.month ~= now.month then
                table.insert(nav, HorizontalSpan:new{width=Screen:scaleBySize(6)})
                table.insert(nav, Button:new{
                    text=_("Today"), bordersize=0,
                    text_font_face="cfont",
                    text_font_size=16,
                    padding=Screen:scaleBySize(6),
                    callback=function()
                        local t = os.date("*t")
                        self.year, self.month = t.year, t.month
                        self._covers_loaded = true
                        self:_build()
                    end,
                })
            end
            return FrameContainer:new{
                padding=0, padding_left=Screen:scaleBySize(6), bordersize=0,
                nav,
            }
        end)(),
        -- Top-right: yearly overview + close
        RightContainer:new{
            dimen = Geom:new{w=SW - Screen:scaleBySize(6), h=CORNER_H},
            HorizontalGroup:new{ overlap=false,
                Button:new{
                    text=_("Year"), bordersize=0,
                    text_font_face="cfont",
                    text_font_size=16,
                    padding=Screen:scaleBySize(6),
                    callback=function() self:_openYearView() end,
                },
                HorizontalSpan:new{width=Screen:scaleBySize(6)},
                Button:new{
                    text="✕", bordersize=0,
                    padding=Screen:scaleBySize(6),
                    callback=function() self:onClose() end,
                },
            },
        },
    }

    -- ── DoW header ───────────────────────────────────────────────────────────
    local DOW_H = Screen:scaleBySize(22)
    -- Exact pixel widths: give remainder pixels to col 6
    local cell_w  = math.floor(SW / 7)
    local last_w  = SW - cell_w * 6  -- last column takes any remainder

    local dow_labels = (self.start_dow == 2)
        and {"MON","TUE","WED","THU","FRI","SAT","SUN"}
        or  {"SUN","MON","TUE","WED","THU","FRI","SAT"}

    local dow_row = HorizontalGroup:new{overlap=false}
    for i = 1, 7 do
        local w = (i == 7) and last_w or cell_w
        table.insert(dow_row, CenterContainer:new{
            dimen=Geom:new{w=w, h=DOW_H},
            TextWidget:new{
                text=dow_labels[i], bold=true,
                face=Font:getFace("cfont", DOW_SIZE),
                fgcolor=Blitbuffer.COLOR_BLACK,
            },
        })
    end

    -- ── Grid ─────────────────────────────────────────────────────────────────
    local data       = loadMonthData(self.db_path, self.year, self.month)
    local days_in_m  = daysInMonth(self.year, self.month)
    local first_col  = wdayToCol(firstWday(self.year, self.month), self.start_dow)
    local n_rows     = math.ceil((first_col + days_in_m) / 7)

    -- ── Streak detection (scoped to the displayed month) ────────────────────
    -- NOTE: this only looks at days within the currently-shown month, so a
    -- streak that started in the previous month won't show as continuing
    -- into day 1 here. Cross-month streak tracking would need a wider DB
    -- query; this is a reasonable scope for a "which days were I on a roll"
    -- visual cue rather than the exact streak-counter math used elsewhere.
    local streak_days = {}
    do
        local has_reading = {}
        for d = 1, days_in_m do
            local ds = string.format("%04d-%02d-%02d", self.year, self.month, d)
            has_reading[d] = (data[ds] ~= nil and #data[ds] > 0)
        end
        -- Mark any day that's part of a run of 2+ consecutive reading days.
        local run_start = nil
        for d = 1, days_in_m + 1 do
            if d <= days_in_m and has_reading[d] then
                run_start = run_start or d
            else
                if run_start and (d - run_start) >= 2 then
                    for rd = run_start, d - 1 do streak_days[rd] = true end
                end
                run_start = nil
            end
        end
    end

    -- ── Stats row: three configurable stat slots (reference design) ──────────
    -- Which three stats appear is chosen in settings → Monthly stats.
    local SUMMARY_H = 0
    local summary_row = nil
    if self.month_summary then
        local slots = self.month_stats or {"books", "pages", "pages_per_day"}

        local days_with_reading = 0
        local seen_titles = {}
        local distinct_books = 0
        -- pages_today is per-book-per-day DISTINCT pages read, so summing it
        -- across the month is a true month total — unlike the lifetime
        -- total_read_pages the old summary had to fall back to.
        local total_pages = 0
        local total_secs  = 0

        for _, books_for_day in pairs(data) do
            if #books_for_day > 0 then
                days_with_reading = days_with_reading + 1
            end
            for _, b in ipairs(books_for_day) do
                if not seen_titles[b.title] then
                    seen_titles[b.title] = true
                    distinct_books = distinct_books + 1
                end
                total_pages = total_pages + (b.pages_today or 0)
                total_secs  = total_secs + (b.dur or 0)
            end
        end

        -- "Books" = books FINISHED this month, via the shared engine in
        -- coverutil.lua (sidecar completion date first, else the last
        -- meaningful session in the month). Only computed when a slot
        -- actually shows it, since it reads sidecars from disk.
        local books_finished = 0
        local wants_finished = false
        for _, id in ipairs(slots) do
            if id == "books" then wants_finished = true end
        end
        if wants_finished then
            local per_book = {}
            for ds, books_for_day in pairs(data) do
                for _, b in ipairs(books_for_day) do
                    local pb = per_book[b.title]
                    if not pb then
                        pb = { title=b.title, pages=b.pages,
                               total_read_pages=b.total_read_pages,
                               sessions={} }
                        per_book[b.title] = pb
                    end
                    if (b.total_read_pages or 0) > (pb.total_read_pages or 0) then
                        pb.total_read_pages = b.total_read_pages
                    end
                    table.insert(pb.sessions,
                        {ds=ds, dur=b.dur, pages_today=b.pages_today})
                end
            end
            local range_start = string.format("%04d-%02d-01",
                self.year, self.month)
            local range_end = string.format("%04d-%02d-%02d",
                self.year, self.month, days_in_m)
            for _, pb in pairs(per_book) do
                table.sort(pb.sessions, function(a, b) return a.ds < b.ds end)
                local fds = CoverUtil.finishedDateInRange(
                    self._title_path_map, pb, pb.sessions, range_start, range_end)
                if fds then books_finished = books_finished + 1 end
            end
        end

        local pages_per_day = (days_with_reading > 0)
            and math.floor(total_pages / days_with_reading + 0.5) or 0
        local avg_mins = (days_with_reading > 0)
            and math.floor(total_secs / days_with_reading / 60 + 0.5) or 0
        local hours = math.floor(total_secs / 3600)
        local mins  = math.floor((total_secs % 3600) / 60)
        local time_str = (hours > 0)
            and string.format("%dh %dm", hours, mins)
            or  string.format("%dm", mins)

        -- Streaks are all-time (cross-month); only hit the DB if a slot uses them.
        local needs_streaks = false
        for _, id in ipairs(slots) do
            if id == "current_streak" or id == "longest_streak" then
                needs_streaks = true
            end
        end
        local streaks = { current = 0, longest = 0 }
        if needs_streaks then
            -- All-time streak scan is cached per view session — no need to
            -- re-walk the entire reading history on every month navigation.
            self._streaks_cache = self._streaks_cache or loadAllTimeStreaks(self.db_path)
            streaks = self._streaks_cache
        end

        local function statFor(id)
            if id == "books" then return tostring(books_finished), _("BOOKS")
            elseif id == "books_read" then return tostring(distinct_books), _("BOOKS READ")
            elseif id == "pages" then return tostring(total_pages), _("PAGES")
            elseif id == "pages_per_day" then return tostring(pages_per_day), _("PAGES/DAY")
            elseif id == "time" then return time_str, _("TIME READ")
            elseif id == "time_days" then
                local dh = (hours >= 24)
                    and string.format("%dd %dh", math.floor(hours / 24), hours % 24)
                    or time_str
                return dh, _("TIME READ")
            elseif id == "avg_time" then return tostring(avg_mins) .. "m", _("MIN/DAY")
            elseif id == "days_active" then return tostring(days_with_reading), _("DAYS ACTIVE")
            elseif id == "current_streak" then return tostring(streaks.current), _("STREAK")
            elseif id == "longest_streak" then return tostring(streaks.longest), _("BEST STREAK")
            end
            return "—", "?"
        end

        local val_face = Font:getFace("cfont", STAT_VAL_SIZE)
        local lbl_face = Font:getFace("cfont", STAT_LBL_SIZE)
        local VAL_H = Screen:scaleBySize(30)
        local LBL_H = Screen:scaleBySize(15)
        SUMMARY_H = VAL_H + LBL_H + Screen:scaleBySize(8)

        local col_w = math.floor(SW / 3)

        local function statBlock(val, lbl, w)
            return CenterContainer:new{
                dimen = Geom:new{w=w, h=SUMMARY_H},
                VerticalGroup:new{ overlap=false,
                    CenterContainer:new{
                        dimen = Geom:new{w=w, h=VAL_H},
                        TextWidget:new{
                            text=tostring(val), face=val_face, bold=true,
                            fgcolor=Blitbuffer.COLOR_BLACK,
                        },
                    },
                    CenterContainer:new{
                        dimen = Geom:new{w=w, h=LBL_H},
                        TextWidget:new{
                            text=lbl, face=lbl_face, bold=true,
                            fgcolor=Blitbuffer.COLOR_BLACK,
                        },
                    },
                },
            }
        end

        summary_row = HorizontalGroup:new{ overlap=false }
        for i = 1, 3 do
            local w = (i == 3) and (SW - col_w*2) or col_w
            local val, lbl = statFor(slots[i])
            table.insert(summary_row, statBlock(val, lbl, w))
        end
    end

    -- Remaining height for the grid (flat design — no separator rules)
    local GAP = Screen:scaleBySize(4)
    local summary_block_h = summary_row and (SUMMARY_H + GAP) or 0
    local remaining_h = SH - HDR_H - GAP - summary_block_h - DOW_H - GAP
    local n_rows_calc = math.ceil((first_col + days_in_m) / 7)
    local cell_h = math.floor(remaining_h / n_rows_calc)

    local grid = VerticalGroup:new{overlap=false}
    local cur_day = 1

    for row = 1, n_rows do
        -- Use OverlapGroup instead of HorizontalGroup so each cell is
        -- placed at an explicit pixel x-offset rather than relying on
        -- HorizontalGroup summing children's getSize() results. That
        -- summation fails when children report wrong sizes (the root
        -- cause of partial rows centering in the middle of the screen),
        -- because HorizontalGroup centres or left-aligns based on whatever
        -- total width the children report, not on SW. With OverlapGroup +
        -- overlap_offset we know exactly where each cell lands regardless
        -- of what any child's getSize() returns.
        local hrow = OverlapGroup:new{
            dimen = Geom:new{w=SW, h=cell_h},
            allow_mirroring = false,
        }

        local x_offset = 0
        for col = 0, 6 do
            local w = (col == 6) and last_w or cell_w
            local is_prefix = (row == 1 and col < first_col)
            local is_overflow = (cur_day > days_in_m)

            local child
            if is_prefix or is_overflow then
                child = makeEmptyCell(w, cell_h)
            else
                local ds    = string.format("%04d-%02d-%02d",
                    self.year, self.month, cur_day)
                local books = data[ds]
                local today = (self.year  == self._today.year
                    and self.month == self._today.month
                    and cur_day    == self._today.day)

                child = DayCell:new{
                    width      = w,
                    height     = cell_h,
                    day        = cur_day,
                    day_str    = ds,
                    books      = books,
                    title_path_map = self._title_path_map,
                    is_today   = today,
                    cover_size   = self.cover_size,
                    stack_covers = self.stack_covers,
                    in_streak    = streak_days[cur_day] or false,
                    today_color_id  = self.today_color_id,
                    skip_covers  = not self._covers_loaded,
                    cell_time    = self.cell_time,
                }
                cur_day = cur_day + 1
            end

            -- overlap_offset positions this child at an absolute x within
            -- the OverlapGroup — this is the only reliable way to pin
            -- cells to exact pixel positions regardless of their reported
            -- getSize() width.
            child.overlap_offset = {x_offset, 0}
            table.insert(hrow, child)
            x_offset = x_offset + w
        end

        table.insert(grid, hrow)
    end

    -- ── Assemble full screen (flat — no separator rules) ─────────────────────
    local vgroup_children = {
        overlap=false,
        header,
        VerticalSpan:new{height=GAP},
    }
    if summary_row then
        table.insert(vgroup_children, summary_row)
        table.insert(vgroup_children, VerticalSpan:new{height=GAP})
    end
    table.insert(vgroup_children, dow_row)
    table.insert(vgroup_children, VerticalSpan:new{height=GAP})
    table.insert(vgroup_children, grid)

    self[1] = FrameContainer:new{
        width=SW, height=SH, padding=0, bordersize=0,
        background=Blitbuffer.COLOR_WHITE,
        VerticalGroup:new(vgroup_children),
    }

    -- "full" on skeleton pass so e-ink redraws before cover loading starts.
    -- "ui" on the covers pass — faster, less visible flash than "partial".
    if not self._covers_loaded then
        UIManager:setDirty(self, "full")
    else
        UIManager:setDirty(self, "ui")
    end
end

function CoverCalendarView:_pickMonthYear()
    local ButtonDialog = require("ui/widget/buttondialog")
    local self_ref = self
    local pick_year = self.year

    -- Month name list matches the header
    local month_short = {
        "Jan","Feb","Mar","Apr","May","Jun",
        "Jul","Aug","Sep","Oct","Nov","Dec",
    }

    local function buildDialog()
        local buttons = {}
        -- Row 1-3: months in a 4-column grid
        for row = 0, 2 do
            local r = {}
            for col = 1, 4 do
                local m = row * 4 + col
                table.insert(r, {
                    text = (m == self_ref.month and "["..month_short[m].."]" or month_short[m]),
                    callback = function()
                        UIManager:close(self_ref._month_picker)
                        self_ref._month_picker = nil
                        CoverUtil.clearCoverCache()
                        self_ref.month = m
                        self_ref.year = pick_year
                        self_ref._covers_loaded = true
                        self_ref:_build()
                    end,
                })
            end
            table.insert(buttons, r)
        end
        -- Year row: prev year | year label | next year
        table.insert(buttons, {
            {
                text = "‹ " .. (pick_year - 1),
                callback = function()
                    pick_year = pick_year - 1
                    UIManager:close(self_ref._month_picker)
                    self_ref._month_picker = nil
                    UIManager:scheduleIn(0.05, function()
                        self_ref._month_picker = buildDialog()
                        UIManager:show(self_ref._month_picker)
                    end)
                end,
            },
            {
                text = tostring(pick_year),
                callback = function() end,  -- label only, no action
            },
            {
                text = (pick_year + 1) .. " ›",
                callback = function()
                    pick_year = pick_year + 1
                    UIManager:close(self_ref._month_picker)
                    self_ref._month_picker = nil
                    UIManager:scheduleIn(0.05, function()
                        self_ref._month_picker = buildDialog()
                        UIManager:show(self_ref._month_picker)
                    end)
                end,
            },
        })

        return ButtonDialog:new{
            title = _("Go to month"),
            buttons = buttons,
        }
    end

    self._month_picker = buildDialog()
    UIManager:show(self._month_picker)
end



function CoverCalendarView:_openYearView()
    local ok, CoverYearView = pcall(require, "coveryearview")
    if not ok or not CoverYearView then
        logger.warn("CoverCalendar: coveryearview.lua missing:", tostring(CoverYearView))
        return
    end
    local self_ref = self
    UIManager:show(CoverYearView:new{
        db_path        = self.db_path,
        year           = self.year,
        month          = self.month,
        title_path_map = self._title_path_map,
        year_stats     = self.year_stats,
        months_per_page = self.year_layout or 12,
        read_min_secs  = self.read_min_secs or 300,
        on_month_tap   = function(y, m)
            -- Jump the (still-open) monthly calendar underneath to the
            -- tapped month, then rebuild it with fresh covers.
            CoverUtil.clearCoverCache()
            self_ref.year  = y
            self_ref.month = m
            self_ref._covers_loaded = true
            self_ref:_build()
        end,
    })
end

function CoverCalendarView:_prevMonth()
    CoverUtil.clearCoverCache()
    self.month = self.month - 1
    if self.month < 1 then self.month=12; self.year=self.year-1 end
    -- After first open, BookInfoManager's SQLite cache makes cover loading
    -- near-instant. Do a single direct build — no skeleton pass, no double
    -- refresh, no flash. The two-phase skeleton approach is only needed
    -- on the very first cold open (handled in init()).
    self._covers_loaded = true
    self:_build()
end

function CoverCalendarView:_nextMonth()
    CoverUtil.clearCoverCache()
    self.month = self.month + 1
    if self.month > 12 then self.month=1; self.year=self.year+1 end
    self._covers_loaded = true
    self:_build()
end

function CoverCalendarView:onSwipe(_, ges)
    if ges.direction == "left"  then self:_nextMonth(); return true end
    if ges.direction == "right" then self:_prevMonth(); return true end
end

function CoverCalendarView:onClose()
    -- Mark covers as loaded so any pending scheduled rebuild doesn't fire
    -- after the view has been closed and freed.
    self._covers_loaded = true
    -- Free the cover cache immediately on close so BlitBuffer C memory
    -- is released back to the OS rather than waiting for Lua GC.
    CoverUtil.clearCoverCache()
    UIManager:close(self, "full")
end

function CoverCalendarView:onShow()
    UIManager:setDirty(self, "full")
end

return CoverCalendarView
