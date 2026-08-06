--[[
    Daseeki Core — perf.lua

    THE PERFORMANCE LOG: a persisted ring of addon-CPU snapshots, written to
    SavedVariables (DaseekiCoreDB.perfLog) so "the suite feels heavy in Naxx" can be
    answered from a WTF read instead of from a feeling.

    This is the suite's THIRD telemetry ring and it follows the two that already
    earned their keep:
      * Daseeki-Bags  DaseekiBags2DB.sortLog   — bounded ring, additive SV key, one
                                                 entry per event, flat parseable rows.
      * Daseeki-Conduit DaseekiConduitDB.attachTrace — build stamps on every entry,
                                                 RAW capture of an undocumented API's
                                                 return shape, caps enforced on write.

    ── WHAT ONE ENTRY IS ────────────────────────────────────────────────────────
    One SNAPSHOT of the client's own addon profiler, taken at one of three moments:

        "login"     once, a few minutes after login (warm-up: a snapshot taken at
                    second zero measures the load spike, not the steady state)
        "interval"  every INTERVAL seconds thereafter
        "logout"    once, at PLAYER_LOGOUT — the sample that covers the tail of a
                    raid night, which no interval tick is guaranteed to catch

    Each entry records what was SEEN, never what was concluded:
      * the build stamp (Core's ## Version + a token), so a snapshot from stale code
        is self-evident — Conduit's ghost-fix lesson;
      * every LOADED Daseeki-* addon the client knows about, PREFIX-MATCHED at
        runtime and never from a list in this file. The suite grows; a hardcoded
        roster would silently stop measuring the newest addon, which is exactly the
        one worth measuring;
      * per addon, EVERY metric the client's own Enum.AddOnProfilerMetric offers,
        stored under the enum's own KEY NAME. Encounter metrics come along free if
        this client has them — no combat-event machinery is built for them;
      * the same metric set for the profiler's OVERALL (all addons) and APPLICATION
        (the game itself) rollups, which is what turns "0.4ms" into a share;
      * the OVERALL top-K addons by session average — non-Daseeki addons included,
        deliberately: the suite's cost only means something next to its neighbours;
      * ticksPerSecond, once per session, so the units of everything above can be
        pinned from field data rather than assumed.

    ── THE UNDOCUMENTED SURFACE, AND HOW IT IS HANDLED ──────────────────────────
    wow-api-catalog 1.15.9.68808 confirms the FUNCTIONS exist (functions.txt:125-134)
    but documents neither Enum.AddOnProfilerMetric's members nor the shape of
    GetTopKAddOnsForMetric's results table (doc-tables.txt:11 / :206 list the names
    and nothing else). So nothing here is written against an assumed shape:

      * METRICS ARE DISCOVERED, NEVER NAMED. The sampler reads whatever
        Enum.AddOnProfilerMetric actually contains, keeps the string->number pairs,
        and stores results under the client's own key names. A client that adds,
        renames or renumbers a metric is handled with no code change, and the
        SavedVariables file is self-describing to whoever reads it.
      * THE TOP-K SHAPE IS CAPTURED RAW. Each result row is normalised into
        {name, value} by TYPE, not by field name; alongside that, the first sample
        of each session records the row's raw key=value pairs in `topKRaw`. That is
        Conduit's GetSendMailItem trick: one field of honest capture pins an
        undocumented shape permanently, from real field data, and the guessing stops.
      * EVERY READ IS TYPE-GUARDED AND pcall-WRAPPED. A metric that returns a string,
        a table, nil, NaN or infinity is recorded as ABSENT. A profiler call that
        raises is recorded as absent. Telemetry that can break a login is worse than
        no telemetry.

    ── COST ─────────────────────────────────────────────────────────────────────
    No OnUpdate, no per-frame work, no combat hooks. One C_Timer ticker and a handful
    of C calls (~150) every INTERVAL seconds. Between samples this file does nothing
    at all. If the profiler is switched off or absent, ONE entry says so and the
    sampler stops for the session — no ticker is ever created.

    ── SHAPE RULES ──────────────────────────────────────────────────────────────
    Plain data only: numbers, booleans, short strings, and shallow nesting. No
    functions, no cycles. Every string truncated, every array capped, ON WRITE —
    this lives in the player's saved variables forever, and an unbounded log is a
    bug, not a feature.

    ── PURITY ───────────────────────────────────────────────────────────────────
    Everything above the LIVE WRAPPERS bar is a function of its arguments alone,
    which is what lets the headless harness drive the whole collector — including a
    profiler that returns garbage — with no game client anywhere near it.
--]]

local ADDON, Core = ...

