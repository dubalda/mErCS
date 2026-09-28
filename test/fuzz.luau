--!strict
--[[
    Randomized test against a plain Luau model of the world: components, tags, three kinds of
    relationships (plain with a cleanup policy that changes at runtime, exclusive, ChildOf with
    cascading delete, data pairs), deletes, clears,
    remove_all, batch operations on query matches, Disabled, change tracking, and loops that
    change or delete the entity they visit (every match that is still alive must be visited
    once). After every
    batch of operations all observable state is compared: has/get, targets and their order,
    parents, world:ids, change filters, and queries (for-in, each, has) with and without
    terms, wildcards, relationship terms and data pair values, including cached queries kept
    across all rounds.

    Run from the repository root (seed, number of rounds and the flags are optional; "wide"
    creates 300 other ids first, so that the relation records get signature indices beyond
    the shared signature tables; "hooks" adds hooks that change the entity, except when it is
    deleted: adding T2 sets C2 to 42, removing T2 removes C1, removing T1 (a tracked id: the
    hook runs with the tracking signal) sets C2 to 5, removing a pair of R2 sets C2 to 7;
    "sparse" creates up to 300 empty entities after each entity of the model, so that the
    matches spread over many value pages and all bitset levels; "pool" creates half of the
    entities of the model from a slot pool; "verify" uses a debug world, which checks every
    patched match list of a cached query against a scan of its bitsets; "churn" adds and
    removes pairs with 400 targets on an entity outside the model after every operation, so
    that the pair records left empty (those of the model too) are freed in batches between
    and inside the operations of the model):
        luau test/fuzz.luau
        luau test/fuzz.luau -a 42 400 wide hooks churn
        luau test/fuzz.luau -a 7 300 sparse pool verify hooks churn
]]

local ecs = require("../src")

local args = { ... }
local seed = tonumber(args[1]) or 20260926
local rounds = tonumber(args[2]) or 150
local wide = table.find(args, "wide") ~= nil
local hooks = table.find(args, "hooks") ~= nil
local sparse = table.find(args, "sparse") ~= nil
local pooled = table.find(args, "pool") ~= nil
local verify = table.find(args, "verify") ~= nil
local churn = table.find(args, "churn") ~= nil

local function next_int(low: number, high: number): number
    seed = seed * 16807 % 2147483647
    return low + seed % (high - low + 1)
end

local pair = ecs.pair
local W = ecs.Wildcard
local world = ecs.world(verify)
local pool = if pooled then world:pool() else nil

if wide then
    local holder = world:entity()
    for _ = 1, 300 do
        world:add(holder, world:entity())
    end
end

-- "churn": a relation, an entity and targets outside the model; churn_step adds and removes
-- pairs of them in a fixed order (it draws no random numbers: the operations of the model are
-- the same with and without the flag)
local churn_relation: any, churn_holder: any = nil, nil
local churn_targets: { any } = {}
local churn_next = 0
if churn then
    churn_relation, churn_holder = world:entity(), world:entity()
    for i = 1, 400 do
        churn_targets[i] = world:entity()
    end
end

local function churn_step()
    for _ = 1, 8 do
        churn_next = churn_next % #churn_targets + 1
        local t = churn_targets[churn_next]
        world:add(churn_holder, pair(churn_relation, t))
        world:remove(churn_holder, pair(churn_relation, t))
    end
end

local C1 = world:component()
local C2 = world:component()
local T1 = world:entity()
local T2 = world:entity()
local R1 = world:entity() -- plain relation: any number of targets
local R2 = world:entity() -- exclusive relation
world:add(R2, ecs.Exclusive)
local R3 = world:component() -- data relation: its pairs carry values
local anchor = world:entity() -- a target that is never deleted (not in the model)
local make_stored: () -> () -- defined with the stored queries below
local ChildOf = ecs.ChildOf
local plain_ids: { any } = { C1, C2, T1, T2 }
local function t1_hook(entity: any, _: any, deleting: any?)
    if not deleting then
        world:set(entity, C2, 5)
    end
