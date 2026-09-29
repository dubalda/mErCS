--!strict
--!optimize 2
--[[
    A model of the reference workload of a game that uses the library: its server world in the
    terms of the release requirements of the game (the kinds of entities, their numbers, rates
    and access patterns), for the performance suite of bench/workload.luau. It uses only calls
    that the releases of the library since 0.2.2 have, so that a release is measured against
    the previous one.

    The world (Scale gives the numbers of the small and the target scale):
    - agents from a slot pool, active and retained (a retained tag), and a few agents of a
      second kind; 20 components and 5–7 tags each, a (ChildOf, group) membership;
    - owned entities, created in one burst right after their agent (adjacent slots): 9 of 10
      components, a state (a component value and a mirror tag of 7), one of 10 system tags for
      life, 1–2 more tags; (Owner, agent), exclusive and deleted with the agent; one of 8
      (Trigger_k, agent) relations (owned entity j answers relation j % 8); (Extra, agent) on the
      first two; the third is the (Parent, ...) of the next three;
    - groups (2 values, 1–2 tags, (ChildOf, anchor)) that hold (Expiry, agent) data pairs with an
      expiry time on 3 agents each; anchors (3 values, 2 tags);
    - short-lived messages (one component with a table value, handled and deleted the frame after
      they are made), deferred messages in scattered slots (visited every frame, 2 replaced),
      timed effects ((EffectOf, agent), 2 values, one replaced per frame), 2 modifiers per agent
      ((ModifierOf, agent), 1 value), short-lived objects ((ChildOf, owned entity), 2 values, a
      tag, one replaced every 10 frames);
    - a registry of about 85 components, 115 tags and 30 tags made at run time (the ids no kind
      above uses are carried by anchors and groups), and 12 relations besides ChildOf;
    - hooks on add and change of the state component move its mirror tag; removal listeners on
      the 7 state tags and on 3 ids that deleted entities carry.

    A frame (Model.frame) does the work of section 1.3 of the requirements: state transitions,
    walks over state tags and over the members of a state tag with a system tag, agents whose
    tags and values change, 25 stored queries at periods of 1 to 60 frames (a loop over one of
    them changes the state of its current entity), searches over a query of agents, messages
    (each walks the holders of (Trigger_k, agent) and (Extra, agent) and reads 3 values of each),
    deferred messages, a batch add_all and remove_all, a timed effect replaced, a few expiry
    pairs refreshed; and the lifecycle events of section 1.4 at their rate: the end of the
    activity of an agent, the removal of a retained agent (the cascade over its owned
    entities, modifiers and effects) and a new agent with its owned entities.

    The choices the requirements leave open (the ids of each kind, the terms of the stored
    queries, the rates within their ranges) are the ones above and in Scale; the numbers of the
    model are close to those of the requirements, not the same.

    Usage (from bench/workload.luau):
        local model = require("./workload_model")
        local m = model.new(ecs, model.TARGET, 1)
        m.frame()
]]

export type Scale = {
    name: string,
    -- agents: active, retained (they keep their owned entities), of a second kind
    active: number,
    retained: number,
    second_kind: number,
    -- owned entities per agent, and per agent of the second kind
    owned: number,
    owned_second: number,
    groups: number,
    anchors: number,
    -- per frame: messages made, state transitions, agents changed
    messages: number,
    transitions: number,
    agent_changes: number,
    -- alive at a time: deferred messages, timed effects, short-lived objects
    deferred: number,
    effects: number,
    objects: number,
    -- owned entities out of the idle state
    busy: number,
    -- frames between two lifecycle events (the three kinds in turn)
    event_every: number,
}

local SMALL: Scale = {
    name = "small",
    active = 100,
    retained = 20,
    second_kind = 2,
    owned = 12,
    owned_second = 20,
    groups = 30,
    anchors = 40,
    messages = 7,
    transitions = 10,
    agent_changes = 5,
    deferred = 40,
    effects = 30,
    objects = 10,
    busy = 60,
    -- 0.6 events of each kind per second
    event_every = 33,
}

local TARGET: Scale = {
    name = "target",
    active = 200,
    retained = 500,
    second_kind = 4,
    owned = 500,
    owned_second = 25,
    groups = 175,
    anchors = 100,
    messages = 12,
    transitions = 20,
    agent_changes = 10,
    deferred = 300,
    effects = 200,
    objects = 30,
    busy = 480,
    -- 0.5 events of each kind per second
    event_every = 40,
}