local Perf = {}
Core.Perf = Perf

-- ── Build stamp ───────────────────────────────────────────────────────────────
-- Bumped whenever the entry SHAPE changes, so a mixed ring stays attributable.
Perf.BUILD_TOKEN = "perf.1"

-- ── Cadence ───────────────────────────────────────────────────────────────────
Perf.WARMUP   = 180    -- seconds after login before the first sample (steady state,
                       -- not the load spike)
Perf.INTERVAL = 900    -- seconds between samples thereafter (~15 min)

-- ── Caps. All enforced on write, none advisory. ───────────────────────────────
Perf.CAP         = 60   -- entries retained (~several days of play at this cadence)
Perf.MAX_ADDONS  = 24   -- suite addons recorded per entry
Perf.MAX_METRICS = 16   -- metrics recorded per metric table
Perf.MAX_TOPK    = 10   -- top-K rows recorded
Perf.TOPK_K      = 10   -- k asked of the client
Perf.MAX_RAW     = 4    -- top-K rows whose RAW shape is captured (first sample only)
Perf.MAX_NAME    = 40   -- characters of an addon name
Perf.MAX_STR     = 80   -- characters of any other captured string
Perf.MAX_NOTE    = 160  -- characters of the profiler-unavailable note

-- The prefix that defines "ours". Anchored and case-insensitive; the ONLY place the
-- suite's identity is written down.
Perf.PREFIX = "daseeki"

-- ════════════════════════════════════════════════════════════════════════════
--  PURE
-- ════════════════════════════════════════════════════════════════════════════

-- Anything -> a short, safe, printable string, or nil. Tables become their TYPE
-- rather than their address, so a captured shape never changes between reads.
function Perf.Str(v, cap)
    cap = tonumber(cap) or Perf.MAX_STR
    if cap < 2 then cap = 2 end
    if v == nil then return nil end
    local t, s = type(v), nil
    if t == "string" then s = v
    elseif t == "number" or t == "boolean" then s = tostring(v)
    else s = "<" .. t .. ">" end
    if #s > cap then s = s:sub(1, cap - 1) .. "~" end
    return s
end

-- A finite number, or nil. STRICT about type: a metric that hands back "1.5" is a
-- client we do not understand, and guessing at it would poison the log. NaN and the
-- infinities are rejected too — they serialise into a SavedVariables file that the
-- client then refuses to load.
function Perf.Num(v)
    if type(v) ~= "number" then return nil end
    if v ~= v then return nil end                        -- NaN
    if v == math.huge or v == -math.huge then return nil end
    -- Four decimals: lossless for counters, plenty for sub-millisecond timings, and
    -- it keeps the saved file readable instead of a wall of float noise.
    local r = math.floor(v * 10000 + 0.5) / 10000
    if r ~= r then return nil end
    return r
end

