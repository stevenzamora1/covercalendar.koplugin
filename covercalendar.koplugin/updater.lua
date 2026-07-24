--[[
    updater.lua

    Version check and self-update for the CoverCalendar plugin, against
    GitHub releases at:
        https://github.com/stevenzamora1/covercalendar.koplugin

    ── Why it installs on the NEXT startup ───────────────────────────────────
    A running plugin cannot safely overwrite its own .lua files: they are
    already loaded, other modules may still be required lazily, and a failed
    mid-write leaves a half-broken plugin that may not load at all. So the
    update is a two-phase operation:

      Phase 1 (now):  download the release zip, extract it into a STAGING
                      directory next to the plugin, verify it looks sane
                      (contains _meta.lua + main.lua), leave the running
                      plugin completely untouched.
      Phase 2 (next start): CoverCalendar:init() calls applyStagedUpdate()
                      BEFORE doing anything else. At that moment none of the
                      new files are loaded yet, so copying them over the live
                      plugin directory is safe. The staging dir is removed
                      afterwards, success or failure.

    If phase 2 fails partway, the previous version is restored from the
    backup taken immediately before the copy.

    ── Platform notes ────────────────────────────────────────────────────────
    Extraction shells out to `unzip`, which exists on Kobo (BusyBox) and most
    Kindle/KOReader builds but is NOT guaranteed everywhere. When it is
    missing, the updater degrades gracefully: the version CHECK still works
    and the user is pointed at the release URL to install manually. Nothing
    here is required for the calendar itself to function.
--]]

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local UIManager   = require("ui/uimanager")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local _ = require("gettext")

local Updater = {}

Updater.REPO      = "stevenzamora1/covercalendar.koplugin"
Updater.API_URL   = "https://api.github.com/repos/stevenzamora1/covercalendar.koplugin/releases/latest"
Updater.RELEASE_URL = "https://github.com/stevenzamora1/covercalendar.koplugin/releases/latest"

local PLUGIN_DIRNAME = "covercalendar.koplugin"
local STAGING_DIRNAME = "covercalendar.koplugin.update"
local BACKUP_DIRNAME  = "covercalendar.koplugin.backup"

-- ── Paths ────────────────────────────────────────────────────────────────────

-- The plugins directory that actually contains this plugin. Users may install
-- under either the data dir or the install dir, so probe both rather than
-- assuming.
function Updater.getPluginsDir()
    local candidates = {}
    local ok_ds, ds = pcall(function() return DataStorage:getDataDir() end)
    if ok_ds and ds then table.insert(candidates, ds .. "/plugins") end
    local ok_fu, ffiutil = pcall(require, "ffi/util")
    if ok_fu and ffiutil and ffiutil.realpath then
        local ok_p, p = pcall(ffiutil.realpath, "plugins")
        if ok_p and p then table.insert(candidates, p) end
    end
    for _, dir in ipairs(candidates) do
        if lfs.attributes(dir .. "/" .. PLUGIN_DIRNAME, "mode") == "directory" then
            return dir
        end
    end
    return candidates[1]
end

-- ── Version helpers ──────────────────────────────────────────────────────────

function Updater.getLocalVersion()
    local ok, meta = pcall(dofile, Updater.getPluginsDir()
        .. "/" .. PLUGIN_DIRNAME .. "/_meta.lua")
    if ok and type(meta) == "table" and meta.version then
        return tostring(meta.version)
    end
    return "0"
end

-- Compares dotted numeric versions ("2.10" > "2.9"), ignoring a leading "v".
-- Returns true when `remote` is strictly newer than `local_v`.
function Updater.isNewer(remote, local_v)
    local function parts(v)
        local out = {}
        for n in tostring(v):gsub("^[vV]", ""):gmatch("%d+") do
            table.insert(out, tonumber(n))
        end
        return out
    end
    local a, b = parts(remote), parts(local_v)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

-- ── HTTP ─────────────────────────────────────────────────────────────────────

-- Returns body (string) or nil, err. GitHub requires a User-Agent header.
--
-- Redirects are followed MANUALLY here. LuaSec's ssl.https does not follow
-- redirects at all — worse, it returns nil, "redirect not supported" if the
-- request table even contains a `redirect` field — and GitHub's download
-- URLs (release assets, zipballs) always redirect to
-- objects.githubusercontent.com / codeload.github.com. So we issue the
-- request, and on a 3xx re-issue it against the Location header, up to
-- MAX_REDIRECTS hops, picking http vs https per hop.
local MAX_REDIRECTS = 5