end
if hooks then
    world:set(T2, ecs.OnAdd, function(entity: any)
        world:set(entity, C2, 42)
    end)
    world:set(T2, ecs.OnRemove, function(entity: any, _: any, deleting: any?)
        if not deleting then
            world:remove(entity, C1)
        end
    end)
    world:set(T1, ecs.OnRemove, t1_hook)
    world:set(R2, ecs.OnRemove, function(entity: any, _: any, deleting: any?)
        if not deleting then
            world:set(entity, C2, 7)
        end
    end)
end

-- the value of a component added with world:add (present, get returns nil)
local NO_VALUE = table.freeze({})

type EntityModel = {
    values: { [any]: any }, -- C1, C2 -> value (or NO_VALUE); T1, T2 -> true
    r1: { [any]: boolean },
    r3: { [any]: number }, -- target -> value
    r2: any?,
    parent: any?,
    disabled: boolean?,
}

local model: { [any]: EntityModel } = {}

-- T2 in the model, with the effects of the hooks
local function t2_add(m: EntityModel)
    if hooks and not m.values[T2] then
        m.values[C2] = 42
    end
    m.values[T2] = true
end

local function t2_remove(m: EntityModel)
    if hooks and m.values[T2] then
        m.values[C1] = nil
    end
    m.values[T2] = nil
end

-- T1 removed from a live entity (the caller records the tracking mark)
local function t1_remove(m: EntityModel)
    if hooks and m.values[T1] then
        m.values[C2] = 5
    end
    m.values[T1] = nil
end
-- change tracking of C1 and T1 in the current round (a round ends with world:tick())
world:track(C1)
world:track(T1)
if hooks then
    -- set again after world:track: the hook and the tracking signal must both run
    world:set(T1, ecs.OnRemove, t1_hook)
end
local c1_added: { [any]: boolean } = {}
local c1_changed: { [any]: boolean } = {}
local t1_removed: { [any]: boolean } = {}
local added_query = world:query(C1):added(C1):cached()
local changed_query = world:query(C1):changed(C1):cached()
local removed_query = world:query(C1):removed(T1):cached()
local list: { any } = {}
local failures: { string } = {}

local function fail(message: string)
    if #failures < 20 then
        table.insert(failures, message)
    end
end

local function spawn(): any
    local e = if pool and next_int(1, 2) == 1 then pool:entity() else world:entity()
    if sparse then
        for _ = 1, next_int(0, 300) do
            world:entity() -- not in the model: it never gets an id
        end
    end
    model[e] = { values = {}, r1 = {}, r3 = {} }
    table.insert(list, e)
    return e
end

