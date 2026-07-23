--[[
    coverutil.lua

    Cover extraction, title-to-path mapping, fuzzy matching, and
    color preset definitions for the CoverCalendar plugin.

    Cover extraction uses KOReader's native BookInfoManager — the same
    module CoverBrowser itself uses — rather than relying on SimpleUI.
    This means covers work on any KOReader installation with no optional
    dependencies required.
--]]

local logger = require("logger")
local CoverUtil = {}

-- ── Title → file path mapping ─────────────────────────────────────────────────

function CoverUtil.buildTitlePathMap()
    local map = {}
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or not ReadHistory then
        logger.warn("CoverCalendar: require('readhistory') failed")
        return map
    end
    local hist = ReadHistory.hist
    if not hist then return map end
    for _, item in ipairs(hist) do
        local title = item.title or item.text
        local path  = item.file
        if title and path and not map[title] then
            map[title] = path
        end
    end
    logger.info("CoverCalendar: built", (function()
        local n = 0; for _ in pairs(map) do n=n+1 end; return n
    end)(), "title->path mappings")
    return map
end

local function normalize(s)
    if not s then return "" end
    s = s:gsub("%.%w+$", "")              -- drop file extension
    local before_dash = s:match("^(.-)%s%-%s[^%-]+$")
    local base = before_dash or s
    base = base:gsub("[%:%_%-%.]", " ")   -- separators + colons → space
    base = base:lower()
    base = base:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return base
end

