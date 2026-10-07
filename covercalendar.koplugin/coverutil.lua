--[[
    coverutil.lua  (v2.0.2)

    Shared helpers for the CoverCalendar plugin:
      - finding the book FILE that belongs to a title in the statistics DB
      - getting that file's cover out of KOReader's cover cache
      - the title "chip" shown when there genuinely is no cover
      - the large header tap targets used by both views
      - finished-book detection and colour presets

    ── Why covers went missing in 2.0.1 ──────────────────────────────────────
    The statistics DB only knows a book's TITLE. To draw a cover we need the
    FILE, and 2.0.1 found it by comparing the title against the file NAMES in
    reading history. Three things went wrong for some libraries:

      1. The name doesn't look like the title, e.g.
           "Author - Title.epub"  (KOReader's own OPDS downloads use this)
           "9781234567897.epub"   (ISBN / store / library names)
           transliterated or shortened names
         — and a book that has dropped out of history can't be found at all.
      2. Books KOReader had indexed WITHOUT a cover (file browser set to a
         list with metadata only) were never asked for one.
      3. With the Cover Browser plugin switched off, its cover cache could
         not be loaded, so no book had a cover.

    2.0.2 looks a book up in these places and stops at the first hit:
      a. a file name that equals the title, or has it as one " - " part,
         on either side of the dash
      b. the title stored in KOReader's cover cache — the real metadata
         title, so the file name is irrelevant, and it still knows books
         that are gone from history
      c. the file's checksum: the statistics DB records it and so does each
         book's sidecar, which makes this exact whatever the file is called.
         Sidecars are only read when a and b found nothing.
      d. looser matching (title without its subtitle, reordered words), and
         last of all 2.0.1's own matcher, so nothing that used to be found
         stops being found

    Covers come from BookInfoManager (Cover Browser's cache). Books that are
    not cached yet are extracted the way Cover Browser does it: in a
    background process, never inside the running KOReader. 2.0.1 extracted
    in-process, which froze the screen meanwhile and switched KOReader's own
    rendering cache to a temporary folder for the rest of the session.
--]]

local logger = require("logger")
local CoverUtil = {}

-- How many not-yet-seen sidecars one calendar session may read while looking
-- for a book that the cheaper lookups could not find.
local SIDECAR_SCAN_BUDGET = 400

local function getLfs()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    return ok and lfs or nil
end

local function fileExists(path)
    local lfs = getLfs()
    return lfs ~= nil and path ~= nil and lfs.attributes(path, "mode") == "file"
end

-- ── Text normalisation ────────────────────────────────────────────────────────
-- Lower-case, and turn everything that is not a letter or digit into a single
-- space. Bytes >= 128 are kept so non-Latin titles survive untouched.
local function norm(s)
    if not s then return "" end
    s = tostring(s):lower()
    s = s:gsub("\226\128[\128-\191]", " ")       -- curly quotes, dashes, ellipsis
    s = s:gsub("[^0-9a-z\128-\255]+", " ")
    s = s:gsub("^ +", ""):gsub(" +$", "")
    return s
end

-- Same, with the spaces removed: "Don't Wake" and "Don_t Wake" both become
-- "dontwake", so punctuation and spacing differences stop mattering.
local function squash(n)
    return (n:gsub(" ", ""))
end

local function stripExt(name)
    local base = name:gsub("%.[%w]+$", "")       -- .epub
    base = base:gsub("%.kepub$", "")             -- name.kepub.epub
    return base
end

local function stripBrackets(s)
    s = s:gsub("%b()", " "):gsub("%b[]", " "):gsub("%b{}", " ")
    return s
end

-- "Author - Title", "Title - Author", "Title -- Author -- Year" → the parts
local function splitSegments(s)
    s = s:gsub("\226\128[\147\148]", "-")        -- en/em dash → hyphen
    s = s:gsub("_%-+_", " - ")
    local out, pos = {}, 1
    while true do
        local a, b = s:find("%s%-+%s", pos)
        if not a then
            table.insert(out, s:sub(pos))
            break
        end
        table.insert(out, s:sub(pos, a - 1))
        pos = b + 1
    end
    return out
end

-- The part before a subtitle: "The Quiet Meridian: A Novel" → "The Quiet
-- Meridian". Calibre writes ":" as "_" in file names, so accept "_ " too.
local function mainTitle(s)
    return s:match("^(.-)%s*:%s") or s:match("^(.-)_%s")
end

-- Every form of a title / file name worth comparing, squashed, with how much
-- of the original each one stands for:
local W_FULL = 100   -- the whole string
local W_NOBR = 97    -- ... minus anything in (brackets)
local W_SEG  = 95    -- one " - " separated part
local W_MAIN = 80    -- the part before a subtitle
-- Returns { [form] = weight }
local function variants(raw)
    local set = {}
    local function add(str, weight)
        if not str then return end
        local q = squash(norm(str))
        if q ~= "" and (set[q] or 0) < weight then set[q] = weight end
    end
    add(raw, W_FULL)
    local nobr = stripBrackets(raw)
    add(nobr, W_NOBR)
    add(mainTitle(nobr), W_MAIN)
    local segs = splitSegments(nobr)
    if #segs > 1 then
        for _, seg in ipairs(segs) do
            add(seg, W_SEG)
            add(mainTitle(seg), W_MAIN)
        end
    end
    return set
end

local function tokenSet(n)
    local set, count = {}, 0
    for w in n:gmatch("%S+") do
        if not set[w] then
            set[w] = true
            count = count + 1
        end
    end
    return set, count
end

-- A match on a very short, single-word title ("It", "Veil") is only trusted
-- when something else backs it up (the author's name in the file name).
local function substantial(q)
    return #q >= 5
end

-- ── Reading history → resolver ────────────────────────────────────────────────
-- The returned table is passed around by the views as "title_path_map"; only
-- this file looks inside it.
function CoverUtil.buildTitlePathMap()
    local map = {
        entries = {},          -- history items, most recent first
        by_path = {},          -- path → entry
        memo = {},             -- md5 or title → path | false
        sidecars = {},         -- path → parsed sidecar summary | false
        scan_budget = SIDECAR_SCAN_BUDGET,
    }
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or not ReadHistory then
        logger.warn("CoverCalendar: require('readhistory') failed")
        return map
    end
    local hist = ReadHistory.hist
    if not hist then return map end
    for _, item in ipairs(hist) do
        local path = item.file
        if path and not map.by_path[path] then
            local e = {
                path = path,
                -- history only stores the file NAME, never the book's title
                name = item.text or path:gsub(".*/", ""),
                gone = item.dim and true or false,
            }
            table.insert(map.entries, e)
            map.by_path[path] = e
        end
    end
    logger.info("CoverCalendar: history has", #map.entries, "books")
    return map
end

local function prepEntries(map)
    if map.prepared then return end
    map.prepared = true
    map.strong = {}            -- form → { {e = entry, w = weight}, ... }
    for _, e in ipairs(map.entries) do
        local base = stripExt(e.name)
        e.vars = variants(base)
        e.tokens = tokenSet(norm(base))
        e.segs = {}            -- { norm = "...", tokens = set, count = n }
        for _, seg in ipairs(splitSegments(stripBrackets(base))) do
            local n = norm(seg)
            if n ~= "" then
                local set, count = tokenSet(n)
                table.insert(e.segs, { norm = n, tokens = set, count = count })
            end
        end
        for q, weight in pairs(e.vars) do
            local list = map.strong[q]
            if not list then
                list = {}
                map.strong[q] = list
            end
            table.insert(list, { e = e, w = weight })
        end
    end
end

local function authorTokens(authors)
    local out = {}
    if type(authors) ~= "string" or authors == "" or authors == "N/A" then
        return out
    end
    for w in norm(authors):gmatch("%S+") do
        if #w >= 3 then out[w] = true end
    end
    return out
end

local function hasAuthor(entry, a_tokens)
    for w in pairs(a_tokens) do
        if entry.tokens[w] then return true end
    end
    return false
end

-- ── Layer: file name equals the title (or one part of the name does) ─────────
-- "Tomas Reyes - Salt and Cedar.epub" has the parts "tomas reyes" and
-- "salt and cedar"; the second one IS the title, whichever side of the dash
-- it sits on. (2.0.1 only ever looked at the part before the dash.)
local function findExact(map, title, authors)
    prepEntries(map)
    local t_vars = variants(title)
    local a_tokens = authorTokens(authors)
    local best, best_rank
    for q, tw in pairs(t_vars) do
        if tw >= W_NOBR then                      -- the whole title
            for _, c in ipairs(map.strong[q] or {}) do
                if c.w >= W_SEG then              -- a whole part of the name
                    -- whole name == whole title needs no backing: it also
                    -- covers books without metadata, whose "title" in the
                    -- statistics DB IS the file name
                    if (tw == W_FULL and c.w == W_FULL)
                       or substantial(q) or hasAuthor(c.e, a_tokens) then
                        local rank = tw + c.w + (c.e.gone and 0 or 0.5)
                        if not best or rank > best_rank then
                            best, best_rank = c.e, rank
                        end
                    end
                end
            end
        end
    end
    return best and best.path or nil
end

-- ── Layer: only the main title matches ────────────────────────────────────────
-- "Glasswork - Odile Brandt.epub" for "Glasswork: A Novel", or the other way
-- round. Less certain than the above (a series name before the colon would
-- match a sibling volume), so this only runs after the exact lookups,
-- including the checksum scan, found nothing.
local function findVariant(map, title, authors)
    prepEntries(map)
    local t_vars = variants(title)
    local a_tokens = authorTokens(authors)
    local best, best_rank
    for q, tw in pairs(t_vars) do
        for _, c in ipairs(map.strong[q] or {}) do
            if (tw < W_NOBR or c.w < W_SEG)
               and (substantial(q) or hasAuthor(c.e, a_tokens)) then
                local rank = #q * 2 + (tw + c.w) / 100 + (c.e.gone and 0 or 0.5)
                if not best or rank > best_rank then
                    best, best_rank = c.e, rank
                end
            end
        end
    end
    return best and best.path or nil
end

-- ── Layer: the title recorded in KOReader's cover cache ───────────────────────
-- CoverBrowser stores every indexed book's real metadata title next to its
-- path, so this is an exact title match that does not care what the file is
-- called — and it still works for books that are gone from history.
local function bimIndex(map)
    if map.bim_index ~= nil then return map.bim_index or nil end
    map.bim_index = false
    local ok, idx = pcall(function()
        local DataStorage = require("datastorage")
        local db = DataStorage:getSettingsDir() .. "/bookinfo_cache.sqlite3"
        if not fileExists(db) then return nil end
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(db, "ro")
        pcall(function() conn:set_busy_timeout(1000) end)
        local ok_q, res = pcall(function()
            return conn:exec([[SELECT directory, filename, title, authors
                               FROM bookinfo
                               WHERE title IS NOT NULL AND title != '']])
        end)
        pcall(function() conn:close() end)
        if not ok_q or not res or not res[1] then return nil end
        local out = {}
        for i = 1, #res[1] do
            local q = squash(norm(res[3][i]))
            if q ~= "" then
                local list = out[q]
                if not list then
                    list = {}
                    out[q] = list
                end
                table.insert(list, {
                    path = tostring(res[1][i]) .. tostring(res[2][i]),
                    authors = res[4] and res[4][i] or nil,
                })
            end
        end
        return out
    end)
    if ok and idx then map.bim_index = idx end
    return map.bim_index or nil
end

local function findInCoverCache(map, title, authors)
    local idx = bimIndex(map)
    if not idx then return nil end
    local list = idx[squash(norm(title))]
    if not list then return nil end
    if #list == 1 then return list[1].path end
    -- Several files share this title: prefer the same author, then a file
    -- that is in history, then one that still exists.
    local want = squash(norm(authors))
    local best, best_rank = nil, -1
    for _, c in ipairs(list) do
        local rank = 0
        if want ~= "" and squash(norm(c.authors)) == want then rank = rank + 4 end
        if map.by_path[c.path] then rank = rank + 2 end
        if fileExists(c.path) then rank = rank + 1 end
        if rank > best_rank then best, best_rank = c, rank end
    end
    return best and best.path or nil
end

-- ── Layer: sidecar scan (checksum, then the sidecar's own title) ──────────────
-- The statistics DB stores each book's partial MD5, and so does the book's
-- sidecar (.sdr). Matching those is exact no matter what the file is called.
-- Sidecars are only read when the cheaper lookups found nothing, at most
-- SIDECAR_SCAN_BUDGET per calendar session, and what was read is remembered
-- for the rest of the KOReader session.
local _scanned = {}        -- path → true
local _md5_index = {}      -- md5 → path
local _sc_titles = {}      -- squashed sidecar title → path

-- Read-only load of a sidecar's table. DocSettings:open() is deliberately
-- avoided where possible: it is heavier and may delete sidecar candidates
-- it considers invalid.
local function loadSidecarTable(path)
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds or not DocSettings then return nil end
    if DocSettings.findSidecarFile then
        local ok, file = pcall(DocSettings.findSidecarFile, DocSettings, path)
        if not ok or not file then return nil end
        local ok_l, data = pcall(dofile, file)
        if ok_l and type(data) == "table" then return data end
        return nil
    end
    -- KOReader older than 2024.04
    local ok, ds = pcall(DocSettings.open, DocSettings, path)
    if ok and ds and type(ds.data) == "table" then return ds.data end
    return nil
end

local function sidecarSummary(map, path)
    local cached = map.sidecars[path]
    if cached ~= nil then return cached or nil end
    local data = loadSidecarTable(path)
    local out = false
    if data then
        out = { md5 = data.partial_md5_checksum }
        local props = data.doc_props or data.stats
        if type(props) == "table" and type(props.title) == "string" then
            out.title = props.title
        end
        if type(data.summary) == "table" then
            out.status = data.summary.status
            if type(data.summary.modified) == "string" then
                out.modified = data.summary.modified:match("^(%d%d%d%d%-%d%d%-%d%d)")
            end
        end
        if type(data.percent_finished) == "number" then
            out.percent = data.percent_finished
        end
    end
    map.sidecars[path] = out
    return out or nil
end

local function scanSidecars(map)
    for _, e in ipairs(map.entries) do
        if map.scan_budget <= 0 then return end
        if not _scanned[e.path] then
            _scanned[e.path] = true
            map.scan_budget = map.scan_budget - 1
            local sc = sidecarSummary(map, e.path)
            if sc then
                if type(sc.md5) == "string" and sc.md5 ~= "" then
                    _md5_index[sc.md5] = _md5_index[sc.md5] or e.path
                end
                if sc.title and sc.title ~= "" then
                    local q = squash(norm(sc.title))
                    if q ~= "" then _sc_titles[q] = _sc_titles[q] or e.path end
                end
            end
        end
    end
end

-- An index hit only counts while that file is still in history; a moved or
-- removed book is dropped so it can be found again under its new path.
local function fromIndex(map, index, key)
    local path = key and index[key]
    if not path then return nil end
    if map.by_path[path] then return path end
    index[key] = nil
    _scanned[path] = nil
    return nil
end

-- ── Layer: looser word matching ───────────────────────────────────────────────
-- Deliberately conservative: a sequel's file ("Hollow Tide Rising") must not
-- stand in for a book whose own file is gone ("Hollow Tide").
local STOPWORDS = { a = true, an = true, the = true, of = true, ["and"] = true,
                    ["in"] = true, to = true, on = true, ["for"] = true }

local function isSubset(small, big)
    for w in pairs(small) do
        if not big[w] then return false end
    end
    return true
end

local function findWeak(map, title, authors)
    prepEntries(map)
    local nobr = stripBrackets(title)
    local t_norm = norm(nobr)
    if t_norm == "" then return nil end
    local t_tokens, t_count = tokenSet(t_norm)
    local t_squash = squash(t_norm)
    local main = mainTitle(nobr)
    local m_tokens, m_count = tokenSet(main and norm(main) or "")
    local a_tokens = authorTokens(authors)

    local content, content_count = {}, 0
    for w in pairs(t_tokens) do
        if not STOPWORDS[w] then
            content[w] = true
            content_count = content_count + 1
        end
    end

    local best, best_score = nil, 0
    for _, e in ipairs(map.entries) do
        local score = 0

        -- (a) one part of the file name is the title's words in another
        --     order or with at most a third more ("Lantern Orchard, The")
        for _, seg in ipairs(e.segs) do
            if (t_count >= 2 and seg.count <= math.floor(t_count * 1.34)
                    and isSubset(t_tokens, seg.tokens))
               or (m_count >= 2 and seg.count <= math.floor(m_count * 1.34)
                    and isSubset(m_tokens, seg.tokens)) then
                score = 70
                break
            end
        end

        -- (b) the file name is a long title cut short by a length limit
        if score == 0 then
            for _, seg in ipairs(e.segs) do
                local sq = squash(seg.norm)
                if #sq >= 20 and #sq < #t_squash and t_squash:sub(1, #sq) == sq then
                    score = 65
                    break
                end
            end
        end

        -- (c) nearly all of the title's meaningful words are in the name
        if score == 0 and content_count >= 3 then
            local matched = 0
            for w in pairs(content) do
                if e.tokens[w] then matched = matched + 1 end
            end
            if matched >= 3 and matched / content_count >= 0.8 then
                score = 50 + matched
            end
        end

        if score > 0 then
            if hasAuthor(e, a_tokens) then score = score + 5 end
            if not e.gone then score = score + 2 end
            if score > best_score then best, best_score = e, score end
        end
    end
    return best and best.path or nil
end

-- ── Layer: 2.0.1's matcher as the last resort ────────────────────────────────
-- Unchanged apart from refusing very short strings ("It" matched any file
-- name containing those two letters).
local function legacyNormalize(s)
    if not s then return "" end
    s = s:gsub("%.%w+$", "")
    local before_dash = s:match("^(.-)%s%-%s[^%-]+$")
    local base = before_dash or s
    base = base:gsub("[%:%_%-%.]", " ")
    base = base:lower()
    base = base:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return base
end

local function findLegacy(map, title)
    local norm_title = legacyNormalize(title)
    if #norm_title < 4 then return nil end   -- "It" would match anything
    local best_path, best_score = nil, -1
    for _, e in ipairs(map.entries) do
        local nh = legacyNormalize(e.name)
        if nh ~= "" then
            local score = nil
            if nh == norm_title then
                score = 1000
            elseif nh:find(norm_title, 1, true) or norm_title:find(nh, 1, true) then
                if #nh >= 4 then score = 100 - math.abs(#nh - #norm_title) end
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
                best_score = score; best_path = e.path
            end
        end
    end
    return best_path
end

-- ── Public: title (+ optional book row) → file path ───────────────────────────
-- book: optional table from the statistics DB with .authors and .md5.
-- Results are remembered per calendar session, so the 30-odd cells of a
-- month that show the same book only pay for the lookup once.
function CoverUtil.findPathForTitle(map, title, book)
    if type(map) ~= "table" or not map.entries or not title then return nil end
    local md5 = book and type(book.md5) == "string" and book.md5 ~= "" and book.md5 or nil
    local authors = book and book.authors or nil
    local key = md5 or title
    local memo = map.memo[key]
    if memo ~= nil then return memo or nil end

    local path, how
    local function try(name, fn, ...)
        if path then return end
        local ok, p = pcall(fn, ...)
        if ok and p then
            path, how = p, name
        elseif not ok then
            logger.warn("CoverCalendar: lookup step", name, "failed:", tostring(p))
        end
    end

    try("checksum", fromIndex, map, _md5_index, md5)
    try("file name", findExact, map, title, authors)
    try("cover cache", findInCoverCache, map, title, authors)
    if not path then
        pcall(scanSidecars, map)
        try("checksum", fromIndex, map, _md5_index, md5)
        try("sidecar title", fromIndex, map, _sc_titles, squash(norm(title)))
    end
    try("part of file name", findVariant, map, title, authors)
    try("words", findWeak, map, title, authors)
    try("2.0.1 matcher", findLegacy, map, title)

    if path then
        logger.dbg("CoverCalendar:", title, "->", path, "(" .. how .. ")")
    else
        logger.info("CoverCalendar: no book file found for", title)
    end
    map.memo[key] = path or false
    return path
end

-- ── BookInfoManager (CoverBrowser's cover cache) ──────────────────────────────

local _cache_warm = false
local _BIM = nil

local function getBIM()
    if _BIM then return _BIM end
    local ok, bim = pcall(require, "bookinfomanager")
    if not (ok and bim) then
        -- KOReader does not load a disabled plugin's code or put its folder
        -- on the module search path, so with Cover Browser switched off the
        -- require above fails — and 2.0.1 then showed no covers at all. The
        -- cache manager is self-contained, so point the search path at
        -- Cover Browser's folder and load it anyway.
        local candidates = { "plugins/coverbrowser.koplugin" }
        local src = debug.getinfo(1, "S").source or ""
        local parent = src:match("^@(.*)/[^/]+/[^/]+$")
        if parent then table.insert(candidates, parent .. "/coverbrowser.koplugin") end
        local ok_ds, DataStorage = pcall(require, "datastorage")
        if ok_ds and DataStorage then
            table.insert(candidates, DataStorage:getDataDir() .. "/plugins/coverbrowser.koplugin")
        end
        for _, dir in ipairs(candidates) do
            if fileExists(dir .. "/bookinfomanager.lua") then
                package.path = dir .. "/?.lua;" .. package.path
                ok, bim = pcall(require, "bookinfomanager")
                if ok and bim then break end
            end
        end
    end
    if ok and bim then
        _BIM = bim
    else
        logger.warn("CoverCalendar: BookInfoManager unavailable:", tostring(bim))
    end
    return _BIM
end

-- Retained for API compatibility; a no-op since cover widgets stopped being
-- shared between views.
function CoverUtil.clearCoverCache()
end

function CoverUtil.isCoverCacheWarm()
    return _cache_warm
end

-- What the cover cache knows about a file.
--   "ok"         has a cover (bookinfo.cover_bb is set when want_bb)
--   "todo"       not cached yet (or cached without ever looking for a cover)
--                and the file exists → worth extracting
--   "missing"    not cached, and the file is gone
--   "nocover"    KOReader looked: this book has no cover image
--   "unreadable" KOReader could not open this file
--   "nobim"      the cover cache could not be loaded
local function coverStatus(path, want_bb)
    local BIM = getBIM()
    if not BIM then return "nobim" end
    local ok, bookinfo = pcall(BIM.getBookInfo, BIM, path, want_bb and true or false)
    if not ok then
        logger.warn("CoverCalendar: getBookInfo failed for", path, tostring(bookinfo))
        return "nobim"
    end
    if bookinfo then
        if bookinfo.has_cover and (bookinfo.cover_bb or not want_bb) then
            return "ok", bookinfo
        end
        if bookinfo.unsupported or bookinfo._no_provider then return "unreadable" end
        -- cover_fetched means KOReader already looked for a cover. A row
        -- WITHOUT it was indexed for metadata only ("list with metadata, no
        -- images"); 2.0.1 mistook that for "this book has no cover".
        if bookinfo.cover_fetched then return "nocover" end
    end
    if fileExists(path) then return "todo" end
    return "missing"
end

-- ── Background extraction ─────────────────────────────────────────────────────
-- Uncached books are handed to BookInfoManager:extractInBackground(), exactly
-- as CoverBrowser does for the file browser. It runs in a forked process, so
-- the calendar stays responsive and a broken book cannot take KOReader down.
-- Views register a callback and are rebuilt as covers arrive.

local _queue = {}          -- paths waiting for the next batch
local _attempts = {}       -- path → times requested this KOReader session
local _in_flight = {}      -- path → true while queued or being extracted
local _batch = nil         -- { paths = {...}, started = os.time() }
local _listeners = {}      -- owner → function()
local _poll_pending = false
local _foreign_wait = 0
local _last_batch_end = 0
local _last_notify = 0
local _unnotified = false  -- covers arrived that no view has been told about

local MAX_ATTEMPTS = 2
local BATCH_TIMEOUT = 180  -- seconds

local function coverSpecs()
    local w, h = 600, 800
    local ok, Device = pcall(require, "device")
    if ok and Device and Device.screen then
        w, h = Device.screen:getWidth(), Device.screen:getHeight()
    end
    local short, long = math.min(w, h), math.max(w, h)
    -- A third of the screen: enough for the largest cover either view draws,
    -- and the size CoverBrowser's own 3x3 mosaic uses, so it won't redo them.
    return {
        sizetag = "M",     -- only read by KOReader older than 2024.04
        max_cover_w = math.floor(short / 3),
        max_cover_h = math.floor(long / 3),
    }
end

local function queueExtraction(path)
    if _in_flight[path] then return true end
    if (_attempts[path] or 0) >= MAX_ATTEMPTS then return false end
    _attempts[path] = (_attempts[path] or 0) + 1
    _in_flight[path] = true
    table.insert(_queue, path)
    return true
end

local function notifyListeners()
    _last_notify = os.time()
    for owner, fn in pairs(_listeners) do
        local ok, err = pcall(fn)
        if not ok then
            logger.warn("CoverCalendar: cover refresh failed:", tostring(err))
            _listeners[owner] = nil
        end
    end
end

local function isExtracting(BIM)
    local ok, running = pcall(BIM.isExtractingInBackground, BIM)
    return ok and running and true or false
end

local poll

local function schedulePoll(delay)
    if _poll_pending then return end
    local ok, UIManager = pcall(require, "ui/uimanager")
    if not ok then return end
    _poll_pending = true
    UIManager:scheduleIn(delay, poll)
end

poll = function()
    _poll_pending = false
    local BIM = getBIM()
    if not BIM then
        _queue, _batch, _in_flight = {}, nil, {}
        return
    end

    if _batch then
        local remaining = {}
        for _, p in ipairs(_batch.paths) do
            local status = coverStatus(p, false)
            if status == "todo" then
                table.insert(remaining, p)
            else
                _in_flight[p] = nil
                _unnotified = true
            end
        end
        _batch.paths = remaining
        if #remaining == 0 then
            _batch = nil
            _last_batch_end = os.time()
        elseif not isExtracting(BIM)
               or os.time() - _batch.started > BATCH_TIMEOUT then
            -- The job ended without finishing these (killed by a file
            -- browser page turn, or it crashed on a book). Books are
            -- processed in order, so only the first one left can be the
            -- culprit: it keeps its strike (MAX_ATTEMPTS per session), the
            -- rest were never started and get theirs back. Telling the
            -- views makes them ask again for whatever is still missing.
            for i, p in ipairs(remaining) do
                _in_flight[p] = nil
                if i > 1 then _attempts[p] = math.max(0, (_attempts[p] or 1) - 1) end
            end
            _batch = nil
            _last_batch_end = os.time()
            _unnotified = true
        end
    end

    if not _batch and #_queue > 0 then
        -- Someone else (the file browser) is mid-extraction: starting ours
        -- would kill theirs, so give it a few seconds first. KOReader only
        -- notices that a job has ended every 10 s, so "still extracting"
        -- right after one of OUR batches just means it hasn't looked yet.
        local ours_just_ended = os.time() - _last_batch_end < 12
        if isExtracting(BIM) and not ours_just_ended and _foreign_wait < 3 then
            _foreign_wait = _foreign_wait + 1
        else
            _foreign_wait = 0
            local specs = coverSpecs()
            local files, paths = {}, {}
            for _, p in ipairs(_queue) do
                table.insert(files, { filepath = p, cover_specs = specs })
                table.insert(paths, p)
            end
            _queue = {}
            local ok, started = pcall(BIM.extractInBackground, BIM, files)
            if ok and started then
                logger.info("CoverCalendar: extracting", #paths, "covers in the background")
                _batch = { paths = paths, started = os.time() }
            else
                logger.warn("CoverCalendar: could not start cover extraction:", tostring(started))
                for _, p in ipairs(paths) do _in_flight[p] = nil end
            end
        end
    end

    -- Repaint as covers arrive, but not more than every other second while
    -- a batch is still running: each repaint is a visible e-ink refresh.
    if _unnotified and (not _batch or os.time() - _last_notify >= 2) then
        _unnotified = false
        notifyListeners()
    end

    if _batch or #_queue > 0 then schedulePoll(1) end
end

-- Views call this after every build. on_ready is called (possibly several
-- times) when covers that were missing during that build have arrived.
function CoverUtil.requestPendingCovers(owner, on_ready)
    if owner and on_ready then _listeners[owner] = on_ready end
    if #_queue > 0 or _batch then schedulePoll(0.2) end
end

-- Views call this when they close.
function CoverUtil.forgetListener(owner)
    if owner then _listeners[owner] = nil end
end

-- ── Cover widget ──────────────────────────────────────────────────────────────
-- Returns an ImageWidget scaled to fit w x h (aspect ratio kept), or
-- nil, status when there is no cover to show right now.
function CoverUtil.getCoverWidget(path, w, h)
    if not path or path == "" then return nil, "nofile" end

    local status, bookinfo = coverStatus(path, true)
    if status == "todo" then
        return nil, queueExtraction(path) and "pending" or "failed"
    end
    if status ~= "ok" then return nil, status end

    local cover_bb = bookinfo.cover_bb
    local bw = bookinfo.cover_w or cover_bb:getWidth()
    local bh = bookinfo.cover_h or cover_bb:getHeight()
    if not bw or not bh or bw <= 0 or bh <= 0 then
        cover_bb:free()
        return nil, "nocover"
    end
    local sf = math.min(w / bw, h / bh)

    local ok_iw, ImageWidget = pcall(require, "ui/widget/imagewidget")
    if not ok_iw then
        cover_bb:free()
        return nil, "nobim"
    end

    -- getBookInfo() hands back a FRESH decompressed bitmap on every call, so
    -- this widget owns it outright (nothing is shared between cells or
    -- views). Rendering straight away lets ImageWidget scale it down and
    -- free the full-size original now, instead of every cell of the month
    -- holding one until the garbage collector gets round to it.
    local ok_w, widget = pcall(ImageWidget.new, ImageWidget, {
        image = cover_bb,
        scale_factor = sf,
        image_disposable = true,
    })
    if not ok_w or not widget then
        cover_bb:free()
        return nil, "nobim"
    end
    pcall(widget._render, widget)

    _cache_warm = true
    return widget
end

-- ── Title chip (shown when a book has no cover to draw) ───────────────────────
-- The title is wrapped and kept inside the chip; 2.0.1 drew it on one line,
-- which spilled over the neighbouring days.
function CoverUtil.makeTitleChip(title, w, h, opts)
    opts = opts or {}
    local Blitbuffer      = require("ffi/blitbuffer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Font            = require("ui/font")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local Geom            = require("ui/geometry")
    local Screen          = require("device").screen
    local TextBoxWidget   = require("ui/widget/textboxwidget")

    local bg   = opts.background or Blitbuffer.COLOR_LIGHT_GRAY
    local pad  = Screen:scaleBySize(3)
    local face = Font:getFace("cfont", opts.font_size or 8)
    local in_w = math.max(4, w - 2 * pad - 2)
    local in_h = math.max(4, h - 2 * pad - 2)

    local function box(fixed_h)
        return TextBoxWidget:new{
            text = tostring(title or ""),
            face = face,
            width = in_w,
            height = fixed_h,
            height_adjust = fixed_h and true or nil,
            height_overflow_show_ellipsis = fixed_h and true or nil,
            alignment = "center",
            fgcolor = Blitbuffer.COLOR_BLACK,
            bgcolor = bg,
        }
    end

    local content
    local ok, text = pcall(box, nil)
    if ok and text then
        local ok_s, text_h, line_h = pcall(function()
            return text:getSize().h, text:getLineHeight()
        end)
        if ok_s and text_h > in_h then
            pcall(function() text:free() end)
            text = nil
            if line_h and line_h <= in_h then
                ok, text = pcall(box, in_h)
                if not ok then text = nil end
            end
        end
        content = text
    end
    if not content then
        content = require("ui/widget/verticalspan"):new{ width = 1 }
    end

    return FrameContainer:new{
        padding = 0, bordersize = 1, radius = Screen:scaleBySize(3),
        width = w, height = h,
        background = bg,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2, h = h - 2 },
            content,
        },
    }
end

-- ── Header tap targets ────────────────────────────────────────────────────────
-- A borderless Button with an explicit, generous touch area. 2.0.1's arrows
-- and close button were only as big as their glyph plus a few pixels (about
-- 4 mm on a Libra Colour), which is hard to hit.
--   opts.text, opts.callback
--   opts.height     total touch height
--   opts.width      total touch width (omit for text buttons: sized to the
--                   label plus opts.pad_h on each side)
--   opts.font_size, opts.bold
function CoverUtil.headerButton(opts)
    local Button     = require("ui/widget/button")
    local Font       = require("ui/font")
    local Screen     = require("device").screen
    local TextWidget = require("ui/widget/textwidget")

    local font_size = opts.font_size or 20
    local bold = opts.bold ~= false
    -- Button has no reliable "height" before KOReader 2025, so reach the
    -- wanted height through vertical padding around the measured label.
    local probe = TextWidget:new{
        text = opts.text, face = Font:getFace("cfont", font_size), bold = bold,
    }
    local label = probe:getSize()
    probe:free()
    local pad_v = math.max(0, math.floor(((opts.height or 0) - label.h) / 2))
    local pad_h = opts.pad_h or Screen:scaleBySize(10)

    return Button:new{
        text = opts.text,
        bordersize = 0,
        margin = 0,
        width = opts.width,
        padding = pad_v,
        padding_v = pad_v,
        padding_h = opts.width and 0 or pad_h,
        text_font_face = "cfont",
        text_font_size = font_size,
        text_font_bold = bold,
        callback = opts.callback,
    }
end

-- ── Finished-book detection (shared: monthly stats + yearly overview) ────────
CoverUtil.FINISH_PERCENT   = 0.95  -- endnotes/back matter often leave ~3-5%
CoverUtil.MEANINGFUL_SECS  = 300   -- a session counts toward a finish date
CoverUtil.MEANINGFUL_PAGES = 5     -- only if ≥5 min or ≥5 distinct pages

-- bk: {title=..., authors=..., md5=..., pages=..., total_read_pages=...}
-- Returns: finished (bool), path (string|nil), sidecar_date ("YYYY-MM-DD"|nil)
function CoverUtil.getFinishedInfo(title_path_map, bk)
    local path = title_path_map
        and CoverUtil.findPathForTitle(title_path_map, bk.title, bk)
    local sc = path and sidecarSummary(title_path_map, path) or nil
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

-- ── Missing-cover report (Cover Calendar menu → Missing covers report) ────────
-- Lists every book read in the last `days` days that the calendar cannot
-- draw a cover for, with the reason — so "my covers don't show" can be
-- answered without guessing.
local STATUS_TEXT = {
    nofile     = "No matching book file found. It was probably deleted, renamed outside KOReader, or removed from History.",
    missing    = "The file has been deleted and its cover was never cached.",
    nocover    = "KOReader found no cover image inside this book.",
    unreadable = "KOReader could not open this file to look for a cover.",
    nobim      = "KOReader's cover cache (the Cover Browser plugin) could not be loaded.",
    todo       = "Not fetched yet. Open the calendar on that month and wait a few seconds.",
}

function CoverUtil.missingCoverReport(db_path, days)
    days = days or 365
    local lines = {}
    local ok, err = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(db_path, "ro")
        local sql = string.format([[
            SELECT b.title, b.authors, b.md5, MAX(psd.start_time) AS last_seen
            FROM page_stat_data psd
            JOIN book b ON b.id = psd.id_book
            WHERE psd.start_time >= %d
            GROUP BY b.id
            ORDER BY last_seen DESC
        ]], os.time() - days * 86400)
        local ok_q, res = pcall(function() return conn:exec(sql) end)
        pcall(function() conn:close() end)
        local n = (ok_q and res and res[1]) and #res[1] or 0

        local map = CoverUtil.buildTitlePathMap()
        local missing = 0
        for i = 1, n do
            local book = {
                title = res[1][i],
                authors = res[2] and res[2][i] or nil,
                md5 = res[3] and res[3][i] or nil,
            }
            local path = CoverUtil.findPathForTitle(map, book.title, book)
            local status = path and coverStatus(path, false) or "nofile"
            if status ~= "ok" then
                missing = missing + 1
                table.insert(lines, "")
                table.insert(lines, "• " .. tostring(book.title))
                if path then table.insert(lines, "  " .. path) end
                table.insert(lines, "  " .. (STATUS_TEXT[status] or status))
            end
        end
        table.insert(lines, 1, string.format(
            "Books read in the last %d days: %d\nWith a cover: %d\nWithout: %d",
            days, n, n - missing, missing))
        if missing == 0 then
            table.insert(lines, "")
            table.insert(lines, "Every book has a cover available.")
        end
    end)
    if not ok then
        return "Could not build the report:\n" .. tostring(err)
    end
    return table.concat(lines, "\n")
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