local function pick(): any?
    if #list == 0 then
        return nil
    end
    return list[next_int(1, #list)]
end

-- Deleting an entity in the model: its ChildOf children are deleted too; pairs of other
-- relations that target it are removed (the default Remove policy).
-- whether R1 has (OnDeleteTarget, Delete): deleting a target deletes its R1 sources
local r1_deletes_sources = false

local function model_delete(e: any)
    if model[e] == nil then
        return
    end
    model[e] = nil
    c1_added[e] = nil
    c1_changed[e] = nil
    t1_removed[e] = nil
    local at = table.find(list, e)
    if at then
        list[at] = list[#list]
        list[#list] = nil
    end
    local children: { any } = {}
    for other, m in model do
        if m.r1[e] and r1_deletes_sources then
            table.insert(children, other)
        end
        m.r1[e] = nil
        m.r3[e] = nil
        if m.r2 == e then
            m.r2 = nil
            if hooks then
                m.values[C2] = 7
            end
        end
        if m.parent == e then
            table.insert(children, other)
        end
    end
    for _, child in children do
        model_delete(child)
    end
end

-- Entities of the model that a query with these terms matches (queries skip disabled ones).
local function matches(with: { any }, without: { any }?): { any }
    local out: { any } = {}
    for e, m in model do
        if m.disabled then
            continue
        end
        local ok = true
        for _, id in with do
            if m.values[id] == nil then
                ok = false
                break
            end
        end
        for _, id in without or {} do
            if m.values[id] ~= nil then
                ok = false
                break
            end
        end
        if ok then
            table.insert(out, e)
        end
    end
    return out
end

-- Batch operations on query matches: T2 (untracked) takes the word by word paths, T1 and C1
-- (tracked, so hooked) and pairs take the per entity paths.
local function batch()
    local roll = next_int(1, 12)
    if roll == 1 then
        world:remove_all(T1)
        for other, other_model in model do
            if other_model.values[T1] then
                t1_removed[other] = true
            end
            t1_remove(other_model)
        end
    elseif roll == 2 then
        for _, e in matches({ C1 }, { C2 }) do
            t2_add(model[e])
        end
        world:query(C1):without(C2):add_all(T2)
    elseif roll == 3 then
        local value = next_int(1, 1000)
        for _, e in matches({ T2 }) do
            model[e].values[C2] = value
        end
        world:query(T2):set_all(C2, value)
    elseif roll == 4 then
        for _, e in matches({ C2 }) do
            t2_remove(model[e])
        end
        world:query(C2):remove_all(T2)
    elseif roll == 5 then
        for _, e in matches({ T2 }) do
            local m = model[e]
            if m.values[T1] then
                t1_removed[e] = true
            end
            t1_remove(m)
        end
        world:query(T2):remove_all(T1)
    elseif roll == 6 then
        for _, e in matches({ C2 }) do
            model[e].values[T1] = true
        end
        world:query(C2):add_all(T1)
    elseif roll == 7 then
        local doomed = matches({ C1, T2 })
        world:query(C1, T2):delete_all()
        for _, e in doomed do
            model_delete(e)
        end
    elseif roll == 8 then
        local t = pick()
        if t then
            for _, e in matches({ T1 }) do
                model[e].r1[t] = true
            end
            world:query(T1):add_all(pair(R1, t))
        end
    elseif roll == 10 then
        for _, e in matches({ T2 }) do
            model[e].values[C2] = nil
        end
        world:query(T2):remove_all(C2)
    elseif roll == 12 then
        local t = pick()
        if t then
            local value = next_int(1, 1000)
            for _, e in matches({ T2 }) do
                model[e].r3[t] = value
            end
            world:query(T2):set_all(pair(R3, t), value)
        end
    elseif roll == 9 then
        local value = next_int(1, 1000)
        for _, e in matches({ C1 }) do
            model[e].values[C1] = value
            c1_changed[e] = true
        end
        world:query(C1):set_all(C1, value)
    else
        local expected = #matches({ C1 }, { T1 })
        local counted = world:query(C1):without(T1):count()
        if counted ~= expected then
            fail(`count: {counted} ~= {expected}`)
        end
    end
end

-- A loop over query(C1) that changes the entity it is visiting (allowed): every match is
-- visited exactly once with its value, whatever the loop does to the entity.
local function loop_and_change()
    local expected = matches({ C1 })
    local visited: { [any]: boolean } = {}
    local function visit(e: any, value: any)
        if model[e] == nil and not world:contains(e) then
            return -- deleted ahead of the loop by a cascade: may still be returned once
        end
        if visited[e] then
            fail(`loop: {e} visited twice`)
            return
        end
        visited[e] = true
        local m = model[e]
        if m == nil or m.values[C1] ~= value then
            fail(`loop: {e} with value {value}`)
            return
        end
        local r = value % 4
        if r == 0 then
            world:set(e, C1, value + 1)
            m.values[C1] = value + 1
            c1_changed[e] = true
        elseif r == 1 then
            world:remove(e, C1)
            m.values[C1] = nil
        elseif r == 2 then
            world:add(e, T2)
            t2_add(m)
        else
            world:delete(e) -- ChildOf children go too, maybe ahead of the loop
            model_delete(e)
        end
        if next_int(1, 4) == 1 then
            -- nested loops over the same (shared) query after the change: the second one may
            -- rebuild its match list, which must not disturb this loop
            local expected_now = #matches({ C1 })
            for _ = 1, 2 do
                local n = 0
                for _ in world:query(C1) do
                    n += 1
                end
                if n ~= expected_now then
                    fail(`nested loop: {n} ~= {expected_now}`)
                end
            end
        end
    end
    if next_int(1, 2) == 1 then
        world:query(C1):each(visit)
    else
        for e, value in world:query(C1) do
            visit(e, value)
        end
    end
    local missing = 0
    for _, e in expected do
        if not visited[e] and model[e] ~= nil then
            missing += 1
        end
        visited[e] = nil
    end
    if missing > 0 or next(visited) ~= nil then
        fail(`loop: {missing} matches skipped, extra visits: {next(visited) ~= nil}`)
    end
end

local function mutate()
    local roll = next_int(1, 100)
    local e = pick()
    if roll <= 12 or e == nil then
        spawn()
        return
    end
    local m = model[e]
    if roll <= 18 then
        world:delete(e)
        model_delete(e)
    elseif roll <= 20 then
        world:clear(e)
        if m.values[T1] then
            t1_removed[e] = true
        end
        m.values = {}
        m.r1 = {}
        m.r3 = {}
        m.r2 = nil
        m.parent = nil
        m.disabled = nil
    elseif roll <= 40 then
        local id = plain_ids[next_int(1, 4)]
        if id == C2 and next_int(1, 4) == 1 then
            -- a component without a value; a later set gives it one
            world:add(e, C2)
            if m.values[C2] == nil then
                m.values[C2] = NO_VALUE
            end
        elseif id == C1 or id == C2 then
            local value = next_int(1, 1000)
            if id == C1 then
                if m.values[C1] ~= nil then
                    c1_changed[e] = true
                else
                    c1_added[e] = true
                end
            end
            world:set(e, id, value)
            m.values[id] = value
        else
            world:add(e, id)
            if id == T2 then
                t2_add(m)
            else
                m.values[id] = true
            end
        end
    elseif roll <= 50 then
        local id = plain_ids[next_int(1, 4)]
        world:remove(e, id)
        if id == T1 and m.values[T1] then
            t1_removed[e] = true
        end
        if id == T2 then
            t2_remove(m)
        elseif id == T1 then
            t1_remove(m)
        else
            m.values[id] = nil
        end
    elseif roll <= 58 then
        local t = if next_int(1, 3) == 1 then anchor else pick()
        if t then
            world:add(e, pair(R1, t))
            m.r1[t] = true
        end
    elseif roll <= 60 then
        local t = pick()
        if t then
            local value = next_int(1, 1000)
            world:set(e, pair(R3, t), value)
            m.r3[t] = value
        end
    elseif roll <= 61 then
        local t = next(m.r3) or pick()
        if t then
            world:remove(e, pair(R3, t))
            m.r3[t] = nil
        end
    elseif roll <= 62 then
        world:remove(e, pair(R3, W))
        m.r3 = {}
    elseif roll <= 67 then
        local t = pick()
        if t then
            world:remove(e, pair(R1, t))
            m.r1[t] = nil
        end
    elseif roll <= 69 then
        world:remove(e, pair(R1, W))
        m.r1 = {}
    elseif roll <= 76 then
        local t = pick()
        if t then
            world:add(e, pair(R2, t))
            if hooks and m.r2 ~= nil and m.r2 ~= t then
                m.values[C2] = 7 -- the previous target is replaced
            end
            m.r2 = t
        end
    elseif roll <= 86 then
        -- a parent that is neither e nor one of its descendants (no cycles)
        local t = pick()
        local cursor = t
        while cursor ~= nil and cursor ~= e do
            cursor = model[cursor] and model[cursor].parent
        end
        if t and cursor == nil then
            world:add(e, pair(ChildOf, t))
            m.parent = t
        end
    elseif roll <= 90 then
        world:remove(e, pair(ChildOf, W))
        m.parent = nil
    elseif roll <= 91 then
        batch()
    elseif roll <= 94 then
        if m.disabled then
            world:remove(e, ecs.Disabled)
            m.disabled = nil
        else
            world:add(e, ecs.Disabled)
            m.disabled = true
        end
    elseif roll == 95 then
        -- delete a component: every entity loses it; a new component takes its place
        world:delete(C2)
        for _, other in model do
            other.values[C2] = nil
        end
        C2 = world:component()
        plain_ids[2] = C2
        make_stored()
    elseif roll <= 98 then
        -- delete and spawn again: the new entity takes the freed slot and gets C1
        world:delete(e)
        model_delete(e)
        local fresh = spawn()
        world:set(fresh, C1, 1)
        model[fresh].values[C1] = 1
        c1_added[fresh] = true
    elseif roll == 99 then
        if next_int(1, 2) == 1 then
            -- delete a relation: every entity loses its pairs; a new relation takes its place
            world:delete(R1)
            for _, other in model do
                other.r1 = {}
            end
            R1 = world:entity()
            r1_deletes_sources = false
            make_stored()
        else
            -- the cleanup policy of R1 changes: deleting a target deletes or keeps its sources
            if r1_deletes_sources then
                world:remove(R1, pair(ecs.OnDeleteTarget, ecs.Delete))
            else
                world:add(R1, pair(ecs.OnDeleteTarget, ecs.Delete))
            end
            r1_deletes_sources = not r1_deletes_sources
        end
    else
        loop_and_change()
    end
end

local function slot_order(a: any, b: any): boolean
    return ecs.ECS_ID(a) < ecs.ECS_ID(b)
end

local function check_entities()
    for e, m in model do
        if not world:contains(e) then
            fail(`entity {e} is not alive`)
            continue
        end
        local count = 0
        for _, id in plain_ids do
            local expected = m.values[id]
            if world:has(e, id) ~= (expected ~= nil) then
                fail(`has {id} of {e}`)
            end
            if (id == C1 or id == C2) and world:get(e, id) ~= (if expected == NO_VALUE then nil else expected) then
                fail(`get {id} of {e}`)
            end
            if expected ~= nil then
                count += 1
            end
        end
        local targets: { any } = {}
        for t in m.r1 do
            table.insert(targets, t)
        end
        table.sort(targets, slot_order)
        for k, t in targets do
            if world:target(e, R1, k - 1) ~= t then
                fail(`target {k - 1} of {e}`)
            end
        end
        if world:target(e, R1, #targets) ~= nil then
            fail(`extra target of {e}`)
        end
        count += #targets
        local data_targets: { any } = {}
        for t, value in m.r3 do
            table.insert(data_targets, t)
            if world:get(e, pair(R3, t)) ~= value then
                fail(`value of (R3, {t}) of {e}`)
            end
        end
        table.sort(data_targets, slot_order)
        for k, t in data_targets do
            if world:target(e, R3, k - 1) ~= t then
                fail(`data target {k - 1} of {e}`)
            end
        end
        local first = data_targets[1]
        if world:get(e, pair(R3, W)) ~= (if first then m.r3[first] else nil) then
            fail(`value of (R3, *) of {e}`)
        end
        count += #data_targets
        if world:target(e, R2) ~= m.r2 then
            fail(`exclusive target of {e}`)
        end
        if m.r2 then
            count += 1
        end
        if world:parent(e) ~= m.parent then
            fail(`parent of {e}`)
        end
        if m.parent then
            count += 1
        end
        if world:has(e, ecs.Disabled) ~= (m.disabled == true) then
            fail(`disabled state of {e}`)
        end
        if m.disabled then
            count += 1
        end
        if #world:ids(e) ~= count then
            fail(`ids of {e}: {#world:ids(e)} ~= {count}`)
        end
    end
end

local function check_query(label: string, q: any, expected: (m: EntityModel) -> boolean)
    local want: { [any]: boolean } = {}
    local n_want = 0
    for e, m in model do
        if expected(m) then
            want[e] = true
            n_want += 1
        end
    end
    for _ = 1, 3 do -- the third pass may use the list mode
        local seen = 0
        for e in q do
            seen += 1
            if not want[e] then
                fail(`{label}: unexpected {e}`)
            end
        end
        if seen ~= n_want then
            fail(`{label}: {seen} ~= {n_want}`)
        end
    end
    local each_seen = 0
    q:each(function(e: any)
        each_seen += 1
        if not want[e] then
            fail(`{label} each: unexpected {e}`)
        end
    end)
    if each_seen ~= n_want then
        fail(`{label} each: {each_seen} ~= {n_want}`)
    end
    for e in model do
        if q:has(e) ~= (want[e] == true) then
            fail(`{label} has {e}`)
        end
    end
end

-- Cached queries kept across all rounds (created again when C2 or R1 is replaced).
local stored: { { any } } = {}
local stored_c2: any = nil
function make_stored()
    stored_c2 = world:query(C2):cached()
    stored = {
        {
            "stored C1 with (R1, anchor)",
            world:query(C1):with(pair(R1, anchor)):cached(),
            function(m: EntityModel): boolean
                return m.values[C1] ~= nil and m.r1[anchor] == true and not m.disabled
            end,
        },
        {
            "stored (R1, *) without T2",
            world:query(pair(R1, W)):without(T2):cached(),
            function(m: EntityModel): boolean
                return next(m.r1) ~= nil and m.values[T2] == nil and not m.disabled
            end,
        },
        {
            "stored C2 any(T1, (R1, anchor))",
            world:query(C2):any(T1, pair(R1, anchor)):cached(),
            function(m: EntityModel): boolean
                return m.values[C2] ~= nil and (m.values[T1] ~= nil or m.r1[anchor] == true) and not m.disabled
            end,
        },
    }
end
make_stored()

local function check_query_once(label: string, q: any, expected: (m: EntityModel) -> boolean)
    local n_want = 0
    for _, m in model do
        if expected(m) then
            n_want += 1
        end
    end
    local seen = 0
    for e in q do
        seen += 1
        local m = model[e]
        if m == nil or not expected(m) then
            fail(`{label}: unexpected {e}`)
        end
    end
    if seen ~= n_want then
        fail(`{label}: {seen} ~= {n_want}`)
    end
end

local function check_stored()
    for _, entry in stored do
        for _ = 1, 3 do -- unchanged between the passes: the later ones may use the match list
            check_query_once(entry[1], entry[2], entry[3])
        end
    end
    -- values through a cached query (the match list keeps page references)
    local wrong = 0
    for e, value in stored_c2 do
        local m = model[e]
        local expected = if m then m.values[C2] else nil
        if expected == NO_VALUE then
            expected = nil
        end
        if m == nil or value ~= expected then
            wrong += 1
        end
    end
    if wrong > 0 then
        fail(`values of stored C2: {wrong} wrong`)
    end
end

local function check_queries()
    check_query("C1", world:query(C1), function(m)
        return m.values[C1] ~= nil and not m.disabled
    end)
    check_query("C1 C2", world:query(C1, C2), function(m)
        return m.values[C1] ~= nil and m.values[C2] ~= nil and not m.disabled
    end)
    check_query("T1 without T2", world:query(T1):without(T2), function(m)
        return m.values[T1] ~= nil and m.values[T2] == nil and not m.disabled
    end)
    check_query("C2 with T2", world:query(C2):with(T2), function(m)
        return m.values[C2] ~= nil and m.values[T2] ~= nil and not m.disabled
    end)
    check_query("C1 any(T1, T2)", world:query(C1):any(T1, T2), function(m)
        return m.values[C1] ~= nil and (m.values[T1] ~= nil or m.values[T2] ~= nil) and not m.disabled
    end)
    check_query("C1 with Disabled", world:query(C1):with(ecs.Disabled), function(m)
        return m.values[C1] ~= nil and m.disabled == true
    end)
    check_query("(R1, *)", world:query(pair(R1, W)), function(m)
        return next(m.r1) ~= nil and not m.disabled
    end)
    check_query("(R2, *) without (ChildOf, *)", world:query(pair(R2, W)):without(pair(ChildOf, W)), function(m)
        return m.r2 ~= nil and m.parent == nil and not m.disabled
    end)
    local t = pick()
    if t then
        check_query("(*, t)", world:query(pair(W, t)), function(m)
            return (m.r1[t] == true or m.r2 == t or m.parent == t or m.r3[t] ~= nil) and not m.disabled
        end)
        check_query("(R1, t)", world:query(pair(R1, t)), function(m)
            return m.r1[t] == true and not m.disabled
        end)
        check_query("C1 (R3, t)", world:query(C1, pair(R3, t)), function(m)
            return m.values[C1] ~= nil and m.r3[t] ~= nil and not m.disabled
        end)
        -- the values a query returns: a data pair, and (R3, *) gives the value of the first target
        local wrong = 0
        for e, c1, value in world:query(C1, pair(R3, t)) do
            local m = model[e]
            if m == nil or m.values[C1] ~= c1 or m.r3[t] ~= value then
                wrong += 1
            end
        end
        for e, value in world:query(pair(R3, W)) do
            local m = model[e]
            local first: any = nil
            for target in (if m then m.r3 else {}) :: { [any]: number } do
                if first == nil or slot_order(target, first) then
                    first = target
                end
            end
            if m == nil or first == nil or m.r3[first] ~= value then
                wrong += 1
            end
        end
        if wrong > 0 then
            fail(`values of data pair queries: {wrong} wrong`)
        end
        local children = 0
        for _ in world:children(t) do
            children += 1
        end
        local expected = 0
        for _, m in model do
            if m.parent == t then
                expected += 1
            end
        end
        if children ~= expected then
            fail(`children of {t}: {children} ~= {expected}`)
        end
    end
end

for _ = 1, 60 do
    spawn()
end
local function check_tracking()
    world:tick()
    for _, case in
        {
            { "added C1", added_query, c1_added },
            { "changed C1", changed_query, c1_changed },
            { "removed T1", removed_query, t1_removed },
        }
    do
        local label, q, set = case[1], case[2], case[3]
        local want: { [any]: boolean } = {}
        local n_want = 0
        for e in set do
            local m = model[e]
            if m and m.values[C1] ~= nil and not m.disabled then
                want[e] = true
                n_want += 1
            end
        end
        local seen = 0
        for e in q do
            seen += 1
            if not want[e] then
                fail(`{label}: unexpected {e}`)
            end
        end
        if seen ~= n_want then
            fail(`{label}: {seen} ~= {n_want}`)
        end
    end
    table.clear(c1_added)
    table.clear(c1_changed)
    table.clear(t1_removed)
end

for round = 1, rounds do
    for _ = 1, 40 do
        mutate()
        if churn then
            churn_step()
        end
    end
    check_tracking()
    check_entities()
    check_stored()
    if round % 3 == 0 then
        check_queries()
    end
    if #failures > 0 then
        print(`round {round}:`)
        break
    end
end

if #failures > 0 then
    for _, message in failures do
        print("  " .. message)
    end
    error(`fuzz: {#failures} mismatches (seed {tonumber(args[1]) or 20260926})`)
end
print(`fuzz: ok ({rounds} rounds)`)

-- for a runner that requires this file as a module (studio/runner.luau)
return rounds
