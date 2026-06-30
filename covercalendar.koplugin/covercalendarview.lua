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
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger          = require("logger")
local _ = require("gettext")

local CoverUtil = require("coverutil")

-- ── Constants ─────────────────────────────────────────────────────────────────
local PAD          = 2
local DAY_NUM_SIZE = 13
local TITLE_SIZE   = 8
local DOW_SIZE     = 11
local MONTH_SIZE   = 16
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
            b.id AS book_id,
            SUM(psd.duration) AS dur,
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

    -- res is column-major: res[1]=ds, res[2]=title, res[3]=book_id, res[4]=dur,
    -- res[5]=pages, res[6]=total_read_pages, res[7]=last_seen
    local n_rows = res[1] and #res[1] or 0
    logger.info("CoverCalendar: loadMonthData got", n_rows, "rows for", year, month)

    for i = 1, n_rows do
        local ds    = res[1][i]
        local title = res[2][i]
        local dur   = tonumber(res[4][i]) or 0
        local pages = tonumber(res[5] and res[5][i]) or 0
        local total_read_pages = tonumber(res[6] and res[6][i]) or 0
        if not result[ds] then result[ds] = {} end
        table.insert(result[ds], {
            title = title,
            notes = "",
            dur   = dur,
            pages = pages,
            total_read_pages = total_read_pages,
        })
    end

    pcall(function() conn:close() end)
    return result
end

-- ── Empty cell ────────────────────────────────────────────────────────────────
local function makeEmptyCell(w, h)
    local radius = math.floor(math.min(w, h) * 0.18)
    return FrameContainer:new{
        width=w, height=h, padding=0, bordersize=BORDER, radius=radius,
        background=Blitbuffer.gray(0.95),
        VerticalSpan:new{width=1, height=1},
    }
end