local function httpGet(url, sink_to_file)
    local ok_h, http = pcall(require, "socket.http")
    local ok_s, https = pcall(require, "ssl.https")
    local ok_l, ltn12 = pcall(require, "ltn12")
    if not ok_l or not ltn12 then return nil, "ltn12 unavailable" end

    for _ = 0, MAX_REDIRECTS do
        local requester = (url:match("^https") and ok_s and https)
            or (ok_h and http)
        if not requester then return nil, "no http library" end

        local sink, body_tbl, fh
        if sink_to_file then
            local err
            fh, err = io.open(sink_to_file, "wb")
            if not fh then return nil, "cannot write " .. tostring(err) end
            sink = ltn12.sink.file(fh)   -- closes fh when the request ends
        else
            body_tbl = {}
            sink = ltn12.sink.table(body_tbl)
        end

        local ok_req, code, headers = pcall(function()
            local _, c, h = requester.request{
                url = url,
                headers = {
                    ["User-Agent"] = "KOReader-CoverCalendar",
                    ["Accept"] = "application/vnd.github+json",
                },
                sink = sink,
            }
            return c, h
        end)

        if not ok_req then return nil, "request failed: " .. tostring(code) end

        if code == 301 or code == 302 or code == 303
           or code == 307 or code == 308 then
            local location = headers and (headers.location or headers.Location)
            if not location then return nil, "redirect without location" end
            -- Relative redirect: resolve against the current URL's host
            if not location:match("^https?://") then
                local base = url:match("^(https?://[^/]+)")
                location = (base or "") .. location
            end
            url = location
            -- loop: re-request against the new URL
        elseif code ~= 200 then
            return nil, "HTTP " .. tostring(code)
        else
            if sink_to_file then return true end
            return table.concat(body_tbl)
        end
    end
    return nil, "too many redirects"
end

-- ── Release lookup ───────────────────────────────────────────────────────────

-- Returns {version=..., zip_url=..., notes=...} or nil, err
function Updater.fetchLatestRelease()
    local body, err = httpGet(Updater.API_URL)
    if not body then return nil, err end

    local data
    local ok_rj, rapidjson = pcall(require, "rapidjson")
    if ok_rj and rapidjson then
        local ok_d, decoded = pcall(rapidjson.decode, body)
        if ok_d then data = decoded end
    end
    if not data then
        local ok_j, JSON = pcall(require, "json")
        if ok_j and JSON and JSON.decode then
            local ok_d, decoded = pcall(JSON.decode, body)
            if ok_d then data = decoded end
        end
    end
    if type(data) ~= "table" then return nil, "could not parse release data" end
    if not data.tag_name then return nil, "no release found" end

    -- Prefer an uploaded .zip asset; fall back to GitHub's source zipball.
    local zip_url = data.zipball_url
    if type(data.assets) == "table" then
        for _, a in ipairs(data.assets) do
            if type(a) == "table" and a.browser_download_url
               and tostring(a.name or ""):match("%.zip$") then
                zip_url = a.browser_download_url
                break
            end
        end
    end

    return {
        version = tostring(data.tag_name),
        zip_url = zip_url,
        notes   = data.body,
    }
end

-- ── Filesystem helpers ───────────────────────────────────────────────────────

local function rmTree(path)
    if lfs.attributes(path, "mode") ~= "directory" then
        if lfs.attributes(path, "mode") then os.remove(path) end
        return
    end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            rmTree(path .. "/" .. entry)
        end
    end
    lfs.rmdir(path)
end

local function copyTree(src, dst)
    if lfs.attributes(dst, "mode") ~= "directory" then
        lfs.mkdir(dst)
    end
    for entry in lfs.dir(src) do
        if entry ~= "." and entry ~= ".." then
            local s, d = src .. "/" .. entry, dst .. "/" .. entry
            if lfs.attributes(s, "mode") == "directory" then
                copyTree(s, d)
            else
                local fi = io.open(s, "rb")
                if fi then
                    local content = fi:read("*a")
                    fi:close()
                    local fo = io.open(d, "wb")
                    if fo then fo:write(content); fo:close() end
                end
            end
        end
    end
end

-- A staged update is valid only if it contains the plugin's core files.
-- GitHub source zipballs nest everything one level deep under
-- "<user>-<repo>-<sha>/", so look one level down too.
local function findPluginRoot(dir)
    if lfs.attributes(dir .. "/_meta.lua", "mode") == "file"
       and lfs.attributes(dir .. "/main.lua", "mode") == "file" then
        return dir
    end
    if lfs.attributes(dir, "mode") ~= "directory" then return nil end
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local sub = dir .. "/" .. entry
            if lfs.attributes(sub, "mode") == "directory"
               and lfs.attributes(sub .. "/_meta.lua", "mode") == "file"
               and lfs.attributes(sub .. "/main.lua", "mode") == "file" then
                return sub
            end
        end
    end
    return nil
