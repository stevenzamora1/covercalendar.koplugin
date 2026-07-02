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

local _cover_cache = {}
local _cache_warm = false
local _BIM = nil

local function getBIM()
    if _BIM then return _BIM end
    local ok, bim = pcall(require, "bookinfomanager")
    if ok and bim then _BIM = bim end
    return _BIM
end

function CoverUtil.clearCoverCache()
    for _, widget in pairs(_cover_cache) do
        if widget and widget.free then
            pcall(widget.free, widget)
        end
    end
    _cover_cache = {}
end

function CoverUtil.isCoverCacheWarm()
    return _cache_warm
end

function CoverUtil.getCoverWidget(path, w, h)
    if not path or path == "" then return nil end

    local cache_key = path .. ":" .. w .. "x" .. h
    if _cover_cache[cache_key] then return _cover_cache[cache_key] end

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

    local ok_w, widget = pcall(ImageWidget.new, ImageWidget, {
        image=bookinfo.cover_bb, scale_factor=sf,
    })
    if not ok_w or not widget then return nil end

    _cache_warm = true
    _cover_cache[cache_key] = widget
    return widget
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