local STATES = 7
local SYSTEM_TAGS = 10
local TRIGGERS = 8
local AGENT_COMPONENTS = 20
local AGENT_TAGS = 10
local OWNED_COMPONENTS = 10
local OWNED_TAGS = 4
local RUNTIME_TAGS = 30
-- the registry of the game: components and tags in all
local REGISTRY_COMPONENTS = 85
local REGISTRY_TAGS = 115

export type Model = {
    world: any,
    scale: Scale,
    frame_count: number,
    -- one frame of section 1.3, with the lifecycle events at their rate
    frame: () -> (),
    -- the parts of a frame, for the tests of the suite
    transitions: (count: number) -> (),
    state_walks: () -> number,
    intersection_each: () -> number,
    intersection_queries: () -> number,
    agent_changes: () -> (),
    stored_queries: () -> number,
    searches: () -> number,
    messages: () -> number,
    deferred_messages: () -> number,
    batch: () -> number,
    replace_effect: () -> (),
    -- the holders of (Trigger_k, agent) of a random agent
    trigger_walk: () -> number,
    -- lifecycle events
    end_activity: () -> (),
    remove_retained: () -> (),
    new_agent: () -> (),
    -- a stored query and the id of a state tag, for the allocation checks
    sample_query: any,
    sample_tag: any,
    -- a relation and entities for the memory of pairs
    spare_relation: () -> any,
    owned_entities: (count: number) -> { any },
    agents: () -> { any },
}