-- ── Day cell widget ───────────────────────────────────────────────────────────
local DayCell = InputContainer:extend{
    width=0, height=0, day=0, day_str="",
    books=nil, title_path_map=nil,
    show_title=false, is_today=false,
    cover_size="compact",  -- "compact" | "cozy" | "large"
    stack_covers=true,     -- show a fanned stack for multi-book days
    in_streak=false,       -- this day is part of an active reading streak
    today_color_id="none",
    streak_color_id="none",
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

    -- Small explicit left/top inset for the day-number badge so it doesn't
    -- sit flush against the rounded card's edge. Folded directly into
    -- num_h (rather than applied as a separate later offset) so all the
    -- downstream cover-positioning math that reserves space for the day
    -- number stays self-consistent.
    local NUM_INSET_X = math.max(2, math.floor(W * 0.07))
    local NUM_INSET_Y = math.max(2, math.floor(H * 0.04))
    local num_h = DAY_NUM_SIZE + 6 + NUM_INSET_Y

    local top = books[1]
    local extra = #books - 1

    -- ── Cell shape & fill ─────────────────────────────────────────────────────
    -- Streak-aware background: cells that are part of an active reading
    -- streak get a light fill so the day number and cover stay clearly
    -- readable, but ONLY if the user has explicitly chosen a color via
    -- settings. Default is "none" — plain white cells, no tinting at all.
    --
    -- Colors come from CoverUtil.COLOR_PRESETS, chosen independently for
    -- "today" and "streak day". "none" → plain white (no fill). "gray" →
    -- explicit light gray, works identically on every screen type. Named
    -- colors (orange/blue/green) use Blitbuffer.ColorRGB32(r,g,b) directly
    -- with explicit light values on color screens — NOT colorFromName()/
    -- gray(), which an earlier version used and which rendered as
    -- near-solid black on-device — and fall back to light gray on
    -- grayscale e-ink, where the named tint can't be shown anyway.
    local has_color = Device:hasColorScreen() and
        (not G_reader_settings:has("color_rendering") or G_reader_settings:isTrue("color_rendering"))
    local ok_rgb, RGB32 = pcall(function() return Blitbuffer.ColorRGB32 end)

    local function resolvePresetColor(preset_id)
        local preset = CoverUtil.getColorPreset(preset_id)
        if preset.none then
            return Blitbuffer.COLOR_WHITE
        end
        if preset.rgb and has_color and ok_rgb and RGB32 then
            return RGB32(preset.rgb[1], preset.rgb[2], preset.rgb[3])
        end
        -- "gray" preset, or a named color on a grayscale screen.
        return Blitbuffer.COLOR_LIGHT_GRAY
    end

    local cell_bg = Blitbuffer.COLOR_WHITE
    if self.is_today then
        cell_bg = resolvePresetColor(self.today_color_id or "none")
    elseif self.in_streak then
        cell_bg = resolvePresetColor(self.streak_color_id or "none")
    end

    local CELL_RADIUS = math.floor(math.min(W, H) * 0.18)

    -- cover area: deliberately inset, not edge-to-edge, so the cell
    -- doesn't feel crowded. Size ratio depends on the cover_size setting.
    local size_ratio = COVER_SIZE_RATIO[self.cover_size] or COVER_SIZE_RATIO.compact
    local raw_cover_h = H - num_h - PAD*2
    local raw_cover_w = W - PAD*2
    local cover_h = math.max(0, math.floor(raw_cover_h * size_ratio))
    local cover_w = math.max(0, math.floor(raw_cover_w * size_ratio))

    local content = OverlapGroup:new{
        dimen = Geom:new{w=W, h=H},
        allow_mirroring = false,
    }

    -- Day number: top-left, small rounded badge (matches the reference
    -- app's pill-shaped day numbers) rather than plain text. Given a small
    -- explicit left/top inset so it doesn't sit flush against the rounded
    -- card's edge.
    local num_widget
    if self.is_today then
        num_widget = FrameContainer:new{
            padding=2, bordersize=0, radius=Screen:scaleBySize(8),
            background=Blitbuffer.COLOR_BLACK,
            TextWidget:new{
                text=tostring(self.day), face=num_face, bold=true,
                fgcolor=Blitbuffer.COLOR_WHITE,
            },
        }
    else
        num_widget = FrameContainer:new{
            padding=2, bordersize=0,
            TextWidget:new{
                text=tostring(self.day), face=num_face, bold=true,
                fgcolor=Blitbuffer.COLOR_BLACK,
            },
        }
    end
    num_widget = FrameContainer:new{
        padding=0, padding_left=NUM_INSET_X, padding_top=NUM_INSET_Y, bordersize=0,
        num_widget,
    }
    table.insert(content, num_widget)

    -- ── Cover, anchored to the BOTTOM of the cell (matches reference image) ──
    if top and cover_h > 8 and cover_w > 8 then
        local function resolveCoverWidget(book, w, h)
            local path = self.title_path_map and CoverUtil.findPathForTitle(self.title_path_map, book.title)
            logger.info("CoverCalendar: day", self.day_str, "book='" .. tostring(book.title) .. "' path=" .. tostring(path))
            if path then
                local img = CoverUtil.getCoverWidget(path, w, h)
                if img then
                    -- IMPORTANT: SimpleUI's getBookCover() preserves the
                    -- cover's real aspect ratio rather than stretching it
                    -- to exactly w×h, so the returned widget's ACTUAL
                    -- rendered size can differ from (w, h) on either axis
                    -- — including being TALLER than h on narrow/tall
                    -- covers. Previously we boxed it into a fixed h-tall
                    -- wrapper and bottom-anchored it, which silently
                    -- clipped the top of any cover taller than our
                    -- request. We now measure the widget's real size via
                    -- getSize() and build the wrapper to match that
                    -- measured size (capped at our originally-requested
                    -- box so it still fits the cell), so nothing gets
                    -- clipped — the cover may render very slightly
                    -- smaller than the nominal cover_h on one axis, but
                    -- always shows the whole image.
                    local ok_size, img_size = pcall(function() return img:getSize() end)
                    local actual_w, actual_h = w, h
                    if ok_size and img_size and img_size.w and img_size.h
                       and img_size.w > 0 and img_size.h > 0 then
                        actual_w = math.min(img_size.w, w)
                        actual_h = math.min(img_size.h, h)
                    end

                    return FrameContainer:new{
                        padding=0, bordersize=1, radius=Screen:scaleBySize(3),
                        width=w + 2, height=h + 2,
                        BottomContainer:new{
                            dimen = Geom:new{w=w, h=h},
                            CenterContainer:new{
                                dimen = Geom:new{w=w, h=actual_h},
                                img,
                            },
                        },
                    }
                end
            end
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

        -- Bottom anchoring: pad from the TOP by (cell height − cover height
        -- − a small bottom margin), pinning the cover flush to the bottom
        -- edge for both single-cover and 2-book fan-stack days, regardless
        -- of the cover_size setting. (Earlier formula added the leftover
        -- raw_cover_h-cover_h gap ON TOP of num_h, which only looked
        -- "flush" when cover_h was close to raw_cover_h — i.e. "large"
        -- size — and left a visible gap at "compact"/"cozy" sizes, since
        -- it wasn't actually computing a bottom-edge position.)
        local BOTTOM_MARGIN = math.max(1, math.floor(H * 0.03))
        local bottom_pad = H - cover_h - BOTTOM_MARGIN
        bottom_pad = math.max(num_h, bottom_pad)

        if self.stack_covers and extra > 0 then
            local FAN_OFFSET = math.max(4, math.floor(cover_w * 0.12))
            local stack_w = math.max(8, cover_w - FAN_OFFSET)

            local front_widget = resolveCoverWidget(top, stack_w, cover_h)
            local back_widget  = resolveCoverWidget(books[2], stack_w, cover_h)

            local stack = OverlapGroup:new{
                dimen = Geom:new{w=cover_w, h=cover_h},
                allow_mirroring = false,
                FrameContainer:new{
                    padding=0, padding_left=FAN_OFFSET, padding_top=math.floor(FAN_OFFSET/2), bordersize=0,
                    back_widget,
                },
                FrameContainer:new{
                    padding=0, bordersize=0,
                    front_widget,
                },
            }

            table.insert(content, FrameContainer:new{
                padding=0, padding_top=bottom_pad, bordersize=0,
                CenterContainer:new{
                    dimen = Geom:new{w=W, h=cover_h},
                    stack,
                },
            })

            local remaining = #books - 2
            if remaining > 0 then
                local badge_face = Font:getFace("cfont", TITLE_SIZE)
                local badge = FrameContainer:new{
                    padding=1, bordersize=0, radius=Screen:scaleBySize(6),
                    background=Blitbuffer.COLOR_DARK_GRAY,
                    TextWidget:new{
                        text="+" .. remaining, face=badge_face,
                        fgcolor=Blitbuffer.COLOR_WHITE,
                    },
                }
                table.insert(content, RightContainer:new{
                    dimen=Geom:new{w=W, h=H},
                    FrameContainer:new{
                        padding=0, padding_top=BOTTOM_MARGIN, bordersize=0,
                        badge,
                    },
                })
            end
        else
            local cover_widget = resolveCoverWidget(top, cover_w, cover_h)

            table.insert(content, FrameContainer:new{
                padding=0, padding_top=bottom_pad, bordersize=0,
                CenterContainer:new{
                    dimen = Geom:new{w=W, h=cover_h},
                    cover_widget,
                },
            })

            if extra > 0 then
                local badge_face = Font:getFace("cfont", TITLE_SIZE)
                local badge = FrameContainer:new{
                    padding=1, bordersize=0, radius=Screen:scaleBySize(6),
                    background=Blitbuffer.COLOR_DARK_GRAY,
                    TextWidget:new{
                        text="+" .. extra, face=badge_face,
                        fgcolor=Blitbuffer.COLOR_WHITE,
                    },
                }
                table.insert(content, RightContainer:new{
                    dimen=Geom:new{w=W, h=H},
                    FrameContainer:new{
                        padding=0, padding_top=BOTTOM_MARGIN, bordersize=0,
                        badge,
                    },
                })
            end
        end

        if self.show_title then
            local t = top.title
            local max_chars = math.floor(cover_w / (TITLE_SIZE * 0.55))
            if #t > max_chars then t = t:sub(1, max_chars-1) .. "…" end
            table.insert(content, FrameContainer:new{
                padding=0, padding_top=num_h, bordersize=0,
                TextWidget:new{
                    text=t, face=title_face,
                    fgcolor=Blitbuffer.COLOR_BLACK,
                },
            })
        end
    end

    self[1] = FrameContainer:new{
        width=W, height=H, padding=0, bordersize=BORDER, radius=CELL_RADIUS,
        background=cell_bg,
        content,
    }

    -- IMPORTANT: InputContainer (which DayCell extends) only computes
    -- self.dimen lazily, inside paintTo() — see inputcontainer.lua:
    --   if not self.dimen then
    --       local content_size = self[1]:getSize()
    --       self.dimen = Geom:new{x=x, y=y, w=content_size.w, h=content_size.h}
    --   end
    -- Until first paint, self.dimen is nil, so any getSize() call a
    -- parent layout container (HorizontalGroup) makes BEFORE that first
    -- paint can't read a real width/height off it the way it can off a
    -- plain FrameContainer (used by the empty/blank cells), which
    -- computes its size immediately. This is the most likely explanation
    -- for the row-width inconsistency between months: populated rows
    -- (containing DayCells) and empty-only stretches behaved differently
    -- depending on render/measurement order. Setting self.dimen directly
    -- here — using position 0,0 as a placeholder, since InputContainer's
    -- own paintTo() already repositions dimen.x/y on every paint without
    -- touching w/h once set — guarantees a correct, immediately-available
    -- width and height for layout purposes from the moment this cell is
    -- constructed.
    self.dimen = Geom:new{x=0, y=0, w=W, h=H}

    -- IMPORTANT: gesture ranges are evaluated in absolute screen
    -- coordinates, but at init() time this cell hasn't been positioned
    -- by its parent grid yet. self.dimen.x/y get corrected to the real
    -- on-screen position by InputContainer's own paintTo() on each
    -- paint, so referencing it via a closure (rather than a value
    -- captured now) gives the correct on-screen rectangle at tap time.
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
    local lines = {self.day_str .. ":"}
    for _, b in ipairs(books) do
        table.insert(lines, string.format("• %s  (%d min)",
            b.title, math.floor(b.dur / 60)))
    end
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
    return true
end

-- ── Main calendar view ────────────────────────────────────────────────────────
local CoverCalendarView = InputContainer:extend{
    db_path       = "",
    show_title    = false,
    start_dow     = 2,
    year          = 0,
    month         = 0,
    cover_size    = "compact",
    stack_covers  = true,
    month_summary = false,
    today_color_id  = "none",
    streak_color_id = "none",
    stat_toggles  = nil,   -- {hours=bool, daily_avg=bool, pages=bool, days_active=bool, current_streak=bool, longest_streak=bool}
}

function CoverCalendarView:init()
    local now    = os.date("*t")
    self.year    = (self.year  ~= 0) and self.year  or now.year
    self.month   = (self.month ~= 0) and self.month or now.month
    self._today  = now
    self.stat_toggles = self.stat_toggles or {}
    CoverUtil.resetDebugLog()
    self._title_path_map = CoverUtil.buildTitlePathMap()
    if not CoverUtil.simpleUIAvailable() then
        logger.warn("CoverCalendar: SimpleUI's module_books_shared not found — "
            .. "covers will fall back to title placeholders")
    end

    self.ges_events = {
        Swipe = {
            GestureRange:new{
                ges="swipe",
                range=Geom:new{x=0,y=0,
                    w=Screen:getWidth(),h=Screen:getHeight()},
            }
        },
    }
    self:_build()
end

function CoverCalendarView:_build()
    local SW = Screen:getWidth()
    local SH = Screen:getHeight()

    -- ── Header ────────────────────────────────────────────────────────────────
    local HDR_H = Screen:scaleBySize(38)
    local BTN_W = Screen:scaleBySize(44)
    local HDR_MARGIN = Screen:scaleBySize(10)   -- keep edge buttons off the screen border

    local month_names = {
        _("January"),_("February"),_("March"),_("April"),
        _("May"),_("June"),_("July"),_("August"),
        _("September"),_("October"),_("November"),_("December"),
    }

    local header_children = {
        dimen=Geom:new{w=SW, h=HDR_H},
        allow_mirroring=false,
        -- prev
        FrameContainer:new{
            padding=2, padding_left=HDR_MARGIN, bordersize=BORDER,
            Button:new{
                text="‹", width=BTN_W, bordersize=0,
                callback=function() self:_prevMonth() end,
            },
        },
        -- month+year centred
        CenterContainer:new{
            dimen=Geom:new{w=SW, h=HDR_H},
            TextWidget:new{
                text=month_names[self.month].." "..self.year,
                face=Font:getFace("cfont", MONTH_SIZE),
            },
        },
        -- next (right of centre)
        RightContainer:new{
            dimen=Geom:new{w=BTN_W*2+4+HDR_MARGIN, h=HDR_H},
            FrameContainer:new{
                padding=2, bordersize=BORDER,
                Button:new{
                    text="›", width=BTN_W, bordersize=0,
                    callback=function() self:_nextMonth() end,
                },
            },
        },
        -- close (far right)
        RightContainer:new{
            dimen=Geom:new{w=SW - HDR_MARGIN, h=HDR_H},
            FrameContainer:new{
                padding=2, bordersize=BORDER,
                Button:new{
                    text="✕", width=BTN_W, bordersize=0,
                    callback=function() self:onClose() end,
                },
            },
        },
    }

    local header = OverlapGroup:new(header_children)

    -- ── DoW header ───────────────────────────────────────────────────────────
    local DOW_H = Screen:scaleBySize(18)
    -- Exact pixel widths: give remainder pixels to col 6
    local cell_w  = math.floor(SW / 7)
    local last_w  = SW - cell_w * 6  -- last column takes any remainder

    local dow_labels = (self.start_dow == 2)
        and {"Mo","Tu","We","Th","Fr","Sa","Su"}
        or  {"Su","Mo","Tu","We","Th","Fr","Sa"}

    local dow_row = HorizontalGroup:new{overlap=false}
    for i = 1, 7 do
        local w = (i == 7) and last_w or cell_w
        table.insert(dow_row, CenterContainer:new{
            dimen=Geom:new{w=w, h=DOW_H},
            TextWidget:new{
                text=dow_labels[i],
                face=Font:getFace("cfont", DOW_SIZE),
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

    -- ── Month summary header (optional) ─────────────────────────────────────
    -- Computed from the same `data` we already loaded for the grid.
    local SUMMARY_H = 0
    local summary_row = nil
    local toggles = self.stat_toggles or {}
    if self.month_summary then
        local total_secs = 0
        local days_with_reading = 0
        local seen_titles = {}
        local distinct_books = 0

        -- "Total pages" — the DB only stores a lifetime cumulative
        -- total_read_pages per book, not a per-session delta, so we can't
        -- isolate pages read in just this month precisely. As the most
        -- honest proxy available, we sum each touched book's CURRENT
        -- lifetime total_read_pages once per book. This overstates the
        -- month's share for books partly read before this month, but
        -- avoids inventing data the schema doesn't track.
        local total_pages = 0
        local pages_counted_for = {}

        for _, books_for_day in pairs(data) do
            if #books_for_day > 0 then
                days_with_reading = days_with_reading + 1
            end
            for _, b in ipairs(books_for_day) do
                total_secs = total_secs + (b.dur or 0)
                if not seen_titles[b.title] then
                    seen_titles[b.title] = true
                    distinct_books = distinct_books + 1
                end
                if not pages_counted_for[b.title] then
                    pages_counted_for[b.title] = true
                    total_pages = total_pages + (b.total_read_pages or 0)
                end
            end
        end

        local hours = math.floor(total_secs / 3600)
        local mins  = math.floor((total_secs % 3600) / 60)
        local time_str = (hours > 0)
            and string.format("%dh %dm", hours, mins)
            or string.format("%dm", mins)

        local avg_secs = (days_with_reading > 0) and (total_secs / days_with_reading) or 0
        local avg_mins = math.floor(avg_secs / 60)

        -- Current streak / longest streak — derived from streak_days
        -- (computed earlier for cell shading), which is scoped to the
        -- displayed month only. "Current streak" here means the run
        -- ending on the LAST day of the month that has reading data (not
        -- necessarily today, if viewing a past month); it will under-count
        -- streaks that started in the previous month since we don't query
        -- across month boundaries.
        local longest_streak = 0
        local current_streak = 0
        do
            local run = 0
            local last_active_day = nil
            for d = 1, days_in_m do
                local ds = string.format("%04d-%02d-%02d", self.year, self.month, d)
                local active = (data[ds] ~= nil and #data[ds] > 0)
                if active then
                    run = run + 1
                    last_active_day = d
                    if run > longest_streak then longest_streak = run end
                else
                    run = 0
                end
            end
            -- Current streak: the run ending at the most recent active day.
            if last_active_day then
                local run2 = 0
                for d = last_active_day, 1, -1 do
                    local ds = string.format("%04d-%02d-%02d", self.year, self.month, d)
                    if data[ds] ~= nil and #data[ds] > 0 then
                        run2 = run2 + 1
                    else
                        break
                    end
                end
                current_streak = run2
            end
        end

        -- Build the summary line from only the toggled-on pieces, joined
        -- with a middle dot, so the user controls exactly what shows.
        local parts = {}
        if toggles.hours then
            table.insert(parts, string.format(_("%s read"), time_str))
        end
        if toggles.daily_avg and days_with_reading > 0 then
            table.insert(parts, string.format(_("%d min/day avg"), avg_mins))
        end
        if toggles.days_active then
            table.insert(parts, string.format(
                _("%d day%s active"), days_with_reading, days_with_reading == 1 and "" or "s"))
        end
        if toggles.pages and total_pages > 0 then
            table.insert(parts, string.format(_("%d pages"), total_pages))
        end
        if toggles.current_streak and current_streak > 0 then
            table.insert(parts, string.format(
                _("Current streak: %d day%s"), current_streak, current_streak == 1 and "" or "s"))
        end
        if toggles.longest_streak and longest_streak > 0 then
            table.insert(parts, string.format(
                _("Longest streak: %d day%s"), longest_streak, longest_streak == 1 and "" or "s"))
        end

        if #parts > 0 then
            local summary_text = table.concat(parts, "  ·  ")
            SUMMARY_H = Screen:scaleBySize(24)
            summary_row = CenterContainer:new{
                dimen = Geom:new{w=SW, h=SUMMARY_H},
                TextWidget:new{
                    text = summary_text,
                    face = Font:getFace("cfont", DOW_SIZE),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                },
            }
        end
    end

    -- Remaining height after header + separator + dow + separator + summary
    -- (+ its own separator line, if shown)
    local SEP = BORDER
    local summary_block_h = self.month_summary and (SUMMARY_H + SEP) or 0
    local remaining_h = SH - HDR_H - SEP - DOW_H - SEP - summary_block_h
    local n_rows_calc = math.ceil((first_col + days_in_m) / 7)
    local cell_h = math.floor(remaining_h / n_rows_calc)

    local grid = VerticalGroup:new{overlap=false}
    local cur_day = 1

    for row = 1, n_rows do
        local hrow = HorizontalGroup:new{overlap=false}

        for col = 0, 6 do
            local w = (col == 6) and last_w or cell_w
            -- Is this cell before day 1 of the month?
            local is_prefix = (row == 1 and col < first_col)
            -- Have we passed the last day?
            local is_overflow = (cur_day > days_in_m)

            if is_prefix or is_overflow then
                table.insert(hrow, makeEmptyCell(w, cell_h))
            else
                local ds    = string.format("%04d-%02d-%02d",
                    self.year, self.month, cur_day)
                local books = data[ds]
                local today = (self.year  == self._today.year
                    and self.month == self._today.month
                    and cur_day    == self._today.day)

                table.insert(hrow, DayCell:new{
                    width      = w,
                    height     = cell_h,
                    day        = cur_day,
                    day_str    = ds,
                    books      = books,
                    title_path_map = self._title_path_map,
                    show_title = self.show_title,
                    is_today   = today,
                    cover_size   = self.cover_size,
                    stack_covers = self.stack_covers,
                    in_streak    = streak_days[cur_day] or false,
                    today_color_id  = self.today_color_id,
                    streak_color_id = self.streak_color_id,
                })
                cur_day = cur_day + 1
            end
        end

        -- IMPORTANT: explicitly force this row to occupy the FULL screen
        -- width via a fixed-dimen wrapper, rather than trusting
        -- HorizontalGroup to auto-size to exactly SW from its children's
        -- measured widths. This is the same "force a dimen" pattern used
        -- throughout KOReader's own core widgets (e.g. WidgetContainer
        -- wrappers with an explicit Geom dimen in screensaver.lua,
        -- menu.lua) specifically to avoid auto-sizing ambiguity. Without
        -- this, a row whose total measured width came out even slightly
        -- under SW (for any reason — rounding, a child not honoring its
        -- declared width, etc.) could end up centered or left-shifted by
        -- whatever the parent VerticalGroup's default behavior is, which
        -- is exactly the inconsistent centering bug being chased here.
        local hrow_fixed = WidgetContainer:new{
            dimen = Geom:new{x=0, y=0, w=SW, h=cell_h},
            hrow,
        }
        table.insert(grid, hrow_fixed)

        -- DIAGNOSTIC: log the row's actual measured size vs the expected
        -- screen width, so the next debug log tells us ground truth
        -- instead of another guess about HorizontalGroup/VerticalGroup
        -- auto-sizing behavior.
        local ok_size, hrow_size = pcall(function() return hrow:getSize() end)
        local ok_size2, hrow_fixed_size = pcall(function() return hrow_fixed:getSize() end)
        logger.info("CoverCalendar: row", row, "of", n_rows,
            "raw hrow size:", ok_size and (hrow_size.w .. "x" .. hrow_size.h) or "ERR",
            "wrapped size:", ok_size2 and (hrow_fixed_size.w .. "x" .. hrow_fixed_size.h) or "ERR",
            "expected SW:", SW)
        -- No row separator: rounded, self-bordered cells already read as
        -- distinct cards, and a full-width line behind them produced a
        -- visible "ghost grid" effect cutting across the rounded corners.
    end

    -- ── Assemble full screen ──────────────────────────────────────────────────
    local vgroup_children = {
        overlap=false,
        header,
        LineWidget:new{background=Blitbuffer.COLOR_BLACK,
            line_width=SEP, dimen=Geom:new{w=SW,h=SEP}},
    }
    if summary_row then
        table.insert(vgroup_children, summary_row)
        table.insert(vgroup_children, LineWidget:new{
            background=Blitbuffer.gray(0.7),
            line_width=SEP, dimen=Geom:new{w=SW,h=SEP},
        })
    end
    table.insert(vgroup_children, dow_row)
    table.insert(vgroup_children, LineWidget:new{
        background=Blitbuffer.COLOR_DARK_GRAY,
        line_width=SEP, dimen=Geom:new{w=SW,h=SEP},
    })
    table.insert(vgroup_children, grid)

    self[1] = FrameContainer:new{
        width=SW, height=SH, padding=0, bordersize=0,
        background=Blitbuffer.COLOR_WHITE,
        VerticalGroup:new(vgroup_children),
    }

    UIManager:setDirty(self, "partial")
end

function CoverCalendarView:_prevMonth()
    self.month = self.month - 1
    if self.month < 1 then self.month=12; self.year=self.year-1 end
    self:_build()
end

function CoverCalendarView:_nextMonth()
    self.month = self.month + 1
    if self.month > 12 then self.month=1; self.year=self.year+1 end
    self:_build()
end

function CoverCalendarView:onSwipe(_, ges)
    if ges.direction == "left"  then self:_nextMonth(); return true end
    if ges.direction == "right" then self:_prevMonth(); return true end
end

function CoverCalendarView:onClose()
    -- IMPORTANT: UIManager:close() alone doesn't guarantee an e-ink
    -- refresh happens — it only enqueues one if other dirty widgets are
    -- still on the stack. Passing "full" here forces the screen to
    -- actually repaint immediately, instead of leaving the stale
    -- calendar image on screen until some unrelated UI event (like
    -- tapping the status bar) happens to trigger a refresh.
    UIManager:close(self, "full")
end

function CoverCalendarView:onShow()
    UIManager:setDirty(self, "full")
end

return CoverCalendarView