-- Is this addon one of ours? Anchored, case-insensitive prefix match — NOT a list.
-- A future "Daseeki-NewThing" is picked up the day it ships, with no edit here.
function Perf.IsSuiteName(name)
    if type(name) ~= "string" then return false end
    return name:lower():sub(1, #Perf.PREFIX) == Perf.PREFIX
end

-- Filter a client addon list down to the LOADED suite addons, in the client's own
-- order. Accepts either plain names (assumed loaded) or {name=, loaded=} rows, so
-- the live enumerator and a harness fixture feed the same pure function.
function Perf.SuiteAddOns(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for i = 1, #list do
        local row = list[i]
        local name, loaded
        if type(row) == "string" then name, loaded = row, true
        elseif type(row) == "table" then
            name = row.name
            loaded = (row.loaded == nil) or (row.loaded and true or false)
        end
        if Perf.IsSuiteName(name) and loaded then
            if #out >= Perf.MAX_ADDONS then break end
            out[#out + 1] = Perf.Str(name, Perf.MAX_NAME)
        end
    end
    return out
end

-- The client's OWN metric enum, as a sorted array of { key = <string>, value = <number> }.
-- Discovered, never declared: this is the whole answer to an enum the catalog names
-- but does not enumerate. Sorted by numeric value so the order is identical every
-- session (pairs() order is not).
function Perf.MetricList(enum)
    local out = {}
    if type(enum) ~= "table" then return out end
    for k, v in pairs(enum) do
        if type(k) == "string" and type(v) == "number" and v == v then
            out[#out + 1] = { key = Perf.Str(k, Perf.MAX_NAME), value = v }
        end
    end
    table.sort(out, function(a, b)
        if a.value == b.value then return a.key < b.key end
        return a.value < b.value
    end)
    -- Cap AFTER sorting so the set kept is stable rather than whatever pairs() saw first.
    while #out > Perf.MAX_METRICS do out[#out] = nil end
    return out
end

-- Normalised key for fuzzy metric matching: letters only, lowercased. Lets
-- "SessionAverageTime", "sessionAvgTime" and "SESSION_AVERAGE" all answer to
-- "sessionaverage" without this file ever asserting which one the client uses.
local function normKey(k)
    return tostring(k or ""):lower():gsub("[^%a]", "")
end

-- First metric in `list` whose normalised key CONTAINS one of `wants`, tried in
-- preference order. Returns the {key, value} row, or nil.
function Perf.PickMetric(list, wants)
    if type(list) ~= "table" or type(wants) ~= "table" then return nil end
    for _, want in ipairs(wants) do
        for _, m in ipairs(list) do
            if normKey(m.key):find(want, 1, true) then return m end
        end
    end
    return nil
end

-- The metric the top-K is ranked by: session average for preference (the number that
-- describes a whole play session), then recent average, then peak, then whatever the
-- client offers first. Returned so the entry can RECORD what it ranked by.
function Perf.TopKMetric(list)
    return Perf.PickMetric(list, { "sessionaverage", "session", "recentaverage", "recent", "peak" })
        or (type(list) == "table" and list[1])
        or nil
end

-- One result row from GetTopKAddOnsForMetric, normalised BY TYPE rather than by
-- field name, because the field names are exactly what the catalog does not
-- document. A row may legitimately be a bare string on some clients.
--   * a string field whose key looks name-ish wins the name; otherwise the first
--     string field does.
--   * a number field whose key looks value-ish wins the value; otherwise the first
--     number field does.
-- Anything else is dropped. `raw` (below) is what settles the real shape.
function Perf.TopKRow(row)
    if type(row) == "string" then
        return { name = Perf.Str(row, Perf.MAX_NAME) }
    end
    if type(row) ~= "table" then return nil end
    local name, value, fbName, fbValue
    -- Deterministic order: pairs() over a result table is not stable, and two
    -- string fields would otherwise make the fallback a coin toss.
    local keys = {}
    for k in pairs(row) do if type(k) == "string" then keys[#keys + 1] = k end end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local v, nk = row[k], normKey(k)
        if type(v) == "string" then
            if not name and (nk:find("name", 1, true) or nk:find("addon", 1, true)) then name = v end
            if not fbName then fbName = v end
        elseif type(v) == "number" then
            if not value and (nk:find("value", 1, true) or nk:find("metric", 1, true)
                              or nk:find("time", 1, true)) then value = v end
            if not fbValue then fbValue = v end
        end
    end
    name  = name  or fbName
    value = value or fbValue
    if name == nil and value == nil then return nil end
    return { name = Perf.Str(name, Perf.MAX_NAME), value = Perf.Num(value) }
end

-- The RAW shape of one result row, as a sorted "key=value|key=value" string. This is
-- the field that pins an undocumented table permanently, from one real capture.
function Perf.TopKRaw(row)
    if row == nil then return nil end
    if type(row) ~= "table" then return Perf.Str(row) end
    local keys = {}
    for k in pairs(row) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for i = 1, #keys do
        local v = row[keys[i]]
        if v == nil then v = row[tonumber(keys[i]) or keys[i]] end
        parts[#parts + 1] = keys[i] .. "=" .. tostring(Perf.Str(v, 24))
    end
    if #parts == 0 then return "<empty table>" end
    return Perf.Str(table.concat(parts, "|"), Perf.MAX_STR)
end

-- Coerce any metric map into a capped, finite-number-only table keyed by ENUM KEY
-- NAME. Absent, garbage and non-finite readings simply do not appear — "recorded as
-- absent" is a missing key, which is honest and costs nothing in the saved file.
function Perf.NormMetrics(t)
    if type(t) ~= "table" then return nil end
    local keys = {}
    for k in pairs(t) do if type(k) == "string" then keys[#keys + 1] = k end end
    table.sort(keys)
    local out, n = {}, 0
    for _, k in ipairs(keys) do
        if n >= Perf.MAX_METRICS then break end
        local v = Perf.Num(t[k])
        if v ~= nil then
            out[Perf.Str(k, Perf.MAX_NAME)] = v
            n = n + 1
        end
    end
    if n == 0 then return nil end
    return out
end

-- One entry, normalised and capped. NEVER trusts its input — this is the only door
-- into the ring, so every cap in this file is enforced right here.
function Perf.NewEntry(e)
    e = (type(e) == "table") and e or {}

    local addons
    if type(e.addons) == "table" then
        addons = {}
        for i = 1, math.min(#e.addons, Perf.MAX_ADDONS) do
            local a = e.addons[i]
            if type(a) == "table" and a.name ~= nil then
                addons[#addons + 1] = {
                    name = Perf.Str(a.name, Perf.MAX_NAME),
                    m    = Perf.NormMetrics(a.m),
                }
            end
        end
        if #addons == 0 then addons = nil end
    end

    local topK
    if type(e.topK) == "table" then
        topK = {}
        for i = 1, math.min(#e.topK, Perf.MAX_TOPK) do
            local r = e.topK[i]
            if type(r) == "table" and (r.name ~= nil or r.value ~= nil) then
                topK[#topK + 1] = { name = Perf.Str(r.name, Perf.MAX_NAME), value = Perf.Num(r.value) }
            end
        end
        if #topK == 0 then topK = nil end
    end

    local topKRaw
    if type(e.topKRaw) == "table" then
        topKRaw = {}
        for i = 1, math.min(#e.topKRaw, Perf.MAX_RAW) do
            topKRaw[#topKRaw + 1] = Perf.Str(e.topKRaw[i], Perf.MAX_STR)
        end
        if #topKRaw == 0 then topKRaw = nil end
    end

    local metricKeys
    if type(e.metricKeys) == "table" then
        metricKeys = {}
        for i = 1, math.min(#e.metricKeys, Perf.MAX_METRICS) do
            local k = e.metricKeys[i]
            -- Accept either the {key=,value=} rows MetricList produces or bare strings.
            if type(k) == "table" then k = k.key end
            if k ~= nil then metricKeys[#metricKeys + 1] = Perf.Str(k, Perf.MAX_NAME) end
        end
        if #metricKeys == 0 then metricKeys = nil end
    end

    -- nil rather than false when the profiler state could not be read at all: "we did
    -- not ask" and "it said no" are different findings, and the classic
    -- `cond and nil or x` idiom CANNOT express that (it collapses nil to x), so this
    -- is written out longhand deliberately.
    local profiler = nil
    if e.profiler ~= nil then profiler = e.profiler and true or false end

    local kind = Perf.Str(e.kind, 16)
    if kind ~= "login" and kind ~= "interval" and kind ~= "logout" and kind ~= "off" then
        kind = "interval"
    end

    return {
        ts         = Perf.Num(e.ts) or 0,
        char       = Perf.Str(e.char, Perf.MAX_NAME),
        build      = Perf.Str(e.build, Perf.MAX_NAME),
        session    = Perf.Str(e.session, 16),
        kind       = kind,
        seq        = Perf.Num(e.seq),
        profiler   = profiler,
        note       = Perf.Str(e.note, Perf.MAX_NOTE),
        tps        = Perf.Num(e.tps),
        tpsRaw     = Perf.Str(e.tpsRaw, Perf.MAX_STR),
        metricKeys = metricKeys,
        topKMetric = Perf.Str(e.topKMetric, Perf.MAX_NAME),
        addons     = addons,
        overall    = Perf.NormMetrics(e.overall),
        app        = Perf.NormMetrics(e.app),
        topK       = topK,
        topKRaw    = topKRaw,
    }
end

-- Append to a ring, enforcing the cap. Returns the stored entry.
--
-- A WHILE loop, not one remove: a cap LOWERED between builds must converge on the
-- first append rather than leaking one stale entry per sample forever.
function Perf.Append(ring, e, cap)
    if type(ring) ~= "table" then return nil end
    cap = tonumber(cap) or Perf.CAP
    if cap < 1 then cap = 1 end
    local stored = Perf.NewEntry(e)
    ring[#ring + 1] = stored
    while #ring > cap do table.remove(ring, 1) end
    return stored
end

-- Newest-first COPY for a reader. The live SavedVariables table is never handed out.
function Perf.Records(ring)
    local out = {}
    if type(ring) ~= "table" then return out end
    for i = #ring, 1, -1 do
        if type(ring[i]) == "table" then out[#out + 1] = ring[i] end
    end
    return out
end

-- ── THE COLLECTOR ─────────────────────────────────────────────────────────────
-- PURE over `api`: every client call it makes arrives in that table, which is what
-- lets the harness drive a profiler that lies, errors, or is not there at all.
--
-- api = {
--   enabled  = function() -> bool        C_AddOnProfiler.IsEnabled
--   addon    = function(name, metric)    C_AddOnProfiler.GetAddOnMetric
--   overall  = function(metric)          C_AddOnProfiler.GetOverallMetric
--   app      = function(metric)          C_AddOnProfiler.GetApplicationMetric
--   topk     = function(metric, k)       C_AddOnProfiler.GetTopKAddOnsForMetric
--   tps      = function()                C_AddOnProfiler.GetTicksPerSecond
--   metrics  = <table>                   Enum.AddOnProfilerMetric
--   addons   = function() -> list        the client's addon list (names or rows)
--   now      = function() -> number      epoch seconds
--   who      = function() -> string      "Name-Realm"
-- }
-- opts = { kind = , session = , seq = , build = , first = <bool: first of the session> }
--
-- Returns a RAW entry table (Perf.NewEntry normalises it on the way into the ring).

-- Call something that may not exist, may raise, and may hand back anything.
-- Returns the raw first return value, or nil.
local function callAny(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, ...)
    if not ok then return nil end
    return v
end

local function callNum(fn, ...)
    return Perf.Num(callAny(fn, ...))
end

function Perf.Collect(api, opts)
    api  = (type(api) == "table") and api or {}
    opts = (type(opts) == "table") and opts or {}

    local e = {
        ts      = callNum(api.now) or 0,
        char    = Perf.Str(callAny(api.who), Perf.MAX_NAME),
        build   = opts.build,
        session = opts.session,
        kind    = opts.kind,
        seq     = opts.seq,
    }

    -- Is there a profiler at all, and is it on? `enabled` missing entirely and
    -- `enabled` answering false are recorded differently: the first is a client that
    -- has no profiler, the second is a player who switched it off.
    -- Written longhand, not as `hasEnabled and (...) or nil`: that idiom collapses a
    -- FALSE result back to nil, which is precisely the distinction being drawn here.
    local hasEnabled = (type(api.enabled) == "function")
    local on = nil
    if hasEnabled then on = callAny(api.enabled) and true or false end
    e.profiler = on

    if not hasEnabled then
        e.kind = "off"
        e.note = "This client has no addon profiler (C_AddOnProfiler is absent), so nothing was sampled."
        return e
    end
    if not on then
        e.kind = "off"
        e.note = "The client's addon profiler is switched off, so nothing was sampled. "
              .. "Turn it on in the game's addon settings and relog to start the log."
        return e
    end

    -- The metric set, as THIS client reports it.
    local metrics = Perf.MetricList(api.metrics)
    if opts.first then
        local keys = {}
        for i = 1, #metrics do keys[i] = metrics[i].key end
        e.metricKeys = keys
        -- ticksPerSecond is a per-session constant; recording it once is enough, and
        -- it is what lets a reader convert the numbers above into real units.
        local rawTps = callAny(api.tps)
        e.tps = Perf.Num(rawTps)
        if e.tps == nil and rawTps ~= nil then e.tpsRaw = Perf.Str(rawTps) end
    end

    -- Per suite addon: GetAddOnMetric(name, metric).
    local suite = Perf.SuiteAddOns(callAny(api.addons))
    local addons = {}
    for i = 1, #suite do
        local name, m, any = suite[i], {}, false
        for j = 1, #metrics do
            local v = callNum(api.addon, name, metrics[j].value)
            if v ~= nil then m[metrics[j].key] = v; any = true end
        end
        addons[#addons + 1] = { name = name, m = any and m or nil }
    end
    e.addons = addons

    -- The two rollups, same metric set: OVERALL is every addon combined, APPLICATION
    -- is the game itself. Without them a per-addon millisecond count has no scale.
    local function rollup(fn)
        if type(fn) ~= "function" then return nil end
        local out, any = {}, false
        for j = 1, #metrics do
            local v = callNum(fn, metrics[j].value)
            if v ~= nil then out[metrics[j].key] = v; any = true end
        end
        return any and out or nil
    end
    e.overall = rollup(api.overall)
    e.app     = rollup(api.app)

    -- The top-K overall — non-Daseeki addons included on purpose. Our suite's cost
    -- only means something next to what else is running.
    local tk = Perf.TopKMetric(metrics)
    if tk and type(api.topk) == "function" then
        e.topKMetric = tk.key
        local res = callAny(api.topk, tk.value, Perf.TOPK_K)
        if type(res) == "table" then
            local rows, raw = {}, {}
            for i = 1, math.min(#res, Perf.MAX_TOPK) do
                local norm = Perf.TopKRow(res[i])
                if norm then rows[#rows + 1] = norm end
                if opts.first and #raw < Perf.MAX_RAW then
                    raw[#raw + 1] = Perf.TopKRaw(res[i])
                end
            end
            e.topK = rows
            if opts.first and #raw > 0 then e.topKRaw = raw end
        elseif res ~= nil then
            -- Not a table at all: capture what it WAS, so the next build knows.
            if opts.first then e.topKRaw = { Perf.Str(res) } end
        end
    end

    return e
end

-- ── PRINT FORMATTING (pure) ───────────────────────────────────────────────────

-- WoW's Lua sandbox publishes `date` as a GLOBAL and ships no `os` table; headless it
-- is the other way round. Try both, then fall back to the raw epoch — a log line must
-- never be the thing that errors.
function Perf.Stamp(ts)
    local d = _G.date or (type(os) == "table" and os.date)
    if d then
        local ok, s = pcall(d, "%m-%d %H:%M", ts)
        if ok and type(s) == "string" then return s end
    end
    return tostring(ts)
end

-- Is this metric a COUNT (print as an integer) rather than a duration?
--
-- ANCHORED, not a loose substring search: "EncounterAverageTime" normalises to
-- "encounteraveragetime", which CONTAINS "count" — a loose match printed a 0.12ms
-- encounter average as "0". A counter names itself at the front ("CountTimeOver5Ms")
-- or spells the threshold out ("timeOver10Ms").
local function isCount(key)
    local n = normKey(key)
    return n:sub(1, 5) == "count" or n:find("timeover", 1, true) ~= nil
end

-- One metric value, formatted for chat.
function Perf.FormatValue(key, v)
    if v == nil then return "—" end
    if isCount(key) then return string.format("%d", math.floor(v + 0.5)) end
    return string.format("%.2fms", v)
end

-- The three columns the owner actually reads, resolved from whatever this client's
-- enum offered. Returns { recent = <key|nil>, session = , peak = , encounter = }.
-- `keys` is a plain array of metric key strings (an entry's metricKeys, or the keys
-- of any metric map in it).
function Perf.Columns(keys)
    local list = {}
    if type(keys) == "table" then
        for i = 1, #keys do list[#list + 1] = { key = keys[i], value = i } end
    end
    local function pick(...) local m = Perf.PickMetric(list, { ... }); return m and m.key or nil end
    return {
        recent    = pick("recentaverage", "recent"),
        session   = pick("sessionaverage", "session"),
        peak      = pick("peak"),
        encounter = pick("encounter"),
    }
end

-- Every metric key present anywhere in an entry, sorted. Used when the entry predates
-- (or lacks) a metricKeys legend — the maps are keyed by name, so the legend is
-- recoverable from the data itself.
function Perf.EntryMetricKeys(entry)
    if type(entry) ~= "table" then return {} end
    if type(entry.metricKeys) == "table" and #entry.metricKeys > 0 then
        local out = {}
        for i = 1, #entry.metricKeys do out[i] = entry.metricKeys[i] end
        return out
    end
    local seen, out = {}, {}
    local function harvest(m)
        if type(m) ~= "table" then return end
        for k in pairs(m) do
            if type(k) == "string" and not seen[k] then seen[k] = true; out[#out + 1] = k end
        end
    end
    harvest(entry.overall)
    harvest(entry.app)
    if type(entry.addons) == "table" then
        for i = 1, #entry.addons do harvest(entry.addons[i] and entry.addons[i].m) end
    end
    table.sort(out)
    return out
end

-- The human-readable report for one entry, as an ARRAY OF LINES. Pure, so the
-- harness pins the report itself rather than the fact that something was printed.
function Perf.FormatEntry(entry, count, cap)
    local out = {}
    local function add(s) out[#out + 1] = s end
    if type(entry) ~= "table" then
        add("No performance samples yet — the first one lands a few minutes after login.")
        return out
    end

    add(string.format("Addon performance — %d of %d samples kept.",
        tonumber(count) or 0, tonumber(cap) or Perf.CAP))
    add(string.format("Latest: %s  %s  (build %s, session %s, sample %d)",
        Perf.Stamp(entry.ts), tostring(entry.kind or "?"),
        tostring(entry.build or "?"), tostring(entry.session or "?"),
        tonumber(entry.seq) or 0))

    if entry.note then
        add("  " .. entry.note)
        return out
    end

    local cols = Perf.Columns(Perf.EntryMetricKeys(entry))
    local function row(label, m)
        local r = m and cols.recent  and m[cols.recent]
        local s = m and cols.session and m[cols.session]
        local p = m and cols.peak    and m[cols.peak]
        return string.format("  %-24s %9s %9s %9s", label,
            Perf.FormatValue(cols.recent, r),
            Perf.FormatValue(cols.session, s),
            Perf.FormatValue(cols.peak, p))
    end

    add(string.format("  %-24s %9s %9s %9s", "addon", "recent", "session", "peak"))
    if type(entry.addons) == "table" and #entry.addons > 0 then
        for i = 1, #entry.addons do
            local a = entry.addons[i]
            add(row(tostring(a and a.name or "?"), a and a.m))
        end
    else
        add("  (no Daseeki addons were sampled)")
    end
    if entry.overall then add(row("ALL ADDONS", entry.overall)) end
    if entry.app     then add(row("the game itself", entry.app)) end

    -- Encounter metrics ride along only if this client's enum offered them; no combat
    -- machinery was built to produce them.
    if cols.encounter then
        local parts = {}
        if type(entry.addons) == "table" then
            for i = 1, #entry.addons do
                local a = entry.addons[i]
                local v = a and a.m and a.m[cols.encounter]
                if v then parts[#parts + 1] = string.format("%s %s", a.name, Perf.FormatValue(cols.encounter, v)) end
            end
        end
        if #parts > 0 then add("  encounter avg: " .. table.concat(parts, ", ")) end
    end

    if type(entry.topK) == "table" and #entry.topK > 0 then
        add(string.format("  Top %d overall by %s:",
            math.min(5, #entry.topK), tostring(entry.topKMetric or "session average")))
        for i = 1, math.min(5, #entry.topK) do
            local r = entry.topK[i]
            add(string.format("   %d. %-28s %9s", i, tostring(r.name or "?"),
                Perf.FormatValue(entry.topKMetric, r.value)))
        end
    end

    if entry.tps then
        add(string.format("  client profiler ticks/second: %d", math.floor(entry.tps + 0.5)))
    end
    return out
end

-- ════════════════════════════════════════════════════════════════════════════
--  LIVE WRAPPERS
-- ════════════════════════════════════════════════════════════════════════════

function Perf.Build()
    local v = Core.CORE_VERSION
    return ((type(v) == "string" and v ~= "") and v or "?") .. "+" .. Perf.BUILD_TOKEN
end

-- The saved ring. ADDITIVE: one new top-level key on DaseekiCoreDB, created lazily on
-- the first write. Nothing else in the save is touched and no schema bump is due.
function Perf.Ring(create)
    local db = _G.DaseekiCoreDB or Core.db
    if type(db) ~= "table" then return nil end
    if type(db.perfLog) ~= "table" then
        if not create then return nil end
        db.perfLog = {}
    end
    return db.perfLog
end

function Perf.Count()
    local ring = Perf.Ring(false)
    return ring and #ring or 0
end

function Perf.Clear()
    local ring = Perf.Ring(false)
    if not ring then return 0 end
    local n = #ring
    -- IN PLACE: the SavedVariables table identity survives a clear, so nothing that
    -- captured a reference is left pointing at a corpse.
    for i = n, 1, -1 do ring[i] = nil end
    return n
end

local function now()
    if type(_G.GetServerTime) == "function" then
        local ok, v = pcall(_G.GetServerTime)
        if ok and type(v) == "number" then return v end
    end
    if type(_G.time) == "function" then
        local ok, v = pcall(_G.time)
        if ok and type(v) == "number" then return v end
    end
    return 0
end

local function who()
    local name = type(_G.UnitName) == "function" and select(1, _G.UnitName("player")) or nil
    local realm = type(_G.GetRealmName) == "function" and _G.GetRealmName() or nil
    if type(name) ~= "string" or name == "" then return nil end
    if type(realm) == "string" and realm ~= "" then return name .. "-" .. realm end
    return name
end

-- The client's addon list as {name=, loaded=} rows. C_AddOns first, the pre-11.0
-- globals as a fallback, and NOTHING hardcoded: whatever the client says is
-- installed is what gets prefix-matched.
local function liveAddOnList()
    local A = _G.C_AddOns
    local getNum    = (A and A.GetNumAddOns)   or _G.GetNumAddOns
    local getName   = (A and A.GetAddOnName)   or _G.GetAddOnName
    local isLoaded  = (A and A.IsAddOnLoaded)  or _G.IsAddOnLoaded
    if type(getNum) ~= "function" or type(getName) ~= "function" then return {} end
    local okN, n = pcall(getNum)
    if not okN or type(n) ~= "number" then return {} end
    local out = {}
    for i = 1, n do
        local okName, name = pcall(getName, i)
        if okName and type(name) == "string" then
            local loaded = true
            if type(isLoaded) == "function" then
                local okL, v = pcall(isLoaded, name)
                loaded = okL and (v and true or false) or false
            end
            out[#out + 1] = { name = name, loaded = loaded }
        end
    end
    return out
end

-- The live API surface, assembled once per sample. Every field may be nil; Collect
-- copes with all of them being nil.
function Perf.LiveAPI()
    local P = _G.C_AddOnProfiler
    return {
        enabled = P and P.IsEnabled,
        addon   = P and P.GetAddOnMetric,
        overall = P and P.GetOverallMetric,
        app     = P and P.GetApplicationMetric,
        topk    = P and P.GetTopKAddOnsForMetric,
        tps     = P and P.GetTicksPerSecond,
        metrics = _G.Enum and _G.Enum.AddOnProfilerMetric,
        addons  = liveAddOnList,
        now     = now,
        who     = who,
    }
end

-- Session identity: stable for one play session, short, and readable in a WTF file.
-- Not a UUID — it only has to separate this session's samples from yesterday's in a
-- 60-entry ring.
local session, seq, ticker, stopped = nil, 0, nil, false

function Perf.SessionId()
    if session then return session end
    local t = now()
    local r = 0
    if type(math.random) == "function" then
        local okR, v = pcall(math.random, 0, 4095)
        if okR and type(v) == "number" then r = v end
    end
    session = string.format("%06x%03x", math.floor(t) % 0xFFFFFF, r)
    return session
end

-- Take one snapshot and append it. Returns the stored entry, or nil when there was
-- nowhere to store it. Never raises: the whole call is pcall-fenced, because a
-- telemetry line that can break PLAYER_LOGOUT is worse than no telemetry.
function Perf.Sample(kind)
    local okAll, stored = pcall(function()
        local ring = Perf.Ring(true)
        if not ring then return nil end
        seq = seq + 1
        local raw = Perf.Collect(Perf.LiveAPI(), {
            kind    = kind,
            session = Perf.SessionId(),
            seq     = seq,
            build   = Perf.Build(),
            first   = (seq == 1),
        })
        return Perf.Append(ring, raw, Perf.CAP)
    end)
    if not okAll then return nil end
    return stored
end

-- Stop sampling for the rest of the session (profiler off/absent). Idempotent.
function Perf.Stop()
    stopped = true
    if ticker and type(ticker.Cancel) == "function" then pcall(ticker.Cancel, ticker) end
    ticker = nil
end

-- The whole cadence, in one place: warm-up sample, then a ticker, and a final sample
-- at logout. NO ticker is ever created when the profiler is off or absent.
function Perf.Begin()
    local entry = Perf.Sample("login")
    if entry and entry.kind == "off" then
        -- One honest entry, and that is the end of it for this session.
        Perf.Stop()
        return
    end
    if stopped then return end
    local T = _G.C_Timer
    if T and type(T.NewTicker) == "function" then
        local okT, t = pcall(T.NewTicker, Perf.INTERVAL, function()
            if not stopped then Perf.Sample("interval") end
        end)
        if okT then ticker = t end
    end
end

-- ── Events ────────────────────────────────────────────────────────────────────
-- PLAYER_LOGIN arms the warm-up timer; PLAYER_LOGOUT takes the closing sample.
-- SavedVariables are written after PLAYER_LOGOUT, so that last entry does persist.
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_LOGOUT")
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        local T = _G.C_Timer
        if T and type(T.After) == "function" then
            pcall(T.After, Perf.WARMUP, function() Perf.Begin() end)
        else
            -- No timer service at all: take the one sample we can, and skip the ticker.
            Perf.Begin()
        end
    elseif event == "PLAYER_LOGOUT" then
        if not stopped then Perf.Sample("logout") end
    end
end)
Perf.frame = ev

-- ── The reader: /daseeki perf ─────────────────────────────────────────────────

local function say(msg)
    local out = _G.DEFAULT_CHAT_FRAME
    if out and type(out.AddMessage) == "function" then
        pcall(out.AddMessage, out, msg)
    elseif type(_G.print) == "function" then
        pcall(_G.print, msg)
    end
end

local TAG = "|cff00ccff[Daseeki Suite]|r "

-- `/daseeki perf` prints the latest snapshot; `/daseeki perf clear` empties the ring.
function Perf.PrintReport(arg)
    if type(arg) == "string" and arg:lower():match("^clear") then
        local n = Perf.Clear()
        say(TAG .. string.format("Performance log cleared (%d sample%s dropped).",
            n, n == 1 and "" or "s"))
        return
    end
    local ring = Perf.Ring(false)
    local recs = Perf.Records(ring)
    if #recs == 0 then
        say(TAG .. "No performance samples yet — the first one lands a few minutes after "
            .. "login, then every 15 minutes. (/daseeki perf clear empties the log.)")
        return
    end
    local lines = Perf.FormatEntry(recs[1], #recs, Perf.CAP)
    for i = 1, #lines do
        say((i == 1) and (TAG .. lines[i]) or lines[i])
    end
end

return Perf