local function new(ecs: any, scale: Scale, seed: number): Model
    local world = ecs.world()
    local pair = ecs.pair

    local random_state = seed
    local function rand(n: number): number
        random_state = random_state * 16807 % 2147483647
        return random_state % n + 1
    end

    ----------------------------------------------------------------------------
    -- the registry
    ----------------------------------------------------------------------------

    local components_made, tags_made = 0, 0
    local function component(): any
        components_made += 1
        return world:component()
    end
    local function tag(): any
        tags_made += 1
        return world:entity()
    end

    local AgentC: { any } = {}
    for i = 1, AGENT_COMPONENTS do
        AgentC[i] = component()
    end
    local AgentT: { any } = {}
    for i = 1, AGENT_TAGS do
        AgentT[i] = tag()
    end
    local Retained, SecondKind = tag(), tag()
    local OwnedC: { any } = {}
    for i = 1, OWNED_COMPONENTS do
        OwnedC[i] = component()
    end
    local OwnedT: { any } = {}
    for i = 1, OWNED_TAGS do
        OwnedT[i] = tag()
    end
    local RetainedOwned, Flag = tag(), tag()
    local State = component()
    local StateTag: { any } = {}
    for i = 1, STATES do
        StateTag[i] = tag()
    end
    local SystemTag: { any } = {}
    for i = 1, SYSTEM_TAGS do
        SystemTag[i] = tag()
    end
    local GroupC1, GroupC2, GroupT1, GroupT2 = component(), component(), tag(), tag()
    local AnchorC1, AnchorC2, AnchorC3, AnchorT1, AnchorT2 = component(), component(), component(), tag(), tag()
    local Message, Deferred = component(), component()
    local EffectC1, EffectC2, ModifierC, ObjectC1, ObjectC2, ObjectT =
        component(), component(), component(), component(), component(), tag()

    -- relations: those that point at an agent go with it
    local function relation(exclusive: boolean, deleted_with_target: boolean, data: boolean): any
        local r = if data then world:component() else world:entity()
        if exclusive then
            world:add(r, ecs.Exclusive)
        end
        if deleted_with_target then
            world:add(r, pair(ecs.OnDeleteTarget, ecs.Delete))
        end
        return r
    end
    local Owner = relation(true, true, false)
    local Trigger: { any } = {}
    for i = 1, TRIGGERS do
        Trigger[i] = relation(false, false, false)
    end
    local Extra = relation(false, false, false)
    local Parent = relation(false, false, false)
    local EffectOf = relation(true, true, false)
    local ModifierOf = relation(true, true, false)
    local Expiry = relation(false, false, true)

    -- the ids that no kind of the model uses, carried by anchors and groups
    local FillerC: { any } = {}
    while components_made < REGISTRY_COMPONENTS do
        table.insert(FillerC, component())
    end
    local FillerT: { any } = {}
    while tags_made < REGISTRY_TAGS do
        table.insert(FillerT, tag())
    end
    local RuntimeTag: { any } = {}

    ----------------------------------------------------------------------------
    -- hooks and listeners
    ----------------------------------------------------------------------------

    -- the state component moves its mirror tag
    world:set(State, ecs.OnAdd, function(entity: any, _: any, value: any)
        world:add(entity, StateTag[value])
    end)
    world:set(State, ecs.OnChange, function(entity: any, _: any, value: any)
        for k = 1, STATES do
            if k ~= value and world:has(entity, StateTag[k]) then
                world:remove(entity, StateTag[k])
                break
            end
        end
        world:add(entity, StateTag[value])
    end)
    local removals = 0
    local function count_removal()
        removals += 1
    end
    for k = 1, STATES do
        world:removed(StateTag[k], count_removal)
    end
    world:removed(OwnedC[1], count_removal)
    world:removed(State, count_removal)
    world:removed(ModifierC, count_removal)

    ----------------------------------------------------------------------------
    -- entities
    ----------------------------------------------------------------------------

    local agent_pool = world:pool()
    local anchors: { any } = {}
    local groups: { any } = {}
    local active: { any } = {}
    local retained: { any } = {}
    -- the owned entities of each agent, in the order they were made
    local owned_of: { [any]: { any } } = {}
    -- owned entities out of the idle state
    local busy: { any } = {}
    local busy_at: { [any]: number } = {}
    local effects: { any } = {}
    local objects: { any } = {}
    local deferred: { any } = {}

    for i = 1, scale.anchors do
        local a = world:entity()
        world:set(a, AnchorC1, i)
        world:set(a, AnchorC2, i)
        world:set(a, AnchorC3, i)
        world:add(a, AnchorT1)
        world:add(a, AnchorT2)
        anchors[i] = a
    end
    for i = 1, scale.groups do
        local g = world:entity()
        world:set(g, GroupC1, i)
        world:set(g, GroupC2, i)
        world:add(g, GroupT1)
        if i % 2 == 0 then
            world:add(g, GroupT2)
        end
        world:add(g, pair(ecs.ChildOf, anchors[rand(#anchors)]))
        groups[i] = g
    end
    -- the ids of the registry that no kind uses, one entity each
    for i, id in FillerC do
        world:set(anchors[(i - 1) % #anchors + 1], id, i)
    end
    for i, id in FillerT do
        world:add(groups[(i - 1) % #groups + 1], id)
    end

    local function add_owned(agent: any, count: number): { any }
        local list = table.create(count)
        for j = 1, count do
            local e = world:entity()
            for c = 1, OWNED_COMPONENTS do
                if c ~= j % OWNED_COMPONENTS + 1 then
                    world:set(e, OwnedC[c], j + c)
                end
            end
            world:set(e, State, 1)
            world:add(e, SystemTag[j % SYSTEM_TAGS + 1])
            world:add(e, OwnedT[j % OWNED_TAGS + 1])
            if j % 3 == 0 then
                world:add(e, OwnedT[(j + 1) % OWNED_TAGS + 1])
            end
            world:add(e, pair(Owner, agent))
            world:add(e, pair(Trigger[j % TRIGGERS + 1], agent))
            if j <= 2 then
                world:add(e, pair(Extra, agent))
            elseif j >= 4 and j <= 6 then
                world:add(e, pair(Parent, list[3]))
            end
            list[j] = e
        end
        return list
    end

    local function make_agent(kind: any?): any
        local a = agent_pool:entity()
        for c = 1, AGENT_COMPONENTS do
            world:set(a, AgentC[c], c)
        end
        for t = 1, 5 do
            world:add(a, AgentT[t])
        end
        if rand(2) == 1 then
            world:add(a, AgentT[5 + rand(5)])
        end
        if kind then
            world:add(a, kind)
        end
        world:add(a, pair(ecs.ChildOf, groups[rand(#groups)]))
        owned_of[a] = add_owned(a, if kind == SecondKind then scale.owned_second else scale.owned)
        for _ = 1, 2 do
            local m = world:entity()
            world:set(m, ModifierC, rand(100))
            world:add(m, pair(ModifierOf, a))
        end
        return a
    end

    -- an owned entity leaves the list of those out of the idle state
    local function forget_busy(e: any)
        local at = busy_at[e]
        if at then
            local last = busy[#busy]
            busy[at] = last
            busy_at[last] = at
            busy[#busy] = nil
            busy_at[e] = nil
        end
    end

    local function set_busy(e: any, state: number)
        world:set(e, State, state)
        if state == 1 then
            forget_busy(e)
        elseif busy_at[e] == nil then
            table.insert(busy, e)
            busy_at[e] = #busy
        end
    end

    for _ = 1, scale.active do
        table.insert(active, make_agent())
    end
    for _ = 1, scale.retained do
        local a = make_agent(Retained)
        for _, e in owned_of[a] do
            world:add(e, RetainedOwned)
        end
        table.insert(retained, a)
    end
    for _ = 1, scale.second_kind do
        make_agent(SecondKind)
    end
    -- the expiry pairs of the groups
    for _, g in groups do
        for _ = 1, 3 do
            world:set(g, pair(Expiry, active[rand(#active)]), rand(1000))
        end
    end
    -- owned entities of active agents out of the idle state
    local function random_owned(): any
        local list = owned_of[active[rand(#active)]]
        return list[rand(#list)]
    end
    while #busy < scale.busy do
        set_busy(random_owned(), 1 + rand(STATES - 1))
    end

    local function make_effect(): any
        local e = world:entity()
        world:set(e, EffectC1, rand(100))
        world:set(e, EffectC2, rand(100))
        world:add(e, pair(EffectOf, active[rand(#active)]))
        return e
    end
    for i = 1, scale.effects do
        effects[i] = make_effect()
    end
    local function make_object(): any
        local e = world:entity()
        world:set(e, ObjectC1, 1)
        world:set(e, ObjectC2, 2)
        world:add(e, ObjectT)
        world:add(e, pair(ecs.ChildOf, random_owned()))
        return e
    end
    for i = 1, scale.objects do
        objects[i] = make_object()
    end
    local function make_deferred(): any
        local e = world:entity()
        world:set(e, Deferred, { agent = active[rand(#active)], value = rand(100) })
        return e
    end
    for i = 1, scale.deferred do
        deferred[i] = make_deferred()
        -- scattered: other entities come between
        for _ = 1, rand(8) do
            world:entity()
        end
    end
    -- the tags made at run time, toggled on agents
    for i = 1, RUNTIME_TAGS do
        RuntimeTag[i] = world:entity()
    end

    ----------------------------------------------------------------------------
    -- stored queries: 25, run at periods of 1 to 60 frames
    ----------------------------------------------------------------------------

    local stored: { { any } } = {
        -- agents
        { 1, world:query(AgentC[1], AgentC[2]):with(AgentT[1]):without(Retained):cached() },
        { 1, world:query(AgentC[3]):with(AgentT[2]):cached() },
        { 3, world:query(AgentC[4], AgentC[5], AgentC[6]):without(Retained, AgentT[3]):cached() },
        { 6, world:query(AgentC[7]):with(AgentT[4], AgentT[5]):cached() },
        { 30, world:query(AgentC[8], AgentC[9]):with(Retained):cached() },
        { 12, world:query(AgentC[10]):with(SecondKind):cached() },
        { 3, world:query(AgentC[11], AgentC[12]):with(AgentT[6]):without(AgentT[7]):cached() },
        { 12, world:query(AgentC[13]):with(RuntimeTag[1]):cached() },
        { 60, world:query(AgentC[14], AgentC[15]):without(AgentT[8]):cached() },
        -- groups and anchors
        { 1, world:query(GroupC1, GroupC2):with(GroupT1):cached() },
        { 6, world:query(GroupC1):without(GroupT2):cached() },
        { 12, world:query(AnchorC1, AnchorC2):with(AnchorT1):cached() },
        { 60, world:query(AnchorC3):cached() },
        -- owned entities in states
        { 1, world:query(State, OwnedC[1]):with(StateTag[2]):cached() },
        { 1, world:query(OwnedC[2]):with(StateTag[3], SystemTag[1]):cached() },
        { 3, world:query(OwnedC[3], OwnedC[4]):with(StateTag[4]):without(RetainedOwned):cached() },
        { 3, world:query(OwnedC[5]):with(StateTag[5]):cached() },
        { 6, world:query(OwnedC[6], OwnedC[7]):with(StateTag[6], SystemTag[2]):cached() },
        { 12, world:query(OwnedC[8]):with(StateTag[7]):cached() },
        { 1, world:query(OwnedC[1]):with(Flag):cached() },
        -- effects, modifiers, objects, messages
        { 1, world:query(EffectC1, EffectC2):cached() },
        { 3, world:query(ModifierC):cached() },
        { 6, world:query(ObjectC1, ObjectC2):with(ObjectT):cached() },
        { 30, world:query(Deferred):cached() },
        { 1, world:query(Message):cached() },
    }
    -- the loop over this one (owned entities in state 2) sends every 8th of them back to idle
    local changing_query = stored[14][2]

    ----------------------------------------------------------------------------
    -- the work of a frame
    ----------------------------------------------------------------------------

    local model: Model = {} :: any
    model.world = world
    model.scale = scale
    model.frame_count = 0

    function model.transitions(count: number)
        for _ = 1, count do
            if #busy > scale.busy // 2 and rand(2) == 1 then
                set_busy(busy[rand(#busy)], 1)
            else
                local e = random_owned()
                set_busy(e, if busy_at[e] then 1 else 1 + rand(STATES - 1))
            end
        end
    end

    -- the members of a state tag, each checked as it is reached, one value read
    function model.state_walks(): number
        local n = 0
        for k = 2, 6 do
            local state_tag = StateTag[k]
            for e in world:each(state_tag) do
                if world:has(e, state_tag) then
                    n += world:get(e, OwnedC[1]) or 0
                end
            end
        end
        return n
    end

    -- the members of a state tag that have a system tag: world:each and a check
    function model.intersection_each(): number
        local n = 0
        for s = 1, SYSTEM_TAGS do
            local state_tag, system_tag = StateTag[s % 6 + 2], SystemTag[s]
            for e in world:each(state_tag) do
                if world:has(e, system_tag) then
                    n += 1
                end
            end
        end
        return n
    end

    -- the same through one stored query per system tag
    local intersections: { any } = {}
    for s = 1, SYSTEM_TAGS do
        intersections[s] = world:query():with(StateTag[s % 6 + 2], SystemTag[s]):cached()
    end
    function model.intersection_queries(): number
        local n = 0
        for _, q in intersections do
            for _ in q do
                n += 1
            end
        end
        return n
    end

    function model.agent_changes()
        for _ = 1, scale.agent_changes do
            local a = active[rand(#active)]
            local roll = rand(4)
            if roll == 1 then
                local t = AgentT[5 + rand(5)]
                if world:has(a, t) then
                    world:remove(a, t)
                else
                    world:add(a, t)
                end
            elseif roll == 2 then
                local t = RuntimeTag[rand(RUNTIME_TAGS)]
                if world:has(a, t) then
                    world:remove(a, t)
                else
                    world:add(a, t)
                end
            elseif roll == 3 then
                world:set(a, AgentC[rand(AGENT_COMPONENTS)], rand(100))
            else
                local c = AgentC[16 + rand(4)]
                if world:has(a, c) then
                    world:remove(a, c)
                else
                    world:set(a, c, 1)
                end
            end
        end
        -- a few expiry pairs refreshed
        for _ = 1, 2 do
            world:set(groups[rand(#groups)], pair(Expiry, active[rand(#active)]), rand(1000))
        end
    end

    function model.stored_queries(): number
        local frame = model.frame_count
        local n = 0
        for _, entry in stored do
            if frame % entry[1] == 0 then
                local q = entry[2]
                if q == changing_query then
                    local i = 0
                    for e in q do
                        i += 1
                        if i % 8 == 0 then
                            set_busy(e, 1) -- the current entity leaves the query
                        end
                    end
                    n += i
                else
                    for _, a in q do
                        n += if type(a) == "number" then 1 else 0
                    end
                end
            end
        end
        return n
    end

    -- searches over the active agents: the one with the highest value
    local search_query = stored[1][2]
    function model.searches(): number
        local found = 0
        for _ = 1, 5 do
            local best = -math.huge
            for e, a, b in search_query do
                local score = a + b
                if score > best then
                    best = score
                    found = e
                end
            end
        end
        return found
    end

    local function walk_holders(id: any): number
        local n = 0
        for e in world:each(id) do
            local a, b, c = world:get(e, OwnedC[2], OwnedC[3], OwnedC[4])
            n += (a or 0) + (b or 0) + (c or 0)
        end
        return n
    end

    -- the messages of the previous frame handled and deleted, then the messages of this one
    function model.messages(): number
        local n = 0
        for e in world:each(Message) do
            local m = world:get(e, Message)
            if m and world:contains(m.agent) then
                n += walk_holders(pair(Trigger[m.trigger], m.agent))
                n += walk_holders(pair(Extra, m.agent))
            end
            world:delete(e)
        end
        for _ = 1, scale.messages do
            local e = world:entity()
            world:set(e, Message, { agent = active[rand(#active)], trigger = rand(TRIGGERS) })
        end
        return n
    end

    function model.deferred_messages(): number
        local n = 0
        for e in world:each(Deferred) do
            local m = world:get(e, Deferred)
            if m then
                n += m.value
            end
        end
        for _ = 1, 2 do
            local k = rand(#deferred)
            world:delete(deferred[k])
            deferred[k] = make_deferred()
        end
        return n
    end

    -- a batch over the owned entities in state 3, taken back the next frame
    local batch_query = world:query(OwnedC[1]):with(StateTag[3]):cached()
    local flagged = false
    function model.batch(): number
        if flagged then
            world:remove_all(Flag)
            flagged = false
        else
            batch_query:add_all(Flag)
            flagged = true
        end
        return 1
    end

    function model.replace_effect()
        local k = rand(#effects)
        world:delete(effects[k])
        effects[k] = make_effect()
    end

    function model.trigger_walk(): number
        local a = active[rand(#active)]
        local n = 0
        for _ in world:each(pair(Trigger[rand(TRIGGERS)], a)) do
            n += 1
        end
        return n
    end

    ----------------------------------------------------------------------------
    -- lifecycle events
    ----------------------------------------------------------------------------

    -- an active agent ends its activity: it keeps its owned entities, back to idle
    function model.end_activity()
        if #active <= 1 then
            return
        end
        local k = rand(#active)
        local a = active[k]
        active[k] = active[#active]
        active[#active] = nil
        world:add(a, Retained)
        for _, e in owned_of[a] do
            world:add(e, RetainedOwned)
            if busy_at[e] then
                set_busy(e, 1)
            end
        end
        world:remove_all(pair(Expiry, a))
        table.insert(retained, a)
    end

    -- a retained agent goes, with its owned entities, modifiers, effects and children
    function model.remove_retained()
        if #retained == 0 then
            return
        end
        local k = rand(#retained)
        local a = retained[k]
        retained[k] = retained[#retained]
        retained[#retained] = nil
        for _, e in owned_of[a] do
            forget_busy(e)
        end
        owned_of[a] = nil
        world:delete(a)
        -- the effects and the objects that went with it are made again
        for i, e in effects do
            if not world:contains(e) then
                effects[i] = make_effect()
            end
        end
        for i, e in objects do
            if not world:contains(e) then
                objects[i] = make_object()
            end
        end
    end

    function model.new_agent()
        table.insert(active, make_agent())
    end

    local events = { model.end_activity, model.remove_retained, model.new_agent }
    local next_event = 1

    function model.frame()
        local frame = model.frame_count + 1
        model.frame_count = frame
        model.transitions(scale.transitions)
        model.state_walks()
        model.intersection_each()
        model.agent_changes()
        model.stored_queries()
        model.searches()
        model.messages()
        model.deferred_messages()
        model.batch()
        model.replace_effect()
        if frame % 10 == 0 then
            local k = rand(#objects)
            world:delete(objects[k])
            objects[k] = make_object()
        end
        if frame % scale.event_every == 0 then
            events[next_event]()
            next_event = next_event % #events + 1
        end
    end

    model.sample_query = stored[10][2]
    model.sample_tag = StateTag[2]

    function model.spare_relation(): any
        return world:entity()
    end
    function model.owned_entities(count: number): { any }
        local list: { any } = {}
        for _, a in active do
            for _, e in owned_of[a] do
                table.insert(list, e)
                if #list >= count then
                    return list
                end
            end
        end
        return list
    end
    function model.agents(): { any }
        return active
    end

    return model
end

return {
    new = new,
    SMALL = SMALL,
    TARGET = TARGET,
}
