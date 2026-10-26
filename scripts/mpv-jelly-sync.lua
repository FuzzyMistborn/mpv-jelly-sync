-- mpv-jelly-sync.lua
-- Reports local playback in mpv back to a Jellyfin server.
--
-- Install:  ~/.config/mpv/scripts/mpv-jelly-sync.lua
-- Config:   ~/.config/mpv/script-opts/mpv-jelly-sync.conf
-- Needs:    mpv >= 0.38, curl
--
-- Modes (sync_progress option):
--   no  - mark the item as watched once you pass watched_threshold (or hit EOF)
--   yes - full sync: playback start, periodic progress, pause/seek, and stop
--         (Jellyfin then tracks resume position and decides "watched" itself)
--
-- Secrets: the password is read from a file or $JELLYFIN_PASSWORD, and every
-- request is fed to curl over stdin, so nothing sensitive appears in `ps`.

local mp = require "mp"
local msg = require "mp.msg"
local utils = require "mp.utils"
local options = require "mp.options"

local opts = {
    url = "",
    username = "",
    password_file = "",
    path_map = "",
    sync_progress = false,
    progress_interval = 10,
    watched_threshold = 90,
    request_timeout = 5,
}
options.read_options(opts, "mpv-jelly-sync")

if opts.url == "" or opts.username == "" then
    msg.warn("url and username must be set in script-opts/mpv-jelly-sync.conf; script disabled")
    return
end
opts.url = opts.url:gsub("/+$", "")

-- Keep numeric options in a sane range.
opts.progress_interval = math.max(1, tonumber(opts.progress_interval) or 10)
opts.request_timeout = math.max(1, tonumber(opts.request_timeout) or 5)
opts.watched_threshold = math.min(100, math.max(0, tonumber(opts.watched_threshold) or 90))

-- Seed with more than the wall clock so two mpv instances started in the same
-- second still get different play session ids.
local seed_extra = tonumber((tostring({}):match("0x(%x+)") or "0"), 16) or 0
math.randomseed((os.time() + seed_extra) % 2147483647)