function CoverUtil.findPathForTitle(map, title)
    if not title then return nil end
    if map[title] then return map[title] end

    local norm_title = normalize(title)

    -- Exact normalized match
    for hist_title, path in pairs(map) do
        if normalize(hist_title) == norm_title then return path end
    end

    -- Substring / prefix / word-overlap match
    local best_path, best_score = nil, -1
    for hist_title, path in pairs(map) do
        local nh = normalize(hist_title)
        if nh ~= "" and norm_title ~= "" then
            local score = nil
            if nh:find(norm_title, 1, true) or norm_title:find(nh, 1, true) then
                score = 100 - math.abs(#nh - #norm_title)
            elseif #nh <= #norm_title and norm_title:sub(1, #nh) == nh then
                score = 80 - (#norm_title - #nh)
            elseif #norm_title <= #nh and nh:sub(1, #norm_title) == norm_title then
                score = 80 - (#nh - #norm_title)
            else
                local shorter = #nh <= #norm_title and nh or norm_title
                local longer  = #nh <= #norm_title and norm_title or nh
                local words, matched = 0, 0
                for word in shorter:gmatch("%S+") do
                    words = words + 1
                    if longer:find(word, 1, true) then matched = matched + 1 end
                end
                if words > 0 and matched / words >= 0.7 then
                    score = 60 + matched - words
                end
            end
            if score and score > best_score then
                best_score = score; best_path = path
            end
        end
    end
    return best_path
end

-- ── Native cover extraction via BookInfoManager ───────────────────────────────

local _cache_warm = false
local _BIM = nil

local function getBIM()
    if _BIM then return _BIM end
    local ok, bim = pcall(require, "bookinfomanager")
    if ok and bim then _BIM = bim end
    return _BIM
end

-- Retained for API compatibility but now a NO-OP: cover widgets are no
-- longer shared between views. Each getCoverWidget() call returns a FRESH
-- ImageWidget owned solely by the widget tree it is inserted into, so
-- UIManager freeing a closed view's tree can never corrupt covers painted
-- elsewhere — which was the bug producing garbled noise blocks when
-- reopening the year view or returning from a day popup: the shared cached
-- widgets' internal buffers were freed along with the closed view's tree,
-- then repainted. The expensive part (decoding covers out of the books) is
-- already cached by BookInfoManager in its own SQLite DB, so per-view
-- widget creation stays cheap.
function CoverUtil.clearCoverCache()
end

function CoverUtil.isCoverCacheWarm()
    return _cache_warm
end

function CoverUtil.getCoverWidget(path, w, h)
    if not path or path == "" then return nil end

    local BIM = getBIM()
    if not BIM then return nil end

    local ok, bookinfo = pcall(BIM.getBookInfo, BIM, path, true)
    if not ok or not bookinfo or not bookinfo.cover_bb then return nil end

    local sf
    local ok2, _, _, csf = pcall(
        BIM.getCachedCoverSize, BIM, bookinfo.cover_w, bookinfo.cover_h, w, h)
    if ok2 and csf then
        sf = csf
    else
        local bw = bookinfo.cover_w or w
        local bh = bookinfo.cover_h or h
        sf = math.min(w / bw, h / bh)
    end

    local ok_iw, ImageWidget = pcall(require, "ui/widget/imagewidget")
    if not ok_iw then return nil end

    -- image_disposable=false is the load-bearing part: the source
    -- blitbuffer belongs to BookInfoManager and may be shared by other
    -- simultaneously-alive widgets (monthly grid under the year view).
    -- The widget's own scaled buffer is per-widget and freed with its view.
    local ok_w, widget = pcall(ImageWidget.new, ImageWidget, {
        image = bookinfo.cover_bb,
        scale_factor = sf,
        image_disposable = false,
    })
    if not ok_w or not widget then return nil end

    _cache_warm = true
    return widget
end

-- ── Finished-book detection (shared: monthly stats + yearly overview) ────────
CoverUtil.FINISH_PERCENT   = 0.95  -- endnotes/back matter often leave ~3-5%
CoverUtil.MEANINGFUL_SECS  = 300   -- a session counts toward a finish date
CoverUtil.MEANINGFUL_PAGES = 5     -- only if ≥5 min or ≥5 distinct pages

local function readSidecar(path)
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds or not DocSettings then return nil end
    local ok_sd, sidecar = pcall(DocSettings.open, DocSettings, path)
    if not ok_sd or not sidecar then return nil end
    local out = {}
    local ok_sum, summary = pcall(sidecar.readSetting, sidecar, "summary")
    if ok_sum and type(summary) == "table" then
        out.status = summary.status
        if type(summary.modified) == "string" then
            out.modified = summary.modified:match("^(%d%d%d%d%-%d%d%-%d%d)")
        end
    end
    local ok_pf, pf = pcall(sidecar.readSetting, sidecar, "percent_finished")
    if ok_pf and type(pf) == "number" then out.percent = pf end
    return out
end

-- bk: {title=..., pages=..., total_read_pages=...}
-- Returns: finished (bool), path (string|nil), sidecar_date ("YYYY-MM-DD"|nil)
function CoverUtil.getFinishedInfo(title_path_map, bk)
    local path = title_path_map
        and CoverUtil.findPathForTitle(title_path_map, bk.title)
    local sc = path and readSidecar(path) or nil
    if sc then
        if sc.status == "complete" then
            return true, path, sc.modified
        end
        if sc.status ~= "abandoned"
           and sc.percent and sc.percent >= CoverUtil.FINISH_PERCENT then
            return true, path, nil
        end
    end
    -- DB fallback — also covers books whose files were deleted
    if bk.pages and bk.pages > 0 and bk.total_read_pages
       and bk.total_read_pages >= bk.pages * CoverUtil.FINISH_PERCENT then
        return true, path, nil
    end
    return false, path, nil
end

-- sessions: ascending array of {ds="YYYY-MM-DD", dur=secs, pages_today=n}
-- restricted to the period of interest; range bounds are inclusive ISO dates
-- (ISO dates compare correctly as plain strings).
-- Returns: finished_ds ("YYYY-MM-DD"|nil), path
--
-- A finished book is credited to a period by:
--   1. its sidecar completion date (summary.modified) when inside the range.
--      If a sidecar date exists but falls OUTSIDE the range, the book is NOT
--      credited to this period at all — reopening a long-finished book to
--      check a quote must not re-file it into the current month/year.
--   2. otherwise, the last MEANINGFUL session in range — trivial peeks
--      (under 5 min AND under 5 pages) never set a finish date either.
function CoverUtil.finishedDateInRange(title_path_map, bk, sessions, range_start, range_end)
    local finished, path, sd = CoverUtil.getFinishedInfo(title_path_map, bk)
    if not finished then return nil, path end
    if sd then
        if sd >= range_start and sd <= range_end then
            return sd, path
        end
        return nil, path
    end
    for i = #sessions, 1, -1 do
        local s = sessions[i]
        if (s.dur or 0) >= CoverUtil.MEANINGFUL_SECS
           or (s.pages_today or 0) >= CoverUtil.MEANINGFUL_PAGES then
            return s.ds, path
        end
    end
    return nil, path
end

-- ── Color presets ─────────────────────────────────────────────────────────────

CoverUtil.COLOR_PRESETS = {
    { id = "none",   label = "None (default)", rgb = nil, none = true },
    { id = "orange", label = "Light orange",   rgb = {255, 214, 160} },
    { id = "red",    label = "Light red",      rgb = {255, 205, 200} },
    { id = "blue",   label = "Light blue",     rgb = {221, 235, 250} },
    { id = "green",  label = "Light green",    rgb = {224, 240, 222} },
    { id = "gray",   label = "Light gray",     rgb = nil, gray = true },
}

function CoverUtil.getColorPreset(id)
    for _, p in ipairs(CoverUtil.COLOR_PRESETS) do
        if p.id == id then return p end
    end
    return CoverUtil.COLOR_PRESETS[1]
end

return CoverUtil
