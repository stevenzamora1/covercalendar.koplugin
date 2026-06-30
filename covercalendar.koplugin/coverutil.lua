--[[
    coverutil.lua  (v4 - with diagnostics)

    Same approach as v3 (delegate to SimpleUI's module_books_shared),
    but every step now logs to crash.log via KOReader's logger AND to
    a dedicated debug file we can read back, since silent failures
    have wasted several iterations already.
--]]

local DataStorage = require("datastorage")
local logger      = require("logger")

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end

local CoverUtil = {}

-- Debug log written next to the plugin so it's easy to find/share.
local DEBUG_LOG = DataStorage:getSettingsDir() .. "/covercalendar_debug.log"

local function dbg(...)
    local parts = {}
    for i, v in ipairs({...}) do parts[i] = tostring(v) end
    local line = "[" .. os.date("%H:%M:%S") .. "] " .. table.concat(parts, " ")
    logger.info("CoverCalendar:", line)
    local f = io.open(DEBUG_LOG, "a")
    if f then
        f:write(line .. "\n")
        f:close()
    end
end

function CoverUtil.resetDebugLog()
    local f = io.open(DEBUG_LOG, "w")
    if f then
        f:write("=== CoverCalendar debug log: " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===\n")
        f:close()
    end
end

function CoverUtil.getDebugLogPath()
    return DEBUG_LOG
end

-- Lazily require SimpleUI's shared book module.
local _SH = nil
local _SH_tried = false
local function getSH()
    if _SH_tried then return _SH end
    _SH_tried = true

    local candidates = {
        "desktop_modules/module_books_shared",
        "desktop_modules.module_books_shared",
    }
    for _, modname in ipairs(candidates) do
        local ok, m = pcall(require, modname)
        if ok and m then
            dbg("require('" .. modname .. "') succeeded, type=", type(m))
            if type(m) == "table" then
                local keys = {}
                for k, v in pairs(m) do keys[#keys+1] = k .. "(" .. type(v) .. ")" end
                dbg("  module keys: " .. table.concat(keys, ", "))
            end
            if m.getBookCover then
                _SH = m
                dbg("  -> getBookCover found, using this module")
                return _SH
            else
                dbg("  -> no getBookCover field on this module, skipping")
            end
        else
            dbg("require('" .. modname .. "') failed:", tostring(m))
        end
    end
    dbg("FAILED to find any working module_books_shared. Is SimpleUI installed under that exact path?")
    return nil
end

function CoverUtil.buildTitlePathMap()
    local map = {}

    -- readhistory is the actual KOReader module backing History — NOT a
    -- plain G_reader_settings key. It exposes a `.hist` array of entries
    -- like { file = "/path/to/book.epub", text = "Display Name", ... }.
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or not ReadHistory then
        dbg("require('readhistory') failed:", tostring(ReadHistory))
        return map
    end

    local hist = ReadHistory.hist
    if not hist then
        dbg("readhistory loaded but .hist is nil")
        return map
    end

    local count = 0
    local sample = {}
    for _, item in ipairs(hist) do
        count = count + 1
        -- item.text is usually the filename/display title; item.file is the path.
        -- We also try item.title in case that field exists on this version.
        local title = item.title or item.text
        local path  = item.file
        if title and path and not map[title] then
            map[title] = path
            if #sample < 5 then
                sample[#sample+1] = string.format("  '%s' -> %s", title, path)
            end
        end
    end
    dbg("readhistory.hist has", count, "entries; built",
        (function() local n=0 for _ in pairs(map) do n=n+1 end return n end)(),
        "title->path mappings")
    for _, s in ipairs(sample) do dbg(s) end

    return map
end

-- Strip extension and path, lowercase, collapse separators — used to
-- fuzzy-match a DB title against a history filename when exact title
-- strings don't line up (DB title comes from document metadata; history
-- text is often just the filename).
local function normalize(s)
    if not s then return "" end
    s = s:gsub("%.%w+$", "")              -- drop extension
    -- Strip a trailing " - Author Name" pattern (common filename convention
    -- like "Dune - Frank Herbert"), keeping only the part before the last " - ".
    local before_dash = s:match("^(.-)%s%-%s[^%-]+$")
    local base = before_dash or s
    base = base:gsub("[_%-%.]", " ")      -- separators -> space
    base = base:lower()
    base = base:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return base
end

-- Find a path for a given DB title, trying exact match first, then a
-- normalized/fuzzy match against history filenames as a fallback.
-- `map` is the title->path table from buildTitlePathMap().
local _logged_titles = {}
function CoverUtil.findPathForTitle(map, title)
    if not title then return nil end

    if not _logged_titles[title] then
        _logged_titles[title] = true
        dbg("LOOKUP requested for DB title: '" .. title .. "'")
    end

    if map[title] then
        dbg("  exact match found")
        return map[title]
    end

    local norm_title = normalize(title)
    for hist_title, path in pairs(map) do
        if normalize(hist_title) == norm_title then
            dbg("  normalized exact match: '" .. hist_title .. "'")
            return path
        end
    end

    -- last resort: substring match either direction, but require the
    -- DB title to be reasonably long to avoid short titles matching
    -- unrelated books (e.g. "Dune" inside "Dune Messiah").
    -- We score matches by length-closeness and pick the best one instead
    -- of just the first hit.
    local best_path, best_score = nil, -1
    for hist_title, path in pairs(map) do
        local nh = normalize(hist_title)
        if nh ~= "" and norm_title ~= "" then
            local hit = nh:find(norm_title, 1, true) or norm_title:find(nh, 1, true)
            if hit then
                -- prefer matches where the lengths are closest (avoids
                -- "Dune" matching "Dune Messiah" when "Dune" itself exists)
                local score = -math.abs(#nh - #norm_title)
                if score > best_score then
                    best_score = score
                    best_path = path
                end
            end
        end
    end
    if best_path then
        dbg("  substring/fuzzy match found, score=" .. tostring(best_score))
    else
        dbg("  NO MATCH FOUND for '" .. title .. "' (normalized: '" .. norm_title .. "')")
    end
    return best_path
end

function CoverUtil.getCoverWidget(path, w, h)
    if not path or path == "" then
        dbg("getCoverWidget called with empty path")
        return nil
    end
    local SH = getSH()
    if not SH then
        dbg("getCoverWidget: SH unavailable, returning nil for", path)
        return nil
    end

    local ok, cover = pcall(SH.getBookCover, path, w, h, nil, 0.10)
    if not ok then
        dbg("getBookCover() pcall FAILED for", path, "error:", tostring(cover))
        return nil
    end
    if not cover then
        dbg("getBookCover() returned nil (no error, but no cover) for", path)
        return nil
    end
    dbg("getBookCover() OK for", path, "-> widget type:", type(cover))
    return cover
end

function CoverUtil.simpleUIAvailable()
    return getSH() ~= nil
end

-- ── Shared color presets for cell highlighting ──────────────────────────────
-- Used by the calendar view to resolve a chosen preset id to RGB values.
-- (The settings menu itself is built as fully static, literal menu items in
-- main.lua rather than generated from this table — an earlier dynamic
-- version executed require()/loops at menu-construction time and is the
-- suspected cause of the plugin's menu entry disappearing entirely.)
--
-- "none" is the default: no tint at all, cells stay plain white.
-- Other presets give a very light tint (220+/255 on every channel) so day
-- numbers and cover art stay clearly readable on top of it.
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