---------------------------------------------------------------------------
-- small helpers
---------------------------------------------------------------------------

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Quote a value for a curl config file (-K): escape \ " and newlines.
local function curl_quote(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")
    return '"' .. s .. '"'
end

local function urlencode(s)
    return (s:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function hostname()
    for _, file in ipairs({ "/etc/hostname", "/proc/sys/kernel/hostname" }) do
        local f = io.open(file)
        if f then
            local h = f:read("*l")
            f:close()
            if h and trim(h) ~= "" then
                return (trim(h):gsub("[^%w%-]", "-"))
            end
        end
    end
    return "linux"
end

local DEVICE_NAME = hostname()
local DEVICE_ID = "mpv-jelly-sync-" .. DEVICE_NAME

local function new_session_id()
    return string.format("%08x%08x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
end

local function ticks(seconds)
    return math.floor((seconds or 0) * 10000000)
end

---------------------------------------------------------------------------
-- HTTP via curl (synchronous; mpv runs scripts on their own thread, so
-- this never stalls playback, it only delays this script's own events)
---------------------------------------------------------------------------

local backoff_until = 0 -- after a connection failure, skip requests briefly

local function auth_header(token)
    local h = string.format('MediaBrowser Client="mpv-jelly-sync", Device="%s", DeviceId="%s", Version="1.0"',
        DEVICE_NAME, DEVICE_ID)
    if token then
        h = h .. string.format(', Token="%s"', token)
    end
    return h
end

local function request(method, path, body, token, force, timeout)
    if not force and os.time() < backoff_until then
        return nil, 0
    end
    local cfg = {
        "url = " .. curl_quote(opts.url .. path),
        "request = " .. curl_quote(method),
        "header = " .. curl_quote("Authorization: " .. auth_header(token)),
        'header = "Content-Type: application/json"',
    }
    if body then
        cfg[#cfg + 1] = "data-raw = " .. curl_quote(body)
    end
    local res = mp.command_native({
        name = "subprocess",
        args = {
            "curl", "--silent", "--show-error",
            "--connect-timeout", "3",
            "--max-time", tostring(timeout or opts.request_timeout),
            "--write-out", "\n%{http_code}",
            "--config", "-",
        },
        stdin_data = table.concat(cfg, "\n") .. "\n",
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    })
    if not res or res.status ~= 0 then
        backoff_until = os.time() + 30
        msg.verbose("request failed: " .. ((res and (res.error_string ~= "" and res.error_string or res.stderr)) or "unknown"))
        return nil, 0
    end
    local text, code = (res.stdout or ""):match("^(.*)\n(%d+)$")
    local data = nil
    if text and text ~= "" then
        data = utils.parse_json(text)
    end
    return data, tonumber(code) or 0
end

---------------------------------------------------------------------------
-- authentication (user login, so playback is attributed to your account)
---------------------------------------------------------------------------

local auth = { token = nil, user_id = nil, retry_at = 0 }

local function read_password()
    local env = os.getenv("JELLYFIN_PASSWORD")
    if env and env ~= "" then
        return env
    end
    if opts.password_file ~= "" then
        local path = mp.command_native({ "expand-path", opts.password_file })
        local f = io.open(path, "r")
        if not f then
            msg.warn("cannot read password_file: " .. path)
            return nil
        end
        local pw = f:read("*a")
        f:close()
        return (pw:gsub("[\r\n]+$", ""))
    end
    return "" -- no source configured: assume a passwordless user
end

local function ensure_auth()
    if auth.token then
        return true
    end
    if os.time() < auth.retry_at then
        return false
    end
    local pw = read_password()
    if pw == nil then
        auth.retry_at = os.time() + 300
        return false
    end
    local data, code = request("POST", "/Users/AuthenticateByName",
        utils.format_json({ Username = opts.username, Pw = pw }), nil)
    if type(data) == "table" and data.AccessToken and type(data.User) == "table" then
        auth.token = data.AccessToken
        auth.user_id = data.User.Id
        msg.verbose("logged in to Jellyfin")
        return true
    end
    msg.warn(string.format("Jellyfin login failed (HTTP %s)", tostring(code)))
    auth.retry_at = os.time() + 60
    return false
end

-- Authenticated call; re-logs in once if the token was rejected.
local function api(method, path, body, force, timeout)
    if not ensure_auth() then
        return nil, 0
    end
    local data, code = request(method, path, body, auth.token, force, timeout)
    if code == 401 then
        auth.token, auth.retry_at = nil, 0
        if ensure_auth() then
            data, code = request(method, path, body, auth.token, force, timeout)
        end
    end
    return data, code
end

---------------------------------------------------------------------------
-- local path -> Jellyfin item
---------------------------------------------------------------------------

local mappings = {}
for pair in (opts.path_map .. ";"):gmatch("(.-);") do
    local l, r = pair:match("^%s*(.-)%s*=>%s*(.-)%s*$")
    if l and l ~= "" and r and r ~= "" then
        mappings[#mappings + 1] = { (l:gsub("/+$", "")), (r:gsub("/+$", "")) }
    end
end
table.sort(mappings, function(a, b) return #a[1] > #b[1] end) -- longest prefix wins

local function map_path(p)
    for _, m in ipairs(mappings) do
        local l, r = m[1], m[2]
        if p == l or p:sub(1, #l + 1) == l .. "/" then
            return r .. p:sub(#l + 1)
        end
    end
    return p
end

-- Collapse "//", "/./" and "/../" so equivalent spellings of a path match.
-- (Deliberately not realpath: symlinks and network mounts make that unreliable.)
local function normalize(p)
    local parts = {}
    for seg in p:gmatch("[^/]+") do
        if seg == ".." then
            parts[#parts] = nil
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    return "/" .. table.concat(parts, "/")
end

local function current_local_path()
    local p = mp.get_property("path")
    if not p or p:match("^%a[%w+.-]*://") then
        return nil -- URLs, dvd://, etc.
    end
    if p:sub(1, 1) ~= "/" then
        p = utils.join_path(mp.get_property("working-directory") or "", p)
    end
    return normalize(p)
end

local item_cache = {} -- local path -> item id, or false for "definitely not in Jellyfin"

-- The server-side path filter on /Items turned out to be unreliable, so we
-- index every video item's path once (paged), keep the index on disk, and
-- look paths up locally. Matching is still an exact string comparison.
local INDEX_MAX_AGE = 86400    -- rebuild at least daily so item ids stay fresh
local INDEX_MIN_REBUILD = 300  -- after a lookup miss, rescan at most this often
local index = nil              -- jellyfin path -> item id
local index_time = 0

local function cache_file()
    return mp.command_native({ "expand-path", "~~state/mpv-jelly-sync-cache.json" })
end

local function load_cache()
    local f = io.open(cache_file(), "r")
    if not f then
        return
    end
    local txt = f:read("*a")
    f:close()
    local d = utils.parse_json(txt)
    if type(d) == "table" and d.url == opts.url and d.user == opts.username
        and type(d.items) == "table" then
        index, index_time = d.items, tonumber(d.time) or 0
    end
end

local function save_cache()
    -- Write to a temp file and rename, so a crash can't leave a truncated cache.
    local path = cache_file()
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        return -- state dir missing or read-only: the in-memory index still works
    end
    local ok = f:write(utils.format_json({ url = opts.url, user = opts.username, time = index_time, items = index }))
    f:close()
    if ok then
        os.rename(tmp, path)
    else
        os.remove(tmp)
    end
end

local function build_index()
    if not ensure_auth() then
        return false
    end
    local items, start, page = {}, 0, 1000
    while true do
        local q = string.format(
            "/Items?userId=%s&recursive=true&includeItemTypes=Movie,Episode,Video,MusicVideo" ..
            "&fields=Path&enableImages=false&enableUserData=false&startIndex=%d&limit=%d",
            auth.user_id, start, page)
        local data, code = api("GET", q, nil, false, 30)
        if code ~= 200 or type(data) ~= "table" or type(data.Items) ~= "table" then
            msg.warn(string.format("could not list Jellyfin items (HTTP %s)", tostring(code)))
            return false
        end
        for _, it in ipairs(data.Items) do
            if it.Path and it.Id then
                items[it.Path] = it.Id
            end
        end
        start = start + #data.Items
        if #data.Items == 0 or start >= (data.TotalRecordCount or 0) then
            break
        end
    end
    index, index_time = items, os.time()
    msg.info(string.format("indexed %d Jellyfin items", start))
    save_cache()
    return true
end

-- On a miss, show indexed paths that contain the same filename; this makes a
-- wrong path_map obvious from the log.
local function log_similar(remote)
    local base = remote:match("([^/]+)$")
    if not (index and base) then
        return
    end
    local n = 0
    for p in pairs(index) do
        if p:find(base, 1, true) then
            msg.verbose("  similar path in Jellyfin: " .. p)
            n = n + 1
            if n >= 3 then
                return
            end
        end
    end
    if n == 0 then
        msg.verbose("  no indexed Jellyfin path contains the filename " .. base)
    end
end

local function find_item(local_path)
    local cached = item_cache[local_path]
    if cached ~= nil then
        return cached or nil
    end
    if not ensure_auth() then
        return nil
    end
    local remote = map_path(local_path)

    if not index then
        load_cache()
    end
    if index and os.time() - index_time > INDEX_MAX_AGE then
        index = nil
    end
    local id = index and index[remote]
    if not id and (not index or os.time() - index_time > INDEX_MIN_REBUILD) then
        if not build_index() then
            return nil -- transient failure: don't cache
        end
        id = index[remote]
    end
    if id then
        item_cache[local_path] = id
        return id
    end
    item_cache[local_path] = false
    msg.info("no Jellyfin item with path " .. remote)
    log_similar(remote)
    return nil
end

---------------------------------------------------------------------------
-- reporting
---------------------------------------------------------------------------

local state = nil -- per-file state, nil when the current file isn't tracked

local function playback_body(s, pos, paused)
    return string.format(
        '{"ItemId":%s,"MediaSourceId":%s,"PlaySessionId":%s,"PositionTicks":%.0f,' ..
        '"IsPaused":%s,"CanSeek":true,"PlayMethod":"DirectPlay"}',
        utils.format_json(s.item_id), utils.format_json(s.item_id),
        utils.format_json(s.session_id), ticks(pos), tostring(paused))
end

local function stopped_body(s, pos)
    return string.format('{"ItemId":%s,"MediaSourceId":%s,"PlaySessionId":%s,"PositionTicks":%.0f}',
        utils.format_json(s.item_id), utils.format_json(s.item_id),
        utils.format_json(s.session_id), ticks(pos))
end

local function current_pos(s)
    local p = mp.get_property_number("time-pos")
    if p then
        s.last_pos = p
    end
    return s.last_pos
end

local function report_progress()
    if not (opts.sync_progress and state and state.item_id) then
        return
    end
    api("POST", "/Sessions/Playing/Progress", playback_body(state, current_pos(state), state.paused))
end

local function mark_played(item_id)
    local _, code = api("POST", string.format("/UserPlayedItems/%s?userId=%s", item_id, auth.user_id))
    if code == 404 or code == 405 then -- older servers
        _, code = api("POST", string.format("/Users/%s/PlayedItems/%s", auth.user_id, item_id))
    end
    msg.info(string.format("marked watched (HTTP %s)", tostring(code)))
end

-- Called once per file when playback ends (EOF, stop, quit, or keep-open EOF).
local function finish(reason)
    local s = state
    state = nil
    if not s then
        return
    end
    if s.timer then
        s.timer:kill()
    end
    if reason == "error" or reason == "redirect" then
        return
    end
    if not s.item_id then
        s.item_id = find_item(s.path) -- retry in case the first lookup failed
        if not s.item_id then
            return
        end
    end

    local dur = s.duration or mp.get_property_number("duration")
    local pos = s.last_pos or 0
    if reason == "eof" and dur then
        pos = dur
    end
    local pct = (dur and dur > 0) and (pos / dur * 100) or 0

    if opts.sync_progress then
        api("POST", "/Sessions/Playing/Stopped", stopped_body(s, pos), true)
    elseif reason == "eof" or pct >= opts.watched_threshold then
        mark_played(s.item_id)
    end
end

---------------------------------------------------------------------------
-- mpv hooks
---------------------------------------------------------------------------

mp.register_event("file-loaded", function()
    state = nil
    local path = current_local_path()
    if not path then
        return
    end
    state = {
        path = path,
        last_pos = 0,
        paused = mp.get_property_bool("pause", false),
        duration = mp.get_property_number("duration"),
        session_id = new_session_id(),
    }
    local id = find_item(path)
    if not id then
        return
    end
    state.item_id = id
    if opts.sync_progress then
        api("POST", "/Sessions/Playing", playback_body(state, current_pos(state), state.paused))
        state.timer = mp.add_periodic_timer(opts.progress_interval, report_progress)
    end
end)

mp.observe_property("time-pos", "number", function(_, v)
    if state and v then
        state.last_pos = v
    end
end)

mp.observe_property("duration", "number", function(_, v)
    if state and v then
        state.duration = v
    end
end)

mp.observe_property("pause", "bool", function(_, v)
    if not state then
        return
    end
    state.paused = v and true or false
    report_progress()
end)

mp.register_event("playback-restart", report_progress) -- fires after seeks

-- With --keep-open, mpv never sends end-file at EOF, so catch it here too.
mp.observe_property("eof-reached", "bool", function(_, v)
    if v then
        finish("eof")
    end
end)

mp.register_event("end-file", function(ev)
    finish(ev and ev.reason or "stop")
end)

mp.register_event("shutdown", function()
    finish("quit")
end)

-- Bind in input.conf, e.g.:  F9 script-binding mpv-jelly-sync/status
mp.add_key_binding(nil, "status", function()
    local p = current_local_path()
    if not p then
        mp.osd_message("Jellyfin: not a local file")
        return
    end
    if not ensure_auth() then
        mp.osd_message("Jellyfin: login failed (see mpv log)")
        return
    end
    item_cache[p] = nil
    index_time = 0 -- force a fresh scan of the library
    local id = find_item(p)
    if id and state then
        state.item_id = state.item_id or id
    end
    mp.osd_message(id and ("Jellyfin: matched item " .. id) or ("Jellyfin: no match for " .. map_path(p)), 5)
end)