end

-- ── Phase 1: download + stage ────────────────────────────────────────────────

function Updater.stageUpdate(release)
    local plugins_dir = Updater.getPluginsDir()
    local staging = plugins_dir .. "/" .. STAGING_DIRNAME
    local tmp_zip = plugins_dir .. "/covercalendar_update.zip"

    rmTree(staging)
    os.remove(tmp_zip)

    local ok_dl, err = httpGet(release.zip_url, tmp_zip)
    if not ok_dl then return false, err end

    lfs.mkdir(staging)
    -- No bundled Lua unzip on all platforms; shell out. -o overwrite, -q quiet.
    local cmd = string.format('unzip -o -q "%s" -d "%s"', tmp_zip, staging)
    local ok_ex = os.execute(cmd)
    os.remove(tmp_zip)
    -- os.execute returns true/0 on success depending on Lua version
    if not (ok_ex == true or ok_ex == 0) then
        rmTree(staging)
        return false, "could not extract (unzip unavailable?)"
    end

    local root = findPluginRoot(staging)
    if not root then
        rmTree(staging)
        return false, "downloaded archive did not look like the plugin"
    end

    -- Normalise: if the payload was nested, hoist it to the staging root so
    -- phase 2 has a predictable layout.
    if root ~= staging then
        local hoisted = plugins_dir .. "/" .. STAGING_DIRNAME .. ".tmp"
        rmTree(hoisted)
        copyTree(root, hoisted)
        rmTree(staging)
        os.rename(hoisted, staging)
    end

    return true
end

-- ── Phase 2: install staged update (called at startup, before load) ──────────

-- Returns installed_version or nil. Safe to call unconditionally.
function Updater.applyStagedUpdate()
    local plugins_dir = Updater.getPluginsDir()
    local staging = plugins_dir .. "/" .. STAGING_DIRNAME
    if lfs.attributes(staging, "mode") ~= "directory" then return nil end

    local live   = plugins_dir .. "/" .. PLUGIN_DIRNAME
    local backup = plugins_dir .. "/" .. BACKUP_DIRNAME

    if not findPluginRoot(staging) then
        rmTree(staging)
        return nil
    end

    local new_version
    local ok_meta, meta = pcall(dofile, staging .. "/_meta.lua")
    if ok_meta and type(meta) == "table" then
        new_version = tostring(meta.version or "?")
    end

    rmTree(backup)
    local ok_backup = pcall(copyTree, live, backup)

    local ok_install = pcall(copyTree, staging, live)
    if not ok_install then
        logger.warn("CoverCalendar: update install failed, restoring backup")
        if ok_backup then pcall(copyTree, backup, live) end
        rmTree(staging)
        rmTree(backup)
        return nil
    end

    rmTree(staging)
    rmTree(backup)
    logger.info("CoverCalendar: updated to", tostring(new_version))
    return new_version or "?"
end

-- ── UI entry point ───────────────────────────────────────────────────────────

function Updater.checkForUpdates()
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local checking = InfoMessage:new{ text = _("Checking for updates…"),
                                          timeout = 30 }
        UIManager:show(checking)

        local release, err = Updater.fetchLatestRelease()
        UIManager:close(checking)

        if not release then
            UIManager:show(InfoMessage:new{
                text = _("Could not check for updates.\n\n") .. tostring(err),
            })
            return
        end

        local local_v = Updater.getLocalVersion()
        if not Updater.isNewer(release.version, local_v) then
            UIManager:show(InfoMessage:new{
                text = string.format(
                    _("Cover Calendar is up to date.\n\nInstalled: %s\nLatest: %s"),
                    local_v, release.version),
            })
            return
        end

        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = string.format(
                _("Version %s is available (you have %s).\n\nDownload it now? It will be installed the next time KOReader starts."),
                release.version, local_v),
            ok_text = _("Download"),
            ok_callback = function()
                local downloading = InfoMessage:new{
                    text = _("Downloading update…"), timeout = 60 }
                UIManager:show(downloading)
                local ok_stage, stage_err = Updater.stageUpdate(release)
                UIManager:close(downloading)
                if ok_stage then
                    UIManager:show(InfoMessage:new{
                        text = _("Update downloaded.\n\nRestart KOReader to finish installing."),
                    })
                else
                    UIManager:show(InfoMessage:new{
                        text = string.format(
                            _("Download failed: %s\n\nYou can install it manually from:\n%s"),
                            tostring(stage_err), Updater.RELEASE_URL),
                    })
                end
            end,
        })
    end)
end

return Updater
