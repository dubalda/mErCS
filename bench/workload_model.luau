--!strict
--!optimize 2
--[[
    A model of the reference workload: its server world (the kinds of entities, their numbers,
    rates and access patterns), for the performance suite of bench/workload.luau. It uses only calls that the releases of the library since 0.2.2 have,
    so that a release is measured against the previous one.

    The world (Scale gives the numbers of the small and the target scale):
    - agents from a slot pool, active and retained (a retained tag), and a few agents of a
      second kind; 20 components and 5–7 tags each, a (ChildOf, group) membership;
    - owned entities, created in one burst right after their agent (adjacent slots): 9 of 10
      components, a state (a component value and a mirror tag of 7), one of 10 system tags for
      life, 1–2 more tags; (Owner, agent), exclusive and deleted with the agent; one of 8
      (Trigger_k, agent) relations (owned entity j answers relation j % 8); (Extra, agent) on the
      first two; the third is the (Parent, ...) of the next three;
    - the states: most owned entities rest in the idle state, and the other 6 state tags hold a
      few owned entities of active agents each, scattered (Scale.members): the busiest state, the
      passing state (its members enter and leave it within a frame or two, and the intersection
      walks go over it) and four more;
    - groups (2 values, 1–2 tags, (ChildOf, anchor)) that hold (Expiry, agent) data pairs with an
      expiry time on 3 agents each; anchors (3 values, 2 tags);
    - short-lived messages (one component with a table value, handled and deleted the frame after
      they are made), deferred messages in scattered slots (visited every frame, each lives about
      60 frames), timed effects ((EffectOf, agent), 2 values, one replaced per frame), 2 modifiers
      per agent ((ModifierOf, agent), 1 value), short-lived objects ((ChildOf, owned entity), 2
      values, a tag, one replaced every 10 frames);
    - a registry of about 85 components, 115 tags and 30 tags made at run time (the ids no kind
      above uses are carried by anchors and groups), and 14 relations besides ChildOf;
    - hooks on add and change of the state component move its mirror tag; removal listeners on
      the 7 state tags and on 3 ids that deleted entities carry.

    A frame (Model.frame) does the work of one server frame at the averages of the reference workload:
    state transitions, walks over state tags and over the members of the passing state with a
    system tag, agents whose tags and values change, 25 stored queries at periods of 1 to 60
    frames (a loop over one of them changes the state of its current entity), searches over a
    query of agents, messages (each walks the holders of (Trigger_k, agent) and (Extra, agent) and
    reads 3 values of each), deferred messages, a batch add_all and remove_all, a timed effect
    replaced, a few expiry pairs refreshed; and the lifecycle events at their rate: the end of
    the activity of an agent, the removal of a retained agent (the cascade over its owned
    entities, modifiers and effects) and a new agent with its owned entities. Model.burst
    switches the messages to a burst of activity (tens of messages a frame, up to a few hundred
    deferred ones) and back; Model.stress fills the passing state to the stress case of the
    intersection walks and back.

    The choices the workload leaves open (the ids of each kind, the terms of the stored queries,
    the rates within their ranges, how the transitions move owned entities between the states)
    are the ones above and in Scale; the numbers of the model are close to those of the
    workload, not the same.

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
    -- false: retained agents keep no owned entities (the alternate lifecycle workload)
    retain_owned: boolean?,
    second_kind: number,
    -- owned entities per agent, and per agent of the second kind
    owned: number,
    owned_second: number,
    groups: number,
    anchors: number,
    -- per frame: messages made (on average and in a burst of activity), state transitions,
    -- agents changed
    messages: number,
    burst_messages: number,
    transitions: number,
    agent_changes: number,
    -- alive at a time: deferred messages (on average and in a burst of activity), timed
    -- effects, short-lived objects
    deferred: number,
    burst_deferred: number,
    effects: number,
    objects: number,
    -- the members of the states out of idle on average, states 2 to 7: the busiest state, the
    -- passing state (the one the intersection walks go over) and four more
    members: { number },
    -- the members of the passing state in the stress case of the intersection walks
    stress_members: number,
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
    messages = 2,
    burst_messages = 30,
    transitions = 10,
    agent_changes = 5,
    deferred = 1,
    burst_deferred = 60,
    effects = 30,
    objects = 10,
    -- the averages of the reference workload: 18 in the busiest state, 3.6 in the passing one and
    -- 0.4–1.4 in each of the other four
    members = { 18, 4, 1, 1, 1, 1 },
    stress_members = 80,
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
    messages = 5,
    burst_messages = 30,
    transitions = 20,
    agent_changes = 10,
    deferred = 3,
    burst_deferred = 300,
    effects = 200,
    objects = 30,
    -- twice the members of the small scale
    members = { 36, 8, 2, 2, 2, 2 },
    stress_members = 80,
    -- 0.5 events of each kind per second
    event_every = 40,
}

local STATES = 7
-- the idle state, the busiest state and the passing one (the intersection walks go over it)
local IDLE, BUSIEST, PASSING = 1, 2, 3
-- the states a transition takes a member out of when every state has its members: the passing
-- state PASSING_SHARE times in 10, one of these otherwise
local OTHER_STATES = { 2, 4, 5, 6, 7 }
local PASSING_SHARE = 7
-- the frames a deferred message lives on average
local DEFERRED_FRAMES = 60
local SYSTEM_TAGS = 10
local TRIGGERS = 8
local AGENT_COMPONENTS = 20
local AGENT_TAGS = 10
local OWNED_COMPONENTS = 10
local OWNED_TAGS = 4
local RUNTIME_TAGS = 30
-- the registry of the reference workload: components and tags in all
local REGISTRY_COMPONENTS = 85
local REGISTRY_TAGS = 115

export type Model = {
    world: any,
    scale: Scale,
    frame_count: number,
    -- one frame of the workload, with the lifecycle events at their rate
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
    -- a burst of activity of the messages, and the stress case of the intersection walks
    -- (true switches to it, false back to the averages)
    burst: (on: boolean) -> (),
    stress: (on: boolean) -> (),
    -- the members of a state out of idle, and the deferred messages alive
    state_count: (state: number) -> number,
    deferred_count: () -> number,
    -- a stored query and the id of a state tag, for the allocation checks
    sample_query: any,
    sample_tag: any,
    -- a relation and entities for the memory of pairs
    spare_relation: () -> any,
    owned_entities: (count: number) -> { any },
    agents: () -> { any },
    verify_expiry: () -> (),
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
    -- the owned entities out of the idle state: the members of each state (2 to STATES), the
    -- state of each and its place in the list; goals holds the members each state keeps
    local in_state: { { any } } = {}
    local state_of: { [any]: number } = {}
    local state_at: { [any]: number } = {}
    local goals: { number } = {}
    for k = 2, STATES do
        in_state[k] = {}
        goals[k] = scale.members[k - 1]
    end
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
        owned_of[a] = add_owned(
            a,
            if kind == SecondKind
                then scale.owned_second
                elseif kind == Retained and scale.retain_owned == false then 0
                else scale.owned
        )
        for _ = 1, 2 do
            local m = world:entity()
            world:set(m, ModifierC, rand(100))
            world:add(m, pair(ModifierOf, a))
        end
        return a
    end

    -- an owned entity leaves the list of its state
    local function forget_state(e: any)
        local k = state_of[e]
        if k then
            local list = in_state[k]
            local at = state_at[e]
            local last = list[#list]
            list[at] = last
            state_at[last] = at
            list[#list] = nil
            state_of[e] = nil
            state_at[e] = nil
        end
    end

    local function set_state(e: any, state: number)
        world:set(e, State, state)
        forget_state(e)
        if state ~= IDLE then
            local list = in_state[state]
            table.insert(list, e)
            state_of[e] = state
            state_at[e] = #list
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
    -- Three target slots per group: frames refresh existing pairs. A target whose activity
    -- ended loses its pair through remove_all, and its slot is refilled on the next refresh.
    -- Choosing a new target on every set instead would grow the modeled world for minutes.
    local expiry_targets: { [any]: { any } } = {}
    for _, g in groups do
        local targets: { any } = {}
        expiry_targets[g] = targets
        for i = 1, 3 do
            local a = active[rand(#active)]
            targets[i] = a
            world:set(g, pair(Expiry, a), rand(1000))
        end
    end
    -- the states take their members among the owned entities of active agents
    local function random_owned(): any
        local list = owned_of[active[rand(#active)]]
        return list[rand(#list)]
    end
    local function random_idle(): any
        local e = random_owned()
        while state_of[e] do
            e = random_owned()
        end
        return e
    end
    for k = 2, STATES do
        while #in_state[k] < goals[k] do
            set_state(random_idle(), k)
        end
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
    -- the entities between the deferred messages of a burst of activity, deleted when it ends
    local burst_gaps: { any } = {}
    -- messages made per frame
    local message_rate = scale.messages
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
        { 1, world:query(State, OwnedC[1]):with(StateTag[BUSIEST]):cached() },
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
    -- the loop over this one (owned entities in the busiest state) sends every 8th of them back
    -- to idle
    local changing_query = stored[14][2]

    ----------------------------------------------------------------------------
    -- the work of a frame
    ----------------------------------------------------------------------------

    local model: Model = {} :: any
    model.world = world
    model.scale = scale
    model.frame_count = 0

    -- A transition moves one owned entity of an active agent: into the state furthest below its
    -- members, or, when every state has them, out of a state into idle (and the next transition
    -- takes another one in). Most of these leave the passing state, whose members pass it
    -- within a frame or two.
    function model.transitions(count: number)
        for _ = 1, count do
            local refill, deficit = 0, 0
            for k = 2, STATES do
                local missing = goals[k] - #in_state[k]
                if missing > deficit then
                    refill, deficit = k, missing
                end
            end
            if refill ~= 0 then
                set_state(random_idle(), refill)
            else
                local k = if rand(10) <= PASSING_SHARE then PASSING else OTHER_STATES[rand(#OTHER_STATES)]
                local list = in_state[k]
                if #list > 0 then
                    set_state(list[rand(#list)], IDLE)
                else
                    set_state(random_idle(), k)
                end
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

    -- the members of the passing state that have a system tag, for each system tag: world:each
    -- and a check
    function model.intersection_each(): number
        local n = 0
        local state_tag = StateTag[PASSING]
        for s = 1, SYSTEM_TAGS do
            local system_tag = SystemTag[s]
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
        intersections[s] = world:query():with(StateTag[PASSING], SystemTag[s]):cached()
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
            local g = groups[rand(#groups)]
            local targets = expiry_targets[g]
            local at = rand(3)
            local a = targets[at]
            if not world:contains(a) or not world:has(g, pair(Expiry, a)) then
                a = active[rand(#active)]
                targets[at] = a
            end
            world:set(g, pair(Expiry, a), rand(1000))
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
                            set_state(e, IDLE) -- the current entity leaves the query
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
        for _ = 1, message_rate do
            local e = world:entity()
            world:set(e, Message, { agent = active[rand(#active)], trigger = rand(TRIGGERS) })
        end
        return n
    end

    -- the deferred messages visited; each lives about DEFERRED_FRAMES frames, so a frame
    -- replaces #deferred / DEFERRED_FRAMES of them on average
    local deferred_due = 0
    function model.deferred_messages(): number
        local n = 0
        for e in world:each(Deferred) do
            local m = world:get(e, Deferred)
            if m then
                n += m.value
            end
        end
        deferred_due += #deferred / DEFERRED_FRAMES
        while deferred_due >= 1 do
            deferred_due -= 1
            local k = rand(#deferred)
            world:delete(deferred[k])
            deferred[k] = make_deferred()
        end
        return n
    end

    -- A burst of activity: tens of messages a frame and up to a few hundred deferred messages,
    -- made in scattered slots; false goes back to the averages.
    function model.burst(on: boolean)
        message_rate = if on then scale.burst_messages else scale.messages
        local goal = if on then scale.burst_deferred else scale.deferred
        while #deferred < goal do
            table.insert(deferred, make_deferred())
            for _ = 1, rand(8) do
                local gap: any = world:entity()
                table.insert(burst_gaps, gap)
            end
        end
        while #deferred > goal do
            world:delete(table.remove(deferred))
        end
        if not on then
            for _, e in burst_gaps do
                world:delete(e)
            end
            table.clear(burst_gaps)
        end
    end

    -- The stress case of the intersection walks: the passing state filled to stress_members
    -- members; false goes back to its average.
    function model.stress(on: boolean)
        local goal = if on then scale.stress_members else scale.members[PASSING - 1]
        goals[PASSING] = goal
        local list = in_state[PASSING]
        while #list < goal do
            set_state(random_idle(), PASSING)
        end
        while #list > goal do
            set_state(list[rand(#list)], IDLE)
        end
    end

    -- a batch over the owned entities in the passing state, taken back the next frame
    local batch_query = world:query(OwnedC[1]):with(StateTag[PASSING]):cached()
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

    -- An active agent ends its activity: retain its owned entities, or delete them in the
    -- alternate profile. Both profiles keep the same agents and the same event rates.
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
            if scale.retain_owned == false then
                forget_state(e)
                world:delete(e)
            else
                world:add(e, RetainedOwned)
                if state_of[e] then
                    set_state(e, IDLE)
                end
            end
        end
        if scale.retain_owned == false then
            owned_of[a] = {}
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
            forget_state(e)
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
    model.sample_tag = StateTag[BUSIEST]

    function model.state_count(state: number): number
        return #in_state[state]
    end
    function model.deferred_count(): number
        return #deferred
    end

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

    function model.verify_expiry()
        for _, g in groups do
            local count = 0
            for _ in world:targets(g, Expiry) do
                count += 1
            end
            assert(count <= 3, "the workload must keep at most three expiry pairs per group")
        end
    end

    return model
end

return {
    new = new,
    SMALL = SMALL,
    TARGET = TARGET,
    -- the state the intersection walks go over (Scale.members[PASSING - 1] on average)
    PASSING = PASSING,
}
