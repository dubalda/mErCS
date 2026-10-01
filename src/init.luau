--!optimize 2
--!native
--!strict
--[[
    mErCS: an entity component system for Luau / Roblox built on inverted bitsets.

    Why: adding or removing a component sets a bit and a value; the entity never moves and
    nothing is created per combination of components, so frequent structural changes (tags
    for states, relationships, spawn/despawn) stay O(1) and the memory does not grow with the
    number of component combinations.

    Quick start:
        local ecs = require(path.to.mErCS)
        local world = ecs.world()

        local Position = world:component() :: ecs.Component<Vector3>
        local Velocity = world:component() :: ecs.Component<Vector3>
        local Frozen = world:entity() -- any entity can be used as a tag

        local e = world:entity()
        world:set(e, Position, Vector3.zero)
        world:set(e, Velocity, Vector3.xAxis)

        -- fastest iteration: a callback per entity
        world:query(Position, Velocity):without(Frozen):each(function(entity, position, velocity)
            world:set(entity, Position, position + velocity)
        end)

        -- or a for-in loop
        for entity, position, velocity in world:query(Position, Velocity) do
        end

        -- relationships
        local parent = world:entity()
        world:add(e, ecs.pair(ecs.ChildOf, parent))
        print(world:parent(e) == parent)

    Storage model:
    - An entity id is a number: slot + generation * 2^24.
    - alive[slot] is the live entity of a slot, or -1 - slot * 2^24 when the slot is free
      (negative, with all 24 low bits set: iterators never take it for a slot). A slot pool
      (world:pool) hands out slots from blocks of 256 reserved for it and takes its freed
      slots back, so that a kind of entities created among many others stays dense.
    - Every id used on entities (component, tag, pair) has a record with presence bitsets:
      words[w] holds 32 slots (w = slot // 32 + 1), sums[sw] marks the non-empty words of
      1024 slots and sums[-tw] the non-empty summary words of 32768 slots, so a scan costs
      the number of non-empty parts, not the size of the world. Components also keep their
      values in pages of 256 slots. Every change of a record increments its version; a record
      that a cached query observes also notes the changed slots in a journal.
    - Each entity has a signature: a bitset of the record indices it has (components, tags
      and relation records (R, *)). delete/clear use it to find all records of the entity
      without scanning; a mask of the signature bits with on_remove hooks tells whether the
      hooks have to run first.
    - Relationships: a pair (R, T) is a record of its own, reached from the relation record
      (R, *), which keeps the pairs of every entity (target() reads it). The target record
      (*, T) lists the pairs with target T for cleanup policies (a small record until then);
      from the first time a query, has() or an iteration reads it, it also keeps the bitset of
      the slots that have any of them (with a count for the slots that have several). Pair
      records left without members are freed in batches (free_empty_pairs), a (*, T) record
      with the last pair record of T, and all of them when R or T is deleted. A wildcard whose
      values a query returns keeps a copy of them in value pages of its own (a mirror, see
      mirror.create), which the query reads like a column.

    Queries AND the bitsets of the included ids and AND-NOT the excluded ones; full words are
    merged into runs and iterated sequentially. A cached query with scattered matches keeps a
    list of them grouped by value page, and after changes that cost less to re-check than a
    pass over the bitsets it re-checks only the slots noted in the journals of its records
    (patch_list), skipping those that an unchanged required record does not have (tested per
    word against the words of a small one); an empty result is kept as an empty list. Queries
    created on every call share their state by shape from the second request of the shape (see
    query_state and share_shape): an inline world:query allocates only a small handle, and
    iterating allocates nothing; the shapes that have a deleted entity id, or a pair with it as
    the target, are dropped (prune_shapes). A query that is not shared reuses the
    iteration contexts of the world (spare_contexts), and a small one gathers its matches into
    a buffer first (scan.fill).
    Value pages of dense components are preallocated arrays, of sparse ones small hash tables.

    Also: Disabled (hidden from queries that do not name it), change tracking (world:track,
    world:tick, query:added/changed/removed) and creation tracking (world:track_created,
    query:created), query monitors (query:monitor: callbacks for the entities that start and
    stop matching a query), batch operations on the matches of a query
    (query:add_all/set_all/remove_all/delete_all/toggle_all), world:toggle, world:remove_all,
    world:ids. A query must select entities (a required id, an OR term or a change filter);
    one with excluded ids alone raises an error when it is used (check: selects). A removal
    that the hooks of the same removal start again does nothing (see removing), so relations
    kept in sync by hooks run the hook of each side once. world_new has used all 200
    registers of a Luau function: new state goes into existing tables or locals declared
    before the functions that use it, and new methods are assigned to world and Query directly.

    Changes during iteration: the current entity may be changed or deleted. Changes of other
    entities may or may not be seen by the running loop; an entity deleted ahead of the loop
    may still be returned once (world:contains tells).

    get/has take at most 8 ids (get_list/has_all take any number); hooks get (entity, id,
    value); query:each is the fastest way to iterate. The API reference is the block of doc
    comments after the types (published on the documentation site); docs/guide/README.md is the guide.
]]

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

type i53 = number

-- Ids are numbers at runtime; the phantom field carries the component data type.
export type Id<T = any> = { __T: T }
export type Entity<T = nil> = Id<T>
export type Component<T = any> = Id<T>

-- selene: allow(undefined_variable) -- `types` is the type function library
type function pair_type(first: type, second: type)
    local key = types.singleton("__T")
    local first_data = first:readproperty(key)
    local second_data = second:readproperty(key)
    assert(first_data and second_data, "Expected ids in pair")
    local id = types.newtable()
    id:setproperty(key, if first_data:is("nil") then second_data else first_data)
    return id
end

-- A pair carries the data of its relation, or of its target when the relation is a tag.
export type Pair<First = any, Second = any> = pair_type<Id<First>, Id<Second>>

type Hook = (entity: i53, id: i53, value: any?) -> ()
type Page = { [number]: any }
type Pages = { [number]: Page }
type Words = { [number]: number }

type Record = {
    id: i53,
    -- KIND_PLAIN, KIND_PAIR (R, T), KIND_RELATION (R, *) or KIND_TARGET (*, T)
    kind: number,
    -- signature bit of the record; pair and (*, T) records are not in signatures (index 0):
    -- the pairs of an entity are reached through the (R, *) records of its signature
    index: number,
    -- (nil for pair and (*, T) records: they have no signature bit)
    sig_word: number,
    sig_bit: number,
    sig_table: Words?,
    -- presence: words[w] holds 32 slots, sums[sw] (sw >= 1) marks the non-empty words of 1024
    -- slots, and sums[-tw] (the third level, "tops", in the same table) the non-empty summary
    -- words of 32768 slots; an emptied entry stays 0 (see word_last), and zeros counts the
    -- words emptied since the zeros were last dropped. A lazy (*, T) record has none of the
    -- fields from here to journal_mask (and no multi) until target_materialize adds them.
    words: Words,
    sums: Words,
    word_count: number,
    zeros: number,
    -- incremented by every change of the presence or the value pages
    version: number,
    -- change journal (see note): (version, slot) entries in a ring of journal_mask + 1 entries,
    -- false without one (a field that is present is read faster than a missing one)
    journal: { number } | false,
    journal_mask: number,
    -- values (components only)
    pages: Pages?,
    on_add: Hook?,
    on_change: Hook?,
    on_remove: Hook?,
    -- pair (R, T) records
    relation: i53?,
    target: i53?,
    wc_rel: Record?,
    wc_tgt: Record?,
    -- wildcard (R, *) and (*, T) records: all pair records of the wildcard
    pairs: { [i53]: Record }?,
    -- (R, *): pair record with the lowest target slot, and all pair records sorted by
    -- target slot when the slot has more than one target
    slot_pair: { [number]: Record }?,
    slot_pairs: { [number]: { Record } }?,
    exclusive: boolean?,
    -- (*, T): whether the presence is kept (see target_materialize), and the slots that have
    -- more than one pair with the target with how many they have (false while there are none)
    eager: boolean?,
    multi: { [number]: number } | false | nil,
    -- (R, *) and (*, T): the number of pair records of the wildcard that hold values (the
    -- wildcard returns no values while it is 0)
    data_pairs: number?,
    -- (R, *) and (*, T) records whose values a query returns (see mirror.create): the value of
    -- the first pair of every member slot in value pages of their own (also in columns), and
    -- for (*, T) the pair that gives the value of each slot that has several pairs (the slots
    -- in multi)
    mirror: Pages?,
    source: { [number]: Record }?,
    -- pair records: the index in the list of records that were left empty (see
    -- note_empty_pair), nil when not listed
    empty_listed: number?,
}

type QueryState = {
    ids: { i53 },
    filter_with: { i53 },
    filter_without: { i53 }?,
    -- OR terms (see Query.any) and their merged bitsets
    any_groups: { { i53 } }?,
    any_merged: { any }?,
    is_cached: boolean,
    -- cached and without change filters: the query may keep a match list (see iteration_mode)
    listable: boolean,
    observed: { any },
    versions: { number },
    mode: number,
    -- list mode: the matches grouped by value page, in ascending slot order. Group g holds
    -- the list_sizes[g] matches of page list_gpages[g] in list_items[g]: the entity of the
    -- k-th at 2k - 1 and its index in the page at 2k. list_firsts[g] and list_first_lis[g]
    -- repeat the first match: the loops read a group of one match (an entity alone in its
    -- page, which is common for a kind scattered among many other entities) from them and do
    -- not touch its array. list_pages[column][g] is the page of the column for the group and
    -- list_cols the columns. A group is never empty; list_sizes has exactly list_groups
    -- entries.
    list_gpages: { number },
    list_items: { { number } },
    list_sizes: { number },
    list_firsts: { number },
    list_first_lis: { number },
    -- list_ghint[page]: the group of the page when the list last saw it (a hint: groups move
    -- when a group before them is created or removed, and patch_list checks it)
    list_ghint: { [number]: number },
    list_pages: { { Page } },
    list_cols: { Pages },
    list_count: number,
    list_groups: number,
    -- the list is empty because a required id has no record: only a new record changes that
    list_missing: boolean?,
    -- the query does not name Disabled: disabled entities are excluded
    skip_disabled: boolean,
    -- a returned id is a wildcard pair: its values come from a mirror (see mirror.ensure)
    wild_values: boolean,
    -- list mode: the reusable iterator (step, reset) and whether it is running, and the
    -- number of loops over the current list tables that have not finished
    list_step: (() -> ...any)?,
    list_reset: (() -> ())?,
    list_busy: boolean?,
    list_readers: number,
    -- changes when the list tables are replaced (a running loop keeps the tables it started
    -- with): a loop counts itself out of list_readers only while its tables are the current
    -- ones, so a loop left with break makes one update copy the list, not every update
    list_epoch: number,
    -- changes_stamp when the query last found its list up to date (nil when the list is not
    -- in use): while the stamp is the same, nothing that the query observes changed
    list_stamp: number?,
    -- records_generation when the query observed its records, how many it observed, and how many
    -- of them are required ones (the first ones)
    observed_generation: number?,
    observed_records: number?,
    observed_with: number?,
    -- the words of the smallest required term when the query was planned last: a pass over the
    -- bitsets reads about that many words (see iteration_mode)
    scan_words: number,
    -- the words of the terms for patch_list (see Terms), made by term_words; nil until the list
    -- is patched first
    terms: Terms?,
    -- the state of the first request of a shape (see share_shape): the node of the mark of the
    -- shape in the tree, until the state is shared or stays a query of its own (see promote);
    -- looped once it has been iterated
    first_use: any?,
    looped: boolean?,
    -- shared query (see query_state): modifiers return shared variants, never change it;
    -- variants is false once the state has left the tree of shapes (see prune_shapes): the
    -- modifiers return queries of their own then
    shared: boolean?,
    variants: { [any]: any } | false | nil,
    -- reusable iteration contexts of a cached query (see new_direct and query_each)
    direct: any?,
    each_ctx: any?,
    -- change filters: { kind, id } pairs, and the first tick not seen yet by this query
    tracking: { { any } }?,
    seen_tick: number?,
}

-- The terms of a query for patch_list (see term_words), valid while records_generation is
-- `generation`: the words of the required ids, smallest first, of each OR term (nil without),
-- of the excluded ids (nil without); `empty` when a required id has no record or the query has
-- no terms (nothing matches).
type Terms = {
    generation: number,
    with: { Words },
    any: { { Words } }?,
    without: { Words }?,
    empty: boolean,
}

-- the object returned by world:query: the query state it currently uses
type QueryHandle = { state: QueryState }

export type Query<T...> = typeof(setmetatable(
    {} :: {
        with: (self: Query<T...>, ...Id<any>) -> Query<T...>,
        without: (self: Query<T...>, ...Id<any>) -> Query<T...>,
        cached: (self: Query<T...>) -> Query<T...>,
        each: (self: Query<T...>, callback: (Entity, T...) -> ()) -> (),
        has: (self: Query<T...>, entity: Id<any>) -> boolean,
        -- an OR term: the entity has at least one of the ids
        any: (self: Query<T...>, ...Id<any>) -> Query<T...>,
        -- change filters (the id must be tracked, see World.track): entities that got the id
        -- added / its value set / the id removed since the previous iteration of this query
        added: (self: Query<T...>, id: Id<any>) -> Query<T...>,
        changed: (self: Query<T...>, id: Id<any>) -> Query<T...>,
        removed: (self: Query<T...>, id: Id<any>) -> Query<T...>,
        -- the entities made since the previous iteration of this query (see World.track_created)
        created: (self: Query<T...>) -> Query<T...>,
        spans: (self: Query<T...>) -> () -> (number?, number?, number),
        -- batch operations on the entities that match now
        count: (self: Query<T...>) -> number,
        add_all: (self: Query<T...>, id: Id<any>) -> (),
        set_all: <V>(self: Query<T...>, id: Id<V>, value: V) -> (),
        remove_all: (self: Query<T...>, id: Id<any>) -> (),
        delete_all: (self: Query<T...>) -> (),
        toggle_all: (self: Query<T...>, id: Id<any>) -> (),
        -- callbacks for the entities that start and stop matching the query
        monitor: (self: Query<T...>) -> Monitor,
    },
    {} :: {
        __iter: (self: Query<T...>) -> () -> (Entity, T...),
    }
))

-- The object returned by query:monitor (see Query.monitor).
export type Monitor = {
    -- sets the callback for the entities that start matching the query (nil clears it)
    added: (callback: ((entity: Entity) -> ())?) -> (),
    -- sets the callback for the entities that stop matching it (nil clears it)
    removed: (callback: ((entity: Entity) -> ())?) -> (),
    -- stops the monitor: no callback runs after it
    disconnect: () -> (),
}

-- A slot pool (see World.pool): entities that take their slots from blocks of their own.
export type Pool = {
    entity: (self: Pool) -> Entity,
}

export type World = {
    entity: ((self: World) -> Entity) & (<T>(self: World, id: Id<T>) -> Id<T>) & ((self: World, id: number) -> Entity),
    -- a slot pool: its entities keep their slots together (dense bitsets for a rare kind)
    pool: (self: World) -> Pool,
    component: <T>(self: World) -> Component<T>,
    set: <T>(self: World, entity: Id<any>, id: Id<T>, value: T) -> (),
    add: (self: World, entity: Id<any>, id: Id<any>) -> (),
    get: (<A>(self: World, entity: Id<any>, a: Id<A>) -> A?)
        & (<A, B>(self: World, entity: Id<any>, a: Id<A>, b: Id<B>) -> (A?, B?))
        & (<A, B, C>(self: World, entity: Id<any>, a: Id<A>, b: Id<B>, c: Id<C>) -> (A?, B?, C?))
        & (<A, B, C, D>(self: World, entity: Id<any>, a: Id<A>, b: Id<B>, c: Id<C>, d: Id<D>) -> (A?, B?, C?, D?))
        & ((
            self: World,
            entity: Id<any>,
            a: Id<any>,
            b: Id<any>,
            c: Id<any>,
            d: Id<any>,
            e: Id<any>,
            ...Id<any>
        ) -> ...any),
    get_list: (self: World, entity: Id<any>, ids: { Id<any> }, out: { any }?) -> { any },
    has: (self: World, entity: Id<any>, ...Id<any>) -> boolean,
    has_all: (self: World, entity: Id<any>, ids: { Id<any> }) -> boolean,
    remove: (self: World, entity: Id<any>, id: Id<any>) -> (),
    -- adds the id when the entity does not have it, removes it when it does: true when added
    toggle: (self: World, entity: Id<any>, id: Id<any>) -> boolean,
    delete: (self: World, entity: Id<any>) -> (),
    clear: (self: World, entity: Id<any>) -> (),
    contains: (self: World, entity: Id<any>) -> boolean,
    exists: (self: World, entity: Id<any>) -> boolean,
    target: (self: World, entity: Id<any>, relation: Id<any>, index: number?) -> Entity?,
    targets: (self: World, entity: Id<any>, relation: Id<any>) -> () -> Entity?,
    parent: (self: World, entity: Id<any>) -> Entity?,
    children: (self: World, parent: Id<any>) -> () -> Entity?,
    each: (self: World, id: Id<any>) -> () -> Entity?,
    -- removes an id from every entity that has it (fast for ids without on_remove hooks)
    remove_all: (self: World, id: Id<any>) -> (),
    added: <T>(self: World, id: Id<T>, listener: (entity: Entity, id: Id<T>, value: T) -> ()) -> () -> (),
    -- change tracking: record additions, value changes and removals of an id per tick
    track: (self: World, id: Id<any>) -> (),
    -- creation tracking: record the entities made from now on per tick (Query.created)
    track_created: (self: World) -> (),
    -- advances the tick: the changes recorded so far become visible to change filters
    tick: (self: World) -> number,
    changed: <T>(self: World, id: Id<T>, listener: (entity: Entity, id: Id<T>, value: T) -> ()) -> () -> (),
    removed: <T>(self: World, id: Id<T>, listener: (entity: Entity, id: Id<T>, delete: boolean?) -> ()) -> () -> (),
    range: (self: World, range_begin: number, range_end: number?) -> (),
    query: ((self: World) -> Query<>)
        & (<A>(self: World, a: Id<A>) -> Query<A>)
        & (<A, B>(self: World, a: Id<A>, b: Id<B>) -> Query<A, B>)
        & (<A, B, C>(self: World, a: Id<A>, b: Id<B>, c: Id<C>) -> Query<A, B, C>)
        & (<A, B, C, D>(self: World, a: Id<A>, b: Id<B>, c: Id<C>, d: Id<D>) -> Query<A, B, C, D>)
        & (<A, B, C, D, E>(self: World, a: Id<A>, b: Id<B>, c: Id<C>, d: Id<D>, e: Id<E>) -> Query<A, B, C, D, E>)
        & (<A, B, C, D, E, F>(
            self: World,
            a: Id<A>,
            b: Id<B>,
            c: Id<C>,
            d: Id<D>,
            e: Id<E>,
            f: Id<F>
        ) -> Query<A, B, C, D, E, F>)
        & (<A, B, C, D, E, F, G>(
            self: World,
            a: Id<A>,
            b: Id<B>,
            c: Id<C>,
            d: Id<D>,
            e: Id<E>,
            f: Id<F>,
            g: Id<G>
        ) -> Query<A, B, C, D, E, F, G>)
        & (<A, B, C, D, E, F, G, H>(
            self: World,
            a: Id<A>,
            b: Id<B>,
            c: Id<C>,
            d: Id<D>,
            e: Id<E>,
            f: Id<F>,
            g: Id<G>,
            h: Id<H>,
            ...Id<any>
        ) -> Query<A, B, C, D, E, F, G, H, ...any>),
    -- fast path access (see query:spans)
    column: (self: World, id: Id<any>) -> Pages,
    alive_table: (self: World) -> { number },
    -- introspection: every id of an entity (components, tags and pairs), sorted
    ids: (self: World, entity: Id<any>) -> { Id },
}

--------------------------------------------------------------------------------
-- API reference: Moonwave doc comments, published on the documentation site
-- (moonwave.toml; docs/guide/README.md is the guide)
--------------------------------------------------------------------------------

--[=[
    @class mErCS

    The module: creates worlds and holds the builtin ids and the id helpers shared by every
    world.

    ```lua
    local ecs = require(ReplicatedStorage.mErCS)
    local world = ecs.world()
    ```
]=]

--[=[
    @type Id { __T: T }
    @within mErCS
    `Id<T>`: an id of a component, tag, pair or entity. At runtime it is a number; `T` is the data
    type of a component, known only to the type checker.
]=]

--[=[
    @type Entity Id<T>
    @within mErCS
    `Entity<T>`: an entity id: slot + generation × 2^24. A deleted slot is reused with the next
    generation, so an old handle of it is not alive anymore ([World:contains] tells).
]=]

--[=[
    @type Component Id<T>
    @within mErCS
    `Component<T>`: an id that holds data of type `T`: an entity with the [mErCS.Component] trait.
    `world:component()` returns `Component<unknown>`; a cast gives it the data type:

    ```lua
    local Position = world:component() :: ecs.Component<Vector3>
    ```
]=]

--[=[
    @type Pair Id<First | Second>
    @within mErCS
    `Pair<First, Second>`: a relationship id made by [mErCS.pair]. It carries the data of its relation, or of its
    target when the relation is a tag.
]=]

--[=[
    @function world
    @within mErCS
    @param debug boolean? -- raise errors for entities and ids that are not alive
    @return World
    Creates a world. With `debug = true`, `set`, `add`, `remove`, `delete`, `clear` and the
    batch operations raise an error for an entity or an id that is not alive (an outdated
    handle) instead of ignoring the call, every match list that a cached query updates after a
    change is checked against a scan of the bitsets, a query that takes its list as it is
    checks that none of its ids changed, and the world warns once when its 1024 shared query
    states are in use (a query of a new shape then builds a new state on every call).
]=]

--[=[
    @function component
    @within mErCS
    @return Component<T>
    Reserves a component id in every world created afterwards (pre-registration). The ids
    are 1..256, in the order of the calls.
]=]

--[=[
    @function tag
    @within mErCS
    @return Entity
    Reserves a tag id in every world created afterwards (pre-registration).
]=]

--[=[
    @function meta
    @within mErCS
    @param id Id -- a pre-registered id
    @param trait Id<T> -- the trait: a tag, or a component with a value
    @param value T? -- the value of the trait; nil adds the trait without a value
    Adds or sets a trait on a pre-registered id in every world created afterwards, for
    example `ecs.meta(Position, ecs.Name, "Position")`.
]=]

--[=[
    @function ECS_META_RESET
    @within mErCS
    Forgets the pre-registered ids and their traits (tests use it to isolate worlds).
]=]

--[=[
    @function pair
    @within mErCS
    @param first Id<P> -- the relation
    @param second Id<O> -- the target
    @return Pair<P, O>
    The id of the relationship pair (relation, target); an entity gets it like any id:

    ```lua
    world:add(child, ecs.pair(ecs.ChildOf, parent))
    ```

    The pair holds data when the relation is a component, or, for a tag relation, when the
    target is one. The generations of both entities are dropped.
]=]

--[=[
    @function IS_PAIR
    @within mErCS
    @param id Id
    @return boolean
    Whether an id is a pair.
]=]

--[=[
    @function pair_first
    @within mErCS
    @param world World
    @param pair Id
    @return Entity -- 0 when the relation is not alive
    The live entity of the relation of a pair.
]=]

--[=[
    @function pair_second
    @within mErCS
    @param world World
    @param pair Id
    @return Entity -- 0 when the target is not alive
    The live entity of the target of a pair.
]=]

--[=[
    @function ECS_PAIR_FIRST
    @within mErCS
    @param pair Id
    @return number
    The slot of the relation of a pair.
]=]

--[=[
    @function ECS_PAIR_SECOND
    @within mErCS
    @param pair Id
    @return number
    The slot of the target of a pair.
]=]

--[=[
    @function ECS_ID
    @within mErCS
    @param entity Id
    @return number
    The slot of an entity id.
]=]

--[=[
    @function ECS_GENERATION
    @within mErCS
    @param entity Id
    @return number
    The generation of an entity id.
]=]

--[=[
    @function ECS_GENERATION_INC
    @within mErCS
    @param entity Id<T>
    @return Id<T>
    The same slot with the next generation.
]=]

--[=[
    @function ECS_COMBINE
    @within mErCS
    @param id number -- the slot
    @param generation number
    @return Entity
    The entity id of a slot and a generation: slot + generation × 2^24.
]=]

--[=[
    @prop ENTITY_MASK number
    @within mErCS
    @readonly
    2^24: the number of slots; the generation is counted in multiples of it.
]=]

--[=[
    @prop PAGE_SIZE number
    @within mErCS
    @readonly
    256: the values of a component are kept in pages of this many slots (see
    [World:column]).
]=]

--[=[
    @prop OnAdd Component<(entity: Entity, id: Id, value: any?) -> ()>
    @within mErCS
    @readonly
    Hook: runs when the id it is set on is added to an entity, with the value.

    ```lua
    world:set(Health, ecs.OnAdd, function(entity, id, value) end)
    ```

    Hooks may be set and removed at any time; a hook on a relation applies to all its pairs.
    The hook and the listeners of [World:added] all run, the hook first.
]=]

--[=[
    @prop OnChange Component<(entity: Entity, id: Id, value: any?) -> ()>
    @within mErCS
    @readonly
    Hook: runs when the value of the id it is set on is set again on an entity.
]=]

--[=[
    @prop OnRemove Component<(entity: Entity, id: Id, deleting: boolean?) -> ()>
    @within mErCS
    @readonly
    Hook: runs before the id it is set on is removed from an entity, so the other values of
    the entity can still be read; `deleting` is true when the entity itself is being deleted.
]=]

--[=[
    @prop Wildcard Entity
    @within mErCS
    @readonly
    Matches any relation or target in a pair: `ecs.pair(Likes, ecs.Wildcard)` in a query,
    `has` or `remove` stands for every target of `Likes`. A query (and `get`) returns the value
    of one pair of each entity: for `ecs.pair(R, ecs.Wildcard)` the pair with the lowest target
    slot, for `ecs.pair(ecs.Wildcard, T)` the pair with the lowest relation slot (nil when that
    pair holds no value). A query reads these values like a component: the wildcard keeps a
    copy of them while its pairs hold data.
]=]

--[=[
    @prop ChildOf Entity
    @within mErCS
    @readonly
    The hierarchy relation: exclusive (one parent), and deleting a parent deletes its
    children (the `(OnDeleteTarget, Delete)` policy). See [World:parent] and
    [World:children].
]=]

--[=[
    @prop Component Entity
    @within mErCS
    @readonly
    The trait of ids that hold data. [World:component] adds it. It is given before the first use
    of the id (as an id, a relation or a target): added to an id used already, or removed from
    one (remove, clear), it raises an error and nothing changes.
]=]

--[=[
    @prop OnDelete Entity
    @within mErCS
    @readonly
    Cleanup policy for deleting an id: `world:add(R, ecs.pair(ecs.OnDelete, ecs.Delete))`
    deletes the entities that have `R` when `R` is deleted. The default is
    [mErCS.Remove]: they lose it.
]=]

--[=[
    @prop OnDeleteTarget Entity
    @within mErCS
    @readonly
    Cleanup policy for deleting a target: `world:add(R, ecs.pair(ecs.OnDeleteTarget, ecs.Delete))`
    deletes the entities that have `(R, target)` when the target is deleted. The default is
    [mErCS.Remove]: they lose the pair.
]=]

--[=[
    @prop Delete Entity
    @within mErCS
    @readonly
    Cleanup action: delete the entities (see [mErCS.OnDelete], [mErCS.OnDeleteTarget]).
]=]

--[=[
    @prop Remove Entity
    @within mErCS
    @readonly
    Cleanup action: remove the id or the pair from the entities (the default).
]=]

--[=[
    @prop Name Component<string>
    @within mErCS
    @readonly
    The name of an entity: `world:set(e, ecs.Name, "Player")`. The builtins are named, for
    example `"mercs.ChildOf"`.
]=]

--[=[
    @prop Exclusive Entity
    @within mErCS
    @readonly
    Trait of a relation: an entity has at most one target of it, and adding another replaces
    the first: `world:add(Targeting, ecs.Exclusive)`. Given to a relation that an entity has
    with several targets already, it raises an error and is not added.
]=]

--[=[
    @prop Disabled Entity
    @within mErCS
    @readonly
    Tag that hides an entity from every query that does not name `Disabled` itself
    (`:with(ecs.Disabled)` lists the disabled ones). The components stay in place;
    `world:remove(e, ecs.Disabled)` shows the entity again.
]=]

--[=[
    @prop Rest Entity
    @within mErCS
    @readonly
    The last builtin id: entities start after it.
]=]

--[=[
    @class World

    A world holds entities and the components, tags and pairs on them. [mErCS.world]
    creates one.

    Every component, tag and pair keeps a bitset of the entities that have it, and the
    values of a component sit in pages indexed by the entity slot: adding or removing an id
    sets a bit and a value and never moves the entity.
]=]

--[=[
    @method entity
    @within World
    @param id Id? -- an id to make alive
    @return Entity
    A new entity. With `id`, makes that id alive and returns it: the entity of its slot, if it
    has another generation, is deleted first (and so is a new entity that the hooks of that
    delete make in the slot). An id made alive again has none of the components of its old
    life, nor their hooks; the signal listeners of the id hear it again. The next entity of the
    slot takes the generation after `id`, or after the newest generation of the slot when `id`
    is an older one: the ids of the newer generations stay dead.
]=]

--[=[
    @method pool
    @within World
    @return Pool
    A slot pool: [Pool:entity] creates entities whose slots come from blocks of 256 slots
    reserved for the pool, and a deleted entity of the pool gives its slot back to it. The
    entities of a pool stay together, so the bitsets and the value pages of what only they
    have stay dense, whatever other entities are created between them: a query over them
    reads a few words instead of a word per entity.

    ```lua
    local npcs = world:pool()
    local npc = npcs:entity() -- skills created with world:entity() do not scatter the NPCs
    ```

    Worth it for a kind of entities that is created among many others (creatures among their
    skills and effects); each pool takes at least one block of 256 slots.
]=]

--[=[
    @class Pool

    A slot pool made by [World:pool].
]=]

--[=[
    @method entity
    @within Pool
    @return Entity
    A new entity with a slot of the pool. It is an ordinary entity: every world call accepts
    it, [World:delete] gives its slot back to the pool.
]=]

--[=[
    @method component
    @within World
    @return Component<T>
    A new entity with the [mErCS.Component] trait: it can hold data. The first 256 are the
    ids 1..256, then any entity id (there is no limit).
]=]

--[=[
    @method set
    @within World
    @param entity Id
    @param id Id<T> -- a component or a pair that holds data
    @param value T
    Adds `id` with a value, or replaces the value; [mErCS.OnAdd] or [mErCS.OnChange] runs.
    Only ids with the [mErCS.Component] trait hold data: setting a value on a tag raises an
    error.
]=]

--[=[
    @method add
    @within World
    @param entity Id
    @param id Id
    Adds `id` without a value: a tag, or a component whose value stays nil. Any entity can be
    a tag: `local Frozen = world:entity()`. An `id` that is not alive is ignored (a debug world
    raises an error); a pair whose relation or target has a free slot raises an error.
]=]

--[=[
    @method get
    @within World
    @param entity Id
    @param ... Id -- up to 8 ids
    @return ...any -- the values, nil for a tag or a missing id
    The values of up to 8 ids; [World:get_list] takes any number.
]=]

--[=[
    @method get_list
    @within World
    @param entity Id
    @param ids { Id }
    @param out { any }? -- the table to fill; a new one when nil
    @return { any }
    The values of any number of ids.
]=]

--[=[
    @method has
    @within World
    @param entity Id
    @param ... Id -- up to 8 ids
    @return boolean
    Whether the entity has all of up to 8 ids; [World:has_all] takes any number.
]=]

--[=[
    @method has_all
    @within World
    @param entity Id
    @param ids { Id }
    @return boolean
    Whether the entity has all of any number of ids.
]=]

--[=[
    @method remove
    @within World
    @param entity Id
    @param id Id -- a wildcard pair removes every matching pair
    Removes `id` from the entity; [mErCS.OnRemove] runs first. A removal of the same id from the
    same entity that the hooks of this removal start again, also by a delete or a clear of the
    entity, does nothing (this removal completes it): a relation kept in sync by its hooks, each
    side removing the pair of the other, runs the hook of each side once.
]=]

--[=[
    @method toggle
    @within World
    @param entity Id
    @param id Id -- a component, a tag or a pair (not a wildcard)
    @return boolean -- true when the id was added
    Adds `id` when the entity does not have it (as [World:add]: a component gets no value) and
    removes it when it does (as [World:remove]); the hooks, signals, monitors and change
    tracking of the id run as for those calls. A dead entity is ignored (false); a debug world
    raises an error for it.
]=]

--[=[
    @method delete
    @within World
    @param entity Id
    Removes every id of the entity (their [mErCS.OnRemove] hooks run first, once per id; an id
    that the hooks give the entity meanwhile goes without its hooks), applies the cleanup
    policies of the entity used as an id or a target (also to the uses that the hooks make
    meanwhile), and frees the slot. Cascades of any depth work (past 100 nested levels the rest is queued: the
    queued entities lose the deleted id at once, its [mErCS.OnRemove] runs for them with
    `deleting = true`, and they are deleted after the cascade).
]=]

--[=[
    @method clear
    @within World
    @param entity Id
    Removes every id of the entity; the entity stays alive. The [mErCS.OnRemove] hooks run
    first, once per id (an id that the hooks give the entity meanwhile goes without its hooks);
    a removal of an id whose hook has run already does nothing (the clear removes it).
]=]

--[=[
    @method contains
    @within World
    @param entity Id
    @return boolean
    Whether the entity is alive. An old handle of a reused slot is not.
]=]

--[=[
    @method exists
    @within World
    @param entity Id
    @return boolean
    Whether the slot of the entity was ever used, also after the delete (a slot skipped by
    [World:range] or an explicit id, or reserved by a [World:pool], counts as used).
]=]

--[=[
    @method target
    @within World
    @param entity Id
    @param relation Id
    @param index number? -- from 0; the targets are ordered by entity slot
    @return Entity?
    The `index`-th target of the relation on the entity.
]=]

--[=[
    @method targets
    @within World
    @param entity Id
    @param relation Id
    @return () -> Entity? -- an iterator
    Iterates the targets of the relation on the entity.
]=]

--[=[
    @method parent
    @within World
    @param entity Id
    @return Entity?
    The target of [mErCS.ChildOf] on the entity.
]=]

--[=[
    @method children
    @within World
    @param parent Id
    @return () -> Entity? -- an iterator
    Iterates the entities that have `(ChildOf, parent)`, like [World:each].
]=]

--[=[
    @method each
    @within World
    @param id Id
    @return () -> Entity? -- an iterator
    Iterates the entities that have `id` when the loop starts, in ascending slot order,
    whatever their number. They are collected into a buffer that the world reuses: a loop
    allocates only its iterator. Nothing that changes during the loop changes what it returns:
    an entity that gets the id is not visited, one that loses it is visited, and one deleted
    before the loop reaches it is returned as a dead id (a loop that deletes other entities
    checks `world:contains`).
]=]

--[=[
    @method remove_all
    @within World
    @param id Id
    Removes `id` from every entity that has it. Without [mErCS.OnRemove] hooks it takes
    about 20 ns per entity.
]=]

--[=[
    @method query
    @within World
    @param ... Id -- the ids whose values the query returns
    @return Query
    A query over the entities that have all of the given ids (any number; more than 8 go
    through a table). See [Query]. A query must select entities through a required id, an OR
    term or a change filter: one with excluded ids alone raises an error when it is used.
]=]

--[=[
    @method added
    @within World
    @param id Id<T>
    @param listener (entity: Entity, id: Id<T>, value: T) -> ()
    @return () -> () -- disconnects the listener
    Connects a listener that runs when `id` is added to an entity. A listener may connect or
    disconnect listeners, itself included, while it runs: the change applies from the next
    event. `id` is a component, a tag or a relation (the listener runs for all its pairs); a
    pair raises an error.
]=]

--[=[
    @method changed
    @within World
    @param id Id<T>
    @param listener (entity: Entity, id: Id<T>, value: T) -> ()
    @return () -> () -- disconnects the listener
    Connects a listener that runs when the value of `id` is set again on an entity. `id` is not
    a pair (see [World:added]).
]=]

--[=[
    @method removed
    @within World
    @param id Id<T>
    @param listener (entity: Entity, id: Id<T>, deleting: boolean?) -> ()
    @return () -> () -- disconnects the listener
    Connects a listener that runs before `id` is removed from an entity; `deleting` is true
    when the entity itself is being deleted. `id` is not a pair (see [World:added]).
]=]

--[=[
    @method track
    @within World
    @param id Id
    Starts recording additions, value changes and removals of `id` per tick, for the change
    filters [Query:added], [Query:changed] and [Query:removed]. Untracked ids cost nothing; a
    tracked id costs a call per add, change or remove. `id` is not a pair (see [World:added]).
]=]

--[=[
    @method track_created
    @within World
    Starts recording the entities made from now on ([World:entity], a [Pool], [World:entity]
    with an id that makes a new id alive) per tick, for the change filter [Query:created]. A
    world that does not track creations pays a test per new entity; one that does pays a bit
    per new entity, and a deleted entity is gone from the filter.
]=]

--[=[
    @method tick
    @within World
    @return number -- the new tick
    Advances the tick: the changes recorded so far become visible to change filters. Call it
    once per frame, between frames: outside hooks, listeners and loops. It also drops what an
    error raised by a hook or a listener left in the world (a removal, a clear or a cascade that
    did not finish) and deletes the entities that such a cascade had queued, so the frames
    after the error work again; a debug world reports it.
]=]

--[=[
    @method range
    @within World
    @param first number
    @param last number?
    The new entity ids of this world come after `first` (the first one is `first + 1`, as in
    jecs) and stay below `last` (networked worlds), also the ids of the pools made before.
    [World:entity] with an id makes any id alive, also outside the range (an id of another
    world); once deleted, its slot is not given to a new entity of this world.
]=]

--[=[
    @method column
    @within World
    @param id Id
    @return { { any } } -- the value pages
    The value pages of a component, for the fast path of [Query:spans]: the value of a slot
    is `column[slot // PAGE_SIZE + 1][slot % PAGE_SIZE + 1]`.
]=]

--[=[
    @method alive_table
    @within World
    @return { number }
    The entity of every slot, for the fast path: `alive_table()[slot]`. A free slot holds a
    negative number.
]=]

--[=[
    @method ids
    @within World
    @param entity Id
    @return { Id }
    Every id of the entity (components, tags, pairs), sorted ascending.
]=]

--[=[
    @class Query

    A query made by [World:query]: the entities that have all of its ids, with their values.

    ```lua
    for entity, position, velocity in world:query(Position, Velocity):without(Frozen) do
    end
    world:query(Position, Velocity):each(function(entity, position, velocity) end)
    ```

    - A query never goes stale: its ids may be created and deleted at any time.
    - A query written inline in a system is cheap: queries of the same shape share one
      state from the second request of the shape, so an inline query allocates only a small
      handle, and an iteration of a stored query allocates nothing. The first request of a
      shape gets a light state of its own; kept and used again (a second loop, a modifier,
      [Query:cached]), it becomes the shared state. A world shares up to 1024 shapes; the shapes
      of an entity used as a term are dropped when the entity is deleted.
    - A cached query with scattered matches keeps a list of them; after changes that cost less
      to re-check than a pass over the bitsets (a quarter of the list, or half of the words of
      its smallest term) it updates only the changed slots of the list, after more it passes
      over the bitsets once, and a query that matches nothing costs a check of its ids per loop
      (a comparison when no id of any cached query changed in the world since its previous
      loop).
    - The current entity may be changed or deleted inside the loop. Changes of other
      entities may or may not be seen by the running loop; an entity deleted ahead of the
      loop may still be returned once (check [World:contains]).
    - Loops over the same query may be nested. The order is ascending by entity slot.
]=]

--[=[
    @method with
    @within Query
    @param ... Id
    @return Query
    Required ids whose values are not returned. Each call replaces the earlier ids of `with`.
]=]

--[=[
    @method without
    @within Query
    @param ... Id
    @return Query
    Excluded ids. Each call replaces the earlier ids of `without`.
]=]

--[=[
    @method any
    @within Query
    @param ... Id
    @return Query
    An OR term: the entity has at least one of the ids. Several calls add several terms.
]=]

--[=[
    @method cached
    @within Query
    @return Query
    Keeps what the query observed and its iteration state between loops. Shared queries
    (without change filters) are cached already, and the first request of a shape becomes its
    shared state here; call it on a query with change filters that is stored and iterated many
    times. A query that has not been iterated yet is prepared now (it picks how it iterates and
    builds its match list), so that its first loop costs no more than the next ones.
]=]

--[=[
    @method added
    @within Query
    @param id Id -- a tracked id (see [World:track])
    @return Query
    Change filter: the entities that got `id` added since the previous iteration of this
    query. Each query keeps the first tick it has not seen, up to the last 7 finished ticks
    (a ring of 8 ticks, the current one included).
]=]

--[=[
    @method changed
    @within Query
    @param id Id -- a tracked id (see [World:track])
    @return Query
    Change filter: the entities whose value of `id` was set again since the previous
    iteration of this query.
]=]

--[=[
    @method removed
    @within Query
    @param id Id -- a tracked id (see [World:track])
    @return Query
    Change filter: the entities that lost `id` since the previous iteration of this query
    and are still alive.
]=]

--[=[
    @method created
    @within Query
    @return Query
    Change filter: the entities made since the previous iteration of this query and still
    alive (see [World:track_created], which it needs). `world:query(Position):created()`
    returns the new entities that have `Position` now; `world:query():created()` all of them.
]=]

--[=[
    @method each
    @within Query
    @param callback (entity: Entity, ...any) -> ()
    Calls `callback(entity, ...values)` for every match: the fastest loop.
]=]

--[=[
    @method has
    @within Query
    @param entity Id
    @return boolean
    Whether the entity matches the query.
]=]

--[=[
    @method spans
    @within Query
    @return () -> (number?, number?, number) -- an iterator of first, last, mask
    The fast path: runs of matching slots. When `mask == 0xFFFFFFFF` every slot of
    `first..last` matches; otherwise `first..last` is one 32-slot word and the set bits of
    `mask` are the matching slots (`first + bit index`). Read the values with
    [World:column] and the entities with [World:alive_table].
]=]

--[=[
    @method count
    @within Query
    @return number
    The number of matches. It does not consume change filters.
]=]

--[=[
    @method add_all
    @within Query
    @param id Id
    Adds `id` to every entity that matches now. A component or tag without hooks is added 32
    entities at a time; pairs and ids with hooks go entity by entity, and every hook runs. A
    hook that deletes `id` (or the relation or the target of the pair) ends the operation: the
    rest of the matches do not get it.
]=]

--[=[
    @method set_all
    @within Query
    @param id Id<V>
    @param value V -- the same value for every match
    Sets `id` to `value` on every entity that matches now (as [Query:add_all], also when a hook
    deletes `id`).
]=]

--[=[
    @method remove_all
    @within Query
    @param id Id
    Removes `id` from every entity that matches now.
]=]

--[=[
    @method delete_all
    @within Query
    Deletes every entity that matches now.
]=]

--[=[
    @method toggle_all
    @within Query
    @param id Id -- a component, a tag or a pair (not a wildcard)
    Removes `id` from every entity that matches now and has it, and adds it to every one that
    does not. A component or tag without hooks is toggled 32 entities at a time; pairs and ids
    with hooks go entity by entity, and every hook runs. A hook that deletes `id` (or the
    relation or the target of the pair) ends the operation.
]=]

--[=[
    @method monitor
    @within Query
    @return Monitor
    Calls back when an entity starts or stops matching the query, at the change that makes it
    happen: an id of the query added or removed, an excluded id removed or added, `Disabled`,
    `clear`, `delete`, cascades and batch operations. One `added` per entry and one `removed`
    per exit; the entities that match when the monitor is created are members already.

    ```lua
    local monitor = world:query(Model):with(Visible):monitor()
    monitor.added(function(entity) end)
    monitor.removed(function(entity) end) -- before the ids are removed: values can be read
    monitor.disconnect()
    ```

    - `removed` runs before the removal, so the values of the entity can still be read; for a
      `delete` or `clear`, before any id goes.
    - `added` runs after an id is added; when the entity starts matching because an excluded id
      (or `Disabled`) is removed, it runs before that removal completes.
    - An exclusive relation (`ChildOf`) that replaces a pair does not make an entity leave and
      enter a query that has the relation with any target (`ecs.pair(ChildOf, ecs.Wildcard)`).
    - A monitor listens to the signals of the ids of the query (see [World:added]): changes of
      these ids and deletes of entities that have them run a check, and batch operations on
      them go entity by entity.
    - The terms may be components, tags, pairs and `ecs.pair(R, ecs.Wildcard)`; a term
      `ecs.pair(ecs.Wildcard, T)` and change filters raise an error.
    - The monitor keeps the terms of the query as they are when it is made: `with`, `without`
      or `any` called on the query afterwards do not change it (the jecs addon copies the query
      too).
    - A pair keeps the slots of its elements: when the relation of a pair term is deleted and
      another entity takes its slot, the query matches the pairs of that entity, but the
      monitor still listens to the deleted one. Make a new monitor after deleting a relation
      of its terms.
    - A monitor made inside an `OnRemove` hook or a `removed` callback takes the entity being
      changed as it is before the removal (a member that has left already).
    - An entity that a callback deletes while one of its terms is being removed leaves at the
      latest when its slot is freed (its `removed` then gets the dead id), before a new entity
      can take the slot.
    - The callbacks may change the world; an error in one stops the change that ran it, like
      an error in a hook.
]=]

--[=[
    @class Monitor

    The callbacks of a query monitor, made by [Query:monitor]. Its functions are called with
    a dot: `monitor.added(fn)`.
]=]

--[=[
    @function added
    @within Monitor
    @param callback ((entity: Entity) -> ())? -- nil clears it
    Sets the callback for the entities that start matching the query.
]=]

--[=[
    @function removed
    @within Monitor
    @param callback ((entity: Entity) -> ())? -- nil clears it
    Sets the callback for the entities that stop matching the query. It runs before the ids
    are removed: the values of the entity can still be read.
]=]

--[=[
    @function disconnect
    @within Monitor
    Stops the monitor: no callback runs after it, and it stops listening to the signals of the
    ids. Calling it again does nothing.
]=]

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local ENTITY_MASK = 16777216 -- 2^24 slots
local SLOT_BITS = ENTITY_MASK - 1 -- bit32.band(entity, SLOT_BITS) is the slot
local GENERATION_MASK = 65536 -- 2^16 generations
local PAIR_OFFSET = 281474976710656 -- 2^48
local FULL_WORD = 4294967295 -- 2^32 - 1
local PAGE_SIZE = 256 -- values of a component are stored in pages of this many slots
local SIG_FLAT = 8 -- record indices 1..8*32 use shared signature tables

-- Builtin ids follow the range of world:component() ids (1..256); Rest is the last of them,
-- entities start after it.
local HI_COMPONENT_ID = 256
local EcsOnAdd = HI_COMPONENT_ID + 1
local EcsOnRemove = HI_COMPONENT_ID + 2
local EcsOnChange = HI_COMPONENT_ID + 3
local EcsWildcard = HI_COMPONENT_ID + 4
local EcsChildOf = HI_COMPONENT_ID + 5
local EcsComponent = HI_COMPONENT_ID + 6
local EcsOnDelete = HI_COMPONENT_ID + 7
local EcsOnDeleteTarget = HI_COMPONENT_ID + 8
local EcsDelete = HI_COMPONENT_ID + 9
local EcsRemove = HI_COMPONENT_ID + 10
local EcsName = HI_COMPONENT_ID + 11
local EcsExclusive = HI_COMPONENT_ID + 12
-- entities with Disabled are skipped by queries that do not name it
local EcsDisabled = HI_COMPONENT_ID + 13
local EcsRest = HI_COMPONENT_ID + 14

local band = bit32.band
local bor = bit32.bor
local rshift = bit32.rshift
local lshift = bit32.lshift
local countrz = bit32.countrz

local EMPTY: Page = {}
local EMPTY_PAGES: Pages = {}
local NO_STATE: any = table.freeze({})
local EMPTY_WORDS: { Words } = {}
local EMPTY_WORDS_TABLE: Words = {}
local WORDS_PER_PAGE = PAGE_SIZE // 32
local TRACK_TICKS = 8 -- ticks of change history kept per tracked id
local LIST_MAX = 65536 -- a query keeps a match list of at most this many entities (2 MB)
-- the scratch of the spans of a list build (see choose_mode) is kept between builds while it
-- holds at most this many spans; a larger one is dropped after use
local SPANS_KEPT = 256
local TOP_SLOTS = 32768 -- slots per word of the third bitset level (tops)
-- change journals (see note): entries of a new journal and the most a journal grows to (the
-- changes of a record that a query re-checks between two loops, CHANGE_LIMIT at most)
local JOURNAL_MIN = 4
local JOURNAL_MAX = 1024
-- a cached query re-checks at most this many noted slots between two loops: as many as cost
-- less than a pass over the bitsets (a quarter of its match list, or half of the words of its
-- smallest required term), but always up to CHANGE_MIN (more: a pass over the bitsets, see
-- iteration_mode)
local CHANGE_LIMIT = 1024
local CHANGE_MIN = 32
-- slots are reserved for a pool (see world:pool) in aligned blocks of this many
local POOL_BLOCK = PAGE_SIZE
-- what a change of an id of a monitored query can do to a match (see Query.monitor)
local EXIT_ON_REMOVE = 1
local EXIT_ON_ADD = 2
local ENTER_ON_ADD = 3
local OTHER_TERM = 4
-- pair records left without members are freed in batches, once there are more than this many
-- of them and they are more than a quarter of all pair records (see free_empty_pairs)
local EMPTY_PAIRS = 256
-- a cascade of deletes nested deeper than this queues the rest (see cleanup_record)
local MAX_DELETE_DEPTH = 100
-- the arrays of removed groups of match lists kept for new groups (see patch_list)
local SPARE_ITEMS = 64
-- a query that is not cached whose smallest term has at most this many words gathers its
-- matches into a buffer before its loop (see scan.fill)
local BUFFER_WORDS = 64
-- query states shared by shape per world (see query_state), and shapes requested once (marked)
local MAX_SHAPES = 1024
local MAX_MARKS = 16 * MAX_SHAPES
-- the kinds of changes a tracked id records (see world:track)
local TRACK_KINDS = { "added", "changed", "removed" }
-- the key of the creation marks among the tracked ids (no id is 0): world:track_created
local CREATED = 0

local TOO_MANY_IDS = "at most 8 ids can be passed; use get_list/has_all for more"
-- reported once by a debug world whose shared query states ran out (see share_shape)
local SHAPES_EXHAUSTED = `mErCS: {MAX_SHAPES} query shapes are shared, the most a world keeps; a query of a new `
    .. "shape builds a new state on every world:query call. Entity ids and pairs with an entity target used "
    .. "as query terms make a shape per entity: see the Queries section of the guide."

-- what a debug world reports when world:tick finds what an error raised by a callback left
local RECOVERED = "mErCS: world:tick dropped what an error raised by a hook or a listener left (a removal, "
    .. "a clear or a cascade that did not finish): the changes of the frame of the error may be incomplete"

local function NOOP(): any
    return nil
end

-- The buffers of world:each and world:children (see iterate_record in world_new): a loop
-- collects the members of the id into a buffer taken from here and gives it back when it ends
-- (a loop left with break leaves its buffer to the collector). A buffer holds entity ids only.
-- At most EACH_POOL_MAX buffers and EACH_POOL_SLOTS array slots are kept. Index 0 of a buffer
-- holds its capacity charge (the next power of two of its largest snapshot), including when
-- a smaller loop reuses it. This bounds retained arrays without reallocating dense hot loops.
-- each_words holds the sorted keys of a record with at most EACH_FEW_WORDS keys.
local each_pool: { { number } } = {}
local each_pool_n = 0
local EACH_POOL_MAX = 16
local each_pool_slots = 0
local EACH_POOL_SLOTS = 262144 -- at most 4 MiB of array values (plus table headers)
local each_words: { number } = {}
local EACH_FEW_WORDS = 64

local function each_take(): { number }
    if each_pool_n == 0 then
        return {}
    end
    local list = each_pool[each_pool_n]
    each_pool[each_pool_n] = nil
    each_pool_n -= 1
    each_pool_slots -= list[0]
    return list
end

local function each_release(list: { number })
    local size = list[0]
    if each_pool_n < EACH_POOL_MAX and each_pool_slots + size <= EACH_POOL_SLOTS then
        each_pool_n += 1
        each_pool[each_pool_n] = list
        each_pool_slots += size
    end
end

--------------------------------------------------------------------------------
-- Id helpers
--------------------------------------------------------------------------------

-- Id of the relationship pair (first, second). Generations are dropped.
local function ECS_PAIR(first: i53, second: i53): i53
    first %= ENTITY_MASK
    second %= ENTITY_MASK
    return second + first * ENTITY_MASK + PAIR_OFFSET
end

local function ECS_IS_PAIR(id: i53): boolean
    return id > PAIR_OFFSET
end

-- Slot of the first element of a pair.
local function ECS_PAIR_FIRST(id: i53): i53
    return (id - PAIR_OFFSET) // ENTITY_MASK
end

-- Slot of the second element of a pair.
local function ECS_PAIR_SECOND(id: i53): i53
    return (id - PAIR_OFFSET) % ENTITY_MASK
end

local function ECS_ID(entity: i53): i53
    return entity % ENTITY_MASK
end

local function ECS_GENERATION(entity: i53): number
    return entity // ENTITY_MASK
end

local function ECS_GENERATION_INC(entity: i53): i53
    local generation = entity // ENTITY_MASK + 1
    if generation >= GENERATION_MASK then
        generation = 0
    end
    return entity % ENTITY_MASK + generation * ENTITY_MASK
end

local function is_wildcard(id: i53): boolean
    return id > PAIR_OFFSET and (ECS_PAIR_FIRST(id) == EcsWildcard or ECS_PAIR_SECOND(id) == EcsWildcard)
end

--------------------------------------------------------------------------------
-- Pre-registration (ids that exist in every world created afterwards)
--------------------------------------------------------------------------------

local preregistered_components = 0
local preregistered_tags = EcsRest
local preregistered_meta: { [i53]: { [i53]: any } } = {}
local NULL = newproxy(false)

-- record kinds
local KIND_PLAIN = 0
local KIND_PAIR = 1
local KIND_RELATION = 2
local KIND_TARGET = 3

-- Reserves a component id (1..256) in every world.
local function ECS_COMPONENT(): i53
    preregistered_components += 1
    if preregistered_components > HI_COMPONENT_ID then
        error("too many pre-registered components")
    end
    return preregistered_components
end

-- Reserves a tag id in every world.
local function ECS_TAG(): i53
    preregistered_tags += 1
    return preregistered_tags
end

-- Adds (value == nil) or sets a trait on a pre-registered id in every world.
local function ECS_META(id: i53, trait: i53, value: any?)
    local bundle = preregistered_meta[id]
    if bundle == nil then
        bundle = {}
        preregistered_meta[id] = bundle
    end
    bundle[trait] = if value == nil then NULL else value
end

--------------------------------------------------------------------------------
-- Helpers without world state (kept out of world_new: a Luau function has at most 200
-- local registers, and the locals of world_new are close to that)
--------------------------------------------------------------------------------

-- the hook component of each hook field of a record
local HOOK_IDS: { [string]: i53 } = { on_add = EcsOnAdd, on_change = EcsOnChange, on_remove = EcsOnRemove }

-- Number of set bits of a word.
local function popcount(x: number): number
    x -= band(rshift(x, 1), 0x55555555)
    x = band(x, 0x33333333) + band(rshift(x, 2), 0x33333333)
    x = band(x + rshift(x, 4), 0x0F0F0F0F)
    return rshift(x * 0x01010101, 24)
end

-- A record-like bitset without values, signature bit or journal (change filters and the
-- merged words of OR terms).
local function new_bitset(): Record
    return {
        words = {},
        sums = {},
        word_count = 0,
        zeros = 0,
        version = 0,
        journal_mask = 0,
        journal = false,
        kind = KIND_PLAIN,
        index = 0,
    } :: any
end

-- The checks of a debug world (see the end of world_new): they take the alive table of the
-- world, so that they take no registers of world_new, which has used all 200 of them. `level`
-- is the level of the error, as for error(): 3 when a wrapper of a world method calls them.
local function debug_check_entity(alive: { number }, entity: i53, level: number)
    if type(entity) ~= "number" or alive[entity % ENTITY_MASK] ~= entity then
        error(`entity {entity} is not alive: an outdated handle or a deleted entity`, level)
    end
end

local function debug_check_id(alive: { number }, id: i53, level: number, allow_wildcard: boolean)
    if type(id) ~= "number" then
        error(`id {id} is not a number`, level)
    end
    if id > PAIR_OFFSET then
        if is_wildcard(id) then
            if not allow_wildcard then
                error("wildcard pairs can only be used in queries and remove", level)
            end
            return
        end
        local first, second = alive[ECS_PAIR_FIRST(id)], alive[ECS_PAIR_SECOND(id)]
        if first == nil or first <= 0 or second == nil or second <= 0 then
            error("an element of the pair is not alive", level)
        end
    elseif alive[id % ENTITY_MASK] ~= id then
        error(
            `id {id} is not alive: an outdated handle, a deleted id, or ecs.component() called after ecs.world()`,
            level
        )
    end
end

-- A query must select entities: a required id, an OR term or a change filter. Excluded ids
-- alone would match nothing, so a query used without such a term (iterated, counted, checked
-- with has, made a monitor, given to a batch operation) raises NO_TERMS from the query method,
-- at level 2 (the code that called it; the compiler may inline `selects`, so the method raises
-- the error itself). A query object without terms that is not used (jabby takes the metatable
-- of one) is not an error.
local NO_TERMS = "a query needs a required id, an OR term or a change filter: excluded ids alone match nothing"
local function selects(query: any): boolean
    return query.filter_with[1] ~= nil or query.any_groups ~= nil or query.tracking ~= nil
end

-- Keeps the free slots of a free list (list[1..count]) that are inside the range of
-- world:range (bounds[1], bounds[2]), in their order, and returns how many are kept.
local function keep_in_range(list: { number }, count: number, bounds: { number }): number
    local kept = 0
    for i = 1, count do
        local e = list[i]
        local slot = e % ENTITY_MASK
        if slot > bounds[1] and slot < bounds[2] then
            kept += 1
            list[kept] = e
        end
    end
    for i = kept + 1, count do
        list[i] = nil
    end
    return kept
end

-- The query states that a world shares by shape (see query_state in world_new). The shape of
-- a state is a path of ids in a tree of nodes, root[id1][id2]...query: the roots are roots[n]
-- for world:query with n ids, and variants[kind] of a shared state for its variants (with,
-- without, any). node.query is false for a shape requested once (a mark, see share_shape).
-- count is the number of shared states (at most MAX_SHAPES) and marks the number of marks (at
-- most MAX_MARKS); keys[slot] holds the nodes that have a child keyed by the entity of the slot
-- or by a pair with that entity as its target (see key_slot), each node with the key of that
-- child, or with an array of the keys when it has several (see prune_shapes); warned: a debug
-- world has reported that the shared states ran out.
type Shapes = {
    roots: { [number]: any },
    count: number,
    marks: number,
    keys: { [number]: { [any]: i53 | { i53 } } },
    warned: boolean,
}

-- The slot of the entity whose deletion drops the shapes under a key of the tree of shapes:
-- the slot of an entity id, the target of a pair, 0 for (R, *) (kept: a relation is rarely
-- deleted, and a relation that reuses its slot has the same pairs).
local function key_slot(key: i53): number
    if key < PAIR_OFFSET then
        return key % ENTITY_MASK
    end
    local target = ECS_PAIR_SECOND(key)
    return if target == EcsWildcard then 0 else target
end

-- Notes that `node` has a child keyed by `key`, to be dropped with the entity of `slot`.
local function key_add(shapes: Shapes, slot: number, node: any, key: i53)
    local parents = shapes.keys[slot]
    if parents == nil then
        parents = {}
        shapes.keys[slot] = parents
    end
    local current = parents[node]
    if current == nil then
        parents[node] = key
    elseif type(current) == "table" then
        table.insert(current, key)
    elseif current ~= key then
        parents[node] = { current, key }
    end
end

-- The child keyed by `key` has left `node` (see key_add).
local function key_remove(shapes: Shapes, slot: number, node: any, key: i53)
    local parents = shapes.keys[slot]
    if parents == nil then
        return
    end
    local current = parents[node]
    if type(current) == "table" then
        local at = table.find(current, key)
        if at then
            table.remove(current, at)
        end
        if current[1] ~= nil then
            return
        end
    elseif current ~= key then
        return
    end
    parents[node] = nil
    if next(parents) == nil then
        shapes.keys[slot] = nil
    end
end

local drop_shapes: (shapes: Shapes, node: any) -> ()

-- A shared state leaves the tree with its variants and stops counting. A handle that keeps
-- it keeps a working query, whose modifiers return queries of their own (variants == false,
-- see shared_variant). A state reached twice counts once.
local function drop_state(shapes: Shapes, state: QueryState)
    local variants = state.variants
    if variants == false then
        return
    end
    state.variants = false
    shapes.count -= 1
    if variants then
        for _, root in variants do
            drop_shapes(shapes, root)
        end
    end
end

-- The states and marks of a subtree that is cut off the tree leave it, and its nodes leave keys.
function drop_shapes(shapes: Shapes, node: any)
    for key, child in node do
        if key == "query" then
            if child then
                drop_state(shapes, child)
            else
                shapes.marks -= 1
                node.query = nil -- a first state of the shape can no longer take its place
            end
            continue
        end
        local slot = key_slot(key)
        if slot ~= 0 then
            key_remove(shapes, slot, node, key)
        end
        drop_shapes(shapes, child)
    end
end

-- Cuts the child keyed by `key` off `parent`.
local function drop_child(shapes: Shapes, parent: any, key: i53)
    local child = parent[key]
    if child ~= nil then
        parent[key] = nil
        drop_shapes(shapes, child)
    end
end

-- An entity id is generational: once the entity is deleted, a shape that has its id can never
-- match again (world:entity(id) that makes the id alive again gets new shapes). A pair drops
-- the generations of its ids: a shape with a pair would match the pairs of the entity that
-- reuses the slot of the target, and keeps nothing worth keeping until then. world_delete cuts
-- the branches keyed by the entity of the slot and by the pairs with it as their target off
-- the tree, so that they keep no memory and take no room among the MAX_SHAPES shared states.
-- Every key under keys[slot] belongs to the entity that is deleted: the keys of an entity that
-- had the slot before went with it.
local function prune_shapes(shapes: Shapes, slot: number)
    local parents = shapes.keys[slot]
    if parents == nil then
        return
    end
    shapes.keys[slot] = nil
    for parent, keys in parents do
        if type(keys) == "table" then
            for _, key in keys do
                drop_child(shapes, parent, key)
            end
        else
            drop_child(shapes, parent, keys)
        end
    end
end

-- The callback of a record whose id has an internal hook (see internal_hooks in world_new):
-- the internal hook, then `hook` (the hook of the id or the dispatcher of its signals).
local function chain_hooks(internal: Hook?, hook: Hook?): Hook?
    if internal == nil or hook == nil then
        return internal or hook
    end
    local first, second = internal :: Hook, hook :: Hook
    return function(entity: i53, id: i53, value: any?)
        first(entity, id, value)
        second(entity, id, value)
    end
end

-- Signals and change tracking take a component, a tag or a relation (which covers all its
-- pairs), not a pair: the records of a pair come and go, and take their hooks from the
-- relation. `level` is the error level of the caller of the world method.
local function check_signal_id(id: i53, level: number)
    if id > PAIR_OFFSET then
        error(
            "signals and change tracking take a component, a tag or a relation (for all its pairs), not a pair",
            level + 1
        )
    end
end

--------------------------------------------------------------------------------
-- World
--------------------------------------------------------------------------------

local function world_new(debug: boolean?): World
    -- entity index
    local alive: { number } = table.create(1024) :: { number }
    local free: { number } = {}
    local free_count = 0
    local max_slot = 0
    -- world:range: the new ids of this world come after range[1] and stay below range[2]
    -- (math.huge without a last one); nil without a range. One table, not two locals: world_new
    -- has used all its registers.
    local range: { number }? = nil
    -- The floors of the generations of slots (see world:entity): an older generation of a slot
    -- made alive again over newer ones keeps here the generation after the newest one, which
    -- the next entity of the slot takes when it is deleted, so that the ids of the newer ones
    -- stay dead. Such an entity is marked in id_used: only the delete of a used entity reads
    -- this table.
    local floors: { [number]: number } = {}
    -- slot pools (see world:pool): the pool of each reserved block (slot // POOL_BLOCK), and
    -- per pool the free entity ids of its blocks (a stack, like free)
    type PoolState = { free: { number }, count: number }
    local block_pool: { [number]: PoolState } = {}
    local has_pools = false

    -- records
    local records: { [i53]: Record } = {}
    local pwords: { [i53]: Words } = {}
    local columns: { [i53]: Pages } = {}
    local by_index: { Record } = {}
    local max_index = 0
    local free_indices: { number } = {}

    -- entity signatures
    local sig_flat: { Words } = table.create(SIG_FLAT) :: { Words }
    for k = 1, SIG_FLAT do
        sig_flat[k] = {}
    end
    local sig_flat_used = 0
    local sig_more: { [number]: Words } = {}
    -- hooked[k]: signature bits of word k whose records have on_remove hooks (for a relation
    -- record (R, *): the pairs of R have them); hooked_delete[k]: the same for the hooks that
    -- have something to do when the entity is deleted (not only change tracking)
    local hooked: Words = table.create(SIG_FLAT, 0) :: Words
    local hooked_delete: Words = table.create(SIG_FLAT, 0) :: Words
    -- The words of the shared signature tables that have hooked bits (hooked[k] ~= 0), in
    -- ascending order (hooked_delete has bits in these words only): a clear looks for hooked
    -- ids in these words of the signature only.
    local hooked_list: { number } = {}

    -- The entities whose on_remove hooks run (see run_remove_hooks), innermost last:
    -- clearing[1..clear_depth], each with the records of its hooks in clear_buffers[depth].
    -- Entities, not slots: an entity that reuses the slot inside a hook runs its own hooks. The
    -- stack is short (a hook that deletes another entity adds a level), and it is empty
    -- outside a clear or a delete, so a search of it costs next to nothing. A buffer keeps its
    -- records until the clear ends; its field `at` is the place of the hook that runs (the
    -- records up to it are notified, or false: see removal_runs).
    local clear_buffers: { { Record } } = {}
    local clear_depth = 0
    local clearing: { i53 } = {}
    -- The removals whose on_remove hooks run, innermost last: the entity at 2k - 1, the id at
    -- 2k. A removal of the same id from the same entity that one of these hooks starts again
    -- does nothing (world_remove): the running removal completes it, so the hooks of a relation
    -- kept in sync by hooks (each side removes the pair of the other) run once per side. Empty
    -- outside the hooks of a removal (an error in a hook leaves it as it is, until world:tick).
    -- Made with an array part: every clear tests removing[1], and a table without one answers
    -- from its hash part, a slower path.
    local removing: { i53 } = table.create(2) :: { i53 }

    -- Whether the removal of the id of a record from the entity runs: its hooks run (see
    -- removing), or a clear of the entity has notified the id (the records of the clear up to
    -- its place, see clear_buffers). Such a removal is not started again.
    local function removal_runs(entity: i53, rec: Record): boolean
        local id = rec.id
        for k = 1, #removing, 2 do
            if removing[k] == entity and removing[k + 1] == id then
                return true
            end
        end
        for d = 1, clear_depth do
            if clearing[d] == entity then
                local buffer = clear_buffers[d]
                for i = 1, (buffer :: any).at do
                    if buffer[i] == rec then
                        return true
                    end
                end
            end
        end
        return false
    end
    -- Creation tracking (see world:track_created): marks the slot of a new entity in the
    -- created bitset of the current tick; nil until the world tracks creations, so that a
    -- world that does not costs a test per new entity.
    local mark_created: ((slot: number) -> ())? = nil
    -- the first ChildOf pair of every slot (slot_pair of the (ChildOf, *) record), for parent()
    local childof_pairs: { [number]: Record }? = nil

    -- id_used[slot]: the entity of the slot is (or was) a component, tag, relation or target,
    -- or a term of a shared query shape, or it has a floor of its generation (world_delete
    -- cleans up after such an entity; false while it does)
    local id_used: { [number]: boolean } = {}
    -- the query states shared by shape (see query_state)
    local shapes: Shapes = { roots = {}, count = 0, marks = 0, keys = {}, warned = false }

    local world = {} :: any
    -- the presence words of the Component trait (set when its record is created)
    local component_words: Words = EMPTY_WORDS_TABLE

    ----------------------------------------------------------------------------
    -- entity index
    ----------------------------------------------------------------------------

    -- The free list holds only slots inside the range of the world (world_delete, world_entity
    -- and world_range keep the others out of it), so a new id never leaves the range.
    local function new_slot(): i53
        if free_count > 0 then
            local e = free[free_count]
            free[free_count] = nil
            free_count -= 1
            alive[e % ENTITY_MASK] = e
            return e
        end
        local slot = max_slot + 1
        local bounds = range
        if bounds and slot >= bounds[2] then
            error("entity id is outside the range set by world:range")
        end
        max_slot = slot
        alive[slot] = slot
        return slot
    end

    ----------------------------------------------------------------------------
    -- presence bitsets
    ----------------------------------------------------------------------------

    -- The helpers below are split into a short common path and a separate rare path, so that
    -- the compiler inlines the common path at their call sites (functions above its inlining
    -- cost threshold are called, which costs more than the work itself).
    --
    -- A record has three levels of presence bits: words (32 slots each), sums (a bit per
    -- non-empty word, 1024 slots each) and tops (a bit per non-empty summary word, 32768 slots
    -- each), kept in the sums table at negative indices (one table less per record). Only
    -- word_first and word_last change sums and tops; world_remove_all and world_tick clear all
    -- three levels at once. Loops over the pairs of a sums table skip the negative indices. An
    -- emptied word, summary word or top word stays in its table as 0: removing a key and adding
    -- another one later makes a Luau table rehash all its keys every few changes, which a tag
    -- toggled on scattered entities would do all the time. A word of 0 is empty wherever a word
    -- is read.
    --
    -- Every change of the presence or of the value pages of a record increments its version:
    -- cached queries compare versions to see whether their records changed. note() increments
    -- it for a change of one slot and, when the record has a change journal, writes the
    -- (version, slot) entry that lets a cached query re-check only that slot (see
    -- iteration_mode and patch_list). A version increment without a journal entry (a change of
    -- many slots) makes the queries that observe the record scan it again, so noting is only an
    -- optimization. A version increment of a record with a journal also changes changes_stamp
    -- (journal_write does it for the noted changes).

    local function bit_test(rec: Record, slot: number): boolean
        local word = rec.words[slot // 32 + 1]
        return word ~= nil and band(word, lshift(1, slot % 32)) ~= 0
    end

    -- Rarer paths: summary word sw was empty and gets `sbit`, or lost its last bit (the top
    -- word tw is at sums[-tw]).
    local function sum_first(rec: Record, sw: number, sbit: number)
        local sums = rec.sums
        sums[sw] = sbit
        local key = -((sw - 1) // 32 + 1)
        local tbit = lshift(1, (sw - 1) % 32)
        local top = sums[key]
        sums[key] = if top then top + tbit else tbit
    end

    local function sum_last(rec: Record, sw: number)
        local sums = rec.sums
        local key = -((sw - 1) // 32 + 1)
        sums[key] -= lshift(1, (sw - 1) % 32)
    end

    -- Rare path: word w was empty and gets `bits`. The caller increments the version.
    -- world_set and world_add inline it.
    local function word_first(rec: Record, w: number, bits: number)
        rec.words[w] = bits
        rec.word_count += 1
        local sums = rec.sums
        local sw = (w - 1) // 32 + 1
        local sbit = lshift(1, (w - 1) % 32)
        local sum = sums[sw]
        if sum ~= nil and sum ~= 0 then
            sums[sw] = sum + sbit
        else
            sum_first(rec, sw, sbit)
        end
    end

    -- Drops the keys of the emptied words of a record (see word_last).
    local function drop_zeros(rec: Record)
        local words = rec.words
        for w, word in words do
            if word == 0 then
                words[w] = nil
            end
        end
        local sums = rec.sums -- the summary words and the top words
        for sw, sum in sums do
            if sum == 0 then
                sums[sw] = nil
            end
        end
        rec.zeros = 0
    end

    -- Rare path: word w lost its last bit. The caller increments the version. The word stays
    -- as 0 until the emptied words outnumber the non-empty ones twice (and 1024). world_remove
    -- inlines it.
    local function word_last(rec: Record, w: number)
        rec.words[w] = 0
        local count = rec.word_count - 1
        rec.word_count = count
        local sums = rec.sums
        local sw = (w - 1) // 32 + 1
        local sum = sums[sw] - lshift(1, (w - 1) % 32)
        sums[sw] = sum
        if sum == 0 then
            sum_last(rec, sw)
        end
        local zeros = rec.zeros + 1
        rec.zeros = zeros
        if zeros > 2 * count + 1024 then
            drop_zeros(rec)
        end
    end

    -- Changes whenever a record with a change journal changes (every record that a cached query
    -- observes has one) and when a record is created or freed: a cached query in list mode that
    -- saw the same stamp at its previous loop uses its list without checking its records (see
    -- list_stamp). Every version change of a record with a journal changes it: journal_write
    -- for the noted changes, the version increments without a journal entry next to them.
    local changes_stamp = 0

    -- Increments the version of a record for a change of one slot and notes the slot in the
    -- change journal of the record, if it has one. Each entry keeps its version: an entry
    -- overwritten by a later one (the journal is a ring) no longer matches, so a query can
    -- never take a missing change for a noted one.
    local function journal_write(rec: Record, version: number, slot: number)
        local journal = rec.journal :: { number }
        local at = band(version, rec.journal_mask) * 2 + 1
        journal[at] = version
        journal[at + 1] = slot
        changes_stamp += 1
    end

    local function note(rec: Record, slot: number)
        local version = rec.version + 1
        rec.version = version
        if rec.journal then
            journal_write(rec, version, slot)
        end
    end

    -- Sets the bit of a slot that is known to be clear.
    -- Rare path of bit_set: the first bit of a word, or a record with a journal.
    local function bit_set_rare(rec: Record, slot: number)
        local words = rec.words
        local w = slot // 32 + 1
        local word = words[w]
        if word ~= nil and word ~= 0 then
            words[w] = word + lshift(1, slot % 32)
        else
            word_first(rec, w, lshift(1, slot % 32))
        end
        note(rec, slot)
    end

    local function bit_set(rec: Record, slot: number)
        local words = rec.words
        local w = slot // 32 + 1
        local word = words[w]
        if word ~= nil and word ~= 0 and not rec.journal then
            words[w] = word + lshift(1, slot % 32)
            rec.version += 1
        else
            bit_set_rare(rec, slot)
        end
    end

    -- Clears the bit of a slot that is known to be set.
    -- Rare path of bit_clear: the last bit of a word, or a record with a journal.
    local function bit_clear_rare(rec: Record, slot: number)
        local words = rec.words
        local w = slot // 32 + 1
        local word = words[w] - lshift(1, slot % 32)
        if word ~= 0 then
            words[w] = word
        else
            word_last(rec, w)
        end
        note(rec, slot)
    end

    local function bit_clear(rec: Record, slot: number)
        local words = rec.words
        local w = slot // 32 + 1
        local word = words[w] - lshift(1, slot % 32)
        if word ~= 0 and not rec.journal then
            words[w] = word
            rec.version += 1
        else
            bit_clear_rare(rec, slot)
        end
    end

    -- ORs bits into word w of a record built from other records (merged OR terms, change
    -- filters over several ticks); such records have no journal.
    local function merge_word(rec: Record, w: number, bits: number)
        if bits == 0 then
            return
        end
        local old = rec.words[w]
        if old ~= nil and old ~= 0 then
            rec.words[w] = bor(old, bits)
        else
            word_first(rec, w, bits)
        end
    end

    -- Gives a record a change journal of `size` entries (a power of two). A new journal has
    -- no entries: a query that has not seen the latest changes of the record scans it again.
    local function journal_grow(rec: Record, size: number)
        rec.journal = table.create(size * 2, 0)
        rec.journal_mask = size - 1
    end

    -- Rare paths of sig_add / sig_remove: records beyond the shared signature tables.
    local function sig_more_add(rec: Record, slot: number)
        local more = sig_more[slot]
        if not more then
            more = {}
            sig_more[slot] = more
        end
        local k = rec.sig_word
        local sig = more[k]
        more[k] = if sig then sig + rec.sig_bit else rec.sig_bit
    end

    local function sig_more_remove(rec: Record, slot: number)
        local more = sig_more[slot] :: Words
        local k = rec.sig_word
        more[k] -= rec.sig_bit
    end

    local function sig_add(rec: Record, slot: number)
        local st = rec.sig_table
        if st then
            local sig = st[slot]
            st[slot] = if sig then sig + rec.sig_bit else rec.sig_bit
        else
            sig_more_add(rec, slot)
        end
    end

    local function sig_remove(rec: Record, slot: number)
        local st = rec.sig_table
        if st then
            st[slot] -= rec.sig_bit
        else
            sig_more_remove(rec, slot)
        end
    end

    -- Whether a new value page of a record is preallocated as an array: when the record is
    -- dense around it (at least a quarter of the slots of this and the previous page are
    -- members), as a page with 25-50 % of its slots used would otherwise stay in the hash part
    -- of the table, which is slower to read. Sparse records keep small hash pages.
    local function page_dense(rec: Record, page_index: number): boolean
        -- the two pages are 16 aligned words inside one summary word (32 words)
        local first_w = if page_index > 1 then (page_index - 2) * WORDS_PER_PAGE + 1 else 1
        local sum = rec.sums[(first_w - 1) // 32 + 1]
        if sum then
            local nonempty = band(rshift(sum, (first_w - 1) % 32), 0xFFFF)
            if popcount(nonempty) >= 8 then
                local words = rec.words
                local bits = 0
                while nonempty ~= 0 do
                    bits += popcount(words[first_w + countrz(nonempty)])
                    nonempty = band(nonempty, nonempty - 1)
                end
                return bits >= PAGE_SIZE // 4
            end
        end
        return false
    end

    -- Creates the value page of a record (see page_dense).
    local function new_page(rec: Record, page_index: number): Page
        local page: Page = if page_dense(rec, page_index) then table.create(PAGE_SIZE) else {}
        (rec.pages :: Pages)[page_index] = page
        -- a value can be set on a member that had none (world:add of a component): the match
        -- lists of cached queries keep page references and must see the new page (a slot of
        -- the page is noted: the lists re-read the pages of the noted slots)
        note(rec, (page_index - 1) * PAGE_SIZE)
        return page
    end

    local function set_value(rec: Record, slot: number, value: any)
        local pages = rec.pages :: Pages
        local index = slot // PAGE_SIZE + 1
        local page = pages[index]
        if page == nil then
            page = new_page(rec, index)
        end
        page[slot % PAGE_SIZE + 1] = value
    end

    ----------------------------------------------------------------------------
    -- records
    ----------------------------------------------------------------------------

    local function has_component_trait(slot: number): boolean
        local word = component_words[slot // 32 + 1]
        return word ~= nil and band(word, lshift(1, slot % 32)) ~= 0
    end

    -- Value of hook component `hook` set on the entity in `slot`.
    local function hook_of(hook: i53, slot: number): Hook?
        local pages = columns[hook]
        if pages == nil then
            return nil
        end
        local page = pages[slot // PAGE_SIZE + 1]
        return if page then page[slot % PAGE_SIZE + 1] else nil
    end

    -- signal dispatchers per hook field and id, and for each of them the hook it calls, its
    -- listeners and the number of them that need to run when an entity is deleted (see connect)
    type Dispatch = { hook: Hook?, listeners: { Hook }, loud: number }
    local dispatchers: { [string]: { [i53]: Hook } } = { on_add = {}, on_change = {}, on_remove = {} }
    local dispatched_hooks: { [string]: { [i53]: Dispatch } } = { on_add = {}, on_change = {}, on_remove = {} }

    -- The callback that the records of an id call: the dispatcher of its signals (it calls the
    -- hook first), or the hook set with world:set(id, OnAdd / OnChange / OnRemove, fn).
    local function hook_for(field: string, hook: i53, id: i53): Hook?
        return dispatchers[field][id] or hook_of(hook, id % ENTITY_MASK)
    end

    -- changes when a record is created or freed, or when the column of a record appears or goes
    -- (cached queries skip their lookups otherwise)
    local records_generation = 0

    -- The number of wildcard records with a mirror (see mirror.create): while it is 0, the
    -- changes of pairs skip the mirrors altogether.
    local mirror_count = 0
    -- The functions of the mirrors, in a table: they run on rare paths only, and world_new is
    -- at the limit of local registers.
    type Mirror = {
        drop: (rec: Record) -> (),
        value: (rec: Record, slot: number) -> any,
        write: (rec: Record, slot: number, value: any) -> (),
        first: (rec: Record, slot: number) -> (),
        pair: (rec: Record, slot: number, value: any) -> (),
        source: (rec: Record, slot: number, except: Record?, first: boolean) -> Record?,
        add_source: (rec: Record, pair_rec: Record, slot: number) -> (),
        unsource: (rec: Record, pair_rec: Record, slot: number) -> (),
        detach: (pair_rec: Record, slot: number) -> (),
        dropped: (rec: Record, list: { Record }, slot: number) -> (),
        create: (rec: Record) -> (),
        ensure: (query: QueryState) -> (),
    }
    local mirror: Mirror = {} :: any

    -- Query monitors (see Query.monitor): the active ones, and the pair that an exclusive
    -- relation adds to `entity` in place of the pair it removes (see pair_add), which the
    -- monitors take as present while the old pair is removed. The functions are in the table:
    -- world_new is at the limit of local registers.
    type MonitorState = { check: (entity: i53) -> (), leave: (entity: i53, w: number, bit: number) -> () }
    -- the terms of a query when its monitor was made (see Query.monitor)
    type MonitorTerms = {
        filter_with: { i53 },
        filter_without: { i53 }?,
        any_groups: { { i53 } }?,
        skip_disabled: boolean,
    }
    type Monitoring = {
        list: { MonitorState },
        entity: i53,
        id: i53,
        present: (id: i53, slot: number, w: number, bit: number, excluded: i53, included: i53) -> boolean,
        match: (terms: MonitorTerms, slot: number, excluded: i53, included: i53) -> boolean,
        recheck: (entity: i53) -> (),
        pending: (entity: i53, id: i53) -> boolean,
        removing: (entity: i53) -> boolean,
    }
    -- (the list is made with an array part: every delete tests list[1], see removing)
    local monitoring: Monitoring = { list = table.create(1), entity = 0, id = 0 } :: any

    -- The pair records that lost their last member since the previous batch was freed, in
    -- empty_pairs[1..empty_pair_count] (see note_empty_pair and free_empty_pairs): a pair
    -- added again before that keeps its record. pair_record_count counts all pair records.
    local empty_pairs: { Record } = {}
    local empty_pair_count = 0
    local pair_record_count = 0

    local function new_record(id: i53, kind: number, with_values: boolean): Record
        local index = 0
        local sig_word = 0
        local sig_table: Words? = nil
        if kind == KIND_PLAIN or kind == KIND_RELATION then
            local count = #free_indices
            if count > 0 then
                index = free_indices[count]
                free_indices[count] = nil
            else
                max_index += 1
                index = max_index
            end
            sig_word = (index - 1) // 32 + 1
            if sig_word <= SIG_FLAT then
                sig_table = sig_flat[sig_word]
                if sig_word > sig_flat_used then
                    sig_flat_used = sig_word
                end
            end
        end
        local rec: Record = {
            id = id,
            kind = kind,
            index = index,
            -- a nil field takes no room in the table (a pair record stays within 16 fields)
            sig_word = if index > 0 then sig_word else nil,
            sig_bit = if index > 0 then lshift(1, (index - 1) % 32) else nil,
            sig_table = sig_table,
            words = {},
            sums = {},
            word_count = 0,
            zeros = 0,
            version = 0,
            journal_mask = 0,
            journal = false,
        } :: any
        if with_values then
            rec.pages = {}
        end
        records[id] = rec
        records_generation += 1
        changes_stamp += 1
        if kind ~= KIND_TARGET then
            pwords[id] = rec.words -- a (*, T) record starts lazy (see wildcard_record)
        end
        if index > 0 then
            by_index[index] = rec
        end
        if with_values then
            columns[id] = rec.pages :: Pages
        end
        return rec
    end

    -- Keeps the hooked masks of the signature bit of a record in sync with its hooks. A
    -- record whose on_remove is a signal dispatcher without a hook and with change tracking
    -- listeners only has nothing to do when its entity is deleted.
    local function set_hooked(rec: Record, on: boolean)
        if rec.index == 0 then
            return
        end
        local k, bit = rec.sig_word, rec.sig_bit
        local mask = hooked[k] or 0
        local word_hooked = mask ~= 0
        if band(mask, bit) ~= 0 then
            mask -= bit
        end
        mask = if on then mask + bit else mask
        hooked[k] = mask
        if k <= SIG_FLAT and (mask ~= 0) ~= word_hooked then
            -- the word enters or leaves the list of the hooked words
            if mask ~= 0 then
                local at = 1
                while hooked_list[at] and hooked_list[at] < k do
                    at += 1
                end
                table.insert(hooked_list, at, k)
            else
                table.remove(hooked_list, table.find(hooked_list, k))
            end
        end
        local cell = dispatched_hooks.on_remove[if rec.kind == KIND_RELATION then rec.relation :: i53 else rec.id]
        local loud = on and (cell == nil or cell.hook ~= nil or cell.loud > 0)
        mask = hooked_delete[k] or 0
        if band(mask, bit) ~= 0 then
            mask -= bit
        end
        hooked_delete[k] = if loud then mask + bit else mask
    end

    local function set_on_remove(rec: Record, hook: Hook?)
        if hook or rec.on_remove then
            rec.on_remove = hook
        end
        set_hooked(rec, hook ~= nil)
    end

    -- A wildcard record whose pairs no longer hold values drops its mirror (see mirror.create):
    -- the queries that return it plan again (a column changes).
    function mirror.drop(rec: Record)
        rec.mirror = nil
        if rec.source then
            rec.source = nil
        end
        columns[rec.id] = nil
        mirror_count -= 1
        rec.version += 1
        records_generation += 1
        changes_stamp += 1
    end

    local function free_record(rec: Record)
        local id = rec.id
        if records[id] ~= rec then
            return
        end
        records[id] = nil
        records_generation += 1
        changes_stamp += 1
        -- The bitsets go empty in place: a pending cleanup cannot see members of a freed
        -- record. world:each keeps its own snapshot; a lazy (*, T) record has no bitsets.
        local words: Words? = rec.words
        if words then
            table.clear(words)
            table.clear(rec.sums)
            rec.word_count = 0
            rec.zeros = 0
        end
        if rec.mirror then
            mirror_count -= 1
        end
        -- a nil assigned to a missing key inserts the key (and may rehash the whole table): a
        -- lazy (*, T) record has no words in pwords, a record without values no column
        if pwords[id] ~= nil then
            pwords[id] = nil
        end
        if columns[id] ~= nil then
            columns[id] = nil
        end
        local index = rec.index
        if index > 0 then
            set_hooked(rec, false)
            by_index[index] = nil :: any
            table.insert(free_indices, index)
        end
        if rec.kind == KIND_RELATION and rec.relation == EcsChildOf then
            childof_pairs = nil
        end
        if rec.kind == KIND_PAIR then
            pair_record_count -= 1
            local at = rec.empty_listed
            if at then
                -- it leaves the list of empty pair records: the last one takes its place
                local last = empty_pairs[empty_pair_count]
                empty_pairs[at] = last
                last.empty_listed = at
                empty_pairs[empty_pair_count] = nil
                empty_pair_count -= 1
                rec.empty_listed = nil
            end
        end
        local wc_rel, wc_tgt = rec.wc_rel, rec.wc_tgt
        -- a pair with values leaves its wildcards: queries that return them plan again (the
        -- versions change without a journal entry)
        if wc_rel and wc_rel.pairs then
            wc_rel.pairs[id] = nil
            if rec.pages then
                local data_pairs = (wc_rel.data_pairs :: number) - 1
                wc_rel.data_pairs = data_pairs
                wc_rel.version += 1
                if data_pairs == 0 and wc_rel.mirror then
                    mirror.drop(wc_rel)
                end
            end
        end
        if wc_tgt and wc_tgt.pairs then
            local target_pairs = wc_tgt.pairs
            target_pairs[id] = nil
            if rec.pages then
                local data_pairs = (wc_tgt.data_pairs :: number) - 1
                wc_tgt.data_pairs = data_pairs
                wc_tgt.version += 1
                if data_pairs == 0 and wc_tgt.mirror then
                    mirror.drop(wc_tgt)
                end
            end
            -- a (*, T) record lives while T has pair records
            if next(target_pairs) == nil then
                free_record(wc_tgt)
            end
        end
    end

    -- A pair record lost its last member: it is freed with the next batch of empty pair
    -- records (free_empty_pairs), unless the pair is added again before. A record is listed
    -- once until that batch, also when it gets members again (a pair that keeps being removed
    -- and added again costs a field test, not a hash insert and remove); free_record takes a
    -- freed record out of the list.
    local function note_empty_pair(rec: Record)
        if rec.empty_listed == nil then
            empty_pair_count += 1
            empty_pairs[empty_pair_count] = rec
            rec.empty_listed = empty_pair_count
        end
    end

    -- Frees the listed pair records that are still empty once there are more than EMPTY_PAIRS
    -- of them and they are more than a quarter of all pair records (a (*, T) record goes with
    -- the last pair record of T): a pair that keeps coming back keeps its record, and the
    -- records of pairs that are gone do not add up. The callers check
    -- empty_pair_count > EMPTY_PAIRS first; they call it where no record they use can be freed
    -- (pair_add adds its pair again when it happens during an exclusive replacement).
    local function free_empty_pairs()
        if empty_pair_count * 4 <= pair_record_count then
            return
        end
        local list, n = empty_pairs, empty_pair_count
        empty_pairs = {}
        empty_pair_count = 0
        for i = 1, n do
            local rec = list[i]
            rec.empty_listed = nil -- not listed: free_record leaves the new list alone
            if rec.word_count == 0 then
                free_record(rec)
            end
        end
    end

    -- Record of a plain id (component or tag).
    local function record_create(id: i53): Record
        local slot = id % ENTITY_MASK
        id_used[slot] = true
        local rec = new_record(id, KIND_PLAIN, has_component_trait(slot))
        -- only hooks that exist are stored: a nil assigned to a new field of a full table grows it
        local on_add = hook_for("on_add", EcsOnAdd, id)
        if on_add then
            rec.on_add = on_add
        end
        local on_change = hook_for("on_change", EcsOnChange, id)
        if on_change then
            rec.on_change = on_change
        end
        set_on_remove(rec, hook_for("on_remove", EcsOnRemove, id))
        return rec
    end

    local world_has_pair: (entity: i53, id: i53) -> boolean

    -- A (*, T) record starts lazy: pairs come and go without touching it, and nothing reads
    -- its bits. A lazy record is small (see wildcard_record): it has no presence tables, no
    -- journal and no counts. The first query, has(), iteration or removal that needs its bits
    -- builds them from the pairs of T (target_materialize), and from then on the record is
    -- eager: it keeps the bit of a slot while the slot has at least one pair with T, and multi
    -- counts the pairs of the slots that have more than one. A second pair of a slot does not
    -- change the presence, so it does not change the version either. Most targets (parents,
    -- the targets of one-to-one relations) are never read through (*, T) and cost little more
    -- than their pairs.

    -- Builds the presence of a lazy (*, T) record from the pairs of its target; the record is
    -- eager from then on.
    local function target_materialize(rec: Record)
        if rec.eager then
            return
        end
        rec.eager = true
        -- the fields that a lazy record does not have
        local words: Words = {}
        rec.words = words
        rec.sums = {}
        rec.word_count = 0
        rec.zeros = 0
        rec.journal = false
        rec.journal_mask = 0
        rec.multi = false
        for _, pair_rec in rec.pairs :: { [i53]: Record } do
            for w, word in pair_rec.words do
                if word == 0 then
                    continue
                end
                local old = words[w]
                if old == nil or old == 0 then
                    word_first(rec, w, word)
                    continue
                end
                local both = band(old, word)
                if both ~= 0 then
                    -- slots that have another pair with the target already
                    local found = rec.multi
                    local multi: { [number]: number }
                    if found then
                        multi = found
                    else
                        multi = {}
                        rec.multi = multi
                    end
                    local base = (w - 1) * 32
                    repeat
                        local slot = base + countrz(both)
                        both = band(both, both - 1)
                        multi[slot] = (multi[slot] or 1) + 1
                    until both == 0
                end
                words[w] = bor(old, word)
            end
        end
        pwords[rec.id] = words
        rec.version += 1 -- the presence was not kept before: no journal entry
        changes_stamp += 1
    end

    -- The (*, T) record of a target that is being deleted (see cleanup_ids): its pairs leave
    -- their members, and its bits (and its mirror) are not updated for that (it is freed right
    -- after, like the pair records whose bits stay as they are).
    local dying_target: Record? = nil

    -- Wildcard values. A query that returns (R, *) or (*, T) returns the value of one pair of
    -- each entity: the pair with the lowest target slot for (R, *) (the first pair of
    -- slot_pair) and the pair with the lowest relation slot for (*, T) (the order of the pair
    -- ids, as in jecs). The first such query gives the wildcard record a mirror
    -- (mirror.create): value pages of its own, in columns like those of a component, with the
    -- value of that pair for every member slot. Every change of a pair keeps the mirrors up to
    -- date (mirror.pair, mirror.first, mirror.add_source, mirror.unsource), so the queries read
    -- a mirror like any column, through the specialized loops and the match lists, and get
    -- reads it too. A world without mirrors skips all of it (mirror_count). The mirror goes
    -- when no pair of the wildcard holds values any more (mirror.drop). A (*, T) mirror notes
    -- which pair gives the value (source) only for the slots with several pairs of T: the only
    -- pair of a slot gives it, so the usual case keeps nothing but the values.

    -- The value of a pair record for a slot.
    function mirror.value(rec: Record, slot: number): any
        local pages = rec.pages
        if pages == nil then
            return nil
        end
        local page = pages[slot // PAGE_SIZE + 1]
        return if page then page[slot % PAGE_SIZE + 1] else nil
    end

    -- Writes the value of a slot into the mirror of a wildcard record; a new page is noted like
    -- a page of a component (see new_page).
    function mirror.write(rec: Record, slot: number, value: any)
        local pages = rec.mirror :: Pages
        local index = slot // PAGE_SIZE + 1
        local page = pages[index]
        if page == nil then
            if value == nil then
                return
            end
            page = if page_dense(rec, index) then table.create(PAGE_SIZE) else {}
            pages[index] = page :: Page
            note(rec, (index - 1) * PAGE_SIZE)
        end
        (page :: Page)[slot % PAGE_SIZE + 1] = value
    end

    -- The first pair of a slot of (R, *) changed: its value goes to the mirror.
    function mirror.first(rec: Record, slot: number)
        local first = (rec.slot_pair :: { [number]: Record })[slot]
        mirror.write(rec, slot, if first then mirror.value(first, slot) else nil)
    end

    -- The value of a pair for a slot changed: the mirrors that show it follow.
    function mirror.pair(rec: Record, slot: number, value: any)
        local wc_rel = rec.wc_rel :: Record
        if wc_rel.mirror and (wc_rel.slot_pair :: { [number]: Record })[slot] == rec then
            mirror.write(wc_rel, slot, value)
        end
        local wc_tgt = rec.wc_tgt :: Record
        if wc_tgt.mirror then
            -- the only pair of the slot with the target, or the one that gives the value
            local multi = wc_tgt.multi
            if not (multi and multi[slot]) or (wc_tgt.source :: { [number]: Record })[slot] == rec then
                mirror.write(wc_tgt, slot, value)
            end
        end
    end

    -- The pair with the lowest relation slot among the pairs of the target of a (*, T) record
    -- that the slot has, except `except` (a pair that is leaving the slot); nil when there is
    -- none. `first` stops at the first pair found: the caller knows the slot has one pair.
    function mirror.source(rec: Record, slot: number, except: Record?, first: boolean): Record?
        local best: Record? = nil
        local best_slot = math.huge
        local w = slot // 32 + 1
        local bit = lshift(1, slot % 32)
        for _, pair_rec in rec.pairs :: { [i53]: Record } do
            if pair_rec ~= except then
                local word = pair_rec.words[w]
                if word ~= nil and band(word, bit) ~= 0 then
                    if first then
                        return pair_rec
                    end
                    local relation_slot = (pair_rec.relation :: i53) % ENTITY_MASK
                    if relation_slot < best_slot then
                        best, best_slot = pair_rec, relation_slot
                    end
                end
            end
        end
        return best
    end

    -- A pair with the target of a (*, T) record that has a mirror joined the slot (after
    -- target_add): it gives the value of the slot when it is the only pair of the slot or its
    -- relation slot is the lowest.
    function mirror.add_source(rec: Record, pair_rec: Record, slot: number)
        local multi = rec.multi
        if not (multi and multi[slot]) then
            mirror.write(rec, slot, mirror.value(pair_rec, slot))
            return
        end
        local source = rec.source :: { [number]: Record }
        local current = source[slot]
        if current == nil then
            -- the second pair of the slot: the first one gave the value without an entry
            current = mirror.source(rec, slot, pair_rec, true) :: Record
            source[slot] = current
        end
        if (pair_rec.relation :: i53) % ENTITY_MASK < (current.relation :: i53) % ENTITY_MASK then
            source[slot] = pair_rec
            mirror.write(rec, slot, mirror.value(pair_rec, slot))
        end
    end

    -- A pair left the slot of a (*, T) record that has a mirror (after target_remove): when it
    -- gave the value of the slot, the next pair of the slot gives it (the record keeps the bit of
    -- the slot while the slot has other pairs with the target, and multi while it has several).
    function mirror.unsource(rec: Record, pair_rec: Record, slot: number)
        if rec == dying_target then
            return
        end
        local source = rec.source :: { [number]: Record }
        local current = source[slot]
        if current == nil then
            -- the only pair of the slot left
            mirror.write(rec, slot, nil)
            return
        end
        local multi = rec.multi
        if multi and multi[slot] then
            -- several pairs are left
            if current == pair_rec then
                local next_source = mirror.source(rec, slot, pair_rec, false) :: Record
                source[slot] = next_source
                mirror.write(rec, slot, mirror.value(next_source, slot))
            end
        else
            -- one pair is left: it gives the value without an entry
            source[slot] = nil
            if current == pair_rec then
                local rest = mirror.source(rec, slot, pair_rec, true) :: Record
                mirror.write(rec, slot, mirror.value(rest, slot))
            end
        end
    end

    -- The pairs of the relation record `rec` left the slot (drop_pair, when the slot is cleared):
    -- the mirror of the relation loses the slot, the mirrors of their targets follow.
    function mirror.dropped(rec: Record, list: { Record }, slot: number)
        if rec.mirror then
            mirror.write(rec, slot, nil)
        end
        for _, pair_rec in list do
            local wc_tgt = pair_rec.wc_tgt :: Record
            if wc_tgt.mirror then
                mirror.unsource(wc_tgt, pair_rec, slot)
            end
        end
    end

    -- A pair left the slot (pair_detach): the mirrors of its relation and of its target follow.
    function mirror.detach(pair_rec: Record, slot: number)
        local wc_rel = pair_rec.wc_rel :: Record
        if wc_rel.mirror then
            mirror.first(wc_rel, slot)
        end
        local wc_tgt = pair_rec.wc_tgt :: Record
        if wc_tgt.mirror then
            mirror.unsource(wc_tgt, pair_rec, slot)
        end
    end

    -- Gives a wildcard record its mirror, built from the pairs of the wildcard (a (*, T) record
    -- is materialized first). The queries plan again with the new column.
    function mirror.create(rec: Record)
        if rec.kind == KIND_TARGET then
            target_materialize(rec)
        end
        rec.mirror = {}
        mirror_count += 1
        if rec.kind == KIND_RELATION then
            for slot, pair_rec in rec.slot_pair :: { [number]: Record } do
                local value = mirror.value(pair_rec, slot)
                if value ~= nil then
                    mirror.write(rec, slot, value)
                end
            end
        else
            -- the pair that gives the value of each slot with several pairs; the only pair of a
            -- slot gives it at once
            local source: { [number]: Record } = {}
            rec.source = source
            local multi = rec.multi
            for _, pair_rec in rec.pairs :: { [i53]: Record } do
                local relation_slot = (pair_rec.relation :: i53) % ENTITY_MASK
                for w, word in pair_rec.words do
                    local base = (w - 1) * 32
                    while word ~= 0 do
                        local slot = base + countrz(word)
                        word = band(word, word - 1)
                        if not (multi and multi[slot]) then
                            local value = mirror.value(pair_rec, slot)
                            if value ~= nil then
                                mirror.write(rec, slot, value)
                            end
                            continue
                        end
                        local current = source[slot]
                        if current == nil or relation_slot < (current.relation :: i53) % ENTITY_MASK then
                            source[slot] = pair_rec
                        end
                    end
                end
            end
            for slot, pair_rec in source do
                local value = mirror.value(pair_rec, slot)
                if value ~= nil then
                    mirror.write(rec, slot, value)
                end
            end
        end
        columns[rec.id] = rec.mirror :: Pages
        -- a new column: the queries that return the wildcard plan again (no journal entry)
        rec.version += 1
        records_generation += 1
        changes_stamp += 1
    end

    -- The words of an id for has() when it has none in pwords: those of a lazy (*, T)
    -- record, built now; nil for an id without a record.
    local function lazy_words(id: i53): Words?
        if id > PAIR_OFFSET then
            local rec = records[id]
            if rec and rec.kind == KIND_TARGET then
                target_materialize(rec)
                return rec.words
            end
        end
        return nil
    end

    -- Rare path of adding a pair to (*, T): the first bit of a word, or a slot that has a
    -- pair with the target already (pair_add inlines the common case).
    local function target_add(rec: Record, slot: number)
        local words = rec.words
        local w = slot // 32 + 1
        local bit = lshift(1, slot % 32)
        local word = words[w]
        if word == nil or word == 0 then
            word_first(rec, w, bit)
            note(rec, slot)
        elseif band(word, bit) == 0 then
            words[w] = word + bit
            note(rec, slot)
        else
            local found = rec.multi
            local multi: { [number]: number }
            if found then
                multi = found
            else
                multi = {}
                rec.multi = multi
            end
            multi[slot] = (multi[slot] or 1) + 1
        end
    end

    -- A pair with the target of a (*, T) record left the slot (the callers update the mirror of
    -- the record, see mirror.detach: a function this small is inlined at its call sites).
    local function target_remove(rec: Record, slot: number)
        if not rec.eager or rec == dying_target then
            return
        end
        local multi = rec.multi
        local count = if multi then multi[slot] else nil
        if count then
            (multi :: { [number]: number })[slot] = if count > 2 then count - 1 else nil
        else
            bit_clear(rec, slot)
        end
    end

    -- Record of a wildcard id: (R, *) is part of entity signatures, (*, T) is not.
    local function wildcard_record(id: i53, relation: i53?, target: i53?): Record
        local rec = records[id]
        if rec then
            return rec
        end
        if relation == nil then
            -- a lazy (*, T) record: 8 fields, which a table holds in 8 hash slots (a record
            -- made by new_record takes 16, and two tables); target_materialize adds the rest.
            -- No words in pwords: has() finds the record through lazy_words.
            rec = {
                id = id,
                kind = KIND_TARGET,
                index = 0,
                version = 0,
                pairs = {},
                target = target,
                eager = false,
                data_pairs = 0,
            } :: any
            records[id] = rec
            records_generation += 1
            changes_stamp += 1
            id_used[(target :: i53) % ENTITY_MASK] = true
            return rec
        end
        rec = new_record(id, KIND_RELATION, false)
        rec.pairs = {}
        rec.relation = relation
        id_used[relation % ENTITY_MASK] = true
        rec.slot_pair = {}
        rec.slot_pairs = {}
        if relation == EcsChildOf then
            childof_pairs = rec.slot_pair
        end
        rec.exclusive = world_has_pair(relation, EcsExclusive)
        set_hooked(rec, hook_for("on_remove", EcsOnRemove, relation) ~= nil)
        rec.data_pairs = 0
        return rec
    end

    -- Record of a pair (R, T). Pairs carry data when R (or, for tag relations, T) is a component.
    local function pair_record_create(id: i53): Record
        local relation = alive[ECS_PAIR_FIRST(id)]
        local target = alive[ECS_PAIR_SECOND(id)]
        if relation == nil or relation <= 0 or target == nil or target <= 0 then
            error("pair of an entity that is not alive", 3)
        end
        if relation == EcsWildcard or target == EcsWildcard then
            error("wildcard pairs can only be used in queries", 3)
        end
        local rel_slot = relation % ENTITY_MASK
        local rec =
            new_record(id, KIND_PAIR, has_component_trait(rel_slot) or has_component_trait(target % ENTITY_MASK))
        pair_record_count += 1
        rec.relation = relation
        rec.target = target
        local wc_rel = wildcard_record(ECS_PAIR(relation, EcsWildcard), relation, nil)
        local wc_tgt = wildcard_record(ECS_PAIR(EcsWildcard, target), nil, target)
        rec.wc_rel = wc_rel
        rec.wc_tgt = wc_tgt;
        (wc_rel.pairs :: { [i53]: Record })[id] = rec;
        (wc_tgt.pairs :: { [i53]: Record })[id] = rec
        if rec.pages then
            -- the wildcards return values from now on: queries that return them plan again
            -- (the versions change without a journal entry)
            wc_rel.data_pairs = (wc_rel.data_pairs :: number) + 1
            wc_tgt.data_pairs = (wc_tgt.data_pairs :: number) + 1
            wc_rel.version += 1
            wc_tgt.version += 1
            changes_stamp += 1
        end
        -- only hooks that exist are stored: a nil assigned to a new field of a full table grows it
        local on_add = hook_for("on_add", EcsOnAdd, relation)
        if on_add then
            rec.on_add = on_add
        end
        local on_change = hook_for("on_change", EcsOnChange, relation)
        if on_change then
            rec.on_change = on_change
        end
        local on_remove = hook_for("on_remove", EcsOnRemove, relation)
        if on_remove then
            rec.on_remove = on_remove
        end
        return rec
    end

    -- Adds a second or later pair of a relation to the slot: the pairs of a slot are kept in
    -- a list ordered by target slot, and slot_pair holds the first one. Targets are mostly
    -- added in the order they were created: such a pair goes to the end at once, any other
    -- one finds its place by a binary search (an entity with many targets of a relation).
    local function pair_attach_more(rec: Record, wc_rel: Record, slot: number, first: Record)
        local slot_pairs = wc_rel.slot_pairs :: { [number]: { Record } }
        local list = slot_pairs[slot]
        if list == nil then
            list = { first }
            slot_pairs[slot] = list
        end
        local target_slot = (rec.target :: i53) % ENTITY_MASK
        local n = #list
        if (list[n].target :: i53) % ENTITY_MASK < target_slot then
            list[n + 1] = rec
        else
            -- the first pair with a higher target slot
            local lo, hi = 1, n
            while lo < hi do
                local mid = (lo + hi) // 2
                if (list[mid].target :: i53) % ENTITY_MASK > target_slot then
                    hi = mid
                else
                    lo = mid + 1
                end
            end
            table.insert(list, lo, rec)
        end
        (wc_rel.slot_pair :: { [number]: Record })[slot] = list[1]
    end

    -- Removes a pair record from the relation record (R, *) and the target record (*, T) of the slot.
    local function pair_detach(rec: Record, slot: number)
        local wc_rel = rec.wc_rel :: Record
        local slot_pair = wc_rel.slot_pair :: { [number]: Record }
        local slot_pairs = wc_rel.slot_pairs :: { [number]: { Record } }
        local list = slot_pairs[slot]
        if list == nil then
            slot_pair[slot] = nil
            bit_clear(wc_rel, slot)
            sig_remove(wc_rel, slot)
        else
            local n = #list
            local at: number? = nil
            if n <= 16 then
                at = table.find(list, rec)
            else
                -- a long list (an entity with many targets of a relation): a binary search by
                -- target slot (see pair_attach_more)
                local target_slot = (rec.target :: i53) % ENTITY_MASK
                local lo, hi = 1, n
                while lo < hi do
                    local mid = (lo + hi) // 2
                    if (list[mid].target :: i53) % ENTITY_MASK < target_slot then
                        lo = mid + 1
                    else
                        hi = mid
                    end
                end
                if list[lo] == rec then
                    at = lo
                end
            end
            if at then
                table.remove(list, at)
            end
            slot_pair[slot] = list[1]
            if #list == 1 then
                slot_pairs[slot] = nil
            end
        end
        target_remove(rec.wc_tgt :: Record, slot)
        if mirror_count > 0 then
            mirror.detach(rec, slot)
        end
    end

    ----------------------------------------------------------------------------
    -- set / add / remove
    ----------------------------------------------------------------------------

    local world_remove: (_: any, entity: i53, id: i53) -> ()

    -- Adds a pair (world_set has already replaced an existing value in place). `existing` is
    -- the record of the pair when the caller has looked it up.
    local function pair_add(entity: i53, slot: number, id: i53, value: any, with_value: boolean, existing: Record?)
        local rec = existing or records[id] or pair_record_create(id)
        if rec.kind ~= KIND_PAIR then
            error("wildcard pairs can only be used in queries", 3)
        end
        local words = rec.words
        local w = slot // 32 + 1
        local bit = lshift(1, slot % 32)
        local word = words[w]
        if word ~= nil and band(word, bit) ~= 0 then
            if with_value then
                if rec.pages then
                    set_value(rec, slot, value)
                    if mirror_count > 0 then
                        mirror.pair(rec, slot, value)
                    end
                    local on_change = rec.on_change
                    if on_change then
                        on_change(entity, id, value)
                    end
                elseif value ~= nil then
                    error("cannot set a value on a tag pair; the relation or the target must be a component", 3)
                end
            end
            return
        end
        local wc_rel = rec.wc_rel :: Record
        local slot_pair = wc_rel.slot_pair :: { [number]: Record }
        local first = slot_pair[slot]
        -- An exclusive relation replaces the pairs the entity has. The hooks of a removal may give
        -- the entity another pair of the relation: it is replaced as well, until the entity has
        -- none but the one this call adds (a hook that keeps adding pairs is an error).
        local replaced = 0
        while first ~= nil and wc_rel.exclusive do
            -- A pair whose removal runs already (this call comes from its hooks) is left to that
            -- removal; when it is an exclusive replacement as well, it replaces what this call
            -- adds in turn. Another pair of the slot is replaced in its place.
            local victim: Record? = first
            if (removing[1] ~= nil or clear_depth > 0) and removal_runs(entity, first) then
                victim = nil
                local list = (wc_rel.slot_pairs :: { [number]: { Record } })[slot]
                if list then
                    for _, pair_rec in list do
                        if not removal_runs(entity, pair_rec) then
                            victim = pair_rec
                            break
                        end
                    end
                end
                if victim == nil then
                    break
                end
            end
            replaced += 1
            if replaced > 100 then
                error("the hooks of an exclusive relation keep giving the entity other targets", 3)
            end
            local old_id = (victim :: Record).id
            if monitoring.list[1] == nil then
                -- no monitor checks the entity during the removal: one that a hook of the old pair
                -- makes is not among the listeners of this removal (see Query.monitor)
                world_remove(world, entity, old_id)
            else
                -- the monitors take the new pair as present while the old one is removed
                local outer_entity, outer_id = monitoring.entity, monitoring.id
                monitoring.entity, monitoring.id = entity, id
                world_remove(world, entity, old_id)
                monitoring.entity, monitoring.id = outer_entity, outer_id
            end
            if records[id] ~= rec then
                -- the record was freed meanwhile: a hook deleted its relation or target, or the
                -- record was empty and the removal freed a batch of empty pair records (see
                -- free_empty_pairs); while the entity and both elements are alive, the pair is
                -- added with a new record
                local relation, target = rec.relation :: i53, rec.target :: i53
                if
                    alive[slot] == entity
                    and alive[relation % ENTITY_MASK] == relation
                    and alive[target % ENTITY_MASK] == target
                then
                    pair_add(entity, slot, id, value, with_value, nil)
                elseif monitoring.list[1] ~= nil then
                    -- the new pair is not added after all: the monitors check the entity again
                    monitoring.recheck(entity)
                end
                return
            end
            if alive[slot] ~= entity then
                if rec.word_count == 0 then
                    note_empty_pair(rec) -- a hook deleted the entity: nobody may get the pair
                end
                if monitoring.list[1] ~= nil then
                    -- the monitors that took the pair as replaced (the entity staying in their
                    -- query) see that it is gone
                    monitoring.recheck(entity)
                end
                return
            end
            -- the hooks of the removal may have changed the entity: a pair that they added is
            -- there, and a set gives it the value of this call (as to a pair there before it)
            word = words[w]
            if word ~= nil and band(word, bit) ~= 0 then
                if with_value and rec.pages then
                    set_value(rec, slot, value)
                    if mirror_count > 0 then
                        mirror.pair(rec, slot, value)
                    end
                    local on_change = rec.on_change
                    if on_change then
                        on_change(entity, id, value)
                    end
                end
                return
            end
            first = slot_pair[slot]
        end
        if word ~= nil and word ~= 0 then
            words[w] = word + bit
        else
            word_first(rec, w, bit)
        end
        local version = rec.version + 1 -- note(rec, slot), inline
        rec.version = version
        if rec.journal then
            journal_write(rec, version, slot)
        end
        local pages = rec.pages
        if pages and with_value then
            set_value(rec, slot, value)
        end
        -- attach to the relation record (R, *) and the target record (*, T)
        if first == nil then
            slot_pair[slot] = rec
            bit_set(wc_rel, slot)
            sig_add(wc_rel, slot)
        else
            pair_attach_more(rec, wc_rel, slot, first)
        end
        if mirror_count > 0 and wc_rel.mirror and slot_pair[slot] == rec then
            mirror.write(wc_rel, slot, mirror.value(rec, slot))
        end
        local wc_tgt = rec.wc_tgt :: Record
        if wc_tgt.eager then
            local twords = wc_tgt.words
            local tword = twords[w]
            if tword ~= nil and tword ~= 0 and band(tword, bit) == 0 then
                twords[w] = tword + bit
                version = wc_tgt.version + 1 -- note(wc_tgt, slot), inline
                wc_tgt.version = version
                if wc_tgt.journal then
                    journal_write(wc_tgt, version, slot)
                end
            else
                target_add(wc_tgt, slot)
            end
            if mirror_count > 0 and wc_tgt.mirror then
                mirror.add_source(wc_tgt, rec, slot)
            end
        end
        local on_add = rec.on_add
        if with_value and value ~= nil and not pages then
            -- the pair stays added (its OnAdd runs, without the value), the value is rejected
            if on_add then
                on_add(entity, id, nil)
            end
            error("cannot set a value on a tag pair; the relation or the target must be a component", 3)
        end
        if on_add then
            on_add(entity, id, value)
        end
    end

    local function world_set(_: any, entity: i53, id: i53, value: any)
        local slot = entity % ENTITY_MASK
        if alive[slot] ~= entity then
            return
        end
        local existing = records[id]
        local pages = if existing then existing.pages else nil
        local page_index, page_slot = 0, 0
        local page: Page? = nil
        if pages then
            -- an existing value (of a component or a pair) is replaced in place
            page_index = slot // PAGE_SIZE + 1
            page_slot = slot % PAGE_SIZE + 1
            page = pages[page_index]
            if page and page[page_slot] ~= nil then
                page[page_slot] = value
                if mirror_count > 0 and id > PAIR_OFFSET then
                    mirror.pair(existing :: Record, slot, value)
                end
                local on_change = (existing :: Record).on_change
                if on_change then
                    on_change(entity, id, value)
                end
                return
            end
        end
        if id > PAIR_OFFSET then
            pair_add(entity, slot, id, value, true, existing)
            return
        end
        local rec: Record
        if existing then
            rec = existing
        else
            -- an id that is not alive is ignored (a deleted one has no records left)
            if alive[id % ENTITY_MASK] ~= id then
                return
            end
            rec = record_create(id)
            pages = rec.pages
            if pages then
                page_index = slot // PAGE_SIZE + 1
                page_slot = slot % PAGE_SIZE + 1
            end
        end
        local words = rec.words
        local w = slot // 32 + 1
        local bit = lshift(1, slot % 32)
        local word = words[w]
        if word ~= nil and word ~= 0 then
            if band(word, bit) ~= 0 then
                -- already present: a tag, or a component whose value is nil
                if not pages and value ~= nil then
                    error("cannot set a value on a tag; add the Component trait (world:component()) to store data", 2)
                end
                if pages then
                    if not page then
                        page = new_page(rec, page_index)
                    end
                    (page :: Page)[page_slot] = value
                    local on_change = rec.on_change
                    if on_change then
                        on_change(entity, id, value)
                    end
                end
                return
            end
            words[w] = word + bit
        else
            -- word_first(rec, w, bit), inline on the hot paths
            words[w] = bit
            rec.word_count += 1
            local sums = rec.sums
            local sw = slot // 1024 + 1
            local sbit = lshift(1, (w - 1) % 32)
            local sum = sums[sw]
            if sum ~= nil and sum ~= 0 then
                sums[sw] = sum + sbit
            else
                sum_first(rec, sw, sbit)
            end
        end
        local version = rec.version + 1 -- note(rec, slot), inline
        rec.version = version
        if rec.journal then
            journal_write(rec, version, slot)
        end
        if pages then
            if not page then
                page = new_page(rec, page_index)
            end
            (page :: Page)[page_slot] = value
        end
        local st = rec.sig_table
        if st then
            local sig = st[slot]
            st[slot] = if sig then sig + rec.sig_bit else rec.sig_bit
        else
            sig_more_add(rec, slot)
        end
        local on_add = rec.on_add
        if not pages and value ~= nil then
            -- the tag stays added (its OnAdd runs, without the value), the value is rejected
            if on_add then
                on_add(entity, id, nil)
            end
            error("cannot set a value on a tag; add the Component trait (world:component()) to store data", 2)
        end
        if on_add then
            on_add(entity, id, value)
        end
    end

    local function world_add(_: any, entity: i53, id: i53)
        local slot = entity % ENTITY_MASK
        if alive[slot] ~= entity then
            return
        end
        if id > PAIR_OFFSET then
            pair_add(entity, slot, id, nil, false)
            return
        end
        local rec = records[id]
        if rec == nil then
            -- an id that is not alive is ignored (a deleted one has no records left)
            if alive[id % ENTITY_MASK] ~= id then
                return
            end
            rec = record_create(id)
        end
        local words = rec.words
        local w = slot // 32 + 1
        local bit = lshift(1, slot % 32)
        local word = words[w]
        if word ~= nil and word ~= 0 then
            if band(word, bit) ~= 0 then
                return
            end
            words[w] = word + bit
        else
            -- word_first(rec, w, bit), inline on the hot paths
            words[w] = bit
            rec.word_count += 1
            local sums = rec.sums
            local sw = slot // 1024 + 1
            local sbit = lshift(1, (w - 1) % 32)
            local sum = sums[sw]
            if sum ~= nil and sum ~= 0 then
                sums[sw] = sum + sbit
            else
                sum_first(rec, sw, sbit)
            end
        end
        local version = rec.version + 1 -- note(rec, slot), inline
        rec.version = version
        if rec.journal then
            journal_write(rec, version, slot)
        end
        local st = rec.sig_table
        if st then
            local sig = st[slot]
            st[slot] = if sig then sig + rec.sig_bit else rec.sig_bit
        else
            sig_more_add(rec, slot)
        end
        local on_add = rec.on_add
        if on_add then
            on_add(entity, id, nil)
        end
    end

    -- Removes every pair (R, *) or (*, T) of the entity.
    local function remove_wildcard(entity: i53, slot: number, id: i53)
        local wc = records[id]
        if wc and wc.kind == KIND_TARGET then
            target_materialize(wc)
        end
        if wc == nil or not bit_test(wc, slot) then
            return
        end
        local ids: { i53 } = {}
        local slot_pair = wc.slot_pair
        if slot_pair then
            local list = (wc.slot_pairs :: { [number]: { Record } })[slot]
            if list then
                for _, pair_rec in list do
                    table.insert(ids, pair_rec.id)
                end
            else
                table.insert(ids, slot_pair[slot].id)
            end
        else
            for pair_id, rec in wc.pairs :: { [i53]: Record } do
                if bit_test(rec, slot) then
                    table.insert(ids, pair_id)
                end
            end
        end
        for _, pair_id in ids do
            world_remove(world, entity, pair_id)
        end
    end

    function world_remove(_: any, entity: i53, id: i53)
        local slot = entity % ENTITY_MASK
        if alive[slot] ~= entity then
            return
        end
        local rec = records[id]
        if rec == nil then
            return
        end
        if rec.kind == KIND_TARGET then
            remove_wildcard(entity, slot, id)
            return
        end
        local words = rec.words
        local w = slot // 32 + 1
        local word = words[w]
        if word == nil then
            return
        end
        local bit = lshift(1, slot % 32)
        if band(word, bit) == 0 then
            return
        end
        if rec.pairs then
            remove_wildcard(entity, slot, id)
            return
        end
        local on_remove = rec.on_remove
        if on_remove then
            local n = #removing
            for i = 1, n, 2 do
                if removing[i] == entity and removing[i + 1] == id then
                    return -- started again by the hooks of this removal: it completes itself
                end
            end
            -- the entity may be cleared further out: an id that the clear has notified goes when
            -- the clear ends (see removal_runs), another one goes now
            for d = 1, clear_depth do
                if clearing[d] == entity then
                    if removal_runs(entity, rec) then
                        return
                    end
                    break
                end
            end
            removing[n + 1] = entity
            removing[n + 2] = id
            on_remove(entity, id)
            -- a clear of the entity in the hooks removed the id (it ended the entry, see
            -- clear_slot): an id given back since is a new one, which stays
            local completed = removing[n + 2] ~= id
            removing[n + 2] = nil
            removing[n + 1] = nil
            if completed then
                return
            end
            -- the hook may have changed the entity already
            word = words[w]
            if alive[slot] ~= entity or word == nil or band(word, bit) == 0 then
                return
            end
        end
        word -= bit
        if word == 0 then
            -- word_last(rec, w), inline on the hot paths
            words[w] = 0
            local count = rec.word_count - 1
            rec.word_count = count
            local sums = rec.sums
            local sw = slot // 1024 + 1
            local sum = sums[sw] - lshift(1, (w - 1) % 32)
            sums[sw] = sum
            if sum == 0 then
                sum_last(rec, sw)
            end
            local zeros = rec.zeros + 1
            rec.zeros = zeros
            if zeros > 2 * count + 1024 then
                drop_zeros(rec)
            end
        else
            words[w] = word
        end
        local version = rec.version + 1 -- note(rec, slot), inline
        rec.version = version
        if rec.journal then
            journal_write(rec, version, slot)
        end
        local pages = rec.pages
        if pages then
            local page = pages[slot // PAGE_SIZE + 1]
            if page then
                page[slot % PAGE_SIZE + 1] = nil
            end
        end
        if id > PAIR_OFFSET then
            pair_detach(rec, slot)
            if rec.word_count == 0 then
                note_empty_pair(rec)
                if empty_pair_count > EMPTY_PAIRS then
                    free_empty_pairs()
                end
            end
        else
            local st = rec.sig_table
            if st then
                st[slot] -= rec.sig_bit
            else
                sig_more_remove(rec, slot)
            end
        end
    end

    ----------------------------------------------------------------------------
    -- get / has
    ----------------------------------------------------------------------------

    -- Value of id for the slot, including wildcard pairs: the value of the pair with the lowest
    -- target slot for (R, *) and of the pair with the lowest relation slot for (*, T), read
    -- from the mirror of the wildcard when it has one (see mirror.create).
    local function value_of(id: i53, slot: number): any
        local pages = columns[id]
        if pages then
            local page = pages[slot // PAGE_SIZE + 1]
            return if page then page[slot % PAGE_SIZE + 1] else nil
        end
        if id > PAIR_OFFSET then
            local rec = records[id]
            if rec and rec.kind == KIND_RELATION then
                local pair_rec = (rec.slot_pair :: { [number]: Record })[slot]
                return if pair_rec then mirror.value(pair_rec, slot) else nil
            elseif rec and rec.kind == KIND_TARGET and (rec.data_pairs :: number) > 0 then
                -- an eager record knows the slots that have several pairs with the target
                local multi = rec.multi
                local single = rec.eager and not (multi and multi[slot])
                local pair_rec = mirror.source(rec, slot, nil, single == true)
                return if pair_rec then mirror.value(pair_rec, slot) else nil
            end
        end
        return nil
    end

    local function world_get(
        _: any,
        entity: i53,
        a: i53,
        b: i53?,
        c: i53?,
        d: i53?,
        e: i53?,
        f: i53?,
        g: i53?,
        h: i53?,
        overflow: i53?
    ): ...any
        local slot = entity % ENTITY_MASK
        if alive[slot] ~= entity then
            return nil
        end
        local page_index = slot // PAGE_SIZE + 1
        local page_slot = slot % PAGE_SIZE + 1
        local cols = columns
        local column = cols[a]
        local page = if column then column[page_index] else nil
        local va = if page then page[page_slot] elseif column then nil else value_of(a, slot)
        if b == nil then
            return va
        end
        column = cols[b]
        page = if column then column[page_index] else nil
        local vb = if page then page[page_slot] elseif column then nil else value_of(b, slot)
        if c == nil then
            return va, vb
        end
        column = cols[c]
        page = if column then column[page_index] else nil
        local vc = if page then page[page_slot] elseif column then nil else value_of(c, slot)
        if d == nil then
            return va, vb, vc
        end
        column = cols[d]
        page = if column then column[page_index] else nil
        local vd = if page then page[page_slot] elseif column then nil else value_of(d, slot)
        if e == nil then
            return va, vb, vc, vd
        end
        if overflow ~= nil then
            error(TOO_MANY_IDS, 2)
        end
        return va,
            vb,
            vc,
            vd,
            value_of(e, slot),
            if f then value_of(f, slot) else nil,
            if g then value_of(g, slot) else nil,
            if h then value_of(h, slot) else nil
    end

    -- Values of any number of ids, written into `out` (or a new table).
    local function world_get_list(_: any, entity: i53, ids: { i53 }, out: { any }?): { any }
        local result: { any } = out or table.create(#ids)
        local slot = entity % ENTITY_MASK
        local ok = alive[slot] == entity
        for i, id in ids do
            result[i] = if ok then value_of(id, slot) else nil
        end
        return result
    end

    -- has() of an id without words in pwords: a lazy (*, T) record (built now) or no record.
    local function lazy_has(id: i53, w: number, bit: number): boolean
        local words = lazy_words(id)
        return words ~= nil and band(words[w] or 0, bit) ~= 0
    end

    local function has_bit(id: i53?, w: number, bit: number): boolean
        if id == nil then
            return true
        end
        local words = pwords[id]
        if words == nil then
            return lazy_has(id, w, bit)
        end
        return band(words[w] or 0, bit) ~= 0
    end

    local function world_has(
        _: any,
        entity: i53,
        a: i53,
        b: i53?,
        c: i53?,
        d: i53?,
        e: i53?,
        f: i53?,
        g: i53?,
        h: i53?,
        overflow: i53?
    ): boolean
        local slot = entity % ENTITY_MASK
        if alive[slot] ~= entity then
            return false
        end
        local w = slot // 32 + 1
        local bit = lshift(1, slot % 32)
        local pw = pwords
        local words = pw[a]
        if words == nil then
            if not lazy_has(a, w, bit) then
                return false
            end
        elseif band(words[w] or 0, bit) == 0 then
            return false
        end
        if b == nil then
            return true
        end
        words = pw[b]
        if words == nil then
            if not lazy_has(b, w, bit) then
                return false
            end
        elseif band(words[w] or 0, bit) == 0 then
            return false
        end
        if c == nil then
            return true
        end
        words = pw[c]
        if words == nil then
            if not lazy_has(c, w, bit) then
                return false
            end
        elseif band(words[w] or 0, bit) == 0 then
            return false
        end
        if d == nil then
            return true
        end
        words = pw[d]
        if words == nil then
            if not lazy_has(d, w, bit) then
                return false
            end
        elseif band(words[w] or 0, bit) == 0 then
            return false
        end
        if e == nil then
            return true
        end
        if overflow ~= nil then
            error(TOO_MANY_IDS, 2)
        end
        return has_bit(e, w, bit) and has_bit(f, w, bit) and has_bit(g, w, bit) and has_bit(h, w, bit)
    end

    local function world_has_all(_: any, entity: i53, ids: { i53 }): boolean
        local slot = entity % ENTITY_MASK
        if alive[slot] ~= entity then
            return false
        end
        local w = slot // 32 + 1
        local bit = lshift(1, slot % 32)
        for _, id in ids do
            if not has_bit(id, w, bit) then
                return false
            end
        end
        return true
    end

    function world_has_pair(entity: i53, id: i53): boolean
        local slot = entity % ENTITY_MASK
        if alive[slot] ~= entity then
            return false
        end
        return has_bit(id, slot // 32 + 1, lshift(1, slot % 32))
    end

    ----------------------------------------------------------------------------
    -- clear / delete
    ----------------------------------------------------------------------------

    -- Appends the pairs of a relation record (R, *) of a slot that have on_remove hooks to
    -- buffer (no table for a slot with one pair).
    local function collect_pairs(rec: Record, slot: number, buffer: { Record }, n: number): number
        local list = (rec.slot_pairs :: { [number]: { Record } })[slot]
        if list then
            for _, pair_rec in list do
                if pair_rec.on_remove then
                    n += 1
                    buffer[n] = pair_rec
                end
            end
        else
            local pair_rec = (rec.slot_pair :: { [number]: Record })[slot]
            if pair_rec and pair_rec.on_remove then
                n += 1
                buffer[n] = pair_rec
            end
        end
        return n
    end

    -- Appends the records with on_remove hooks among the ids of word k of a signature (rare
    -- path of run_remove_hooks: records beyond the shared signature tables).
    local function collect_hooked(slot: number, buffer: { Record }, n: number, k: number, mask: number): number
        local base = (k - 1) * 32 + 1
        repeat
            local rec = by_index[base + countrz(mask)]
            mask = band(mask, mask - 1)
            if rec.kind == KIND_RELATION then
                n = collect_pairs(rec, slot, buffer, n)
            elseif rec.on_remove then
                n += 1
                buffer[n] = rec
            end
        until mask == 0
        return n
    end

    -- Runs the on_remove hooks of the ids of a slot. clear_slot found the first word of the
    -- signature with hooked ids: word k0 of the shared tables with the hooked bits mask0, the
    -- words of hooked_list after its place j0, or k0 = 0 when only `more` (sig_more[slot]) has
    -- them. Returns false when a hook deleted the entity.
    -- Every id that the entity has is notified once. The records stay in the buffer of the clear
    -- until its hooks have all run, notified up to the place of the hook that runs: a removal of
    -- one of them that a later hook starts does nothing (the clear removes it), and a nested
    -- clear or delete of the entity does not notify them again (see removal_runs). An id that
    -- the hooks give the entity meanwhile goes with the others, without its hooks.
    local function run_remove_hooks(
        entity: i53,
        slot: number,
        deleting: boolean?,
        more: Words?,
        k0: number,
        mask0: number,
        j0: number
    ): boolean
        local depth = clear_depth + 1
        clear_depth = depth
        clearing[depth] = entity
        local buffer = clear_buffers[depth]
        if not buffer then
            buffer = {}
            clear_buffers[depth] = buffer
        end
        local masks = if deleting then hooked_delete else hooked
        local n = 0
        local k, mask = k0, mask0
        while true do
            if mask ~= 0 then
                -- collect_hooked, inline for the shared signature tables
                local index = (k - 1) * 32 + 1
                repeat
                    local rec = by_index[index + countrz(mask)]
                    mask = band(mask, mask - 1)
                    if rec.kind == KIND_RELATION then
                        n = collect_pairs(rec, slot, buffer, n)
                    elseif rec.on_remove then
                        n += 1
                        buffer[n] = rec
                    end
                until mask == 0
            end
            -- the next word with hooked bits, until the end of the list
            j0 += 1
            k = hooked_list[j0]
            if k == nil then
                break
            end
            mask = band(sig_flat[k][slot] or 0, masks[k])
        end
        if more then
            for more_k, word in more do
                local hooked_bits = band(word, masks[more_k] or 0)
                if hooked_bits ~= 0 then
                    n = collect_hooked(slot, buffer, n, more_k, hooked_bits)
                end
            end
        end
        -- An id whose removal from the entity runs already is skipped: further out (its hooks
        -- notify it) or in an outer clear of the entity (see removal_runs). A clear that neither
        -- can concern checks nothing (and its place is set by its first hook, before anything
        -- reads it).
        local frame = buffer :: any
        local check = removing[1] ~= nil
        if not check then
            for d = 1, depth - 1 do
                if clearing[d] == entity then
                    check = true
                    break
                end
            end
        end
        if check then
            frame.at = 0
        end
        local w = slot // 32 + 1
        local bit = lshift(1, slot % 32)
        for i = 1, n do
            local rec = buffer[i]
            local on_remove = rec.on_remove
            -- an earlier hook may have removed the id (its hook ran then) or the entity
            if on_remove and alive[slot] == entity then
                local word = rec.words[w]
                if word ~= nil and band(word, bit) ~= 0 and not (check and removal_runs(entity, rec)) then
                    frame.at = i
                    on_remove(entity, rec.id, deleting)
                    continue
                end
            end
            buffer[i] = false :: any -- not notified by this clear
        end
        for i = 1, n do
            buffer[i] = nil :: any
        end
        clearing[depth] = nil :: any
        clear_depth = depth - 1
        return alive[slot] == entity
    end

    -- Removes a pair of a slot from its record (the relation and target records are updated
    -- by the caller, and the caller frees the empty pair records when it is done).
    -- (the callers update the mirrors of the targets, see mirror.dropped: a function this small is
    -- inlined at its call sites)
    local function drop_pair(rec: Record, slot: number)
        bit_clear(rec, slot)
        if rec.word_count == 0 then
            note_empty_pair(rec)
        end
        local pages = rec.pages
        if pages then
            local page = pages[slot // PAGE_SIZE + 1]
            if page then
                page[slot % PAGE_SIZE + 1] = nil
            end
        end
        target_remove(rec.wc_tgt :: Record, slot)
    end

    -- Removes every pair (R, *) of a slot, given its relation record.
    local function drop_relation(rec: Record, slot: number)
        local slot_pairs = rec.slot_pairs :: { [number]: { Record } }
        local list = slot_pairs[slot]
        if list then
            slot_pairs[slot] = nil
            for _, pair_rec in list do
                drop_pair(pair_rec, slot)
            end
            if mirror_count > 0 then
                mirror.dropped(rec, list, slot)
            end
        else
            local pair_rec = (rec.slot_pair :: { [number]: Record })[slot]
            drop_pair(pair_rec, slot)
            if mirror_count > 0 then
                mirror.dropped(rec, { pair_rec }, slot)
            end
        end
        (rec.slot_pair :: { [number]: Record })[slot] = nil
        bit_clear(rec, slot)
    end

    -- Removes every id of the slot. on_remove hooks run first (once, whichever part of the
    -- signature holds the hooked ids), while all values are present; the removal then reads
    -- the signature again, because hooks may change the entity. Returns whether hooks ran:
    -- without them no code outside the library ran, and the entity lives as it did.
    local function clear_slot(entity: i53, slot: number, deleting: boolean?): boolean
        local more = sig_more[slot]
        local masks = if deleting then hooked_delete else hooked
        -- the first word with hooked ids (see run_remove_hooks), among the words of the world
        -- that have hooked bits
        local k0, mask0, j0 = 0, 0, 0
        for j, k in hooked_list do
            local mask = sig_flat[k][slot]
            if mask then
                mask = band(mask, masks[k])
                if mask ~= 0 then
                    k0, mask0, j0 = k, mask, j
                    break
                end
            end
        end
        local hooks = k0 ~= 0
        if not hooks and more then
            for k, mask in more do
                if band(mask, masks[k] or 0) ~= 0 then
                    hooks = true
                    j0 = #hooked_list -- only `more` has hooked ids
                    break
                end
            end
        end
        if hooks then
            if not run_remove_hooks(entity, slot, deleting, more, k0, mask0, j0) then
                return true
            end
            more = sig_more[slot]
        end
        -- The ids of the entity go now. Within the hooks of a clear or of a removal (both stacks
        -- are empty otherwise, see removing): the removals of them that run (whose hooks cleared
        -- or deleted the entity) have nothing left to do, their entries in `removing` end, so
        -- that an id given to the entity again afterwards is a new one, notified when it goes.
        if clear_depth ~= 0 or removing[1] ~= nil then
            for k = 1, #removing, 2 do
                if removing[k] == entity then
                    removing[k + 1] = 0
                end
            end
            -- An outer clear of the entity (a hook of it cleared or deleted the entity again):
            -- what it notified is gone, and an id given back since is a new one, which a removal
            -- notifies.
            for d = 1, clear_depth do
                if clearing[d] == entity then
                    local frame = clear_buffers[d] :: any
                    for i = 1, frame.at do
                        frame[i] = false
                    end
                end
            end
        end
        local w = slot // 32 + 1
        local bit = lshift(1, slot % 32)
        local page_index = slot // PAGE_SIZE + 1
        local page_slot = slot % PAGE_SIZE + 1
        for k = 1, sig_flat_used do
            local st = sig_flat[k]
            local mask = st[slot]
            if mask and mask ~= 0 then
                st[slot] = 0
                local base = (k - 1) * 32 + 1
                repeat
                    local rec = by_index[base + countrz(mask)]
                    mask = band(mask, mask - 1)
                    if rec.kind == KIND_RELATION then
                        -- the pairs of the relation, then the relation record itself
                        local list = (rec.slot_pairs :: { [number]: { Record } })[slot]
                        if list then
                            (rec.slot_pairs :: { [number]: { Record } })[slot] = nil
                            (rec.slot_pair :: { [number]: Record })[slot] = nil
                            for _, pair_rec in list do
                                -- drop_pair, inline with the word and the page of the slot
                                local words = pair_rec.words
                                local word = words[w] - bit
                                if word ~= 0 then
                                    words[w] = word
                                else
                                    word_last(pair_rec, w)
                                    if pair_rec.word_count == 0 then
                                        note_empty_pair(pair_rec)
                                    end
                                end
                                local version = pair_rec.version + 1 -- note(pair_rec, slot), inline
                                pair_rec.version = version
                                if pair_rec.journal then
                                    journal_write(pair_rec, version, slot)
                                end
                                local pages = pair_rec.pages
                                if pages then
                                    local page = pages[page_index]
                                    if page then
                                        page[page_slot] = nil
                                    end
                                end
                                target_remove(pair_rec.wc_tgt :: Record, slot)
                            end
                            if mirror_count > 0 then
                                mirror.dropped(rec, list, slot)
                            end
                        else
                            local slot_pair = rec.slot_pair :: { [number]: Record }
                            local pair_rec = slot_pair[slot]
                            slot_pair[slot] = nil
                            local words = pair_rec.words
                            local word = words[w] - bit
                            if word ~= 0 then
                                words[w] = word
                            else
                                word_last(pair_rec, w)
                                if pair_rec.word_count == 0 then
                                    note_empty_pair(pair_rec)
                                end
                            end
                            note(pair_rec, slot)
                            local pages = pair_rec.pages
                            if pages then
                                local page = pages[page_index]
                                if page then
                                    page[page_slot] = nil
                                end
                            end
                            target_remove(pair_rec.wc_tgt :: Record, slot)
                            if mirror_count > 0 then
                                mirror.dropped(rec, { pair_rec }, slot)
                            end
                        end
                    end
                    local words = rec.words
                    local word = words[w] - bit
                    if word ~= 0 then
                        words[w] = word
                    else
                        word_last(rec, w)
                    end
                    note(rec, slot)
                    local pages = rec.pages
                    if pages then
                        local page = pages[page_index]
                        if page then
                            page[page_slot] = nil
                        end
                    end
                until mask == 0
            end
        end
        if more then
            sig_more[slot] = nil
            for k, mask in more do
                local base = (k - 1) * 32 + 1
                while mask ~= 0 do
                    local rec = by_index[base + countrz(mask)]
                    mask = band(mask, mask - 1)
                    -- a relation drops its pairs, a plain id its bit and its value
                    if rec.kind == KIND_RELATION then
                        drop_relation(rec, slot)
                    else
                        bit_clear(rec, slot)
                        local pages = rec.pages
                        if pages then
                            local page = pages[slot // PAGE_SIZE + 1]
                            if page then
                                page[slot % PAGE_SIZE + 1] = nil
                            end
                        end
                    end
                end
            end
        end
        if empty_pair_count > EMPTY_PAIRS then
            free_empty_pairs()
        end
        return hooks
    end

    -- Whether the slot has any id (its signature is not empty).
    local function slot_has_ids(slot: number): boolean
        for k = 1, sig_flat_used do
            local mask = sig_flat[k][slot]
            if mask and mask ~= 0 then
                return true
            end
        end
        local more = sig_more[slot]
        if more then
            for _, mask in more do
                if mask ~= 0 then
                    return true
                end
            end
        end
        return false
    end

    local function world_clear(_: any, entity: i53)
        local slot = entity % ENTITY_MASK
        if alive[slot] ~= entity then
            return
        end
        clear_slot(entity, slot, nil)
    end

    -- Entities that have the id of a record (collected, so the caller may change the world).
    local function members_of(rec: Record): { i53 }
        local list: { i53 } = {}
        local n = 0
        local words = rec.words
        for sw, sum in rec.sums do
            if sw < 1 then
                continue -- a top word
            end
            local mask = sum
            while mask ~= 0 do
                local w = (sw - 1) * 32 + countrz(mask) + 1
                mask = band(mask, mask - 1)
                local word = words[w]
                if word then
                    local base = (w - 1) * 32
                    repeat
                        local e = alive[base + countrz(word)]
                        word = band(word, word - 1)
                        if e > 0 then
                            n += 1
                            list[n] = e
                        end
                    until word == 0
                end
            end
        end
        return list
    end

    -- Removes an id from every entity that has it. Without on_remove hooks the bitsets and
    -- values of the id are dropped at once and only the signatures are updated per entity
    -- (one-frame tags: world:remove_all(Hit)); otherwise each entity goes through remove.
    local function world_remove_all(_: any, id: i53)
        local rec = records[id]
        if rec and rec.kind == KIND_TARGET then
            target_materialize(rec)
        end
        if rec == nil or rec.word_count == 0 then
            return
        end
        if rec.kind ~= KIND_PLAIN or rec.on_remove then
            for _, member in members_of(rec) do
                world_remove(world, member, id)
            end
            return
        end
        local st, sig_bit = rec.sig_table, rec.sig_bit
        local words = rec.words
        for sw, sum in rec.sums do
            if sw < 1 then
                continue -- a top word
            end
            local mask = sum
            while mask ~= 0 do
                local w = (sw - 1) * 32 + countrz(mask) + 1
                mask = band(mask, mask - 1)
                local word = words[w]
                local base = (w - 1) * 32
                while word ~= 0 do
                    local slot = base + countrz(word)
                    word = band(word, word - 1)
                    if st then
                        st[slot] -= sig_bit
                    else
                        sig_more_remove(rec, slot)
                    end
                end
            end
        end
        table.clear(words)
        table.clear(rec.sums)
        rec.word_count = 0
        rec.zeros = 0
        -- many slots at once: no journal entry, the queries of the id scan it again
        rec.version += 1
        changes_stamp += 1
        local pages = rec.pages
        if pages then
            table.clear(pages)
        end
    end

    local world_delete: (_: any, entity: i53) -> ()
    -- change tracking (see world:track): the tick, the bitsets of all tracked ids and their
    -- words, and the last tick a change of each slot was recorded in
    local current_tick = 1
    local track_rings: { Record } = {}
    local track_words: { Words } = {}
    local last_marked: { [number]: number } = {}

    -- Removes the id of a record from its members (members_of) before the record is freed:
    -- only the member side (signature, relation and target records) is updated; values go with
    -- the record. `deleting` goes to the on_remove hook: true for members that are deleted
    -- next (see cleanup_record).
    local function strip_members(rec: Record, members: { i53 }, deleting: boolean?)
        local id = rec.id
        local is_pair = rec.kind == KIND_PAIR
        local on_remove = rec.on_remove
        for _, member in members do
            local slot = member % ENTITY_MASK
            if on_remove then
                -- An earlier member's hook may have removed this id or deleted the member
                -- (and even reused its slot). Its removal was already reported there.
                if alive[slot] ~= member or not bit_test(rec, slot) then
                    continue
                end
                -- Disconnecting the last listener and reconnecting creates a new
                -- dispatcher. The next member is a new event and must use that dispatcher.
                local callback = rec.on_remove
                if callback then
                    -- (a removal of the id from the member that runs has notified it)
                    local pending = (removing[1] ~= nil or clear_depth > 0) and removal_runs(member, rec)
                    if not pending then
                        local top = #removing
                        removing[top + 1] = member
                        removing[top + 2] = id
                        callback(member, id, deleting)
                        local completed = removing[top + 2] ~= id
                        removing[top + 2] = nil
                        removing[top + 1] = nil
                        if completed then
                            -- a clear of the member removed the id: one given back since is a
                            -- new member, which a next round of the cleanup notifies
                            continue
                        end
                    end
                end
                if alive[slot] ~= member or not bit_test(rec, slot) then
                    continue
                end
                -- keep the record consistent for the hooks of the next members: the bit and the
                -- value go (a value without its bit would read as present)
                bit_clear(rec, slot)
                local pages = rec.pages
                if pages then
                    local page = pages[slot // PAGE_SIZE + 1]
                    if page then
                        page[slot % PAGE_SIZE + 1] = nil
                    end
                end
            end
            if is_pair then
                pair_detach(rec, slot)
            else
                sig_remove(rec, slot)
            end
        end
    end

    -- Cascading deletes recurse: the members of a deleted id are deleted inside the delete of
    -- the id. Past MAX_DELETE_DEPTH nested levels the members leave the id and are queued
    -- instead, and deleted once the outermost delete has cleaned up, so deleting a very deep
    -- hierarchy cannot overflow the stack.
    local delete_depth = 0
    local deferred: { i53 } = {}
    local draining = false

    local function drain_deferred()
        if draining then
            return
        end
        draining = true
        while true do
            local n = #deferred
            if n == 0 then
                break
            end
            local e = deferred[n]
            deferred[n] = nil
            world_delete(world, e)
        end
        draining = false
    end

    -- Deletes the members of a record, or removes the id from them; then frees the record.
    local function cleanup_record(rec: Record, delete: boolean)
        -- A hook that runs here (a removal listener of the id, a hook of a deleted member) may
        -- give the id to more entities: they are cleaned up as well, until the record has no
        -- member, so that no signature keeps the index of the freed record. Without a hook of
        -- the id, a removal (the last branch) runs no code and leaves the bits of the record as
        -- they are; then no member can be new.
        for round = 1, 101 do
            if round > 100 then
                error("hooks keep giving an id to entities while it is deleted", 0)
            end
            local has_hook = rec.on_remove ~= nil
            local stripped = not delete
            if delete then
                if delete_depth >= MAX_DELETE_DEPTH then
                    -- the members are deleted after the record is freed: they leave it now, so
                    -- that none of them keeps its signature bit or a reference to it (the
                    -- on_remove hook of the id runs for them now, as for deleted entities)
                    local members = members_of(rec)
                    table.move(members, 1, #members, #deferred + 1, deferred)
                    strip_members(rec, members, true)
                    stripped = true
                else
                    delete_depth += 1
                    for _, member in members_of(rec) do
                        world_delete(world, member)
                    end
                    delete_depth -= 1
                end
            else
                strip_members(rec, members_of(rec), nil)
            end
            if rec.word_count == 0 or (stripped and not has_hook) then
                break
            end
        end
        free_record(rec)
    end

    -- Applies cleanup policies for an entity that is used as an id, relation or target. A hook
    -- that runs meanwhile may delete the entity (that delete cleans up its uses) and give its
    -- slot to a new entity: the records of the slot are then those of the new one, and the
    -- cleanup stops.
    local function cleanup_ids(entity: i53, delete_policy: boolean)
        local slot = entity % ENTITY_MASK
        -- the entity used as a component or tag
        local rec = records[entity]
        if rec then
            cleanup_record(rec, delete_policy)
            if alive[slot] ~= entity then
                return
            end
        end

        -- The entity used as a relation, then as a target. A cleaned pair record leaves the pairs
        -- of both; the hooks of the cleanup may make new pairs with the entity meanwhile, which
        -- another round cleans, until none is left.
        -- the entity used as a relation: pairs (entity, *)
        local relation_rec = records[ECS_PAIR(entity, EcsWildcard)]
        if relation_rec then
            local pairs_of = relation_rec.pairs :: { [i53]: Record }
            local rounds = 0
            while next(pairs_of) ~= nil do
                rounds += 1
                if rounds > 100 then
                    error("hooks keep making pairs of an entity while it is deleted", 0)
                end
                local list: { Record } = {}
                for _, pair_rec in pairs_of do
                    table.insert(list, pair_rec)
                end
                for _, pair_rec in list do
                    cleanup_record(pair_rec, delete_policy)
                    if alive[slot] ~= entity then
                        return
                    end
                end
            end
            free_record(relation_rec)
        end

        -- the entity used as a target: pairs (*, entity)
        local target_rec = records[ECS_PAIR(EcsWildcard, entity)]
        if target_rec then
            local pairs_of = target_rec.pairs :: { [i53]: Record }
            local outer = dying_target
            dying_target = target_rec
            local rounds = 0
            while next(pairs_of) ~= nil do
                rounds += 1
                if rounds > 100 then
                    error("hooks keep making pairs of an entity while it is deleted", 0)
                end
                local list: { Record } = {}
                for _, pair_rec in pairs_of do
                    table.insert(list, pair_rec)
                end
                for _, pair_rec in list do
                    cleanup_record(
                        pair_rec,
                        world_has_pair(pair_rec.relation :: i53, ECS_PAIR(EcsOnDeleteTarget, EcsDelete))
                    )
                    if alive[slot] ~= entity then
                        dying_target = outer
                        return
                    end
                end
            end
            dying_target = outer
            free_record(target_rec)
        end
    end

    function world_delete(_: any, entity: i53)
        local slot = entity % ENTITY_MASK
        if alive[slot] ~= entity then
            return
        end
        -- the cleanup policy of the entity itself is one of its own ids: read it first (id_used:
        -- true for an entity used as an id, false while its uses are cleaned up)
        local used = id_used[slot]
        local delete_policy = used ~= nil and world_has_pair(entity, ECS_PAIR(EcsOnDelete, EcsDelete))
        -- the floor of the generations of the slot, taken with the uses (see floors)
        local floor: number? = nil
        if clear_slot(entity, slot, true) then
            if alive[slot] ~= entity then
                return -- deleted by a hook
            end
            -- The hooks may have used the entity as an id for the first time (giving it to another
            -- entity): those uses go by the default policy, its own ids being gone. A used entity
            -- stays used while it lives (only the end of its delete clears the flag).
            used = id_used[slot]
        end
        if used ~= nil then
            -- The uses of the entity as an id go. The hooks that run meanwhile may use it as an id
            -- again (a new record sets the flag back to true) or give it ids again (a child that
            -- writes into its parent while the parent is deleted): they go as well, in more
            -- rounds, or the freed slot would keep them for the entity that reuses it. The flag
            -- stays false while a round runs: an error that stops it leaves the cleanup to the
            -- next delete.
            local rounds = 0
            repeat
                rounds += 1
                if rounds > 100 then
                    error("hooks keep giving an entity ids or uses while it is deleted", 0)
                end
                id_used[slot] = false
                cleanup_ids(entity, delete_policy == true)
                if alive[slot] == entity then
                    -- the shared query shapes that have the id can never match again (a hook that
                    -- deleted the entity pruned them, and the slot may be another entity's now)
                    prune_shapes(shapes, slot)
                end
                if delete_depth == 0 and deferred[1] ~= nil then
                    drain_deferred()
                end
                if alive[slot] ~= entity then
                    return -- deleted by a hook
                end
                if slot_has_ids(slot) then
                    clear_slot(entity, slot, true)
                    if alive[slot] ~= entity then
                        return -- deleted by a hook
                    end
                end
            until id_used[slot] ~= true
            id_used[slot] = nil
            -- the hooks that the dispatchers of the id kept for the cleanup of its members go: the
            -- id, when it lives again (world:entity, or after the generations of its slot went
            -- round), has none of them (its signal listeners stay connected, see connect)
            for _, cells in dispatched_hooks do
                local cell = cells[entity]
                if cell then
                    cell.hook = nil
                end
            end
            floor = floors[slot]
            if floor ~= nil then
                floors[slot] = nil
            end
        end
        -- (the rounds above end with the entity alive and its uses gone: query shapes that a
        -- hook made with the entity marked it used again, and went with the next round)
        local marked = last_marked[slot]
        if marked then
            last_marked[slot] = nil
        end
        if marked and marked > current_tick - TRACK_TICKS then
            -- the slot may be reused by a new entity, which must not inherit the recorded
            -- changes of this one (nor may a change filter return a dead entity)
            local w = slot // 32 + 1
            local bit = lshift(1, slot % 32)
            for i = 1, #track_words do
                local word = track_words[i][w]
                if word and band(word, bit) ~= 0 then
                    local rec = track_rings[i]
                    if word == bit then
                        word_last(rec, w)
                    else
                        rec.words[w] = word - bit
                    end
                    rec.version += 1
                end
            end
        end
        local generation = entity // ENTITY_MASK + 1
        if generation >= GENERATION_MASK then
            generation = 0
        end
        if floor ~= nil then
            generation = floor
        end
        -- the free slot holds the negative of its next id + 1 (see world:entity)
        local next_id = slot + generation * ENTITY_MASK
        local dead = -1 - next_id
        alive[slot] = dead
        -- the monitors that still count the entity see it leave before the slot can go to a new
        -- entity (see Query.monitor); a callback that disconnects monitors is safe, and one that
        -- makes an entity of the slot keeps it (the slot is not free then)
        local monitors = monitoring.list
        if monitors[1] ~= nil then
            local w = slot // 32 + 1
            local bit = lshift(1, slot % 32)
            for i = #monitors, 1, -1 do
                local monitor = monitors[i]
                if monitor then
                    monitor.leave(entity, w, bit)
                end
            end
            if alive[slot] ~= dead then
                return
            end
        end
        -- a slot outside the range of the world (an id of another world that world:entity(id)
        -- made alive, or a slot taken before world:range) is not given to a new entity: it stays
        -- off the free lists of the world and of its pools
        local bounds = range
        if bounds == nil or (slot > bounds[1] and slot < bounds[2]) then
            local pool = if has_pools then block_pool[slot // POOL_BLOCK] else nil
            if pool then
                local count = pool.count + 1
                pool.count = count
                pool.free[count] = next_id
            else
                free_count += 1
                free[free_count] = next_id
            end
        end
    end

    ----------------------------------------------------------------------------
    -- entities and ids
    ----------------------------------------------------------------------------

    local function world_entity(_: any, id: i53?): i53
        if id == nil then
            -- (the creation is marked here, not in new_slot: a function that small is inlined)
            if mark_created then
                local e = new_slot()
                mark_created(e % ENTITY_MASK)
                return e
            end
            return new_slot()
        end
        local slot = id % ENTITY_MASK
        if alive[slot] == id then
            return id
        end
        if slot > max_slot then
            -- the slots skipped before it are free for new ids (inside the range only), pushed
            -- from the last one: world:entity() takes them in ascending order
            local bounds = range
            for s = slot - 1, max_slot + 1, -1 do
                alive[s] = -1 - s
                if bounds == nil or (s > bounds[1] and s < bounds[2]) then
                    free_count += 1
                    free[free_count] = s
                end
            end
            max_slot = slot
        else
            -- The owner of the slot is deleted first. The hooks of that delete may make a new
            -- entity in the freed slot (or make the id alive themselves): it goes as well, until
            -- the slot is free.
            local current = alive[slot]
            local rounds = 0
            while current > 0 do
                if current == id then
                    return id
                end
                rounds += 1
                if rounds > 100 then
                    error("hooks keep making entities in the slot of an explicit id", 2)
                end
                world_delete(world, current)
                current = alive[slot]
            end
            -- the slot leaves the free list it is on: its pool's or the world's
            local pool = if has_pools then block_pool[slot // POOL_BLOCK] else nil
            if pool then
                local list = pool.free
                for i = pool.count, 1, -1 do
                    if list[i] % ENTITY_MASK == slot then
                        table.remove(list, i)
                        pool.count -= 1
                        break
                    end
                end
            else
                for i = free_count, 1, -1 do
                    if free[i] % ENTITY_MASK == slot then
                        table.remove(free, i)
                        free_count -= 1
                        break
                    end
                end
            end
            -- an older generation than the newest one of the slot (its marker holds the next id,
            -- see world_delete): the generations after it stay dead (see floors)
            local next_generation = (-1 - current) // ENTITY_MASK
            if id // ENTITY_MASK + 1 < next_generation then
                floors[slot] = next_generation
                id_used[slot] = true -- (its delete takes the floor, see world_delete)
            end
        end
        alive[slot] = id
        if mark_created then
            mark_created(slot)
        end
        return id
    end

    -- Reserves the next aligned block of POOL_BLOCK slots after max_slot for a pool; the slots
    -- skipped before it go to the free list of the world.
    local function pool_reserve(pool: PoolState)
        local block = max_slot // POOL_BLOCK + 1
        local first = block * POOL_BLOCK
        local last = first + POOL_BLOCK - 1
        if range and last >= range[2] then
            last = range[2] - 1
            if last < first then
                error("entity id is outside the range set by world:range", 3)
            end
        end
        -- pushed from the last slot: world:entity() takes them in ascending order
        for s = first - 1, max_slot + 1, -1 do
            alive[s] = -1 - s
            free_count += 1
            free[free_count] = s
        end
        local list = pool.free
        local count = pool.count
        -- pushed from the last slot: the pool hands out its slots in ascending order
        for s = last, first, -1 do
            alive[s] = -1 - s
            count += 1
            list[count] = s
        end
        pool.count = count
        max_slot = last
        block_pool[block] = pool
    end

    local function world_pool(_: any): any
        has_pools = true
        local pool: PoolState = { free = {}, count = 0 }
        return {
            entity = function(_: any): i53
                local count = pool.count
                if count == 0 then
                    pool_reserve(pool)
                    count = pool.count
                end
                local list = pool.free
                local e = list[count]
                list[count] = nil
                pool.count = count - 1
                alive[e % ENTITY_MASK] = e
                if mark_created then
                    mark_created(e % ENTITY_MASK)
                end
                return e
            end,
        }
    end

    local max_component_id = preregistered_components

    local function world_component(_: any): i53
        local id: i53
        if max_component_id < HI_COMPONENT_ID then
            max_component_id += 1
            id = max_component_id
        else
            id = new_slot()
        end
        world_add(world, id, EcsComponent)
        return id
    end

    local function world_contains(_: any, entity: i53): boolean
        return alive[entity % ENTITY_MASK] == entity
    end

    -- True when the slot of the entity was ever used (also after deletion).
    local function world_exists(_: any, entity: i53): boolean
        return alive[entity % ENTITY_MASK] ~= nil
    end

    local function world_range(_: any, range_begin: number, range_end: number?)
        local bounds = { range_begin, range_end or math.huge }
        range = bounds
        -- the free slots outside the range, of the world and of its pools, are not for new ids
        -- any more (a pool of several blocks is filtered once per block: the next passes keep
        -- all of its slots)
        free_count = keep_in_range(free, free_count, bounds)
        for _, pool in block_pool do
            pool.count = keep_in_range(pool.free, pool.count, bounds)
        end
        if range_begin > max_slot then
            for s = max_slot + 1, range_begin do
                alive[s] = -1 - s
            end
            max_slot = range_begin
        end
    end

    ----------------------------------------------------------------------------
    -- relationships
    ----------------------------------------------------------------------------

    local function world_target(_: any, entity: i53, relation: i53, index: number?): i53?
        local slot = entity % ENTITY_MASK
        if alive[slot] ~= entity then
            return nil
        end
        local wc = records[ECS_PAIR(relation, EcsWildcard)]
        if wc == nil then
            return nil
        end
        local slot_pair = wc.slot_pair
        if slot_pair == nil then
            return nil
        end
        local pair_rec: Record?
        if index == nil or index == 0 then
            pair_rec = slot_pair[slot]
        else
            local list = (wc.slot_pairs :: { [number]: { Record } })[slot]
            pair_rec = if list then list[index + 1] else nil
        end
        return if pair_rec then pair_rec.target else nil
    end

    local function world_targets(_: any, entity: i53, relation: i53): () -> i53?
        local slot = entity % ENTITY_MASK
        local wc = records[ECS_PAIR(relation, EcsWildcard)]
        if alive[slot] ~= entity or wc == nil or wc.slot_pair == nil then
            return NOOP
        end
        local first = (wc.slot_pair :: { [number]: Record })[slot]
        if first == nil then
            return NOOP
        end
        local list: { i53 } = {}
        local all = (wc.slot_pairs :: { [number]: { Record } })[slot]
        if all then
            for i, pair_rec in all do
                list[i] = pair_rec.target :: i53
            end
        else
            list[1] = first.target :: i53
        end
        local i = 0
        return function(): i53?
            i += 1
            return list[i]
        end
    end

    local function world_parent(_: any, entity: i53): i53?
        local slot = entity % ENTITY_MASK
        local pairs_of = childof_pairs
        if pairs_of == nil or alive[slot] ~= entity then
            return nil
        end
        local pair_rec = pairs_of[slot]
        return if pair_rec then pair_rec.target else nil
    end

    -- world:each and world:children: the members of the id at the start of the loop, in
    -- ascending slot order, whatever their number and their layout, collected into a buffer of
    -- each_pool that the loop reads: a reused buffer costs only the iterator closure. A record of a few words
    -- (at most EACH_FEW_WORDS keys, emptied ones included, and no more words emptied since its
    -- zeros were dropped than non-empty words) has its non-empty keys sorted (a sparse id, the
    -- children of a parent: fewer steps than the levels of the bitset); a larger one, or one whose
    -- members keep moving to other words (a state tag of a small world, where the levels of the
    -- bitset reach its few non-empty words in fewer steps than its emptied keys take), is walked
    -- through its tops, its sums and its words, a full word copied at once. Nothing that changes
    -- during the loop changes what it returns: an entity that gets the id is not visited, one
    -- that loses it is visited, one deleted before the loop reaches it is returned as a dead id.
    local function iterate_record(rec: Record?): () -> i53?
        if rec and rec.kind == KIND_TARGET then
            target_materialize(rec)
        end
        if rec == nil or rec.word_count == 0 then
            return NOOP
        end
        local words = rec.words
        local word_count = rec.word_count
        if word_count == 1 and rec.zeros == 0 then
            local w, word = next(words)
            local bits = word :: number
            if band(bits, bits - 1) == 0 then
                -- one member (a pair with one holder, a parent with one child): no buffer
                local only: i53? = alive[((w :: number) - 1) * 32 + countrz(bits)]
                return function(): i53?
                    local e = only
                    only = nil
                    return e
                end
            end
        end
        local list = each_take()
        local n = 0
        local sums = rec.sums
        local zeros = rec.zeros
        -- the keys path visits at most twice the non-empty words
        if zeros <= word_count and word_count + zeros <= EACH_FEW_WORDS then
            local keys = each_words
            local k = word_count
            if word_count <= 2 and zeros == 0 then
                -- one or two words: in order without a sort
                local w1 = (next(words)) :: number
                keys[1] = w1
                if word_count == 2 then
                    local w2 = (next(words, w1)) :: number
                    if w2 < w1 then
                        keys[1], keys[2] = w2, w1
                    else
                        keys[2] = w2
                    end
                end
            else
                table.clear(keys)
                k = 0
                if zeros == 0 then
                    -- Clean records keep the branch-free key collection of 0.2.3.
                    for w in words do
                        k += 1
                        keys[k] = w
                    end
                else
                    for w, word in words do
                        if word ~= 0 then
                            k += 1
                            keys[k] = w
                        end
                    end
                end
                table.sort(keys)
            end
            for j = 1, k do
                local w = keys[j]
                local word = words[w]
                local base = (w - 1) * 32
                if word == FULL_WORD then
                    -- 32 members: copied at once (the slot of a member is always alive)
                    table.move(alive, base, base + 31, n + 1, list)
                    n += 32
                else
                    while word ~= 0 do
                        n += 1
                        list[n] = alive[base + countrz(word)]
                        word = band(word, word - 1)
                    end
                end
            end
        else
            -- (a bit of a level always has its word below it)
            for tw = 1, max_slot // TOP_SLOTS + 1 do
                local t = sums[-tw] or 0
                local sw_base = (tw - 1) * 32 + 1
                while t ~= 0 do
                    local sw = sw_base + countrz(t)
                    t = band(t, t - 1)
                    local sum = sums[sw]
                    local w_base = (sw - 1) * 32 + 1
                    while sum ~= 0 do
                        local w = w_base + countrz(sum)
                        sum = band(sum, sum - 1)
                        local word = words[w]
                        local base = (w - 1) * 32
                        if word == FULL_WORD then
                            table.move(alive, base, base + 31, n + 1, list)
                            n += 32
                        else
                            while word ~= 0 do
                                n += 1
                                list[n] = alive[base + countrz(word)]
                                word = band(word, word - 1)
                            end
                        end
                    end
                end
            end
        end
        -- the end of the members (a reused buffer holds older ones after it)
        list[n + 1] = nil
        if n + 1 > (list[0] or 0) then
            -- Include the terminating nil: assigning it can grow a full array.
            list[0] = 2 ^ (32 - bit32.countlz(n))
        end
        local i = 0
        return function(): i53?
            i += 1
            local e = list[i]
            if e ~= nil then
                return e
            end
            if i > 0 then
                -- the end of the loop: the buffer goes back, once
                i = -math.huge
                each_release(list)
            end
            return nil
        end
    end

    -- Every id of an entity: the records of its signature, with the pairs of each relation
    -- record (R, *) in place of the record itself. Sorted ascending.
    local function world_ids(_: any, entity: i53): { i53 }
        local slot = entity % ENTITY_MASK
        local list: { i53 } = {}
        if alive[slot] ~= entity then
            return list
        end
        local function add_word(k: number, mask: number)
            local base = (k - 1) * 32 + 1
            while mask ~= 0 do
                local rec = by_index[base + countrz(mask)]
                mask = band(mask, mask - 1)
                if rec.kind == KIND_RELATION then
                    local all = (rec.slot_pairs :: { [number]: { Record } })[slot]
                    if all then
                        for _, pair_rec in all do
                            table.insert(list, pair_rec.id)
                        end
                    else
                        table.insert(list, ((rec.slot_pair :: { [number]: Record })[slot]).id)
                    end
                else
                    table.insert(list, rec.id)
                end
            end
        end
        for k = 1, sig_flat_used do
            local mask = sig_flat[k][slot]
            if mask then
                add_word(k, mask)
            end
        end
        local more = sig_more[slot]
        if more then
            for k, mask in more do
                add_word(k, mask)
            end
        end
        table.sort(list)
        return list
    end

    local function world_each(_: any, id: i53): () -> i53?
        return iterate_record(records[id])
    end

    local function world_children(_: any, parent: i53): () -> i53?
        return iterate_record(records[ECS_PAIR(EcsChildOf, parent)])
    end

    ----------------------------------------------------------------------------
    -- hooks and signals
    ----------------------------------------------------------------------------

    -- Internal hooks of builtin ids (the hook components and Exclusive, see bootstrap), per
    -- hook field: the record of such an id calls its internal hook first and then the hook or
    -- the signal dispatcher of the id, which never replace the internal one (chain_hooks).
    local internal_hooks: { [string]: { [i53]: Hook } } = { on_add = {}, on_change = {}, on_remove = {} }

    -- Gives the records of an id (and of its pairs, for a relation) their callback. Only those
    -- of a live id: a deleted one has no records, and the pairs of its slot belong to the entity
    -- that took the slot (a pair keeps only the slots of its elements).
    local function install_hook(entity: i53, field: string, value: Hook?)
        if alive[entity % ENTITY_MASK] ~= entity then
            return
        end
        local rec = records[entity]
        if rec then
            local callback = chain_hooks(internal_hooks[field][entity], value);
            (rec :: any)[field] = callback
            if field == "on_remove" then
                set_hooked(rec, callback ~= nil)
            end
        end
        local wc = records[ECS_PAIR(entity, EcsWildcard)]
        if wc and wc.pairs then
            for _, pair_rec in wc.pairs :: { [i53]: Record } do
                (pair_rec :: any)[field] = value
            end
            if field == "on_remove" then
                set_hooked(wc, value ~= nil)
            end
        end
    end

    -- The hooked masks of the records of an id after its dispatcher changed (a live id, see
    -- install_hook).
    local function refresh_hooked(id: i53)
        if alive[id % ENTITY_MASK] ~= id then
            return
        end
        local rec = records[id]
        if rec then
            set_hooked(rec, rec.on_remove ~= nil)
        end
        local wc = records[ECS_PAIR(id, EcsWildcard)]
        if wc and wc.kind == KIND_RELATION then
            set_hooked(wc, hook_for("on_remove", EcsOnRemove, id) ~= nil)
        end
    end

    -- A hook was set or removed (world:set / world:remove of OnAdd, OnChange, OnRemove). An id
    -- with signals keeps its dispatcher, which calls the new hook from now on.
    local function apply_hook(entity: i53, field: string, value: Hook?)
        local cell = dispatched_hooks[field][entity]
        if cell then
            cell.hook = value
            if value ~= nil then
                id_used[entity % ENTITY_MASK] = true -- (its delete drops the hook, see world_delete)
            end
            if field == "on_remove" then
                refresh_hooked(entity)
            end
        else
            install_hook(entity, field, value)
        end
    end

    -- Signals: the first listener of an id installs a dispatcher that calls the hook of the id
    -- (if any) and then the listeners, so hooks and signals (and change tracking) coexist; the
    -- last one that disconnects removes it.
    -- The listener list is copied on write: a listener that connects or disconnects others (or
    -- itself) during a dispatch changes the next dispatches only. A quiet listener has nothing
    -- to do when an entity is deleted (change tracking).
    local function connect(field: string, id: i53, listener: Hook, quiet: boolean?): () -> ()
        local cell = dispatched_hooks[field][id]
        if cell == nil then
            -- (a deleted id has no hook: the hook of its slot is that of the entity that took it)
            local own_hook = if alive[id % ENTITY_MASK] == id then hook_of(HOOK_IDS[field], id % ENTITY_MASK) else nil
            if own_hook ~= nil then
                id_used[id % ENTITY_MASK] = true -- (its delete drops the hook, see world_delete)
            end
            local created: Dispatch = { hook = own_hook, listeners = {}, loud = 0 }
            cell = created
            local function dispatch(entity: i53, component: i53, value: any?)
                local hook = created.hook
                if hook then
                    hook(entity, component, value)
                end
                for _, fn in created.listeners do
                    fn(entity, component, value)
                end
            end
            dispatchers[field][id] = dispatch
            dispatched_hooks[field][id] = created
            install_hook(id, field, dispatch)
        end
        local dispatch_cell = cell :: Dispatch
        local listeners = table.clone(dispatch_cell.listeners)
        table.insert(listeners, listener)
        dispatch_cell.listeners = listeners
        if not quiet then
            dispatch_cell.loud += 1
            if field == "on_remove" then
                refresh_hooked(id)
            end
        end
        return function()
            local current = dispatch_cell.listeners
            local at = table.find(current, listener)
            assert(at, "listener not found, maybe it was disconnected twice")
            local rest = table.clone(current)
            table.remove(rest, at)
            dispatch_cell.listeners = rest
            if not quiet then
                dispatch_cell.loud -= 1
            end
            if rest[1] == nil and dispatched_hooks[field][id] == dispatch_cell then
                -- The last listener: the dispatcher goes, and the records of the id call its hook
                -- (or nothing) again, as if no signal had been connected (a live id, see
                -- install_hook). A dispatch that is running keeps the listeners it started with.
                dispatchers[field][id] = nil
                dispatched_hooks[field][id] = nil
                install_hook(id, field, dispatch_cell.hook)
            elseif not quiet and field == "on_remove" then
                refresh_hooked(id)
            end
        end
    end

    local function world_added(_: any, id: i53, listener: Hook): () -> ()
        check_signal_id(id, 2)
        return connect("on_add", id, listener)
    end

    local function world_changed(_: any, id: i53, listener: Hook): () -> ()
        check_signal_id(id, 2)
        return connect("on_change", id, listener)
    end

    local function world_removed(_: any, id: i53, listener: Hook): () -> ()
        check_signal_id(id, 2)
        return connect("on_remove", id, listener)
    end

    ----------------------------------------------------------------------------
    -- change tracking
    ----------------------------------------------------------------------------

    -- A tracked id keeps, per kind of change, a ring of TRACK_TICKS bitsets: one per tick.
    -- Changes go to the bitset of the current tick; change filters read the bitsets of the
    -- ticks a query has not seen yet (never the current one: a change becomes visible after
    -- world:tick()). The bitsets have the shape of a record so that queries can use them as
    -- terms. Recording rides on the signals, so untracked ids cost nothing.
    local tracked: { [i53]: { [string]: { Record } } } = {}

    local function track_mark(rec: Record, slot: number)
        last_marked[slot] = current_tick
        local words = rec.words
        local w = slot // 32 + 1
        local bit = lshift(1, slot % 32)
        local word = words[w]
        if word == nil or word == 0 then
            word_first(rec, w, bit)
            rec.version += 1
        elseif band(word, bit) == 0 then
            words[w] = word + bit
            rec.version += 1
        end
    end

    local function world_track(_: any, id: i53)
        check_signal_id(id, 2)
        if tracked[id] then
            return
        end
        local rings: { [string]: { Record } } = {}
        for _, kind in TRACK_KINDS do
            local ring: { Record } = table.create(TRACK_TICKS) :: { Record }
            for t = 1, TRACK_TICKS do
                local rec = new_bitset()
                ring[t] = rec
                table.insert(track_rings, rec)
                table.insert(track_words, rec.words)
            end
            rings[kind] = ring
        end
        tracked[id] = rings
        local added, changed, removed = rings.added, rings.changed, rings.removed
        -- Only for the entity of the event while it is alive: a listener that runs before these
        -- may have deleted it, and world_delete has forgotten the changes of its slot already
        -- (its slot may even hold a new entity).
        connect("on_add", id, function(entity: i53)
            local slot = entity % ENTITY_MASK
            if alive[slot] == entity then
                track_mark(added[current_tick % TRACK_TICKS + 1], slot)
            end
        end)
        connect("on_change", id, function(entity: i53)
            local slot = entity % ENTITY_MASK
            if alive[slot] == entity then
                track_mark(changed[current_tick % TRACK_TICKS + 1], slot)
            end
        end)
        connect("on_remove", id, function(entity: i53, _: i53, deleting: any?)
            -- not for a deleted entity: world_delete forgets all changes of its slot
            local slot = entity % ENTITY_MASK
            if not deleting and alive[slot] == entity then
                track_mark(removed[current_tick % TRACK_TICKS + 1], slot)
            end
        end, true)
    end

    local function world_tick(_: any): number
        -- An error raised by a hook, a listener or a monitor callback stops the call that ran it
        -- half done, and leaves the bookkeeping of the calls in progress as it was: the removals
        -- whose hooks run, the clears, the depth of a cascade and its queue, the target being
        -- cleaned up, the pair that an exclusive relation replaces. A tick runs between frames,
        -- outside every call, so what it finds there is what such an error left: it goes, and
        -- the entities that the stopped cascade had queued are deleted now.
        if
            removing[1] ~= nil
            or clear_depth ~= 0
            or delete_depth ~= 0
            or draining
            or deferred[1] ~= nil
            or dying_target ~= nil
            or monitoring.entity ~= 0
        then
            table.clear(removing)
            for d = 1, clear_depth do
                clearing[d] = nil :: any
                table.clear(clear_buffers[d])
            end
            clear_depth = 0
            delete_depth = 0
            draining = false
            dying_target = nil
            monitoring.entity, monitoring.id = 0, 0
            if debug then
                local report = warn or print -- the luau CLI has no warn
                report(RECOVERED)
            end
            drain_deferred()
        end
        current_tick += 1
        local index = current_tick % TRACK_TICKS + 1
        for _, rings in tracked do
            for _, ring in rings do
                local rec = ring[index]
                if rec.word_count > 0 then
                    table.clear(rec.words)
                    table.clear(rec.sums)
                    rec.word_count = 0
                    rec.zeros = 0
                    rec.version += 1
                end
            end
        end
        return current_tick
    end

    -- Ticks a query sees now: from its first unseen tick to the last finished one, at most
    -- TRACK_TICKS - 1 of them (older history has been overwritten).
    local function tracking_window(query: QueryState): (number, number)
        local last = current_tick - 1
        local first = query.seen_tick or last
        if first < last - TRACK_TICKS + 2 then
            first = last - TRACK_TICKS + 2
        end
        return first, last
    end

    -- The bitset of one change filter over a window of ticks (a record-like table).
    local function tracking_record(id: i53, kind: string, first: number, last: number): Record?
        local rings = tracked[id]
        if rings == nil then
            if id == CREATED then
                error("the created filter needs world:track_created() first", 4)
            end
            error("change filters need a tracked id: call world:track(id) first", 4)
        end
        local ring = rings[kind]
        if first == last then
            return ring[first % TRACK_TICKS + 1]
        end
        local merged = new_bitset()
        for t = first, last do
            local rec = ring[t % TRACK_TICKS + 1]
            for w, word in rec.words do
                merge_word(merged, w, word)
            end
        end
        return merged
    end

    ----------------------------------------------------------------------------
    -- queries
    ----------------------------------------------------------------------------

    -- The bitset of an OR term: the union of the words of its ids, kept in a record-like table
    -- and rebuilt only when one of the records changed.
    local function any_record(query: QueryState, k: number): Record
        local group = (query.any_groups :: { { i53 } })[k]
        local merged_list = query.any_merged
        if merged_list == nil then
            merged_list = {}
            query.any_merged = merged_list
        end
        local cache = (merged_list :: { any })[k]
        if cache then
            local valid = cache.generation == records_generation
            if valid then
                for i, id in group do
                    local rec = records[id]
                    if (if rec then rec.version else -1) ~= cache.versions[i] then
                        valid = false
                        break
                    end
                end
            end
            if valid then
                return cache.record
            end
        end
        local merged = new_bitset()
        local versions: { number } = {}
        for i, id in group do
            local rec = records[id]
            if rec and rec.kind == KIND_TARGET then
                target_materialize(rec)
            end
            versions[i] = if rec then rec.version else -1
            if rec then
                for w, word in rec.words do
                    merge_word(merged, w, word)
                end
            end
        end
        merged.version = (if cache then cache.record.version else 0) + 1
        (merged_list :: { any })[k] = { record = merged, versions = versions, generation = records_generation }
        return merged
    end

    -- Picks the driver (the term with the fewest non-empty words) and lists the words of the
    -- other terms and of the excluded ids, into the given tables when there are any.
    local function plan_query(
        query: QueryState,
        into_others: { Words }?,
        into_without: { Words }?
    ): (Record?, { Words }, { Words })
        local driver: Record? = nil
        local with = query.filter_with
        local tracking = query.tracking
        local tracking_terms: { Record }? = nil
        if tracking then
            local first, last = tracking_window(query)
            query.seen_tick = current_tick
            if first > last then
                return nil, EMPTY_WORDS, EMPTY_WORDS
            end
            local terms: { Record } = {}
            for _, filter in tracking do
                local rec = tracking_record(filter[2], filter[1], first, last) :: Record
                if rec.word_count == 0 then
                    return nil, EMPTY_WORDS, EMPTY_WORDS
                end
                if driver == nil or rec.word_count < driver.word_count then
                    driver = rec
                end
                table.insert(terms, rec)
            end
            tracking_terms = terms
        end
        for _, id in with do
            local rec = records[id]
            if rec and rec.kind == KIND_TARGET then
                target_materialize(rec)
            end
            if rec == nil or rec.word_count == 0 then
                return nil, EMPTY_WORDS, EMPTY_WORDS
            end
            if driver == nil or rec.word_count < driver.word_count then
                driver = rec
            end
        end
        local any_groups = query.any_groups
        local any_terms: { Record }? = nil
        if any_groups then
            local terms: { Record } = {}
            for k in any_groups do
                local rec = any_record(query, k)
                if rec.word_count == 0 then
                    return nil, EMPTY_WORDS, EMPTY_WORDS
                end
                if driver == nil or rec.word_count < driver.word_count then
                    driver = rec
                end
                table.insert(terms, rec)
            end
            any_terms = terms
        end
        local others: { Words } = into_others or {}
        table.clear(others)
        for _, id in with do
            local rec = records[id]
            if rec ~= driver then
                table.insert(others, rec.words)
            end
        end
        if tracking_terms then
            for _, rec in tracking_terms do
                if rec ~= driver then
                    table.insert(others, rec.words)
                end
            end
        end
        if any_terms then
            for _, rec in any_terms do
                if rec ~= driver then
                    table.insert(others, rec.words)
                end
            end
        end
        local without: { Words } = into_without or {}
        table.clear(without)
        local filter_without = query.filter_without
        if filter_without then
            for _, id in filter_without do
                local rec = records[id]
                if rec and rec.kind == KIND_TARGET then
                    target_materialize(rec)
                end
                if rec and rec.word_count > 0 then
                    table.insert(without, rec.words)
                end
            end
        end
        if query.skip_disabled then
            local rec = records[EcsDisabled]
            if rec and rec.word_count > 0 then
                table.insert(without, rec.words)
            end
        end
        if driver then
            query.scan_words = driver.word_count
        end
        return driver, others, without
    end

    -- Word tests of the general case (more than three other terms, or more than two excluded
    -- ids): the bits of word w that match every term, and whether all of them do.
    local function make_word_tests(
        dwords: Words,
        others: { Words },
        without: { Words }
    ): ((w: number) -> number, (w: number) -> boolean)
        local n_others, n_without = #others, #without
        local function word_mask(w: number): number
            local m = dwords[w]
            if m == nil then
                return 0
            end
            for k = 1, n_others do
                local o = others[k][w]
                if o == nil then
                    return 0
                end
                m = band(m, o)
            end
            for k = 1, n_without do
                local x = without[k][w]
                if x ~= nil then
                    m = band(m, FULL_WORD - x)
                end
            end
            return m
        end
        local function word_full(w: number): boolean
            if dwords[w] ~= FULL_WORD then
                return false
            end
            for k = 1, n_others do
                if others[k][w] ~= FULL_WORD then
                    return false
                end
            end
            for k = 1, n_without do
                if (without[k][w] or 0) ~= 0 then
                    return false
                end
            end
            return true
        end
        return word_mask, word_full
    end

    -- Span generator: each call gives (first, last, mask) or nil when done. A span never
    -- crosses a page. mask == FULL_WORD means every slot of first..last matches (a run of
    -- full words); otherwise first..last is one word and first + bit index is a matching slot.
    -- The driver is walked through its tops and sums, so the empty parts of the world cost
    -- nothing. new_advance returns the generator and a function that binds it to a plan; a
    -- bound generator can be bound again for the next iteration.
    local function new_advance(): (() -> (number?, number?, number), (Record, { Words }, { Words }) -> ())
        local dsums: Words, dwords: Words = EMPTY_WORDS_TABLE, EMPTY_WORDS_TABLE
        local o1: Words?, o2: Words?, o3: Words? = nil, nil, nil
        local y1: Words?, y2: Words? = nil, nil
        -- up to three other terms and up to two excluded ids: the word tests are inline
        local simple = true
        local word_mask: (w: number) -> number, word_full: (w: number) -> boolean
        local max_tw = 0
        local tw, tmask = 0, 0
        local sw, smask = 0, 0

        local function bind(driver: Record, others: { Words }, without: { Words })
            dsums, dwords = driver.sums, driver.words
            o1, o2, o3 = others[1], others[2], others[3]
            y1, y2 = without[1], without[2]
            simple = #others <= 3 and #without <= 2
            if not simple then
                word_mask, word_full = make_word_tests(dwords, others, without)
            end
            max_tw = max_slot // TOP_SLOTS + 1
            tw, tmask, sw, smask = 0, 0, 0, 0
        end

        return function(): (number?, number?, number)
            local mask = smask
            while true do
                while mask == 0 do
                    -- the next non-empty summary word
                    local t = tmask
                    while t == 0 do
                        local next_tw = tw + 1
                        tw = next_tw
                        if next_tw > max_tw then
                            smask, tmask = 0, 0
                            return nil, nil, 0
                        end
                        t = dsums[-next_tw] or 0
                    end
                    local next_sw = (tw - 1) * 32 + countrz(t) + 1
                    tmask = band(t, t - 1)
                    sw = next_sw
                    mask = dsums[next_sw] or 0 -- 0: emptied during the iteration
                end
                local b = countrz(mask)
                mask = band(mask, mask - 1)
                local w = (sw - 1) * 32 + b + 1
                local m: number
                if simple then
                    local d = dwords[w]
                    if d == nil then
                        continue -- emptied during the iteration
                    end
                    m = d
                    -- the terms that the query has (the others come in order: o2 only with o1)
                    local x = o1
                    if x then
                        local o = x[w]
                        if o == nil then
                            continue
                        end
                        m = band(m, o)
                        x = o2
                        if x then
                            o = x[w]
                            if o == nil then
                                continue
                            end
                            m = band(m, o)
                            x = o3
                            if x then
                                o = x[w]
                                if o == nil then
                                    continue
                                end
                                m = band(m, o)
                            end
                        end
                    end
                    local z = y1
                    if z then
                        local y = z[w]
                        if y then
                            m = band(m, FULL_WORD - y)
                        end
                        z = y2
                        if z then
                            y = z[w]
                            if y then
                                m = band(m, FULL_WORD - y)
                            end
                        end
                    end
                else
                    m = word_mask(w)
                end
                if m ~= 0 then
                    local first = (w - 1) * 32
                    if m ~= FULL_WORD then
                        smask = mask
                        return first, first + 31, m
                    end
                    -- merge the following full words of the page
                    local last_w = w
                    local page_last_w = w - (w - 1) % WORDS_PER_PAGE + WORDS_PER_PAGE - 1
                    if simple then
                        local d, x1, x2, x3, z1, z2 = dwords, o1, o2, o3, y1, y2
                        while last_w < page_last_w do
                            local nw = last_w + 1
                            if
                                d[nw] ~= FULL_WORD
                                or (x1 and x1[nw] ~= FULL_WORD)
                                or (x2 and x2[nw] ~= FULL_WORD)
                                or (x3 and x3[nw] ~= FULL_WORD)
                                or (z1 and (z1[nw] or 0) ~= 0)
                                or (z2 and (z2[nw] or 0) ~= 0)
                            then
                                break
                            end
                            last_w = nw
                        end
                    else
                        while last_w < page_last_w and word_full(last_w + 1) do
                            last_w += 1
                        end
                    end
                    -- the merged words are consecutive bits of the summary mask from b
                    smask = band(mask, lshift(FULL_WORD, b + last_w - w + 1))
                    return first, last_w * 32 - 1, FULL_WORD
                end
            end
        end,
            bind
    end

    local function make_advance(driver: Record, others: { Words }, without: { Words }): () -> (number?, number?, number)
        local advance, bind = new_advance()
        bind(driver, others, without)
        return advance
    end

    -- One span generator with its plan tables for the scans that run no user code and never
    -- nest (choose_mode, build_list, verify_list): they allocate nothing. The table also holds
    -- the buffered loops of small queries (scan.fill, scan.new_buffered): world_new is at the
    -- limit of local registers.
    local scan: any = { others = {}, without = {}, spans = {}, count = 0 }
    scan.advance, scan.bind = new_advance()

    -- Gathers the matches of a small query into a buffer: for each value page with matches,
    -- -page and then the entity and the index in the page of each match; nil after the last. A
    -- query that is not cached (the first request of a shape, an entity or a pair used as a
    -- term) with a small driver has a few scattered matches, and a tight loop over the words of
    -- the driver costs far less than a call of the span generator per match. Returns
    -- false for a plan whose word tests are not simple (more than three other terms or two
    -- excluded ids): the caller iterates the bitsets then.
    function scan.fill(buf: { number }, driver: Record, others: { Words }, without: { Words }): boolean
        if #others > 3 or #without > 2 then
            return false
        end
        local o1, o2, o3 = others[1], others[2], others[3]
        local y1, y2 = without[1], without[2]
        local dsums, dwords = driver.sums, driver.words
        local n, current_page, offset = 0, 0, 0
        for tw = 1, max_slot // TOP_SLOTS + 1 do
            local t = dsums[-tw] or 0
            while t ~= 0 do
                local sw = (tw - 1) * 32 + countrz(t) + 1
                t = band(t, t - 1)
                local sum = dsums[sw] or 0
                while sum ~= 0 do
                    local w = (sw - 1) * 32 + countrz(sum) + 1
                    sum = band(sum, sum - 1)
                    local m = dwords[w]
                    if m == nil then
                        continue
                    end
                    if o1 then
                        local o = o1[w]
                        if o == nil then
                            continue
                        end
                        m = band(m, o)
                        if o2 then
                            o = o2[w]
                            if o == nil then
                                continue
                            end
                            m = band(m, o)
                            if o3 then
                                o = o3[w]
                                if o == nil then
                                    continue
                                end
                                m = band(m, o)
                            end
                        end
                    end
                    if y1 then
                        local y = y1[w]
                        if y then
                            m = band(m, FULL_WORD - y)
                        end
                        if y2 then
                            y = y2[w]
                            if y then
                                m = band(m, FULL_WORD - y)
                            end
                        end
                    end
                    if m ~= 0 then
                        local page = (w - 1) // WORDS_PER_PAGE + 1
                        if page ~= current_page then
                            current_page = page
                            offset = (page - 1) * PAGE_SIZE - 1
                            n += 1
                            buf[n] = -page
                        end
                        local base = (w - 1) * 32
                        repeat
                            local slot = base + countrz(m)
                            m = band(m, m - 1)
                            buf[n + 1] = alive[slot]
                            buf[n + 2] = slot - offset
                            n += 2
                        until m == 0
                    end
                end
            end
        end
        buf[n + 1] = nil
        return true
    end

    -- The for-in context of a small query that is not cached, for n returned values (at most
    -- 8): the buffer of its matches (see scan.fill), the step over it and the value pages it
    -- reads. Such contexts are reused while no loop runs on them (spare_contexts.buffered).
    function scan.new_buffered(n: number): any
        local ctx: any = { busy = false, buf = {}, others = {}, without = {} }
        local buf: { number } = ctx.buf
        local pos = 1
        local cp1, cp2, cp3, cp4 = EMPTY_PAGES, EMPTY_PAGES, EMPTY_PAGES, EMPTY_PAGES
        local cp5, cp6, cp7, cp8 = EMPTY_PAGES, EMPTY_PAGES, EMPTY_PAGES, EMPTY_PAGES
        local p1, p2, p3, p4 = EMPTY, EMPTY, EMPTY, EMPTY
        local p5, p6, p7, p8 = EMPTY, EMPTY, EMPTY, EMPTY

        function ctx.bind(query: QueryState)
            local ids = query.ids
            cp1, cp2, cp3, cp4 =
                columns[ids[1]] or EMPTY_PAGES,
                columns[ids[2]] or EMPTY_PAGES,
                columns[ids[3]] or EMPTY_PAGES,
                columns[ids[4]] or EMPTY_PAGES
            cp5, cp6, cp7, cp8 =
                columns[ids[5]] or EMPTY_PAGES,
                columns[ids[6]] or EMPTY_PAGES,
                columns[ids[7]] or EMPTY_PAGES,
                columns[ids[8]] or EMPTY_PAGES
            pos = 1
        end

        local step: () -> ...any
        -- @generated buffer_iterators begin
        if n == 0 then
            step = function(): ...any
                local at = pos
                local x = buf[at]
                if x == nil then
                    ctx.busy = false
                    return nil
                end
                if x < 0 then
                    -- the matches of the next page
                    at += 1
                    x = buf[at]
                end
                pos = at + 2
                return x
            end
        elseif n == 1 then
            step = function(): ...any
                local at = pos
                local x = buf[at]
                if x == nil then
                    ctx.busy = false
                    return nil
                end
                if x < 0 then
                    -- the matches of the next page
                    local page = -x
                    p1 = cp1[page] or EMPTY
                    at += 1
                    x = buf[at]
                end
                pos = at + 2
                local li = buf[at + 1]
                return x, p1[li]
            end
        elseif n == 2 then
            step = function(): ...any
                local at = pos
                local x = buf[at]
                if x == nil then
                    ctx.busy = false
                    return nil
                end
                if x < 0 then
                    -- the matches of the next page
                    local page = -x
                    p1 = cp1[page] or EMPTY
                    p2 = cp2[page] or EMPTY
                    at += 1
                    x = buf[at]
                end
                pos = at + 2
                local li = buf[at + 1]
                return x, p1[li], p2[li]
            end
        elseif n == 3 then
            step = function(): ...any
                local at = pos
                local x = buf[at]
                if x == nil then
                    ctx.busy = false
                    return nil
                end
                if x < 0 then
                    -- the matches of the next page
                    local page = -x
                    p1 = cp1[page] or EMPTY
                    p2 = cp2[page] or EMPTY
                    p3 = cp3[page] or EMPTY
                    at += 1
                    x = buf[at]
                end
                pos = at + 2
                local li = buf[at + 1]
                return x, p1[li], p2[li], p3[li]
            end
        elseif n == 4 then
            step = function(): ...any
                local at = pos
                local x = buf[at]
                if x == nil then
                    ctx.busy = false
                    return nil
                end
                if x < 0 then
                    -- the matches of the next page
                    local page = -x
                    p1 = cp1[page] or EMPTY
                    p2 = cp2[page] or EMPTY
                    p3 = cp3[page] or EMPTY
                    p4 = cp4[page] or EMPTY
                    at += 1
                    x = buf[at]
                end
                pos = at + 2
                local li = buf[at + 1]
                return x, p1[li], p2[li], p3[li], p4[li]
            end
        elseif n == 5 then
            step = function(): ...any
                local at = pos
                local x = buf[at]
                if x == nil then
                    ctx.busy = false
                    return nil
                end
                if x < 0 then
                    -- the matches of the next page
                    local page = -x
                    p1 = cp1[page] or EMPTY
                    p2 = cp2[page] or EMPTY
                    p3 = cp3[page] or EMPTY
                    p4 = cp4[page] or EMPTY
                    p5 = cp5[page] or EMPTY
                    at += 1
                    x = buf[at]
                end
                pos = at + 2
                local li = buf[at + 1]
                return x, p1[li], p2[li], p3[li], p4[li], p5[li]
            end
        elseif n == 6 then
            step = function(): ...any
                local at = pos
                local x = buf[at]
                if x == nil then
                    ctx.busy = false
                    return nil
                end
                if x < 0 then
                    -- the matches of the next page
                    local page = -x
                    p1 = cp1[page] or EMPTY
                    p2 = cp2[page] or EMPTY
                    p3 = cp3[page] or EMPTY
                    p4 = cp4[page] or EMPTY
                    p5 = cp5[page] or EMPTY
                    p6 = cp6[page] or EMPTY
                    at += 1
                    x = buf[at]
                end
                pos = at + 2
                local li = buf[at + 1]
                return x, p1[li], p2[li], p3[li], p4[li], p5[li], p6[li]
            end
        elseif n == 7 then
            step = function(): ...any
                local at = pos
                local x = buf[at]
                if x == nil then
                    ctx.busy = false
                    return nil
                end
                if x < 0 then
                    -- the matches of the next page
                    local page = -x
                    p1 = cp1[page] or EMPTY
                    p2 = cp2[page] or EMPTY
                    p3 = cp3[page] or EMPTY
                    p4 = cp4[page] or EMPTY
                    p5 = cp5[page] or EMPTY
                    p6 = cp6[page] or EMPTY
                    p7 = cp7[page] or EMPTY
                    at += 1
                    x = buf[at]
                end
                pos = at + 2
                local li = buf[at + 1]
                return x, p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li]
            end
        elseif n == 8 then
            step = function(): ...any
                local at = pos
                local x = buf[at]
                if x == nil then
                    ctx.busy = false
                    return nil
                end
                if x < 0 then
                    -- the matches of the next page
                    local page = -x
                    p1 = cp1[page] or EMPTY
                    p2 = cp2[page] or EMPTY
                    p3 = cp3[page] or EMPTY
                    p4 = cp4[page] or EMPTY
                    p5 = cp5[page] or EMPTY
                    p6 = cp6[page] or EMPTY
                    p7 = cp7[page] or EMPTY
                    p8 = cp8[page] or EMPTY
                    at += 1
                    x = buf[at]
                end
                pos = at + 2
                local li = buf[at + 1]
                return x, p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li], p8[li]
            end
        end
        -- @generated buffer_iterators end
        ctx.step = step
        return ctx
    end

    -- Gives the wildcards whose values a query returns their mirrors (see mirror.create): the
    -- query then reads them like the columns of components. A wildcard none of whose pairs
    -- holds values returns nil for every entity and is read like a tag (its version changes
    -- when a pair with values appears, see pair_record_create).
    function mirror.ensure(query: QueryState)
        for _, id in query.ids do
            if id > PAIR_OFFSET and columns[id] == nil and is_wildcard(id) then
                local rec = records[id]
                if rec and (rec.data_pairs :: number) > 0 then
                    mirror.create(rec)
                end
            end
        end
    end

    local function value_pages(query: QueryState): { Pages }
        local list: { Pages } = {}
        for i, id in query.ids do
            list[i] = columns[id] or EMPTY_PAGES
        end
        return list
    end

    -- Direct for-in iterator over the bitsets of a query, with the state it runs on. The for-in
    -- control variable carries the last entity. Cached queries keep one context and bind it
    -- for every iteration, so iterating allocates nothing; ctx.busy is true while an iteration
    -- started from the context has not reached its end.
    local function new_direct(n: number): any
        local ctx: any = { busy = false, others = {}, without = {} }
        local advance, bind_advance = new_advance()
        local cp1, cp2, cp3, cp4 = EMPTY_PAGES, EMPTY_PAGES, EMPTY_PAGES, EMPTY_PAGES
        local cp5, cp6, cp7, cp8 = EMPTY_PAGES, EMPTY_PAGES, EMPTY_PAGES, EMPTY_PAGES
        local p1, p2, p3, p4 = EMPTY, EMPTY, EMPTY, EMPTY
        local p5, p6, p7, p8 = EMPTY, EMPTY, EMPTY, EMPTY
        local cur_page = 0
        local page_offset = 0
        local run_last = -1
        local pbase = 0
        local pmask = 0
        -- values beyond the eighth go through a table
        local nx = if n > 8 then n - 8 else 0
        local xcp: { Pages } = if nx > 0 then table.create(nx) :: { Pages } else NO_STATE
        local xp: { Page } = if nx > 0 then table.create(nx, EMPTY) :: { Page } else NO_STATE
        local xout = if nx > 0 then table.create(nx) else NO_STATE

        function ctx.bind(query: QueryState, driver: Record)
            bind_advance(driver, ctx.others, ctx.without)
            local ids = query.ids
            cp1, cp2, cp3, cp4 =
                columns[ids[1]] or EMPTY_PAGES,
                columns[ids[2]] or EMPTY_PAGES,
                columns[ids[3]] or EMPTY_PAGES,
                columns[ids[4]] or EMPTY_PAGES
            cp5, cp6, cp7, cp8 =
                columns[ids[5]] or EMPTY_PAGES,
                columns[ids[6]] or EMPTY_PAGES,
                columns[ids[7]] or EMPTY_PAGES,
                columns[ids[8]] or EMPTY_PAGES
            for k = 1, nx do
                xcp[k] = columns[ids[8 + k]] or EMPTY_PAGES
                xp[k] = EMPTY
            end
            p1, p2, p3, p4 = EMPTY, EMPTY, EMPTY, EMPTY
            p5, p6, p7, p8 = EMPTY, EMPTY, EMPTY, EMPTY
            cur_page, page_offset, run_last, pbase, pmask = 0, 0, -1, 0, 0
        end

        local step: (any, i53) -> ...any
        -- @generated direct_iterators begin
        if n == 0 then
            step = function(_: any, prev: i53): ...any
                local s = band(prev, SLOT_BITS) + 1
                if s <= run_last then
                    return alive[s]
                end
                local m = pmask
                if m ~= 0 then
                    s = pbase + countrz(m)
                    pmask = band(m, m - 1)
                    return alive[s]
                end
                if prev < 0 then
                    -- the previous entity was deleted meanwhile: continue after its slot
                    s = (-1 - prev) // ENTITY_MASK + 1
                    if s <= run_last then
                        return alive[s]
                    end
                end
                local first, last, span_mask = advance()
                if first == nil then
                    ctx.busy = false
                    return nil
                end
                local page = first // PAGE_SIZE + 1
                if page ~= cur_page then
                    cur_page = page
                    page_offset = (page - 1) * PAGE_SIZE - 1
                end
                if span_mask == FULL_WORD then
                    run_last = last :: number
                    s = first
                else
                    run_last = -1
                    pbase = first
                    s = first + countrz(span_mask)
                    pmask = band(span_mask, span_mask - 1)
                end
                return alive[s]
            end
        elseif n == 1 then
            step = function(_: any, prev: i53): ...any
                local s = band(prev, SLOT_BITS) + 1
                local q1 = p1
                if s <= run_last then
                    local li = s - page_offset
                    return alive[s], q1[li]
                end
                local m = pmask
                if m ~= 0 then
                    s = pbase + countrz(m)
                    pmask = band(m, m - 1)
                    local li = s - page_offset
                    return alive[s], q1[li]
                end
                if prev < 0 then
                    -- the previous entity was deleted meanwhile: continue after its slot
                    s = (-1 - prev) // ENTITY_MASK + 1
                    if s <= run_last then
                        local li = s - page_offset
                        return alive[s], q1[li]
                    end
                end
                local first, last, span_mask = advance()
                if first == nil then
                    ctx.busy = false
                    return nil
                end
                local page = first // PAGE_SIZE + 1
                if page ~= cur_page then
                    cur_page = page
                    p1 = cp1[page] or EMPTY
                    page_offset = (page - 1) * PAGE_SIZE - 1
                end
                if span_mask == FULL_WORD then
                    run_last = last :: number
                    s = first
                else
                    run_last = -1
                    pbase = first
                    s = first + countrz(span_mask)
                    pmask = band(span_mask, span_mask - 1)
                end
                local li = s - page_offset
                return alive[s], p1[li]
            end
        elseif n == 2 then
            step = function(_: any, prev: i53): ...any
                local s = band(prev, SLOT_BITS) + 1
                local q1, q2 = p1, p2
                if s <= run_last then
                    local li = s - page_offset
                    return alive[s], q1[li], q2[li]
                end
                local m = pmask
                if m ~= 0 then
                    s = pbase + countrz(m)
                    pmask = band(m, m - 1)
                    local li = s - page_offset
                    return alive[s], q1[li], q2[li]
                end
                if prev < 0 then
                    -- the previous entity was deleted meanwhile: continue after its slot
                    s = (-1 - prev) // ENTITY_MASK + 1
                    if s <= run_last then
                        local li = s - page_offset
                        return alive[s], q1[li], q2[li]
                    end
                end
                local first, last, span_mask = advance()
                if first == nil then
                    ctx.busy = false
                    return nil
                end
                local page = first // PAGE_SIZE + 1
                if page ~= cur_page then
                    cur_page = page
                    p1 = cp1[page] or EMPTY
                    p2 = cp2[page] or EMPTY
                    page_offset = (page - 1) * PAGE_SIZE - 1
                end
                if span_mask == FULL_WORD then
                    run_last = last :: number
                    s = first
                else
                    run_last = -1
                    pbase = first
                    s = first + countrz(span_mask)
                    pmask = band(span_mask, span_mask - 1)
                end
                local li = s - page_offset
                return alive[s], p1[li], p2[li]
            end
        elseif n == 3 then
            step = function(_: any, prev: i53): ...any
                local s = band(prev, SLOT_BITS) + 1
                local q1, q2, q3 = p1, p2, p3
                if s <= run_last then
                    local li = s - page_offset
                    return alive[s], q1[li], q2[li], q3[li]
                end
                local m = pmask
                if m ~= 0 then
                    s = pbase + countrz(m)
                    pmask = band(m, m - 1)
                    local li = s - page_offset
                    return alive[s], q1[li], q2[li], q3[li]
                end
                if prev < 0 then
                    -- the previous entity was deleted meanwhile: continue after its slot
                    s = (-1 - prev) // ENTITY_MASK + 1
                    if s <= run_last then
                        local li = s - page_offset
                        return alive[s], q1[li], q2[li], q3[li]
                    end
                end
                local first, last, span_mask = advance()
                if first == nil then
                    ctx.busy = false
                    return nil
                end
                local page = first // PAGE_SIZE + 1
                if page ~= cur_page then
                    cur_page = page
                    p1 = cp1[page] or EMPTY
                    p2 = cp2[page] or EMPTY
                    p3 = cp3[page] or EMPTY
                    page_offset = (page - 1) * PAGE_SIZE - 1
                end
                if span_mask == FULL_WORD then
                    run_last = last :: number
                    s = first
                else
                    run_last = -1
                    pbase = first
                    s = first + countrz(span_mask)
                    pmask = band(span_mask, span_mask - 1)
                end
                local li = s - page_offset
                return alive[s], p1[li], p2[li], p3[li]
            end
        elseif n == 4 then
            step = function(_: any, prev: i53): ...any
                local s = band(prev, SLOT_BITS) + 1
                local q1, q2, q3, q4 = p1, p2, p3, p4
                if s <= run_last then
                    local li = s - page_offset
                    return alive[s], q1[li], q2[li], q3[li], q4[li]
                end
                local m = pmask
                if m ~= 0 then
                    s = pbase + countrz(m)
                    pmask = band(m, m - 1)
                    local li = s - page_offset
                    return alive[s], q1[li], q2[li], q3[li], q4[li]
                end
                if prev < 0 then
                    -- the previous entity was deleted meanwhile: continue after its slot
                    s = (-1 - prev) // ENTITY_MASK + 1
                    if s <= run_last then
                        local li = s - page_offset
                        return alive[s], q1[li], q2[li], q3[li], q4[li]
                    end
                end
                local first, last, span_mask = advance()
                if first == nil then
                    ctx.busy = false
                    return nil
                end
                local page = first // PAGE_SIZE + 1
                if page ~= cur_page then
                    cur_page = page
                    p1 = cp1[page] or EMPTY
                    p2 = cp2[page] or EMPTY
                    p3 = cp3[page] or EMPTY
                    p4 = cp4[page] or EMPTY
                    page_offset = (page - 1) * PAGE_SIZE - 1
                end
                if span_mask == FULL_WORD then
                    run_last = last :: number
                    s = first
                else
                    run_last = -1
                    pbase = first
                    s = first + countrz(span_mask)
                    pmask = band(span_mask, span_mask - 1)
                end
                local li = s - page_offset
                return alive[s], p1[li], p2[li], p3[li], p4[li]
            end
        elseif n == 5 then
            step = function(_: any, prev: i53): ...any
                local s = band(prev, SLOT_BITS) + 1
                local q1, q2, q3, q4, q5 = p1, p2, p3, p4, p5
                if s <= run_last then
                    local li = s - page_offset
                    return alive[s], q1[li], q2[li], q3[li], q4[li], q5[li]
                end
                local m = pmask
                if m ~= 0 then
                    s = pbase + countrz(m)
                    pmask = band(m, m - 1)
                    local li = s - page_offset
                    return alive[s], q1[li], q2[li], q3[li], q4[li], q5[li]
                end
                if prev < 0 then
                    -- the previous entity was deleted meanwhile: continue after its slot
                    s = (-1 - prev) // ENTITY_MASK + 1
                    if s <= run_last then
                        local li = s - page_offset
                        return alive[s], q1[li], q2[li], q3[li], q4[li], q5[li]
                    end
                end
                local first, last, span_mask = advance()
                if first == nil then
                    ctx.busy = false
                    return nil
                end
                local page = first // PAGE_SIZE + 1
                if page ~= cur_page then
                    cur_page = page
                    p1 = cp1[page] or EMPTY
                    p2 = cp2[page] or EMPTY
                    p3 = cp3[page] or EMPTY
                    p4 = cp4[page] or EMPTY
                    p5 = cp5[page] or EMPTY
                    page_offset = (page - 1) * PAGE_SIZE - 1
                end
                if span_mask == FULL_WORD then
                    run_last = last :: number
                    s = first
                else
                    run_last = -1
                    pbase = first
                    s = first + countrz(span_mask)
                    pmask = band(span_mask, span_mask - 1)
                end
                local li = s - page_offset
                return alive[s], p1[li], p2[li], p3[li], p4[li], p5[li]
            end
        elseif n == 6 then
            step = function(_: any, prev: i53): ...any
                local s = band(prev, SLOT_BITS) + 1
                local q1, q2, q3, q4, q5, q6 = p1, p2, p3, p4, p5, p6
                if s <= run_last then
                    local li = s - page_offset
                    return alive[s], q1[li], q2[li], q3[li], q4[li], q5[li], q6[li]
                end
                local m = pmask
                if m ~= 0 then
                    s = pbase + countrz(m)
                    pmask = band(m, m - 1)
                    local li = s - page_offset
                    return alive[s], q1[li], q2[li], q3[li], q4[li], q5[li], q6[li]
                end
                if prev < 0 then
                    -- the previous entity was deleted meanwhile: continue after its slot
                    s = (-1 - prev) // ENTITY_MASK + 1
                    if s <= run_last then
                        local li = s - page_offset
                        return alive[s], q1[li], q2[li], q3[li], q4[li], q5[li], q6[li]
                    end
                end
                local first, last, span_mask = advance()
                if first == nil then
                    ctx.busy = false
                    return nil
                end
                local page = first // PAGE_SIZE + 1
                if page ~= cur_page then
                    cur_page = page
                    p1 = cp1[page] or EMPTY
                    p2 = cp2[page] or EMPTY
                    p3 = cp3[page] or EMPTY
                    p4 = cp4[page] or EMPTY
                    p5 = cp5[page] or EMPTY
                    p6 = cp6[page] or EMPTY
                    page_offset = (page - 1) * PAGE_SIZE - 1
                end
                if span_mask == FULL_WORD then
                    run_last = last :: number
                    s = first
                else
                    run_last = -1
                    pbase = first
                    s = first + countrz(span_mask)
                    pmask = band(span_mask, span_mask - 1)
                end
                local li = s - page_offset
                return alive[s], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li]
            end
        elseif n == 7 then
            step = function(_: any, prev: i53): ...any
                local s = band(prev, SLOT_BITS) + 1
                local q1, q2, q3, q4, q5, q6, q7 = p1, p2, p3, p4, p5, p6, p7
                if s <= run_last then
                    local li = s - page_offset
                    return alive[s], q1[li], q2[li], q3[li], q4[li], q5[li], q6[li], q7[li]
                end
                local m = pmask
                if m ~= 0 then
                    s = pbase + countrz(m)
                    pmask = band(m, m - 1)
                    local li = s - page_offset
                    return alive[s], q1[li], q2[li], q3[li], q4[li], q5[li], q6[li], q7[li]
                end
                if prev < 0 then
                    -- the previous entity was deleted meanwhile: continue after its slot
                    s = (-1 - prev) // ENTITY_MASK + 1
                    if s <= run_last then
                        local li = s - page_offset
                        return alive[s], q1[li], q2[li], q3[li], q4[li], q5[li], q6[li], q7[li]
                    end
                end
                local first, last, span_mask = advance()
                if first == nil then
                    ctx.busy = false
                    return nil
                end
                local page = first // PAGE_SIZE + 1
                if page ~= cur_page then
                    cur_page = page
                    p1 = cp1[page] or EMPTY
                    p2 = cp2[page] or EMPTY
                    p3 = cp3[page] or EMPTY
                    p4 = cp4[page] or EMPTY
                    p5 = cp5[page] or EMPTY
                    p6 = cp6[page] or EMPTY
                    p7 = cp7[page] or EMPTY
                    page_offset = (page - 1) * PAGE_SIZE - 1
                end
                if span_mask == FULL_WORD then
                    run_last = last :: number
                    s = first
                else
                    run_last = -1
                    pbase = first
                    s = first + countrz(span_mask)
                    pmask = band(span_mask, span_mask - 1)
                end
                local li = s - page_offset
                return alive[s], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li]
            end
        elseif n == 8 then
            step = function(_: any, prev: i53): ...any
                local s = band(prev, SLOT_BITS) + 1
                local q1, q2, q3, q4, q5, q6, q7, q8 = p1, p2, p3, p4, p5, p6, p7, p8
                if s <= run_last then
                    local li = s - page_offset
                    return alive[s], q1[li], q2[li], q3[li], q4[li], q5[li], q6[li], q7[li], q8[li]
                end
                local m = pmask
                if m ~= 0 then
                    s = pbase + countrz(m)
                    pmask = band(m, m - 1)
                    local li = s - page_offset
                    return alive[s], q1[li], q2[li], q3[li], q4[li], q5[li], q6[li], q7[li], q8[li]
                end
                if prev < 0 then
                    -- the previous entity was deleted meanwhile: continue after its slot
                    s = (-1 - prev) // ENTITY_MASK + 1
                    if s <= run_last then
                        local li = s - page_offset
                        return alive[s], q1[li], q2[li], q3[li], q4[li], q5[li], q6[li], q7[li], q8[li]
                    end
                end
                local first, last, span_mask = advance()
                if first == nil then
                    ctx.busy = false
                    return nil
                end
                local page = first // PAGE_SIZE + 1
                if page ~= cur_page then
                    cur_page = page
                    p1 = cp1[page] or EMPTY
                    p2 = cp2[page] or EMPTY
                    p3 = cp3[page] or EMPTY
                    p4 = cp4[page] or EMPTY
                    p5 = cp5[page] or EMPTY
                    p6 = cp6[page] or EMPTY
                    p7 = cp7[page] or EMPTY
                    p8 = cp8[page] or EMPTY
                    page_offset = (page - 1) * PAGE_SIZE - 1
                end
                if span_mask == FULL_WORD then
                    run_last = last :: number
                    s = first
                else
                    run_last = -1
                    pbase = first
                    s = first + countrz(span_mask)
                    pmask = band(span_mask, span_mask - 1)
                end
                local li = s - page_offset
                return alive[s], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li], p8[li]
            end
        else
            step = function(_: any, prev: i53): ...any
                local s = band(prev, SLOT_BITS) + 1
                local q1, q2, q3, q4, q5, q6, q7, q8 = p1, p2, p3, p4, p5, p6, p7, p8
                local xq = xp
                if s <= run_last then
                    local li = s - page_offset
                    for k = 1, nx do
                        xout[k] = xq[k][li]
                    end
                    return alive[s],
                        q1[li],
                        q2[li],
                        q3[li],
                        q4[li],
                        q5[li],
                        q6[li],
                        q7[li],
                        q8[li],
                        table.unpack(xout, 1, nx)
                end
                local m = pmask
                if m ~= 0 then
                    s = pbase + countrz(m)
                    pmask = band(m, m - 1)
                    local li = s - page_offset
                    for k = 1, nx do
                        xout[k] = xq[k][li]
                    end
                    return alive[s],
                        q1[li],
                        q2[li],
                        q3[li],
                        q4[li],
                        q5[li],
                        q6[li],
                        q7[li],
                        q8[li],
                        table.unpack(xout, 1, nx)
                end
                if prev < 0 then
                    -- the previous entity was deleted meanwhile: continue after its slot
                    s = (-1 - prev) // ENTITY_MASK + 1
                    if s <= run_last then
                        local li = s - page_offset
                        for k = 1, nx do
                            xout[k] = xq[k][li]
                        end
                        return alive[s],
                            q1[li],
                            q2[li],
                            q3[li],
                            q4[li],
                            q5[li],
                            q6[li],
                            q7[li],
                            q8[li],
                            table.unpack(xout, 1, nx)
                    end
                end
                local first, last, span_mask = advance()
                if first == nil then
                    ctx.busy = false
                    return nil
                end
                local page = first // PAGE_SIZE + 1
                if page ~= cur_page then
                    cur_page = page
                    p1 = cp1[page] or EMPTY
                    p2 = cp2[page] or EMPTY
                    p3 = cp3[page] or EMPTY
                    p4 = cp4[page] or EMPTY
                    p5 = cp5[page] or EMPTY
                    p6 = cp6[page] or EMPTY
                    p7 = cp7[page] or EMPTY
                    p8 = cp8[page] or EMPTY
                    for k = 1, nx do
                        xp[k] = xcp[k][page] or EMPTY
                    end
                    page_offset = (page - 1) * PAGE_SIZE - 1
                end
                if span_mask == FULL_WORD then
                    run_last = last :: number
                    s = first
                else
                    run_last = -1
                    pbase = first
                    s = first + countrz(span_mask)
                    pmask = band(span_mask, span_mask - 1)
                end
                local li = s - page_offset
                for k = 1, nx do
                    xout[k] = xp[k][li]
                end
                return alive[s],
                    p1[li],
                    p2[li],
                    p3[li],
                    p4[li],
                    p5[li],
                    p6[li],
                    p7[li],
                    p8[li],
                    table.unpack(xout, 1, nx)
            end
        end
        -- @generated direct_iterators end
        ctx.step = step
        return ctx
    end

    -- The iteration contexts of queries that are not cached (created on every call: change
    -- filters, the first request of a shape, shapes beyond MAX_SHAPES, ids that are not alive),
    -- reused while no loop runs on them, so that such a query does not build its
    -- iterator on every call: [n] is the for-in context for n returned ids (new_direct),
    -- .buffered[n] the one of a small query (scan.new_buffered), .each the context of
    -- query:each.
    local spare_contexts: { [any]: any } = { buffered = {} }

    local function direct_iter(query: QueryState): (any, any, any)
        if query.wild_values then
            mirror.ensure(query)
        end
        local n_ids = #query.ids
        if not query.is_cached and n_ids <= 8 then
            -- a query made for this loop: a small one gathers its matches first (see scan.fill)
            local buffered = spare_contexts.buffered[n_ids]
            if buffered == nil or buffered.busy then
                buffered = scan.new_buffered(n_ids)
                spare_contexts.buffered[n_ids] = buffered
            end
            local seen = query.seen_tick
            local driver = plan_query(query, buffered.others, buffered.without)
            if driver == nil then
                return NOOP, nil, 0
            end
            if
                driver.word_count <= BUFFER_WORDS
                and scan.fill(buffered.buf, driver, buffered.others, buffered.without)
            then
                buffered.bind(query)
                buffered.busy = true
                return buffered.step, nil, 0
            end
            -- the loop goes the general way, which plans again: over the same changes (a plan
            -- marks the changes of the change filters as seen)
            if query.tracking then
                query.seen_tick = seen
            end
        end
        local ctx = query.direct
        if ctx == nil or ctx.busy then
            -- first iteration, or the previous loop was left early or is still running
            local n = #query.ids
            if query.is_cached then
                ctx = new_direct(n)
                query.direct = ctx
            else
                ctx = spare_contexts[n]
                if ctx == nil or ctx.busy then
                    ctx = new_direct(n)
                    spare_contexts[n] = ctx
                end
            end
        end
        local driver = plan_query(query, ctx.others, ctx.without)
        if driver == nil then
            return NOOP, nil, 0
        end
        ctx.bind(query, driver)
        ctx.busy = true
        return ctx.step, nil, 0
    end

    -- Builds the match list of a cached query: the matches grouped by value page (see the
    -- list fields of QueryState), with the value page of every returned id per group.
    local function build_list(query: QueryState, planned: boolean?)
        -- the spans of the matches: those that choose_mode kept (planned), else a pass now
        local n_spans = if planned then scan.count else -1
        if n_spans < 0 then
            n_spans = 0
            local driver, others, without = plan_query(query, scan.others, scan.without)
            if driver then
                local advance = scan.advance
                scan.bind(driver, others, without)
                local spans = scan.spans
                local top = 0
                while true do
                    local first, last, m = advance()
                    if first == nil then
                        break
                    end
                    spans[top + 1] = first
                    spans[top + 2] = last :: number
                    spans[top + 3] = m
                    top += 3
                end
                n_spans = top // 3
            end
        end
        if query.list_gpages == NO_STATE then
            -- the first list of the query
            query.list_ghint = {}
            query.list_cols = {}
        end
        if query.list_readers > 0 or query.list_gpages == NO_STATE then
            -- a loop over the current list has not finished (a nested iteration of the query
            -- after a change, or a loop left early): it keeps the old tables
            query.list_gpages = {}
            query.list_items = {}
            query.list_sizes = {}
            query.list_firsts = {}
            query.list_first_lis = {}
            query.list_pages = {}
            query.list_count = 0
            query.list_groups = 0
            query.list_step = nil
            query.list_reset = nil
            query.list_epoch += 1
            query.list_readers = 0
        end
        local gpages, gitems, gsizes = query.list_gpages, query.list_items, query.list_sizes
        local firsts, first_lis = query.list_firsts, query.list_first_lis
        local ghint = query.list_ghint
        local cols = query.list_cols
        for i, id in query.ids do
            cols[i] = columns[id] or EMPTY_PAGES
        end
        local n_cols = #cols
        local pages_lists = query.list_pages
        for k = 1, n_cols do
            if pages_lists[k] == nil then
                pages_lists[k] = {}
            end
        end
        local n, groups = 0, 0
        local spans = scan.spans
        local top = n_spans * 3
        local at = 1
        while at <= top do
            local page = spans[at] // PAGE_SIZE + 1
            -- the spans of the page first, so that the array of its group gets its exact size
            -- (an array grown a match at a time keeps up to twice the room it needs)
            local lo, count = at, 0
            repeat
                local m = spans[at + 2]
                count += if m == FULL_WORD then spans[at + 1] - spans[at] + 1 else popcount(m)
                at += 3
            until at > top or spans[at] // PAGE_SIZE + 1 ~= page
            groups += 1
            gpages[groups] = page
            ghint[page] = groups
            for k = 1, n_cols do
                pages_lists[k][groups] = cols[k][page] or EMPTY
            end
            -- the array of the group in the previous list is reused when it is large enough
            local items = gitems[groups]
            local old_size = gsizes[groups]
            if items == nil or old_size == nil or old_size < count then
                -- (room for one more match: a patch that adds one does not grow it)
                items = table.create(2 * count + 2) :: { number }
                gitems[groups] = items
            end
            gsizes[groups] = count
            n += count
            local offset = (page - 1) * PAGE_SIZE - 1
            local i = 0
            for sp = lo, at - 1, 3 do
                local a, mm = spans[sp], spans[sp + 2]
                if mm == FULL_WORD then
                    for slot = a, spans[sp + 1] do
                        i += 2
                        items[i - 1] = alive[slot]
                        items[i] = slot - offset
                    end
                else
                    repeat
                        local slot = a + countrz(mm)
                        mm = band(mm, mm - 1)
                        i += 2
                        items[i - 1] = alive[slot]
                        items[i] = slot - offset
                    until mm == 0
                end
            end
            firsts[groups] = items[1]
            first_lis[groups] = items[2]
        end
        if top > SPANS_KEPT * 3 then
            scan.spans = {} -- the scratch grown by a large list is not kept
        end
        for g = groups + 1, query.list_groups do
            gpages[g] = nil
            gitems[g] = nil
            gsizes[g] = nil
            firsts[g] = nil
            first_lis[g] = nil
            for k = 1, n_cols do
                pages_lists[k][g] = nil :: any
            end
        end
        query.list_count = n
        query.list_groups = groups
        local missing = false
        if groups == 0 then
            for _, id in query.filter_with do
                if records[id] == nil then
                    missing = true
                    break
                end
            end
        end
        query.list_missing = missing
    end

    local function list_iter(query: QueryState): (() -> ...any, () -> ())
        local gitems = query.list_items
        local sizes = query.list_sizes
        local firsts = query.list_firsts
        local first_lis = query.list_first_lis
        local pages_lists = query.list_pages
        local epoch = query.list_epoch
        local n = #query.ids

        -- @generated list_iterators begin
        if n == 0 then
            local g, j, last = 0, 0, 0
            local items = EMPTY
            return function(): ...any
                local k = j + 2
                if k > last then
                    local next_g = g + 1
                    local size = sizes[next_g]
                    if size == nil then
                        if g >= 0 then
                            g = -1 -- the end is counted once
                            if query.list_epoch == epoch then
                                query.list_busy = false
                                query.list_readers -= 1
                            end
                        end
                        return nil
                    end
                    g = next_g
                    if size == 1 then
                        -- a group of one match: its array is not read
                        j, last = 0, 0
                        return firsts[next_g]
                    end
                    last = size * 2
                    items = gitems[next_g]
                    k = 2
                end
                j = k
                return items[k - 1]
            end, function()
                g, j, last = 0, 0, 0
            end
        elseif n == 1 then
            local g, j, last = 0, 0, 0
            local items = EMPTY
            local g1 = pages_lists[1]
            local p1 = EMPTY
            return function(): ...any
                local k = j + 2
                if k > last then
                    local next_g = g + 1
                    local size = sizes[next_g]
                    if size == nil then
                        if g >= 0 then
                            g = -1 -- the end is counted once
                            if query.list_epoch == epoch then
                                query.list_busy = false
                                query.list_readers -= 1
                            end
                        end
                        return nil
                    end
                    g = next_g
                    p1 = g1[next_g]
                    if size == 1 then
                        -- a group of one match: its array is not read
                        j, last = 0, 0
                        local li = first_lis[next_g]
                        return firsts[next_g], p1[li]
                    end
                    last = size * 2
                    items = gitems[next_g]
                    k = 2
                end
                j = k
                local li = items[k]
                return items[k - 1], p1[li]
            end, function()
                g, j, last = 0, 0, 0
            end
        elseif n == 2 then
            local g, j, last = 0, 0, 0
            local items = EMPTY
            local g1, g2 = pages_lists[1], pages_lists[2]
            local p1, p2 = EMPTY, EMPTY
            return function(): ...any
                local k = j + 2
                if k > last then
                    local next_g = g + 1
                    local size = sizes[next_g]
                    if size == nil then
                        if g >= 0 then
                            g = -1 -- the end is counted once
                            if query.list_epoch == epoch then
                                query.list_busy = false
                                query.list_readers -= 1
                            end
                        end
                        return nil
                    end
                    g = next_g
                    p1 = g1[next_g]
                    p2 = g2[next_g]
                    if size == 1 then
                        -- a group of one match: its array is not read
                        j, last = 0, 0
                        local li = first_lis[next_g]
                        return firsts[next_g], p1[li], p2[li]
                    end
                    last = size * 2
                    items = gitems[next_g]
                    k = 2
                end
                j = k
                local li = items[k]
                return items[k - 1], p1[li], p2[li]
            end, function()
                g, j, last = 0, 0, 0
            end
        elseif n == 3 then
            local g, j, last = 0, 0, 0
            local items = EMPTY
            local g1, g2, g3 = pages_lists[1], pages_lists[2], pages_lists[3]
            local p1, p2, p3 = EMPTY, EMPTY, EMPTY
            return function(): ...any
                local k = j + 2
                if k > last then
                    local next_g = g + 1
                    local size = sizes[next_g]
                    if size == nil then
                        if g >= 0 then
                            g = -1 -- the end is counted once
                            if query.list_epoch == epoch then
                                query.list_busy = false
                                query.list_readers -= 1
                            end
                        end
                        return nil
                    end
                    g = next_g
                    p1 = g1[next_g]
                    p2 = g2[next_g]
                    p3 = g3[next_g]
                    if size == 1 then
                        -- a group of one match: its array is not read
                        j, last = 0, 0
                        local li = first_lis[next_g]
                        return firsts[next_g], p1[li], p2[li], p3[li]
                    end
                    last = size * 2
                    items = gitems[next_g]
                    k = 2
                end
                j = k
                local li = items[k]
                return items[k - 1], p1[li], p2[li], p3[li]
            end, function()
                g, j, last = 0, 0, 0
            end
        elseif n == 4 then
            local g, j, last = 0, 0, 0
            local items = EMPTY
            local g1, g2, g3, g4 = pages_lists[1], pages_lists[2], pages_lists[3], pages_lists[4]
            local p1, p2, p3, p4 = EMPTY, EMPTY, EMPTY, EMPTY
            return function(): ...any
                local k = j + 2
                if k > last then
                    local next_g = g + 1
                    local size = sizes[next_g]
                    if size == nil then
                        if g >= 0 then
                            g = -1 -- the end is counted once
                            if query.list_epoch == epoch then
                                query.list_busy = false
                                query.list_readers -= 1
                            end
                        end
                        return nil
                    end
                    g = next_g
                    p1 = g1[next_g]
                    p2 = g2[next_g]
                    p3 = g3[next_g]
                    p4 = g4[next_g]
                    if size == 1 then
                        -- a group of one match: its array is not read
                        j, last = 0, 0
                        local li = first_lis[next_g]
                        return firsts[next_g], p1[li], p2[li], p3[li], p4[li]
                    end
                    last = size * 2
                    items = gitems[next_g]
                    k = 2
                end
                j = k
                local li = items[k]
                return items[k - 1], p1[li], p2[li], p3[li], p4[li]
            end, function()
                g, j, last = 0, 0, 0
            end
        elseif n == 5 then
            local g, j, last = 0, 0, 0
            local items = EMPTY
            local g1, g2, g3, g4, g5 = pages_lists[1], pages_lists[2], pages_lists[3], pages_lists[4], pages_lists[5]
            local p1, p2, p3, p4, p5 = EMPTY, EMPTY, EMPTY, EMPTY, EMPTY
            return function(): ...any
                local k = j + 2
                if k > last then
                    local next_g = g + 1
                    local size = sizes[next_g]
                    if size == nil then
                        if g >= 0 then
                            g = -1 -- the end is counted once
                            if query.list_epoch == epoch then
                                query.list_busy = false
                                query.list_readers -= 1
                            end
                        end
                        return nil
                    end
                    g = next_g
                    p1 = g1[next_g]
                    p2 = g2[next_g]
                    p3 = g3[next_g]
                    p4 = g4[next_g]
                    p5 = g5[next_g]
                    if size == 1 then
                        -- a group of one match: its array is not read
                        j, last = 0, 0
                        local li = first_lis[next_g]
                        return firsts[next_g], p1[li], p2[li], p3[li], p4[li], p5[li]
                    end
                    last = size * 2
                    items = gitems[next_g]
                    k = 2
                end
                j = k
                local li = items[k]
                return items[k - 1], p1[li], p2[li], p3[li], p4[li], p5[li]
            end, function()
                g, j, last = 0, 0, 0
            end
        elseif n == 6 then
            local g, j, last = 0, 0, 0
            local items = EMPTY
            local g1, g2, g3, g4, g5, g6 =
                pages_lists[1], pages_lists[2], pages_lists[3], pages_lists[4], pages_lists[5], pages_lists[6]
            local p1, p2, p3, p4, p5, p6 = EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY
            return function(): ...any
                local k = j + 2
                if k > last then
                    local next_g = g + 1
                    local size = sizes[next_g]
                    if size == nil then
                        if g >= 0 then
                            g = -1 -- the end is counted once
                            if query.list_epoch == epoch then
                                query.list_busy = false
                                query.list_readers -= 1
                            end
                        end
                        return nil
                    end
                    g = next_g
                    p1 = g1[next_g]
                    p2 = g2[next_g]
                    p3 = g3[next_g]
                    p4 = g4[next_g]
                    p5 = g5[next_g]
                    p6 = g6[next_g]
                    if size == 1 then
                        -- a group of one match: its array is not read
                        j, last = 0, 0
                        local li = first_lis[next_g]
                        return firsts[next_g], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li]
                    end
                    last = size * 2
                    items = gitems[next_g]
                    k = 2
                end
                j = k
                local li = items[k]
                return items[k - 1], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li]
            end, function()
                g, j, last = 0, 0, 0
            end
        elseif n == 7 then
            local g, j, last = 0, 0, 0
            local items = EMPTY
            local g1, g2, g3, g4, g5, g6, g7 =
                pages_lists[1],
                pages_lists[2],
                pages_lists[3],
                pages_lists[4],
                pages_lists[5],
                pages_lists[6],
                pages_lists[7]
            local p1, p2, p3, p4, p5, p6, p7 = EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY
            return function(): ...any
                local k = j + 2
                if k > last then
                    local next_g = g + 1
                    local size = sizes[next_g]
                    if size == nil then
                        if g >= 0 then
                            g = -1 -- the end is counted once
                            if query.list_epoch == epoch then
                                query.list_busy = false
                                query.list_readers -= 1
                            end
                        end
                        return nil
                    end
                    g = next_g
                    p1 = g1[next_g]
                    p2 = g2[next_g]
                    p3 = g3[next_g]
                    p4 = g4[next_g]
                    p5 = g5[next_g]
                    p6 = g6[next_g]
                    p7 = g7[next_g]
                    if size == 1 then
                        -- a group of one match: its array is not read
                        j, last = 0, 0
                        local li = first_lis[next_g]
                        return firsts[next_g], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li]
                    end
                    last = size * 2
                    items = gitems[next_g]
                    k = 2
                end
                j = k
                local li = items[k]
                return items[k - 1], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li]
            end, function()
                g, j, last = 0, 0, 0
            end
        elseif n == 8 then
            local g, j, last = 0, 0, 0
            local items = EMPTY
            local g1, g2, g3, g4, g5, g6, g7, g8 =
                pages_lists[1],
                pages_lists[2],
                pages_lists[3],
                pages_lists[4],
                pages_lists[5],
                pages_lists[6],
                pages_lists[7],
                pages_lists[8]
            local p1, p2, p3, p4, p5, p6, p7, p8 = EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY
            return function(): ...any
                local k = j + 2
                if k > last then
                    local next_g = g + 1
                    local size = sizes[next_g]
                    if size == nil then
                        if g >= 0 then
                            g = -1 -- the end is counted once
                            if query.list_epoch == epoch then
                                query.list_busy = false
                                query.list_readers -= 1
                            end
                        end
                        return nil
                    end
                    g = next_g
                    p1 = g1[next_g]
                    p2 = g2[next_g]
                    p3 = g3[next_g]
                    p4 = g4[next_g]
                    p5 = g5[next_g]
                    p6 = g6[next_g]
                    p7 = g7[next_g]
                    p8 = g8[next_g]
                    if size == 1 then
                        -- a group of one match: its array is not read
                        j, last = 0, 0
                        local li = first_lis[next_g]
                        return firsts[next_g], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li], p8[li]
                    end
                    last = size * 2
                    items = gitems[next_g]
                    k = 2
                end
                j = k
                local li = items[k]
                return items[k - 1], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li], p8[li]
            end, function()
                g, j, last = 0, 0, 0
            end
        end
        -- @generated list_iterators end
        error("list mode supports at most 8 values") -- choose_mode never picks it for more
    end

    -- Set by observe_record when a record of the query is not the one observed before.
    local observed_changed = false

    -- The slow path of iteration_mode: a record was created or freed somewhere, so the records
    -- of the terms of the query are looked up again. observed[1..observed_records] holds the
    -- records that exist, in the order of the terms (a term without a record takes no entry:
    -- only the creation of its record, which changes records_generation, can change that), and
    -- after them the columns of the returned ids. Returns false when the records or the
    -- columns are not the ones observed before (they are observed from now on). A record
    -- observed by a cached query gets a change journal.
    local function observe_record(query: QueryState, n: number, id: i53): number
        local rec = records[id]
        if rec == nil then
            return n
        end
        if rec.kind == KIND_TARGET then
            target_materialize(rec)
        end
        n += 1
        local observed = query.observed
        if observed[n] ~= rec then
            observed[n] = rec
            query.versions[n] = rec.version
            observed_changed = true
            if not rec.journal then
                journal_grow(rec, JOURNAL_MIN)
            end
        end
        return n
    end

    local function observe_records(query: QueryState): boolean
        observed_changed = false
        local n = 0
        for _, id in query.filter_with do
            n = observe_record(query, n, id)
        end
        query.observed_with = n
        local filter_without = query.filter_without
        if filter_without then
            for _, id in filter_without do
                n = observe_record(query, n, id)
            end
        end
        if query.skip_disabled then
            n = observe_record(query, n, EcsDisabled)
        end
        local any_groups = query.any_groups
        if any_groups then
            for _, group in any_groups do
                for _, id in group do
                    n = observe_record(query, n, id)
                end
            end
        end
        local same = not observed_changed and n == query.observed_records
        query.observed_records = n
        local observed = query.observed
        for _, id in query.ids do
            n += 1
            local pages: any = columns[id] or false
            if observed[n] ~= pages then
                observed[n] = pages
                same = false
            end
        end
        return same
    end

    -- The slots noted by the journals of the records of a query since its previous loop, as
    -- collected by iteration_mode: change_slots[1..change_count] (a slot may repeat).
    local change_slots: { number } = {}
    local change_count = 0

    -- The noted changes of the versions from + 1..to of the record `rec`, as the last query read
    -- them from its journal: the queries of a frame that observe a changed record read the same
    -- range, so it is read once. valid is false when an entry of the range was missing (a change
    -- of many slots, or an entry overwritten); for the n entries, the word of each slot, its bit
    -- and the slot, with the first slot of a page as a negative bit (it may note a new value page,
    -- see new_page). When masks_ready, masks[w] holds the bits of the noted slots of word w and
    -- notes[1..note_count] the slots with a negative bit (made for a query whose smallest term
    -- has few words, see iteration_mode).
    local collected: any = {
        rec = nil,
        from = 0,
        to = 0,
        valid = false,
        n = 0,
        w = {},
        bit = {},
        slot = {},
        masks_ready = false,
        masks = {},
        notes = {},
        note_count = 0,
    }

    -- How a cached query is iterated: 1 = direct bitsets, 2 = match list.
    local function choose_mode(query: QueryState): number
        if #query.ids > 8 then
            return 1
        end
        local driver, others, without = plan_query(query, scan.others, scan.without)
        if driver == nil then
            -- nothing matches: an empty list is iterated at no cost
            build_list(query)
            return 2
        end
        -- direct iteration is fastest over runs of full words, the list over scattered matches;
        -- the spans of the pass are kept for build_list (a pass saved: at most LIST_MAX spans)
        local advance = scan.advance
        scan.bind(driver, others, without)
        local spans = scan.spans
        local top = 0
        local in_runs, scattered = 0, 0
        while true do
            local first, last, m = advance()
            if first == nil then
                break
            end
            if m == FULL_WORD then
                in_runs += (last :: number) - first + 1
            else
                scattered += popcount(m)
            end
            if top >= 0 then
                if top < LIST_MAX * 3 then
                    spans[top + 1] = first
                    spans[top + 2] = last :: number
                    spans[top + 3] = m
                    top += 3
                else
                    top = -1 -- too many: build_list passes over the bitsets again
                end
            end
        end
        if (in_runs > 0 and scattered <= in_runs) or scattered > LIST_MAX then
            if top < 0 or top > SPANS_KEPT * 3 then
                scan.spans = {} -- the scratch grown by a large pass is not kept
            end
            return 1
        end
        scan.count = if top >= 0 then top // 3 else -1
        build_list(query, true)
        return 2
    end

    -- The arrays of removed groups, reused for new ones (patch_list), at most SPARE_ITEMS.
    local spare_items: { { number } } = {}

    -- Gives a query copies of its list tables and of every group array: a loop over the
    -- current list has not finished and keeps the old ones. The copies are the query's alone,
    -- so the updates after this one change them in place, until a loop over them does not
    -- finish before an update.
    local function detach_list(query: QueryState)
        query.list_gpages = table.clone(query.list_gpages)
        local gitems = table.clone(query.list_items)
        for g = 1, query.list_groups do
            gitems[g] = table.clone(gitems[g])
        end
        query.list_items = gitems
        query.list_sizes = table.clone(query.list_sizes)
        query.list_firsts = table.clone(query.list_firsts)
        query.list_first_lis = table.clone(query.list_first_lis)
        local pages_lists = table.clone(query.list_pages)
        for k, list in pages_lists do
            pages_lists[k] = table.clone(list)
        end
        query.list_pages = pages_lists
        query.list_step = nil
        query.list_reset = nil
        query.list_epoch += 1
        query.list_readers = 0
    end

    -- The words of the terms of a query for patch_list: a record keeps its words table while
    -- it lives, so the lists hold until a record is created or freed.
    local function term_words(query: QueryState)
        local with_records: { Record } = {}
        local empty = false
        for _, id in query.filter_with do
            local rec = records[id]
            if rec == nil then
                empty = true -- a required id without a record: nothing matches
            else
                if rec.kind == KIND_TARGET then
                    target_materialize(rec)
                end
                table.insert(with_records, rec)
            end
        end
        -- the smallest terms first: a noted slot that does not match fails on them at once
        table.sort(with_records, function(a: Record, b: Record): boolean
            return a.word_count < b.word_count
        end)
        local with: { Words } = table.create(#with_records) :: { Words }
        for i, rec in with_records do
            with[i] = rec.words
        end
        local any: { { Words } } = {}
        local any_groups = query.any_groups
        if any_groups then
            for k, group in any_groups do
                local list: { Words } = {}
                for _, id in group do
                    local rec = records[id]
                    if rec then
                        if rec.kind == KIND_TARGET then
                            target_materialize(rec)
                        end
                        table.insert(list, rec.words)
                    end
                end
                any[k] = list
            end
        end
        local without: { Words } = {}
        local filter_without = query.filter_without
        if filter_without then
            for _, id in filter_without do
                local rec = records[id]
                if rec then
                    if rec.kind == KIND_TARGET then
                        target_materialize(rec)
                    end
                    table.insert(without, rec.words)
                end
            end
        end
        if query.skip_disabled then
            local rec = records[EcsDisabled]
            if rec then
                table.insert(without, rec.words)
            end
        end
        local terms: Terms = {
            generation = records_generation,
            with = with,
            any = if #any > 0 then any else nil,
            without = if #without > 0 then without else nil,
            -- a query without terms matches nothing
            empty = empty or (#with == 0 and #any == 0),
        }
        query.terms = terms
    end

    -- Brings the match list of a cached query up to date after the changes noted in the
    -- journals of its records (change_slots): each noted slot is tested against the words of
    -- the terms (the same tests as plan_query and the span generator) and inserted into or
    -- removed from its group, found through list_ghint or a binary search; a group is created
    -- or removed with its first or last match. A noted first slot of a page (new_page notes a
    -- page creation so) makes its group read its page references again. While a loop over the
    -- list has not finished, the list is copied first (detach_list). The changes are few for
    -- the list (iteration_mode passes over the bitsets after more). Returns false when the list
    -- grew past LIST_MAX (the query iterates the bitsets then).
    local function patch_list(query: QueryState): boolean
        local changes = change_count
        local current = query.terms
        if current == nil or current.generation ~= records_generation then
            term_words(query)
        end
        local terms = query.terms :: Terms
        if terms.empty then
            build_list(query)
            return true
        end
        local patch_with = terms.with
        local n_with = #patch_with
        local patch_any = terms.any
        local patch_without = terms.without
        -- a loop over the list has not finished: it keeps the old tables
        if query.list_readers > 0 then
            detach_list(query)
        end
        local gpages, gitems, gsizes = query.list_gpages, query.list_items, query.list_sizes
        local firsts, first_lis = query.list_firsts, query.list_first_lis
        local ghint = query.list_ghint
        local pages_lists = query.list_pages
        local cols = query.list_cols
        local n_cols = #cols
        local count = query.list_count
        local groups = query.list_groups
        -- the smallest required term (patch_with is sorted by size): most noted slots of a large
        -- term fail on it at once
        local smallest = if n_with > 0 then patch_with[1] else nil
        for c = 1, changes do
            local s = change_slots[c]
            local w = s // 32 + 1
            local bit = lshift(1, s % 32)
            -- whether the slot matches now
            local member = true
            if smallest then
                local x = smallest[w]
                if x == nil or band(x, bit) == 0 then
                    if ghint[s // PAGE_SIZE + 1] == nil then
                        continue -- the page never had a group: the slot is not in the list
                    end
                    member = false
                end
            end
            for t = 2, if member then n_with else 0 do
                local x = patch_with[t][w]
                if x == nil or band(x, bit) == 0 then
                    member = false
                    break
                end
            end
            if member and patch_any then
                for _, list in patch_any do
                    local found = false
                    for _, words in list do
                        local x = words[w]
                        if x and band(x, bit) ~= 0 then
                            found = true
                            break
                        end
                    end
                    if not found then
                        member = false
                        break
                    end
                end
            end
            if member and patch_without then
                for _, words in patch_without do
                    local x = words[w]
                    if x and band(x, bit) ~= 0 then
                        member = false
                        break
                    end
                end
            end
            -- the group of the page: the hint, else a binary search (gpages is ascending)
            local page = s // PAGE_SIZE + 1
            local g = ghint[page]
            if g == nil and not member then
                continue -- the page never had a group: the slot is not in the list
            end
            local li = s % PAGE_SIZE + 1
            if g == nil or gpages[g] ~= page then
                local lo, hi = 1, groups
                g = 0
                while lo <= hi do
                    local mid = (lo + hi) // 2
                    local gp = gpages[mid]
                    if gp < page then
                        lo = mid + 1
                    elseif gp > page then
                        hi = mid - 1
                    else
                        g = mid
                        break
                    end
                end
                if g == 0 then
                    if member then
                        local spares = #spare_items
                        local items = spare_items[spares]
                        if items then
                            spare_items[spares] = nil
                        else
                            items = {}
                        end
                        local e = alive[s]
                        items[1] = e
                        items[2] = li
                        if lo > groups then
                            -- a group after the last one: no shifting
                            gpages[lo] = page
                            gitems[lo] = items
                            gsizes[lo] = 1
                            firsts[lo] = e
                            first_lis[lo] = li
                            for k = 1, n_cols do
                                pages_lists[k][lo] = cols[k][page] or EMPTY
                            end
                        else
                            table.insert(gpages, lo, page)
                            table.insert(gitems, lo, items)
                            table.insert(gsizes, lo, 1)
                            table.insert(firsts, lo, e)
                            table.insert(first_lis, lo, li)
                            for k = 1, n_cols do
                                table.insert(pages_lists[k], lo, cols[k][page] or EMPTY)
                            end
                        end
                        ghint[page] = lo
                        groups += 1
                        count += 1
                    end
                    continue
                end
                ghint[page] = g
            end
            local items = gitems[g]
            local size = gsizes[g]
            -- the position of the slot in the group: the page indices are ascending
            local a, b, at = 1, size, 0
            while a <= b do
                local mid = (a + b) // 2
                local x = items[2 * mid]
                if x < li then
                    a = mid + 1
                elseif x > li then
                    b = mid - 1
                else
                    at = mid
                    break
                end
            end
            if member or at > 0 then
                if member then
                    local e = alive[s] -- a slot in the list may hold another entity now
                    if at > 0 then
                        items[2 * at - 1] = e
                        if at == 1 then
                            firsts[g] = e
                        end
                    else
                        table.move(items, 2 * a - 1, 2 * size, 2 * a + 1)
                        items[2 * a - 1] = e
                        items[2 * a] = li
                        gsizes[g] = size + 1
                        count += 1
                        if a == 1 then
                            firsts[g] = e
                            first_lis[g] = li
                        end
                    end
                elseif size == 1 then
                    if g == groups then
                        -- the last group: no shifting
                        gpages[g] = nil
                        gitems[g] = nil
                        gsizes[g] = nil
                        firsts[g] = nil
                        first_lis[g] = nil
                        for k = 1, n_cols do
                            pages_lists[k][g] = nil :: any
                        end
                    else
                        table.remove(gpages, g)
                        table.remove(gitems, g)
                        table.remove(gsizes, g)
                        table.remove(firsts, g)
                        table.remove(first_lis, g)
                        for k = 1, n_cols do
                            table.remove(pages_lists[k], g)
                        end
                    end
                    groups -= 1
                    count -= 1
                    items[1], items[2] = nil, nil
                    local spares = #spare_items
                    if spares < SPARE_ITEMS then
                        spare_items[spares + 1] = items
                    end
                    continue
                else
                    table.move(items, 2 * at + 1, 2 * size, 2 * at - 1)
                    items[2 * size - 1], items[2 * size] = nil, nil
                    gsizes[g] = size - 1
                    count -= 1
                    if at == 1 then
                        firsts[g] = items[1]
                        first_lis[g] = items[2]
                    end
                end
            end
            if li == 1 then
                -- a page creation notes the first slot of the page: the group reads its pages
                for k = 1, n_cols do
                    pages_lists[k][g] = cols[k][page] or EMPTY
                end
            end
        end
        query.list_count = count
        query.list_groups = groups
        return count <= LIST_MAX
    end

    -- Debug worlds check every patched list against a scan of the bitsets.
    local function verify_list(query: QueryState)
        local slots: { number } = {}
        local driver, others, without = plan_query(query, scan.others, scan.without)
        if driver then
            local advance = scan.advance
            scan.bind(driver, others, without)
            while true do
                local first, last, m = advance()
                if first == nil then
                    break
                end
                if m == FULL_WORD then
                    for s = first, last :: number do
                        table.insert(slots, s)
                    end
                else
                    repeat
                        table.insert(slots, first + countrz(m))
                        m = band(m, m - 1)
                    until m == 0
                end
            end
        end
        local cols = value_pages(query)
        local i = 0
        local previous = 0
        local ok = #query.list_sizes == query.list_groups
        for g = 1, query.list_groups do
            local page = query.list_gpages[g]
            local size = query.list_sizes[g]
            ok = ok and page > previous and size > 0
            previous = page
            for k, pages in cols do
                ok = ok and query.list_pages[k][g] == (pages[page] or EMPTY)
            end
            local items = query.list_items[g]
            ok = ok and query.list_firsts[g] == items[1] and query.list_first_lis[g] == items[2]
            local offset = (page - 1) * PAGE_SIZE - 1
            for j = 1, size do
                i += 1
                local s = offset + items[2 * j]
                ok = ok and slots[i] == s and items[2 * j - 1] == alive[s]
            end
        end
        if not ok or i ~= #slots or query.list_count ~= i then
            error("mErCS: the match list of a cached query differs from its bitsets (a library bug)", 4)
        end
    end

    -- (defined with the query modifiers below)
    local make_cached: (query: QueryState) -> QueryState
    local promote: (state: QueryState) -> boolean

    -- Mode of a query for this iteration: 1 = direct, 2 = match list. A cached query whose
    -- records changed a little since its previous loop (noted changes: at most a quarter of
    -- its match list, CHANGE_MIN..CHANGE_LIMIT) picks its mode (or patches its list) at once;
    -- after more changes it iterates the bitsets once and picks the mode at its next loop, so
    -- a query whose entities change by many before every loop is not rebuilding its list all
    -- the time. The loops of a query call it only when list_unchanged does not hold.
    local function iteration_mode(query: QueryState): number
        if not query.listable then
            -- the first state of a shape (see share_shape) iterated a second time is kept by the
            -- caller: it is shared, or cached as a query of its own (see promote)
            if query.first_use == nil then
                return 1
            end
            if not query.looped then
                query.looped = true
                return 1
            end
            if not promote(query) then
                make_cached(query)
            end
            if not query.listable then
                return 1
            end
        end
        if query.wild_values then
            -- before the records are observed: a new mirror is a new column
            mirror.ensure(query)
        end
        -- status 0: nothing changed since the previous loop of the query; 1: every change was
        -- noted and is still in the journals (the slots go to change_slots); 2: a record was
        -- created or freed, a returned column changed, or a change is not in a journal (a
        -- change of many slots, or an older one overwritten), and the query scans its records
        local status = 0
        local generation = query.observed_generation
        if generation ~= records_generation then
            query.observed_generation = records_generation
            -- the first observation (or the first after the terms changed) compares with
            -- nothing: the query picks its mode at once
            if not observe_records(query) and generation ~= nil then
                status = 2
            end
        end
        -- the versions of the records since the previous loop are remembered in any case
        local observed = query.observed
        local versions = query.versions
        local n = 0
        -- the noted changes are re-checked one by one while that costs less than one pass over
        -- the bitsets: the edits of a large part of the match list cost more, and so does the
        -- re-check of more slots than half of the words of the smallest term
        local limit = math.clamp(math.max(query.list_count // 4, query.scan_words // 2), CHANGE_MIN, CHANGE_LIMIT)
        -- the filters of the records with many changes (see below), looked up once, and the
        -- number of keys of the words table of the first one (its emptied words too)
        local filter1: Words?, filter2: Words?, filter3: Words? = nil, nil, nil
        local filter1_keys = 0
        local filters_found = false
        for k = 1, query.observed_records :: number do
            local rec = observed[k]
            do
                local version = rec.version
                local seen = versions[k]
                if seen ~= version then
                    versions[k] = version
                    if status ~= 2 then
                        status = 1
                        local count = version - seen
                        local journal = rec.journal
                        local size = rec.journal_mask + 1
                        if not journal or count > size or n + count > limit then
                            status = 2
                            if journal and count > size and count <= limit and count <= JOURNAL_MAX then
                                -- the journal is too short for the changes between two loops
                                -- of this query: a longer one serves the next loops
                                while size < count do
                                    size *= 2
                                end
                                journal_grow(rec, size)
                            end
                        elseif count <= 8 then
                            -- a few changes: read at once (patch_list tests them)
                            local mask = size - 1
                            for v = seen + 1, version do
                                local at = band(v, mask) * 2 + 1
                                if journal[at] ~= v then
                                    status = 2 -- a change without its entry
                                    break
                                end
                                n += 1
                                change_slots[n] = journal[at + 1]
                            end
                        else
                            -- Many changes of a record: a noted slot that a required record of
                            -- a list does not have is dropped, when every change of that record
                            -- is re-checked (it did not change, or its few changes are read at
                            -- once): the slot was not in the list and is not a match now, or a
                            -- change of that record re-checks it. The first record with many
                            -- changes picks the three smallest such records (the records before
                            -- it had few changes; a later one qualifies with at most 8 changes).
                            if not filters_found then
                                filters_found = true
                                if query.mode == 2 then
                                    local size1, size2, size3 = math.huge, math.huge, math.huge
                                    for j = 1, query.observed_with :: number do
                                        local other = observed[j]
                                        if j == k or (j > k and other.version - versions[j] > 8) then
                                            continue
                                        end
                                        local words_count = other.word_count
                                        if words_count < size1 then
                                            filter3, size3 = filter2, size2
                                            filter2, size2 = filter1, size1
                                            filter1, size1 = other.words, words_count
                                            filter1_keys = words_count + other.zeros
                                        elseif words_count < size2 then
                                            filter3, size3 = filter2, size2
                                            filter2, size2 = other.words, words_count
                                        elseif words_count < size3 then
                                            filter3, size3 = other.words, words_count
                                        end
                                    end
                                end
                            end
                            -- the range is read once for the queries that observe the record (see
                            -- collected)
                            local c = collected
                            if c.rec ~= rec or c.from ~= seen or c.to ~= version then
                                -- the entries of the versions after the seen one, in the ring
                                c.rec, c.from, c.to, c.valid = rec, seen, version, true
                                local cw, cbit, cslot = c.w, c.bit, c.slot
                                local last_at = size * 2 - 1
                                local at = band(seen + 1, size - 1) * 2 + 1
                                local m = 0
                                for v = seen + 1, version do
                                    if journal[at] ~= v then
                                        c.valid = false -- a change without its entry
                                        break
                                    end
                                    local slot = journal[at + 1]
                                    at = if at == last_at then 1 else at + 2
                                    m += 1
                                    cw[m] = slot // 32 + 1
                                    cbit[m] = if slot % PAGE_SIZE == 0 then -1 else lshift(1, slot % 32)
                                    cslot[m] = slot
                                end
                                c.n = m
                                c.masks_ready = false
                            end
                            if not c.valid then
                                status = 2
                            elseif filter1 and filter1_keys * 2 < c.n then
                                -- The smallest term has few words (a small tag shared with a
                                -- large term that many changes of a frame touch): its words are
                                -- tested against the noted bits of each word, which are made
                                -- once for all the queries, instead of each noted slot against
                                -- the terms. Each slot comes once; a negative bit always comes.
                                if not c.masks_ready then
                                    c.masks_ready = true
                                    local masks, notes = c.masks, c.notes
                                    table.clear(masks)
                                    local cw, cbit, cslot = c.w, c.bit, c.slot
                                    local note_count = 0
                                    for i = 1, c.n do
                                        local bit = cbit[i]
                                        if bit > 0 then
                                            local w = cw[i]
                                            masks[w] = bor(masks[w] or 0, bit)
                                        else
                                            note_count += 1
                                            notes[note_count] = cslot[i]
                                        end
                                    end
                                    c.note_count = note_count
                                end
                                local masks = c.masks
                                for w, x in filter1 :: Words do
                                    local hit = masks[w]
                                    if hit == nil then
                                        continue
                                    end
                                    hit = band(hit, x)
                                    if hit ~= 0 and filter2 then
                                        hit = band(hit, filter2[w] or 0)
                                        if hit ~= 0 and filter3 then
                                            hit = band(hit, filter3[w] or 0)
                                        end
                                    end
                                    local base = (w - 1) * 32
                                    while hit ~= 0 do
                                        n += 1
                                        change_slots[n] = base + countrz(hit)
                                        hit = band(hit, hit - 1)
                                    end
                                end
                                local notes = c.notes
                                for i = 1, c.note_count do
                                    n += 1
                                    change_slots[n] = notes[i]
                                end
                            else
                                local cw, cbit, cslot = c.w, c.bit, c.slot
                                for i = 1, c.n do
                                    if filter1 then
                                        local bit = cbit[i]
                                        if bit > 0 then
                                            local w = cw[i]
                                            local x = filter1[w]
                                            if x == nil or band(x, bit) == 0 then
                                                continue
                                            end
                                            if filter2 then
                                                x = filter2[w]
                                                if x == nil or band(x, bit) == 0 then
                                                    continue
                                                end
                                                if filter3 then
                                                    x = filter3[w]
                                                    if x == nil or band(x, bit) == 0 then
                                                        continue
                                                    end
                                                end
                                            end
                                        end
                                    end
                                    n += 1
                                    change_slots[n] = cslot[i]
                                end
                            end
                        end
                    end
                end
            end
        end
        change_count = n
        if status == 2 then
            query.mode = 0
            return 1
        end
        local mode = query.mode
        if mode == 0 then
            mode = choose_mode(query)
            query.mode = mode
        elseif mode == 2 and status == 1 then
            -- nothing to re-check when every noted slot was dropped (see filter1)
            if n > 0 and not patch_list(query) then
                query.mode = 0
                return 1
            end
            if debug then
                verify_list(query)
            end
        end
        return mode
    end

    -- Whether a query in list mode can use its list as it is: no record was created or freed
    -- and none of its records changed since its previous loop (the start of iteration_mode,
    -- inlined into the loops of a query: a stable query costs no call).
    local function list_unchanged(query: QueryState): boolean
        if query.mode ~= 2 or query.observed_generation ~= records_generation then
            return false
        end
        if query.list_missing then
            return true -- a required id has no record: nothing matches until one is created
        end
        local observed = query.observed
        local versions = query.versions
        for k = 1, query.observed_records :: number do
            if observed[k].version ~= versions[k] then
                return false
            end
        end
        return true
    end

    -- The iteration of a query handle (Query.__iter).
    local function query_iter(handle: QueryHandle): (any, any, any)
        local query = handle.state
        local listed = query.list_stamp == changes_stamp
        if listed then
            if debug and not list_unchanged(query) then
                error("mErCS: a cached query missed a change of its records (a library bug)", 2)
            end
        elseif list_unchanged(query) then
            listed = true
            query.list_stamp = changes_stamp
        else
            -- a query that selects nothing never has a list: it is refused here, so that the
            -- loops over lists that are up to date pay nothing for the check
            if not selects(query) then
                error(NO_TERMS, 2)
            end
            if iteration_mode(query) == 2 then
                listed = true
                query.list_stamp = changes_stamp
            end
        end
        if listed then
            if query.list_groups == 0 then
                return NOOP, nil, nil
            end
            local step = query.list_step
            if step and not query.list_busy then
                (query.list_reset :: () -> ())()
            else
                -- first iteration, or the previous loop was left early or is still running
                local reset
                step, reset = list_iter(query)
                query.list_step = step
                query.list_reset = reset
            end
            query.list_busy = true
            query.list_readers += 1
            return step, nil, nil
        end
        return direct_iter(query)
    end

    -- Callback loop over the match list of a cached query (see build_list).
    local function list_each(query: QueryState, callback: (...any) -> ())
        local n = #query.ids
        local gitems = query.list_items
        local sizes = query.list_sizes
        local firsts = query.list_firsts
        local first_lis = query.list_first_lis
        local groups = query.list_groups
        local pages_lists = query.list_pages

        -- @generated list_each begin
        if n == 0 then
            for g = 1, groups do
                local size = sizes[g]
                if size == 1 then
                    callback(firsts[g])
                else
                    local items = gitems[g]
                    for k = 1, size * 2, 2 do
                        callback(items[k])
                    end
                end
            end
            return
        elseif n == 1 then
            local g1 = pages_lists[1]
            for g = 1, groups do
                local size = sizes[g]
                local p1 = g1[g]
                if size == 1 then
                    local li = first_lis[g]
                    callback(firsts[g], p1[li])
                else
                    local items = gitems[g]
                    for k = 2, size * 2, 2 do
                        local li = items[k]
                        callback(items[k - 1], p1[li])
                    end
                end
            end
            return
        elseif n == 2 then
            local g1, g2 = pages_lists[1], pages_lists[2]
            for g = 1, groups do
                local size = sizes[g]
                local p1, p2 = g1[g], g2[g]
                if size == 1 then
                    local li = first_lis[g]
                    callback(firsts[g], p1[li], p2[li])
                else
                    local items = gitems[g]
                    for k = 2, size * 2, 2 do
                        local li = items[k]
                        callback(items[k - 1], p1[li], p2[li])
                    end
                end
            end
            return
        elseif n == 3 then
            local g1, g2, g3 = pages_lists[1], pages_lists[2], pages_lists[3]
            for g = 1, groups do
                local size = sizes[g]
                local p1, p2, p3 = g1[g], g2[g], g3[g]
                if size == 1 then
                    local li = first_lis[g]
                    callback(firsts[g], p1[li], p2[li], p3[li])
                else
                    local items = gitems[g]
                    for k = 2, size * 2, 2 do
                        local li = items[k]
                        callback(items[k - 1], p1[li], p2[li], p3[li])
                    end
                end
            end
            return
        elseif n == 4 then
            local g1, g2, g3, g4 = pages_lists[1], pages_lists[2], pages_lists[3], pages_lists[4]
            for g = 1, groups do
                local size = sizes[g]
                local p1, p2, p3, p4 = g1[g], g2[g], g3[g], g4[g]
                if size == 1 then
                    local li = first_lis[g]
                    callback(firsts[g], p1[li], p2[li], p3[li], p4[li])
                else
                    local items = gitems[g]
                    for k = 2, size * 2, 2 do
                        local li = items[k]
                        callback(items[k - 1], p1[li], p2[li], p3[li], p4[li])
                    end
                end
            end
            return
        elseif n == 5 then
            local g1, g2, g3, g4, g5 = pages_lists[1], pages_lists[2], pages_lists[3], pages_lists[4], pages_lists[5]
            for g = 1, groups do
                local size = sizes[g]
                local p1, p2, p3, p4, p5 = g1[g], g2[g], g3[g], g4[g], g5[g]
                if size == 1 then
                    local li = first_lis[g]
                    callback(firsts[g], p1[li], p2[li], p3[li], p4[li], p5[li])
                else
                    local items = gitems[g]
                    for k = 2, size * 2, 2 do
                        local li = items[k]
                        callback(items[k - 1], p1[li], p2[li], p3[li], p4[li], p5[li])
                    end
                end
            end
            return
        elseif n == 6 then
            local g1, g2, g3, g4, g5, g6 =
                pages_lists[1], pages_lists[2], pages_lists[3], pages_lists[4], pages_lists[5], pages_lists[6]
            for g = 1, groups do
                local size = sizes[g]
                local p1, p2, p3, p4, p5, p6 = g1[g], g2[g], g3[g], g4[g], g5[g], g6[g]
                if size == 1 then
                    local li = first_lis[g]
                    callback(firsts[g], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li])
                else
                    local items = gitems[g]
                    for k = 2, size * 2, 2 do
                        local li = items[k]
                        callback(items[k - 1], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li])
                    end
                end
            end
            return
        elseif n == 7 then
            local g1, g2, g3, g4, g5, g6, g7 =
                pages_lists[1],
                pages_lists[2],
                pages_lists[3],
                pages_lists[4],
                pages_lists[5],
                pages_lists[6],
                pages_lists[7]
            for g = 1, groups do
                local size = sizes[g]
                local p1, p2, p3, p4, p5, p6, p7 = g1[g], g2[g], g3[g], g4[g], g5[g], g6[g], g7[g]
                if size == 1 then
                    local li = first_lis[g]
                    callback(firsts[g], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li])
                else
                    local items = gitems[g]
                    for k = 2, size * 2, 2 do
                        local li = items[k]
                        callback(items[k - 1], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li])
                    end
                end
            end
            return
        elseif n == 8 then
            local g1, g2, g3, g4, g5, g6, g7, g8 =
                pages_lists[1],
                pages_lists[2],
                pages_lists[3],
                pages_lists[4],
                pages_lists[5],
                pages_lists[6],
                pages_lists[7],
                pages_lists[8]
            for g = 1, groups do
                local size = sizes[g]
                local p1, p2, p3, p4, p5, p6, p7, p8 = g1[g], g2[g], g3[g], g4[g], g5[g], g6[g], g7[g], g8[g]
                if size == 1 then
                    local li = first_lis[g]
                    callback(firsts[g], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li], p8[li])
                else
                    local items = gitems[g]
                    for k = 2, size * 2, 2 do
                        local li = items[k]
                        callback(items[k - 1], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li], p8[li])
                    end
                end
            end
            return
        end
        -- @generated list_each end
    end

    -- The callback loop of a query handle (Query.each).
    local function query_each(handle: QueryHandle, callback: (...any) -> ())
        local query = handle.state
        if query.list_stamp == changes_stamp then
            -- nothing that a cached query observes changed since this one found its list up to
            -- date
            if debug and not list_unchanged(query) then
                error("mErCS: a cached query missed a change of its records (a library bug)", 2)
            end
            if query.list_groups > 0 then
                local epoch = query.list_epoch
                query.list_readers += 1
                list_each(query, callback)
                if query.list_epoch == epoch then
                    query.list_readers -= 1
                end
            end
            return
        end
        -- list_unchanged(query), inline: a stable query costs no call
        local stable = query.mode == 2 and query.observed_generation == records_generation
        if stable and not query.list_missing then
            local observed = query.observed
            local versions = query.versions
            for k = 1, query.observed_records :: number do
                if observed[k].version ~= versions[k] then
                    stable = false
                    break
                end
            end
        end
        if not stable and not selects(query) then
            -- a query that selects nothing never has a list (see query_iter)
            error(NO_TERMS, 2)
        end
        if stable or iteration_mode(query) == 2 then
            query.list_stamp = changes_stamp
            if query.list_groups > 0 then
                local epoch = query.list_epoch
                query.list_readers += 1
                list_each(query, callback)
                if query.list_epoch == epoch then
                    query.list_readers -= 1
                end
            end
            return
        end
        local n = #query.ids
        if query.wild_values then
            mirror.ensure(query)
        end
        local ctx = query.each_ctx
        if ctx == nil or ctx.busy then
            -- an uncached query takes the spare context while no loop runs on it
            ctx = if query.is_cached then nil else spare_contexts.each
            if ctx == nil or ctx.busy then
                local advance, bind = new_advance()
                ctx = { busy = false, others = {}, without = {}, advance = advance, bind = bind, buf = {} }
                if query.is_cached then
                    query.each_ctx = ctx
                else
                    spare_contexts.each = ctx
                end
            end
        end
        local driver = plan_query(query, ctx.others, ctx.without)
        if driver == nil then
            return
        end
        ctx.busy = true
        local ids = query.ids
        local cp1, cp2, cp3, cp4 =
            columns[ids[1]] or EMPTY_PAGES,
            columns[ids[2]] or EMPTY_PAGES,
            columns[ids[3]] or EMPTY_PAGES,
            columns[ids[4]] or EMPTY_PAGES
        local cp5, cp6, cp7, cp8 =
            columns[ids[5]] or EMPTY_PAGES,
            columns[ids[6]] or EMPTY_PAGES,
            columns[ids[7]] or EMPTY_PAGES,
            columns[ids[8]] or EMPTY_PAGES
        if
            not query.is_cached
            and n <= 8
            and driver.word_count <= BUFFER_WORDS
            and scan.fill(ctx.buf, driver, ctx.others, ctx.without)
        then
            -- a small query made for this loop: its matches gathered first (see scan.fill)
            local buf = ctx.buf
            -- @generated buffer_each begin
            if n == 0 then
                local at = 1
                while true do
                    local x = buf[at]
                    if x == nil then
                        break
                    end
                    if x < 0 then
                        at += 1
                        x = buf[at]
                    end
                    at += 2
                    callback(x)
                end
            elseif n == 1 then
                local p1 = EMPTY
                local at = 1
                while true do
                    local x = buf[at]
                    if x == nil then
                        break
                    end
                    if x < 0 then
                        local page = -x
                        p1 = cp1[page] or EMPTY
                        at += 1
                        x = buf[at]
                    end
                    local li = buf[at + 1]
                    at += 2
                    callback(x, p1[li])
                end
            elseif n == 2 then
                local p1, p2 = EMPTY, EMPTY
                local at = 1
                while true do
                    local x = buf[at]
                    if x == nil then
                        break
                    end
                    if x < 0 then
                        local page = -x
                        p1 = cp1[page] or EMPTY
                        p2 = cp2[page] or EMPTY
                        at += 1
                        x = buf[at]
                    end
                    local li = buf[at + 1]
                    at += 2
                    callback(x, p1[li], p2[li])
                end
            elseif n == 3 then
                local p1, p2, p3 = EMPTY, EMPTY, EMPTY
                local at = 1
                while true do
                    local x = buf[at]
                    if x == nil then
                        break
                    end
                    if x < 0 then
                        local page = -x
                        p1 = cp1[page] or EMPTY
                        p2 = cp2[page] or EMPTY
                        p3 = cp3[page] or EMPTY
                        at += 1
                        x = buf[at]
                    end
                    local li = buf[at + 1]
                    at += 2
                    callback(x, p1[li], p2[li], p3[li])
                end
            elseif n == 4 then
                local p1, p2, p3, p4 = EMPTY, EMPTY, EMPTY, EMPTY
                local at = 1
                while true do
                    local x = buf[at]
                    if x == nil then
                        break
                    end
                    if x < 0 then
                        local page = -x
                        p1 = cp1[page] or EMPTY
                        p2 = cp2[page] or EMPTY
                        p3 = cp3[page] or EMPTY
                        p4 = cp4[page] or EMPTY
                        at += 1
                        x = buf[at]
                    end
                    local li = buf[at + 1]
                    at += 2
                    callback(x, p1[li], p2[li], p3[li], p4[li])
                end
            elseif n == 5 then
                local p1, p2, p3, p4, p5 = EMPTY, EMPTY, EMPTY, EMPTY, EMPTY
                local at = 1
                while true do
                    local x = buf[at]
                    if x == nil then
                        break
                    end
                    if x < 0 then
                        local page = -x
                        p1 = cp1[page] or EMPTY
                        p2 = cp2[page] or EMPTY
                        p3 = cp3[page] or EMPTY
                        p4 = cp4[page] or EMPTY
                        p5 = cp5[page] or EMPTY
                        at += 1
                        x = buf[at]
                    end
                    local li = buf[at + 1]
                    at += 2
                    callback(x, p1[li], p2[li], p3[li], p4[li], p5[li])
                end
            elseif n == 6 then
                local p1, p2, p3, p4, p5, p6 = EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY
                local at = 1
                while true do
                    local x = buf[at]
                    if x == nil then
                        break
                    end
                    if x < 0 then
                        local page = -x
                        p1 = cp1[page] or EMPTY
                        p2 = cp2[page] or EMPTY
                        p3 = cp3[page] or EMPTY
                        p4 = cp4[page] or EMPTY
                        p5 = cp5[page] or EMPTY
                        p6 = cp6[page] or EMPTY
                        at += 1
                        x = buf[at]
                    end
                    local li = buf[at + 1]
                    at += 2
                    callback(x, p1[li], p2[li], p3[li], p4[li], p5[li], p6[li])
                end
            elseif n == 7 then
                local p1, p2, p3, p4, p5, p6, p7 = EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY
                local at = 1
                while true do
                    local x = buf[at]
                    if x == nil then
                        break
                    end
                    if x < 0 then
                        local page = -x
                        p1 = cp1[page] or EMPTY
                        p2 = cp2[page] or EMPTY
                        p3 = cp3[page] or EMPTY
                        p4 = cp4[page] or EMPTY
                        p5 = cp5[page] or EMPTY
                        p6 = cp6[page] or EMPTY
                        p7 = cp7[page] or EMPTY
                        at += 1
                        x = buf[at]
                    end
                    local li = buf[at + 1]
                    at += 2
                    callback(x, p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li])
                end
            elseif n == 8 then
                local p1, p2, p3, p4, p5, p6, p7, p8 = EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY
                local at = 1
                while true do
                    local x = buf[at]
                    if x == nil then
                        break
                    end
                    if x < 0 then
                        local page = -x
                        p1 = cp1[page] or EMPTY
                        p2 = cp2[page] or EMPTY
                        p3 = cp3[page] or EMPTY
                        p4 = cp4[page] or EMPTY
                        p5 = cp5[page] or EMPTY
                        p6 = cp6[page] or EMPTY
                        p7 = cp7[page] or EMPTY
                        p8 = cp8[page] or EMPTY
                        at += 1
                        x = buf[at]
                    end
                    local li = buf[at + 1]
                    at += 2
                    callback(x, p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li], p8[li])
                end
            end
            -- @generated buffer_each end
            ctx.busy = false
            return
        end
        ctx.bind(driver, ctx.others, ctx.without)
        local advance = ctx.advance

        -- @generated direct_each begin
        if n == 0 then
            while true do
                local first, last, m = advance()
                if first == nil then
                    break
                end
                if m == FULL_WORD then
                    for s = first, last :: number do
                        local e = alive[s]
                        if e > 0 then
                            callback(e)
                        end
                    end
                else
                    repeat
                        local s = first + countrz(m)
                        m = band(m, m - 1)
                        local e = alive[s]
                        if e > 0 then
                            callback(e)
                        end
                    until m == 0
                end
            end
        elseif n == 1 then
            while true do
                local first, last, m = advance()
                if first == nil then
                    break
                end
                local page = first // PAGE_SIZE + 1
                local p1 = cp1[page] or EMPTY
                local page_offset = (page - 1) * PAGE_SIZE - 1
                if m == FULL_WORD then
                    for s = first, last :: number do
                        local e = alive[s]
                        if e > 0 then
                            local li = s - page_offset
                            callback(e, p1[li])
                        end
                    end
                else
                    repeat
                        local s = first + countrz(m)
                        m = band(m, m - 1)
                        local e = alive[s]
                        if e > 0 then
                            local li = s - page_offset
                            callback(e, p1[li])
                        end
                    until m == 0
                end
            end
        elseif n == 2 then
            while true do
                local first, last, m = advance()
                if first == nil then
                    break
                end
                local page = first // PAGE_SIZE + 1
                local p1, p2 = cp1[page] or EMPTY, cp2[page] or EMPTY
                local page_offset = (page - 1) * PAGE_SIZE - 1
                if m == FULL_WORD then
                    for s = first, last :: number do
                        local e = alive[s]
                        if e > 0 then
                            local li = s - page_offset
                            callback(e, p1[li], p2[li])
                        end
                    end
                else
                    repeat
                        local s = first + countrz(m)
                        m = band(m, m - 1)
                        local e = alive[s]
                        if e > 0 then
                            local li = s - page_offset
                            callback(e, p1[li], p2[li])
                        end
                    until m == 0
                end
            end
        elseif n == 3 then
            while true do
                local first, last, m = advance()
                if first == nil then
                    break
                end
                local page = first // PAGE_SIZE + 1
                local p1, p2, p3 = cp1[page] or EMPTY, cp2[page] or EMPTY, cp3[page] or EMPTY
                local page_offset = (page - 1) * PAGE_SIZE - 1
                if m == FULL_WORD then
                    for s = first, last :: number do
                        local e = alive[s]
                        if e > 0 then
                            local li = s - page_offset
                            callback(e, p1[li], p2[li], p3[li])
                        end
                    end
                else
                    repeat
                        local s = first + countrz(m)
                        m = band(m, m - 1)
                        local e = alive[s]
                        if e > 0 then
                            local li = s - page_offset
                            callback(e, p1[li], p2[li], p3[li])
                        end
                    until m == 0
                end
            end
        elseif n == 4 then
            while true do
                local first, last, m = advance()
                if first == nil then
                    break
                end
                local page = first // PAGE_SIZE + 1
                local p1, p2, p3, p4 = cp1[page] or EMPTY, cp2[page] or EMPTY, cp3[page] or EMPTY, cp4[page] or EMPTY
                local page_offset = (page - 1) * PAGE_SIZE - 1
                if m == FULL_WORD then
                    for s = first, last :: number do
                        local e = alive[s]
                        if e > 0 then
                            local li = s - page_offset
                            callback(e, p1[li], p2[li], p3[li], p4[li])
                        end
                    end
                else
                    repeat
                        local s = first + countrz(m)
                        m = band(m, m - 1)
                        local e = alive[s]
                        if e > 0 then
                            local li = s - page_offset
                            callback(e, p1[li], p2[li], p3[li], p4[li])
                        end
                    until m == 0
                end
            end
        elseif n == 5 then
            while true do
                local first, last, m = advance()
                if first == nil then
                    break
                end
                local page = first // PAGE_SIZE + 1
                local p1, p2, p3, p4, p5 =
                    cp1[page] or EMPTY, cp2[page] or EMPTY, cp3[page] or EMPTY, cp4[page] or EMPTY, cp5[page] or EMPTY
                local page_offset = (page - 1) * PAGE_SIZE - 1
                if m == FULL_WORD then
                    for s = first, last :: number do
                        local e = alive[s]
                        if e > 0 then
                            local li = s - page_offset
                            callback(e, p1[li], p2[li], p3[li], p4[li], p5[li])
                        end
                    end
                else
                    repeat
                        local s = first + countrz(m)
                        m = band(m, m - 1)
                        local e = alive[s]
                        if e > 0 then
                            local li = s - page_offset
                            callback(e, p1[li], p2[li], p3[li], p4[li], p5[li])
                        end
                    until m == 0
                end
            end
        elseif n == 6 then
            while true do
                local first, last, m = advance()
                if first == nil then
                    break
                end
                local page = first // PAGE_SIZE + 1
                local p1, p2, p3, p4, p5, p6 =
                    cp1[page] or EMPTY,
                    cp2[page] or EMPTY,
                    cp3[page] or EMPTY,
                    cp4[page] or EMPTY,
                    cp5[page] or EMPTY,
                    cp6[page] or EMPTY
                local page_offset = (page - 1) * PAGE_SIZE - 1
                if m == FULL_WORD then
                    for s = first, last :: number do
                        local e = alive[s]
                        if e > 0 then
                            local li = s - page_offset
                            callback(e, p1[li], p2[li], p3[li], p4[li], p5[li], p6[li])
                        end
                    end
                else
                    repeat
                        local s = first + countrz(m)
                        m = band(m, m - 1)
                        local e = alive[s]
                        if e > 0 then
                            local li = s - page_offset
                            callback(e, p1[li], p2[li], p3[li], p4[li], p5[li], p6[li])
                        end
                    until m == 0
                end
            end
        elseif n == 7 then
            while true do
                local first, last, m = advance()
                if first == nil then
                    break
                end
                local page = first // PAGE_SIZE + 1
                local p1, p2, p3, p4, p5, p6, p7 =
                    cp1[page] or EMPTY,
                    cp2[page] or EMPTY,
                    cp3[page] or EMPTY,
                    cp4[page] or EMPTY,
                    cp5[page] or EMPTY,
                    cp6[page] or EMPTY,
                    cp7[page] or EMPTY
                local page_offset = (page - 1) * PAGE_SIZE - 1
                if m == FULL_WORD then
                    for s = first, last :: number do
                        local e = alive[s]
                        if e > 0 then
                            local li = s - page_offset
                            callback(e, p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li])
                        end
                    end
                else
                    repeat
                        local s = first + countrz(m)
                        m = band(m, m - 1)
                        local e = alive[s]
                        if e > 0 then
                            local li = s - page_offset
                            callback(e, p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li])
                        end
                    until m == 0
                end
            end
        elseif n == 8 then
            while true do
                local first, last, m = advance()
                if first == nil then
                    break
                end
                local page = first // PAGE_SIZE + 1
                local p1, p2, p3, p4, p5, p6, p7, p8 =
                    cp1[page] or EMPTY,
                    cp2[page] or EMPTY,
                    cp3[page] or EMPTY,
                    cp4[page] or EMPTY,
                    cp5[page] or EMPTY,
                    cp6[page] or EMPTY,
                    cp7[page] or EMPTY,
                    cp8[page] or EMPTY
                local page_offset = (page - 1) * PAGE_SIZE - 1
                if m == FULL_WORD then
                    for s = first, last :: number do
                        local e = alive[s]
                        if e > 0 then
                            local li = s - page_offset
                            callback(e, p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li], p8[li])
                        end
                    end
                else
                    repeat
                        local s = first + countrz(m)
                        m = band(m, m - 1)
                        local e = alive[s]
                        if e > 0 then
                            local li = s - page_offset
                            callback(e, p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li], p8[li])
                        end
                    until m == 0
                end
            end
        else
            local nx = n - 8
            local xcp: { Pages } = table.create(nx) :: { Pages }
            for k = 1, nx do
                xcp[k] = columns[ids[8 + k]] or EMPTY_PAGES
            end
            local xp: { Page } = table.create(nx, EMPTY) :: { Page }
            local xout = table.create(nx)
            while true do
                local first, last, m = advance()
                if first == nil then
                    break
                end
                local page = first // PAGE_SIZE + 1
                local p1, p2, p3, p4, p5, p6, p7, p8 =
                    cp1[page] or EMPTY,
                    cp2[page] or EMPTY,
                    cp3[page] or EMPTY,
                    cp4[page] or EMPTY,
                    cp5[page] or EMPTY,
                    cp6[page] or EMPTY,
                    cp7[page] or EMPTY,
                    cp8[page] or EMPTY
                for k = 1, nx do
                    xp[k] = xcp[k][page] or EMPTY
                end
                local page_offset = (page - 1) * PAGE_SIZE - 1
                if m == FULL_WORD then
                    for s = first, last :: number do
                        local e = alive[s]
                        if e > 0 then
                            local li = s - page_offset
                            for k = 1, nx do
                                xout[k] = xp[k][li]
                            end
                            callback(
                                e,
                                p1[li],
                                p2[li],
                                p3[li],
                                p4[li],
                                p5[li],
                                p6[li],
                                p7[li],
                                p8[li],
                                table.unpack(xout, 1, nx)
                            )
                        end
                    end
                else
                    repeat
                        local s = first + countrz(m)
                        m = band(m, m - 1)
                        local e = alive[s]
                        if e > 0 then
                            local li = s - page_offset
                            for k = 1, nx do
                                xout[k] = xp[k][li]
                            end
                            callback(
                                e,
                                p1[li],
                                p2[li],
                                p3[li],
                                p4[li],
                                p5[li],
                                p6[li],
                                p7[li],
                                p8[li],
                                table.unpack(xout, 1, nx)
                            )
                        end
                    until m == 0
                end
            end
        end
        -- @generated direct_each end
        ctx.busy = false
    end

    -- True when the entity matches the query.
    local function query_has(query: QueryState, entity: i53): boolean
        local slot = entity % ENTITY_MASK
        if alive[slot] ~= entity then
            return false
        end
        local filter_with = query.filter_with
        if filter_with[1] == nil and query.any_groups == nil and query.tracking == nil then
            return false -- a query without terms matches nothing (see plan_query)
        end
        local w = slot // 32 + 1
        local bit = lshift(1, slot % 32)
        for _, id in filter_with do
            if not has_bit(id, w, bit) then
                return false
            end
        end
        local filter_without = query.filter_without
        if filter_without then
            for _, id in filter_without do
                local words = pwords[id] or lazy_words(id)
                if words and band(words[w] or 0, bit) ~= 0 then
                    return false
                end
            end
        end
        if query.skip_disabled then
            local words = pwords[EcsDisabled]
            if words and band(words[w] or 0, bit) ~= 0 then
                return false
            end
        end
        local any_groups = query.any_groups
        if any_groups then
            for _, group in any_groups do
                local found = false
                for _, id in group do
                    local words = pwords[id] or lazy_words(id)
                    if words and band(words[w] or 0, bit) ~= 0 then
                        found = true
                        break
                    end
                end
                if not found then
                    return false
                end
            end
        end
        local tracking = query.tracking
        if tracking then
            local first, last = tracking_window(query)
            for _, filter in tracking do
                local rings = tracked[filter[2]]
                local found = false
                if rings then
                    local ring = rings[filter[1]]
                    for t = first, last do
                        local word = ring[t % TRACK_TICKS + 1].words[w]
                        if word and band(word, bit) ~= 0 then
                            found = true
                            break
                        end
                    end
                end
                if not found then
                    return false
                end
            end
        end
        return true
    end

    ----------------------------------------------------------------------------
    -- batch operations on the matches of a query
    ----------------------------------------------------------------------------

    -- The matches of a query at the time of the call as pairs (word index, mask) in
    -- match_buffer; returns the number of filled entries. No user code runs while the buffer
    -- is read, so one buffer serves all batch operations.
    local match_buffer: { number } = {}

    local function match_words(query: QueryState): number
        local driver, others, without = plan_query(query)
        if driver == nil then
            return 0
        end
        local word_mask = make_word_tests(driver.words, others, without)
        local buffer = match_buffer
        local n = 0
        for sw, sum in driver.sums do
            if sum == 0 or sw < 1 then
                continue -- an emptied summary word, or a top word
            end
            local base = (sw - 1) * 32 + 1
            local mask = sum
            repeat
                local w = base + countrz(mask)
                mask = band(mask, mask - 1)
                local m = word_mask(w)
                if m ~= 0 then
                    buffer[n + 1] = w
                    buffer[n + 2] = m
                    n += 2
                end
            until mask == 0
        end
        return n
    end

    -- The entities of the first n entries of match_buffer.
    local function matched_entities(n: number): { i53 }
        local buffer = match_buffer
        local entities: { i53 } = {}
        local count = 0
        for i = 1, n, 2 do
            local base = (buffer[i] - 1) * 32
            local m = buffer[i + 1]
            repeat
                count += 1
                entities[count] = alive[base + countrz(m)]
                m = band(m, m - 1)
            until m == 0
        end
        return entities
    end

    local function query_count(query: QueryState): number
        -- counting does not consume the changes seen by change filters
        local seen = query.seen_tick
        local n = match_words(query)
        query.seen_tick = seen
        local buffer = match_buffer
        local count = 0
        for i = 2, n, 2 do
            count += popcount(buffer[i])
        end
        return count
    end

    -- Adds id to every match (with value when set is true, like world:set). A plain id
    -- without hooks is added a word of 32 entities at a time; pairs and hooked ids go through
    -- world:add / world:set one entity at a time.
    local function query_insert(query: QueryState, id: i53, value: any, set: boolean)
        local n = match_words(query)
        if n == 0 then
            return
        end
        -- The id (both elements of a pair) must be alive, also while the hooks of the batch run:
        -- the matches after a hook that deleted it do not get it.
        local first_slot, second_slot = id % ENTITY_MASK, id % ENTITY_MASK
        if id > PAIR_OFFSET then
            first_slot, second_slot = ECS_PAIR_FIRST(id), ECS_PAIR_SECOND(id)
        end
        local first, second = alive[first_slot] or 0, alive[second_slot] or 0
        if first <= 0 or second <= 0 or (id < PAIR_OFFSET and first ~= id) then
            return
        end
        local rec = if id > PAIR_OFFSET then nil else records[id] or record_create(id)
        if rec == nil or rec.on_add or (set and rec.on_change) then
            for _, entity in matched_entities(n) do
                if alive[first_slot] ~= first or alive[second_slot] ~= second then
                    break
                end
                if set then
                    world_set(world, entity, id, value)
                else
                    world_add(world, entity, id)
                end
            end
            return
        end
        local pages = rec.pages
        if set and value ~= nil and pages == nil then
            error("cannot set a value on a tag; add the Component trait (world:component()) to store data", 3)
        end
        local fill = set and pages ~= nil
        local buffer = match_buffer
        local words = rec.words
        local st, sig_bit = rec.sig_table, rec.sig_bit
        local added = false
        for i = 1, n, 2 do
            local w, m = buffer[i], buffer[i + 1]
            local base = (w - 1) * 32
            local old = words[w]
            local fresh = if old then m - band(m, old) else m
            if fresh ~= 0 then
                added = true
                if old ~= nil and old ~= 0 then
                    words[w] = old + fresh
                else
                    word_first(rec, w, fresh)
                end
                repeat
                    local slot = base + countrz(fresh)
                    fresh = band(fresh, fresh - 1)
                    if st then
                        local sig = st[slot]
                        st[slot] = if sig then sig + sig_bit else sig_bit
                    else
                        sig_more_add(rec, slot)
                    end
                until fresh == 0
            end
            if fill then
                -- a word lies inside one page
                local page_index = base // PAGE_SIZE + 1
                local page = (pages :: Pages)[page_index] or new_page(rec, page_index)
                local offset = base % PAGE_SIZE + 1
                repeat
                    page[offset + countrz(m)] = value
                    m = band(m, m - 1)
                until m == 0
            end
        end
        if added then
            -- many slots at once: no journal entry, the queries of the id scan it again
            rec.version += 1
            changes_stamp += 1
        end
    end

    -- Removes id from every match. A plain id without on_remove hooks is removed a word at a
    -- time; pairs, wildcards and hooked ids go through world:remove one entity at a time.
    local function query_remove(query: QueryState, id: i53)
        local rec = records[id]
        if rec == nil then
            return
        end
        local n = match_words(query)
        if n == 0 then
            return
        end
        if rec.kind ~= KIND_PLAIN or rec.on_remove then
            for _, entity in matched_entities(n) do
                world_remove(world, entity, id)
            end
            return
        end
        local buffer = match_buffer
        local words = rec.words
        local st, sig_bit = rec.sig_table, rec.sig_bit
        local pages = rec.pages
        local removed = false
        for i = 1, n, 2 do
            local w = buffer[i]
            local old = words[w]
            if old then
                local gone = band(buffer[i + 1], old)
                if gone ~= 0 then
                    removed = true
                    local word = old - gone
                    if word == 0 then
                        word_last(rec, w)
                    else
                        words[w] = word
                    end
                    local base = (w - 1) * 32
                    local page = if pages then pages[base // PAGE_SIZE + 1] else nil
                    local offset = base % PAGE_SIZE + 1
                    repeat
                        local index = countrz(gone)
                        gone = band(gone, gone - 1)
                        if st then
                            st[base + index] -= sig_bit
                        else
                            sig_more_remove(rec, base + index)
                        end
                        if page then
                            page[offset + index] = nil
                        end
                    until gone == 0
                end
            end
        end
        if removed then
            -- many slots at once: no journal entry, the queries of the id scan it again
            rec.version += 1
            changes_stamp += 1
        end
    end

    local function query_delete(query: QueryState)
        for _, entity in matched_entities(match_words(query)) do
            world_delete(world, entity)
        end
    end

    local Query = {}
    Query.__index = Query

    Query.__iter = query_iter

    -- Shared queries: world:query returns one query object per shape (the returned ids, then
    -- the ids of :with and :without), kept in a tree of shapes (see Shapes). A shared query is
    -- cached and never changes; its modifiers return the shared variant (or a new query when
    -- the variant cannot be shared). At most MAX_SHAPES states are shared; the shapes of a
    -- deleted entity, and those of the pairs with it as their target, leave the tree (see
    -- prune_shapes).

    function make_cached(query: QueryState): QueryState
        if not query.is_cached then
            query.is_cached = true
            query.listable = query.tracking == nil
            query.observed = {}
            query.versions = {}
            -- the tables of the match list are made when the list is built first (see build_list):
            -- a query that iterates its bitsets never needs them
            query.list_gpages = NO_STATE
            query.list_items = NO_STATE
            query.list_sizes = NO_STATE
            query.list_firsts = NO_STATE
            query.list_first_lis = NO_STATE
            query.list_ghint = NO_STATE
            query.list_pages = NO_STATE
            query.list_cols = NO_STATE
            query.list_readers = 0
            query.list_epoch = 0
        end
        return query
    end

    -- A query state for the ids; `copy`, a query with the same ids, gives the flags of the ids.
    local function new_query(ids: { i53 }, copy: QueryState?): QueryState
        local wild_values, skip_disabled
        if copy then
            wild_values, skip_disabled = copy.wild_values, copy.skip_disabled
        else
            wild_values = false
            for _, id in ids do
                if id > PAIR_OFFSET and is_wildcard(id) then
                    wild_values = true
                end
            end
            skip_disabled = table.find(ids, EcsDisabled) == nil
        end
        -- only the fields that a query which is not cached reads: the first request of a shape
        -- written inline is made on every call (make_cached adds the state of a cached query)
        return {
            ids = ids,
            filter_with = ids,
            is_cached = false,
            listable = false,
            mode = 0,
            list_count = 0,
            list_groups = 0,
            scan_words = 0,
            skip_disabled = skip_disabled,
            wild_values = wild_values,
        } :: any
    end

    -- Whether a query names Disabled in any of its terms.
    local function names_disabled(query: QueryState): boolean
        if
            table.find(query.filter_with, EcsDisabled)
            or (query.filter_without and table.find(query.filter_without, EcsDisabled))
        then
            return true
        end
        local groups = query.any_groups
        if groups then
            for _, group in groups do
                if table.find(group, EcsDisabled) then
                    return true
                end
            end
        end
        return false
    end

    -- The terms of a query changed in place: what a cached query observed no longer covers
    -- them (the next iteration observes the records of the new terms and plans again).
    local function forget_plan(query: QueryState)
        query.mode = 0
        -- (a nil assigned to a missing field would add the field)
        if query.list_stamp ~= nil then
            query.list_stamp = nil
        end
        if query.observed_generation ~= nil then
            query.observed_generation = nil
        end
        if query.terms then
            query.terms = nil
        end
    end

    local function apply_with(query: QueryState, ...: i53): QueryState
        local ids = query.ids
        local n_ids, n_with = #ids, select("#", ...)
        local with: { i53 } = table.create(n_ids + n_with) :: { i53 }
        table.move(ids, 1, n_ids, 1, with)
        for i = 1, n_with do
            with[n_ids + i] = (select(i, ...))
        end
        query.filter_with = with
        query.skip_disabled = not names_disabled(query)
        forget_plan(query)
        return query
    end

    local function apply_without(query: QueryState, ...: i53): QueryState
        query.filter_without = { ... }
        query.skip_disabled = not names_disabled(query)
        forget_plan(query)
        return query
    end

    -- A new, unshared copy of the terms of a query.
    local function copy_query(query: QueryState): QueryState
        local copy = new_query(query.ids, query)
        if query.filter_with ~= query.ids then
            copy.filter_with = table.clone(query.filter_with)
        end
        if query.filter_without then
            copy.filter_without = table.clone(query.filter_without :: { i53 })
        end
        if query.any_groups then
            copy.any_groups = table.clone(query.any_groups :: { { i53 } })
        end
        copy.skip_disabled = query.skip_disabled
        return copy
    end

    local function apply_any(query: QueryState, ...: i53): QueryState
        local groups = query.any_groups
        if groups == nil then
            groups = {}
            query.any_groups = groups
        end
        table.insert(groups :: { { i53 } }, { ... })
        query.skip_disabled = not names_disabled(query)
        forget_plan(query)
        return query
    end

    -- A shape that has no shared state yet (the ids after owner[key]), with `state`, a new state
    -- of it. A shape is shared from its second request: a query requested once (an entity used
    -- as a term of a query written inline, a query built once at startup) costs neither a shared
    -- state nor its list. The first request marks the shape (its node holds query = false) and
    -- returns `state` unshared, as its own; when the caller keeps using it (a modifier, :cached(),
    -- a second loop), it takes the place of the mark (see promote). The second request
    -- (`marked`) shares `state`.
    -- Neither happens when the room for marks or states is used up, or when an entity id of the
    -- ids or the target of a pair is not alive (a dead id matches nothing, and a shape of it
    -- would never be pruned): the caller uses `state` unshared. The path of the shape is created
    -- with its mark, from owner[key] (a root of the tree) through the given ids, so a shape that
    -- is neither marked nor shared leaves nothing in the tree. The entity ids and the targets of
    -- the pairs of the path are noted in shapes.keys, and world_delete prunes their shapes and
    -- marks (see prune_shapes).
    local function share_shape(owner: any, key: any, state: QueryState, marked: boolean, ...: i53): QueryState
        if marked then
            if shapes.count >= MAX_SHAPES then
                if debug and not shapes.warned then
                    shapes.warned = true
                    local report = warn or print -- the luau CLI has no warn
                    report(SHAPES_EXHAUSTED)
                end
                return state
            end
        elseif shapes.marks >= MAX_MARKS then
            return state
        end
        local n = select("#", ...)
        for i = 1, n do
            local id = select(i, ...)
            if id < PAIR_OFFSET then
                if alive[id % ENTITY_MASK] ~= id then
                    return state
                end
            else
                local target = ECS_PAIR_SECOND(id)
                if target ~= EcsWildcard then
                    local entity = alive[target]
                    if entity == nil or entity <= 0 then
                        return state
                    end
                end
            end
        end
        local node: any = owner[key]
        if node == nil then
            node = {}
            owner[key] = node
        end
        for i = 1, n do
            local id = select(i, ...)
            local child: any = node[id]
            if child == nil then
                child = {}
                node[id] = child
                local slot = key_slot(id)
                if slot ~= 0 then
                    key_add(shapes, slot, node, id)
                    -- world_delete of the entity prunes its shapes (see prune_shapes)
                    id_used[slot] = true
                end
            end
            node = child
        end
        if not marked then
            shapes.marks += 1
            node.query = false
            state.first_use = node
            return state
        end
        shapes.marks -= 1
        shapes.count += 1
        make_cached(state)
        state.shared = true
        node.query = state
        return state
    end

    -- The first state of a shape (see share_shape) is shared when the caller keeps using it: a
    -- modifier makes it the base of variants, :cached() and a second loop show that it is kept.
    -- It takes the place of the mark of the shape while the mark is in the tree (no other request
    -- shared the shape meanwhile, its entities are alive) and there is room; otherwise it stays
    -- a query of its own. Returns whether it is shared.
    function promote(state: QueryState): boolean
        local node = state.first_use
        state.first_use = nil
        if node == nil or node.query ~= false or shapes.count >= MAX_SHAPES then
            return false
        end
        shapes.marks -= 1
        shapes.count += 1
        make_cached(state)
        state.shared = true
        node.query = state
        return true
    end

    -- The shared variant of a shared query for `kind` ("with", "without" or "any") and the
    -- given ids.
    local function shared_variant(
        query: QueryState,
        kind: string,
        apply: (QueryState, ...i53) -> QueryState,
        ...: i53
    ): QueryState
        local variants = query.variants
        if variants == false then
            -- the query has left the tree of shapes (see prune_shapes)
            return apply(copy_query(query), ...)
        end
        local node: any = if variants then variants[kind] else nil
        for i = 1, select("#", ...) do
            if node == nil then
                break
            end
            node = node[(select(i, ...))]
        end
        local variant: QueryState | false | nil = if node ~= nil then node.query else nil
        if variant then
            return variant
        end
        if variants == nil then
            variants = {}
            query.variants = variants
        end
        return share_shape(variants, kind, apply(copy_query(query), ...), variant == false, ...)
    end

    function Query.with(self: QueryHandle, ...: i53): QueryHandle
        local state = self.state
        if state.first_use then
            promote(state) -- the base of a variant
        end
        if state.shared then
            self.state = shared_variant(state, "with", apply_with, ...)
        else
            apply_with(state, ...)
        end
        return self
    end

    function Query.without(self: QueryHandle, ...: i53): QueryHandle
        local state = self.state
        if state.first_use then
            promote(state) -- the base of a variant
        end
        if state.shared then
            self.state = shared_variant(state, "without", apply_without, ...)
        else
            apply_without(state, ...)
        end
        return self
    end

    function Query.any(self: QueryHandle, ...: i53): QueryHandle
        local state = self.state
        if state.first_use then
            promote(state) -- the base of a variant
        end
        if state.shared then
            self.state = shared_variant(state, "any", apply_any, ...)
        else
            apply_any(state, ...)
        end
        return self
    end

    local function add_tracking(self: QueryState, kind: string, id: i53): QueryState
        if self.first_use then
            promote(self) -- the base of a query with change filters
        end
        if self.shared then
            -- change filters keep a tick per query: a new query, not shared
            self = copy_query(self)
        end
        local tracking = self.tracking
        if tracking == nil then
            tracking = {}
            self.tracking = tracking
        end
        table.insert(tracking :: { { any } }, { kind, id })
        self.listable = false
        forget_plan(self)
        return self
    end

    function Query.added(self: QueryHandle, id: i53): QueryHandle
        self.state = add_tracking(self.state, "added", id)
        return self
    end

    function Query.changed(self: QueryHandle, id: i53): QueryHandle
        self.state = add_tracking(self.state, "changed", id)
        return self
    end

    function Query.removed(self: QueryHandle, id: i53): QueryHandle
        self.state = add_tracking(self.state, "removed", id)
        return self
    end

    -- Change filter: the entities made since the previous iteration of the query and still
    -- alive (world:track_created records them).
    function Query.created(self: QueryHandle): QueryHandle
        self.state = add_tracking(self.state, "created", CREATED)
        return self
    end

    -- A cached query keeps what it observed and its match list between iterations (shared
    -- queries are cached already). A query that has not been iterated yet picks its mode and
    -- builds its match list now, like jecs matches its archetypes here: the first loop costs
    -- no more than the next ones.
    function Query.cached(self: QueryHandle): QueryHandle
        local state = self.state
        if not selects(state) then
            error(NO_TERMS, 2)
        end
        if not (state.first_use and promote(state)) then
            make_cached(state)
        end
        if state.listable and state.observed_generation == nil then
            iteration_mode(state)
        end
        return self
    end

    Query.each = query_each

    function Query.has(self: QueryHandle, entity: i53): boolean
        if not selects(self.state) then
            error(NO_TERMS, 2)
        end
        return query_has(self.state, entity)
    end

    -- Batch operations on the entities that match the query at the time of the call.
    function Query.count(self: QueryHandle): number
        if not selects(self.state) then
            error(NO_TERMS, 2)
        end
        return query_count(self.state)
    end

    function Query.add_all(self: QueryHandle, id: i53)
        if not selects(self.state) then
            error(NO_TERMS, 2)
        end
        query_insert(self.state, id, nil, false)
    end

    function Query.set_all(self: QueryHandle, id: i53, value: any)
        if not selects(self.state) then
            error(NO_TERMS, 2)
        end
        query_insert(self.state, id, value, true)
    end

    function Query.remove_all(self: QueryHandle, id: i53)
        if not selects(self.state) then
            error(NO_TERMS, 2)
        end
        query_remove(self.state, id)
    end

    function Query.delete_all(self: QueryHandle)
        if not selects(self.state) then
            error(NO_TERMS, 2)
        end
        query_delete(self.state)
    end

    -- Removes id from every match that has it and adds it to every match that does not. A plain
    -- id without hooks (nor tracking, signals or monitors) is toggled a word of 32 entities at a
    -- time; pairs and hooked ids go entity by entity through world:remove and world:add, and a
    -- match that the hook of an earlier one deleted is skipped. (Defined here, not as a local
    -- function: world_new has used all its registers.)
    function Query.toggle_all(self: QueryHandle, id: i53)
        if debug then
            debug_check_id(alive, id, 3, false)
        elseif id > PAIR_OFFSET and is_wildcard(id) then
            error("toggle takes a component, a tag or a pair, not a wildcard", 2)
        end
        local query = self.state
        if not selects(query) then
            error(NO_TERMS, 2)
        end
        local n = match_words(query)
        if n == 0 then
            return
        end
        -- the id (both elements of a pair) must be alive, also while the hooks run (see
        -- query_insert)
        local first_slot, second_slot = id % ENTITY_MASK, id % ENTITY_MASK
        if id > PAIR_OFFSET then
            first_slot, second_slot = ECS_PAIR_FIRST(id), ECS_PAIR_SECOND(id)
        end
        local first, second = alive[first_slot] or 0, alive[second_slot] or 0
        if first <= 0 or second <= 0 or (id < PAIR_OFFSET and first ~= id) then
            return
        end
        local rec = if id > PAIR_OFFSET then nil else records[id] or record_create(id)
        if rec == nil or rec.kind ~= KIND_PLAIN or rec.on_add or rec.on_remove then
            for _, entity in matched_entities(n) do
                if alive[first_slot] ~= first or alive[second_slot] ~= second then
                    break
                end
                if alive[entity % ENTITY_MASK] == entity then
                    if world_has(world, entity, id) then
                        world_remove(world, entity, id)
                    else
                        world_add(world, entity, id)
                    end
                end
            end
            return
        end
        local buffer = match_buffer
        local words = rec.words
        local st, sig_bit = rec.sig_table, rec.sig_bit
        local pages = rec.pages
        for i = 1, n, 2 do
            local w, m = buffer[i], buffer[i + 1]
            local old = words[w]
            -- the matches that have the id lose it, the others get it
            local gone = if old then band(m, old) else 0
            local fresh = m - gone
            if old == nil or old == 0 then
                word_first(rec, w, fresh)
            else
                local word = old - gone + fresh
                if word == 0 then
                    word_last(rec, w)
                else
                    words[w] = word
                end
            end
            local base = (w - 1) * 32
            if gone ~= 0 then
                local page = if pages then pages[base // PAGE_SIZE + 1] else nil
                local offset = base % PAGE_SIZE + 1
                repeat
                    local index = countrz(gone)
                    gone = band(gone, gone - 1)
                    if st then
                        st[base + index] -= sig_bit
                    else
                        sig_more_remove(rec, base + index)
                    end
                    if page then
                        page[offset + index] = nil
                    end
                until gone == 0
            end
            while fresh ~= 0 do
                local slot = base + countrz(fresh)
                fresh = band(fresh, fresh - 1)
                if st then
                    local sig = st[slot]
                    st[slot] = if sig then sig + sig_bit else sig_bit
                else
                    sig_more_add(rec, slot)
                end
            end
        end
        -- many slots at once: no journal entry, the queries of the id scan it again
        rec.version += 1
        changes_stamp += 1
    end

    -- Fast path: iterator of (first_slot, last_slot, mask), see make_advance.
    function Query.spans(self: QueryHandle): () -> (number?, number?, number)
        if not selects(self.state) then
            error(NO_TERMS, 2)
        end
        local driver, others, without = plan_query(self.state)
        if driver == nil then
            return function(): (number?, number?, number)
                return nil, nil, 0
            end
        end
        return make_advance(driver, others, without)
    end

    -- Query monitors. A monitor listens to the signals of the ids of its query (connect): on_add
    -- runs after an id is added and on_remove before one is removed, so a check compares the
    -- match of the entity right after the change (monitoring.match) with a bit per member slot.
    -- clear and delete run the on_remove hooks of all ids of the entity before any id goes: an
    -- entity that is cleared (on the stack clearing) or deleted matches nothing from its first
    -- hook on.

    -- Whether an id of a query is on the slot once `excluded` is removed and `included` (0 for
    -- none, see Monitoring) is added. A wildcard (R, *) keeps a slot that loses a pair of R
    -- while the slot has another one: slot_pairs lists the pairs of a slot that has several.
    function monitoring.present(id: i53, slot: number, w: number, bit: number, excluded: i53, included: i53): boolean
        if id == excluded then
            return false
        end
        if id == included then
            return true
        end
        local wildcard = id > PAIR_OFFSET and ECS_PAIR_SECOND(id) == EcsWildcard
        if wildcard and included > PAIR_OFFSET and ECS_PAIR_FIRST(included) == ECS_PAIR_FIRST(id) then
            return true
        end
        if not has_bit(id, w, bit) then
            return false
        end
        local entity = alive[slot]
        if removing[1] ~= nil and not wildcard and monitoring.pending(entity, id) then
            return false -- its removal runs: the entity is checked as it will be
        end
        if wildcard and (removing[1] ~= nil or excluded > PAIR_OFFSET) then
            -- (R, *): a pair of R that the entity keeps
            local rec = records[id]
            if rec == nil then
                return false
            end
            local list = (rec.slot_pairs :: { [number]: { Record } })[slot]
            if list == nil then
                local single = (rec.slot_pair :: { [number]: Record })[slot]
                list = if single then { single } else {}
            end
            for _, pair_rec in list :: { Record } do
                local pair_id = pair_rec.id
                if pair_id ~= excluded and not monitoring.pending(entity, pair_id) then
                    return true
                end
            end
            return false
        end
        return true
    end

    -- Whether the removal of the id from the entity runs (its hooks run now, see `removing`).
    function monitoring.pending(entity: i53, id: i53): boolean
        for k = 1, #removing, 2 do
            if removing[k] == entity and removing[k + 1] == id then
                return true
            end
        end
        return false
    end

    -- Whether a removal from the entity runs.
    function monitoring.removing(entity: i53): boolean
        for k = 1, #removing, 2 do
            if removing[k] == entity then
                return true
            end
        end
        return false
    end

    -- Whether the slot matches the terms of a query once `excluded` is removed and `included`
    -- added (see monitoring.present): query_has for the state right after a change.
    function monitoring.match(terms: MonitorTerms, slot: number, excluded: i53, included: i53): boolean
        local filter_with = terms.filter_with
        local any_groups = terms.any_groups
        if filter_with[1] == nil and any_groups == nil then
            return false -- a query without terms matches nothing (see plan_query)
        end
        local present = monitoring.present
        local w = slot // 32 + 1
        local bit = lshift(1, slot % 32)
        for _, id in filter_with do
            if not present(id, slot, w, bit, excluded, included) then
                return false
            end
        end
        local filter_without = terms.filter_without
        if filter_without then
            for _, id in filter_without do
                if present(id, slot, w, bit, excluded, included) then
                    return false
                end
            end
        end
        if terms.skip_disabled and present(EcsDisabled, slot, w, bit, excluded, included) then
            return false
        end
        if any_groups then
            for _, group in any_groups do
                local found = false
                for _, id in group do
                    if present(id, slot, w, bit, excluded, included) then
                        found = true
                        break
                    end
                end
                if not found then
                    return false
                end
            end
        end
        return true
    end

    -- An exclusive relation that removed a pair and did not add the new one after all (see
    -- pair_add): every monitor checks the entity as it is now.
    function monitoring.recheck(entity: i53)
        for _, monitor in table.clone(monitoring.list) do
            monitor.check(entity)
        end
    end

    function Query.monitor(self: QueryHandle): Monitor
        local state = self.state
        if not selects(state) then
            error(NO_TERMS, 2)
        end
        if state.tracking then
            error("a monitor cannot use change filters", 2)
        end
        -- the terms as they are now: a modifier of a query that is not shared changes its state
        -- in place, the monitor keeps its own copy
        local groups: { { i53 } }? = nil
        if state.any_groups then
            local copied: { { i53 } } = {}
            for g, group in state.any_groups do
                copied[g] = table.clone(group)
            end
            groups = copied
        end
        local terms: MonitorTerms = {
            filter_with = table.clone(state.filter_with),
            filter_without = if state.filter_without then table.clone(state.filter_without) else nil,
            any_groups = groups,
            skip_disabled = state.skip_disabled,
        }
        -- The ids whose signals the monitor listens to (the relation of a pair), and what a change
        -- of an id can do to a match: EXIT_ON_REMOVE for a required id (its removal is an exit,
        -- its add may be an entry), EXIT_ON_ADD for an excluded one (its add is an exit, its
        -- removal may be an entry), ENTER_ON_ADD for an OR term and for the pairs of a required
        -- (R, *) (an add may be an entry, a removal an exit), OTHER_TERM for an id in several
        -- roles (a full check). wild_effects has those of the pairs of the relations of the
        -- terms (R, *), by the slot of the relation.
        local listened: { [i53]: boolean } = {}
        local effects: { [i53]: number } = {}
        local wild_effects: { [number]: number } = {}
        local function term(id: i53, effect: number)
            local into: { [number]: number } = effects
            local key = id
            if id > PAIR_OFFSET then
                local relation_slot = ECS_PAIR_FIRST(id)
                if relation_slot == EcsWildcard then
                    error("a monitor cannot use a term (*, T): the signals of a pair are those of its relation", 3)
                end
                local relation = alive[relation_slot]
                if relation > 0 then
                    listened[relation] = true
                end
                if ECS_PAIR_SECOND(id) == EcsWildcard then
                    -- a required (R, *) stays while the entity has another pair of R
                    into, key = wild_effects, relation_slot
                    if effect == EXIT_ON_REMOVE then
                        effect = ENTER_ON_ADD
                    end
                end
            else
                listened[id] = true
            end
            local current = into[key]
            into[key] = if current == nil or current == effect then effect else OTHER_TERM
        end
        for _, id in terms.filter_with do
            term(id, EXIT_ON_REMOVE)
        end
        local filter_without = terms.filter_without
        if filter_without then
            for _, id in filter_without do
                term(id, EXIT_ON_ADD)
            end
        end
        local any_groups = terms.any_groups
        if any_groups then
            for _, group in any_groups do
                for _, id in group do
                    term(id, ENTER_ON_ADD)
                end
            end
        end
        if terms.skip_disabled then
            term(EcsDisabled, EXIT_ON_ADD)
        end
        -- a pair that is a term and a pair of the relation of a term (R, *): both effects
        for id, effect in effects do
            if id > PAIR_OFFSET then
                local wild = wild_effects[ECS_PAIR_FIRST(id)]
                if wild ~= nil and wild ~= effect then
                    effects[id] = OTHER_TERM
                end
            end
        end

        -- a bit per member slot, from the matches when the monitor is made
        local members: Words = {}
        local n = match_words(state)
        for i = 1, n, 2 do
            members[match_buffer[i]] = match_buffer[i + 1]
        end

        local connected = true
        local on_added: ((entity: i53) -> ())? = nil
        local on_removed: ((entity: i53) -> ())? = nil

        -- whether the hooks of a clear or a delete of the entity run (see run_remove_hooks)
        local function being_cleared(entity: i53): boolean
            for d = 1, clear_depth do
                if clearing[d] == entity then
                    return true
                end
            end
            return false
        end

        -- Whether the entity matches after a change: a callback when that differs from its bit.
        -- The bit changes first, so a callback that changes the entity again is checked anew.
        local function update(entity: i53, now: boolean)
            local slot = entity % ENTITY_MASK
            local w = slot // 32 + 1
            local bit = lshift(1, slot % 32)
            local word = members[w] or 0
            if (band(word, bit) ~= 0) == now then
                return
            end
            if now then
                members[w] = word + bit
                local callback = on_added
                if callback then
                    callback(entity)
                end
            else
                word -= bit
                members[w] = if word ~= 0 then word else nil
                local callback = on_removed
                if callback then
                    callback(entity)
                end
            end
        end

        -- The words of the terms (pwords; a term (*, T), whose words are built lazily, is
        -- refused), EMPTY_WORDS_TABLE for an id without a record: read again in place when a
        -- record is created or freed (records_generation).
        local filter_with = terms.filter_with
        local no_terms = filter_with[1] == nil and any_groups == nil
        local with_words: { Words } = table.create(#filter_with) :: { Words }
        local any_words: { { Words } } = {}
        if any_groups then
            for g, group in any_groups do
                any_words[g] = table.create(#group) :: { Words }
            end
        end
        local without_words: { Words } = {}
        local words_generation = -1
        local function read_words()
            words_generation = records_generation
            for i, id in filter_with do
                with_words[i] = pwords[id] or EMPTY_WORDS_TABLE
            end
            if any_groups then
                for g, group in any_groups do
                    local list = any_words[g]
                    for i, id in group do
                        list[i] = pwords[id] or EMPTY_WORDS_TABLE
                    end
                end
            end
            local count = 0
            if filter_without then
                for _, id in filter_without do
                    count += 1
                    without_words[count] = pwords[id] or EMPTY_WORDS_TABLE
                end
            end
            if terms.skip_disabled then
                count += 1
                without_words[count] = pwords[EcsDisabled] or EMPTY_WORDS_TABLE
            end
        end

        -- Whether the slot of a live entity that is not being cleared matches now (the ids whose
        -- removal from the entity runs are absent already, see monitoring.present).
        local function matches(w: number, bit: number): boolean
            if no_terms then
                return false -- a query without terms matches nothing (see plan_query)
            end
            if removing[1] ~= nil then
                local slot = (w - 1) * 32 + countrz(bit)
                if monitoring.removing(alive[slot]) then
                    return monitoring.match(terms, slot, 0, 0)
                end
            end
            if words_generation ~= records_generation then
                read_words()
            end
            for _, words in with_words do
                local word = words[w]
                if word == nil or band(word, bit) == 0 then
                    return false
                end
            end
            if any_groups then
                for _, list in any_words do
                    local found = false
                    for _, words in list do
                        local word = words[w]
                        if word ~= nil and band(word, bit) ~= 0 then
                            found = true
                            break
                        end
                    end
                    if not found then
                        return false
                    end
                end
            end
            for _, words in without_words do
                local word = words[w]
                if word ~= nil and band(word, bit) ~= 0 then
                    return false
                end
            end
            return true
        end

        -- a full check of the entity as it is now (see monitoring.recheck)
        local function check(entity: i53)
            local slot = entity % ENTITY_MASK
            -- (a dead entity left when its slot was freed: see leave)
            if connected and alive[slot] == entity then
                update(entity, not being_cleared(entity) and matches(slot // 32 + 1, lshift(1, slot % 32)))
            end
        end

        -- A member leaves when its slot is freed (world_delete), before the slot can go to a new
        -- entity, whose membership the bit then means: an entity that a hook deleted while the
        -- removal of a term ran (the hooks of that term then skip it) leaves here.
        local function leave(entity: i53, w: number, bit: number)
            local word = members[w]
            if word ~= nil and band(word, bit) ~= 0 then
                word -= bit
                members[w] = if word ~= 0 then word else nil
                local callback = on_removed
                if callback then
                    callback(entity)
                end
            end
        end

        -- The listeners. The common changes (a required id added or removed, an excluded id
        -- added, a delete) take the paths with update inline.
        local function on_add(entity: i53, id: i53, _: any)
            if not connected then
                return
            end
            local effect = effects[id]
            if effect == nil then
                if id < PAIR_OFFSET then
                    return
                end
                effect = wild_effects[ECS_PAIR_FIRST(id)]
                if effect == nil then
                    return
                end
            end
            local slot = entity % ENTITY_MASK
            local w = slot // 32 + 1
            local bit = lshift(1, slot % 32)
            local word = members[w] or 0
            if band(word, bit) ~= 0 then
                -- a member: an excluded id makes it leave, unless a listener that ran before this
                -- one took the id back (the entity is checked as it is now)
                if (effect == EXIT_ON_ADD or effect == OTHER_TERM) and not matches(w, bit) then
                    word -= bit
                    members[w] = if word ~= 0 then word else nil
                    local callback = on_removed
                    if callback then
                        callback(entity)
                    end
                end
            elseif
                effect ~= EXIT_ON_ADD
                and alive[slot] == entity
                and not being_cleared(entity)
                and matches(w, bit)
            then
                members[w] = word + bit
                local callback = on_added
                if callback then
                    callback(entity)
                end
            end
        end

        local function on_remove(entity: i53, id: i53, deleting: any)
            if not connected then
                return
            end
            local effect = effects[id]
            local exact = effect ~= nil
            if not exact then
                if id < PAIR_OFFSET then
                    return
                end
                effect = wild_effects[ECS_PAIR_FIRST(id)]
                if effect == nil then
                    return
                end
            end
            local slot = entity % ENTITY_MASK
            if alive[slot] ~= entity then
                return -- a dead entity left when its slot was freed (see leave)
            end
            if effect == EXIT_ON_REMOVE or deleting or being_cleared(entity) then
                local w = slot // 32 + 1
                local bit = lshift(1, slot % 32)
                local word = members[w]
                if word ~= nil and band(word, bit) ~= 0 then
                    word -= bit
                    members[w] = if word ~= 0 then word else nil
                    local callback = on_removed
                    if callback then
                        callback(entity)
                    end
                end
                return
            end
            local included = if monitoring.entity == entity then monitoring.id else 0
            if included ~= 0 and not exact and ECS_PAIR_FIRST(included) == ECS_PAIR_FIRST(id) then
                return -- an exclusive relation replaces the pair: its terms (R, *) stay as they are
            end
            local now = monitoring.match(terms, entity % ENTITY_MASK, id, included)
            if
                now
                and included ~= 0
                and (effects[included] ~= nil or wild_effects[ECS_PAIR_FIRST(included)] ~= nil)
            then
                return -- an exclusive pair is replaced: an entry comes with the add of the new pair
            end
            update(entity, now)
        end

        -- A delete only matters for a member, and a member has every required id: the listener
        -- of one of them runs for deletes, the others are quiet then (a delete skips the hooks
        -- of the ids that only quiet listeners watch). Without an exact required id, all run.
        local anchor: i53? = nil
        for _, id in filter_with do
            if id < PAIR_OFFSET then
                anchor = id
                break
            elseif ECS_PAIR_SECOND(id) ~= EcsWildcard then
                local relation = alive[ECS_PAIR_FIRST(id)]
                if relation > 0 then
                    anchor = relation
                    break
                end
            end
        end
        local disconnects: { () -> () } = {}
        for id in listened do
            table.insert(disconnects, connect("on_add", id, on_add))
            table.insert(disconnects, connect("on_remove", id, on_remove, anchor ~= nil and id ~= anchor))
        end
        local handle: MonitorState = { check = check, leave = leave }
        table.insert(monitoring.list, handle)

        local function disconnect()
            if not connected then
                return
            end
            connected = false
            for _, disconnect_signal in disconnects do
                disconnect_signal()
            end
            table.clear(members)
            local list = monitoring.list
            local at = table.find(list, handle)
            if at then
                table.remove(list, at)
            end
        end

        return {
            added = function(callback: ((entity: i53) -> ())?)
                on_added = callback
            end,
            removed = function(callback: ((entity: i53) -> ())?)
                on_removed = callback
            end,
            disconnect = disconnect,
        } :: any
    end

    -- The state for the ids of world:query: shared by shape when possible.
    local function query_state(...: i53): QueryState
        local n = select("#", ...)
        local node: any = shapes.roots[n]
        for i = 1, n do
            if node == nil then
                break
            end
            node = node[(select(i, ...))]
        end
        local state: QueryState | false | nil = if node ~= nil then node.query else nil
        if state then
            return state
        end
        return share_shape(shapes.roots, n, new_query({ ... }), state == false, ...)
    end

    local function world_query(_: any, ...: i53): QueryHandle
        local state: any = query_state(...)
        if state.shared then
            return setmetatable({ state = state }, Query) :: any
        end
        -- a query that is not shared (made on this call) is its own handle
        state.state = state
        return setmetatable(state, Query) :: any
    end

    ----------------------------------------------------------------------------
    -- assembly and bootstrap
    ----------------------------------------------------------------------------

    world.entity = world_entity
    world.pool = world_pool
    world.component = world_component
    world.set = world_set
    world.add = world_add
    world.get = world_get
    world.get_list = world_get_list
    world.has = world_has
    world.has_all = world_has_all
    world.remove = world_remove
    world.delete = world_delete
    world.clear = world_clear
    world.remove_all = world_remove_all
    world.contains = world_contains
    world.exists = world_exists
    world.target = world_target
    world.targets = world_targets
    world.parent = world_parent
    world.children = world_children
    world.each = world_each
    world.added = world_added
    world.track = world_track
    world.tick = world_tick
    world.changed = world_changed
    world.removed = world_removed
    world.range = world_range
    world.query = world_query
    -- Fast path: page table of a component (page index -> values of PAGE_SIZE slots). (These two
    -- are written here, not as local functions: world_new has used all its registers.)
    world.column = function(_: any, id: i53): Pages
        return columns[id] or EMPTY_PAGES
    end
    world.alive_table = function(_: any): { number }
        return alive
    end
    world.ids = world_ids

    -- Adds the id when the entity does not have it and removes it when it does; true when it was
    -- added. (Written here, not as local functions: world_new has used all its registers.)
    world.toggle = function(_: any, entity: i53, id: i53): boolean
        if debug then
            debug_check_entity(alive, entity, 3)
            debug_check_id(alive, id, 3, false)
        elseif id > PAIR_OFFSET and is_wildcard(id) then
            error("toggle takes a component, a tag or a pair, not a wildcard", 2)
        end
        if alive[entity % ENTITY_MASK] ~= entity then
            return false
        end
        if world_has(world, entity, id) then
            world_remove(world, entity, id)
            return false
        end
        if id < PAIR_OFFSET and alive[id % ENTITY_MASK] ~= id then
            return false -- an id that is not alive is ignored (see world_add)
        end
        world_add(world, entity, id)
        return true
    end

    -- Starts recording the entities made from now on (world:entity, a pool, world:entity(id)
    -- making an id alive), per tick, for the change filter Query.created: a ring of TRACK_TICKS
    -- bitsets like those of a tracked id, cleared for a deleted entity with them.
    world.track_created = function(_: any)
        if tracked[CREATED] then
            return
        end
        local ring: { Record } = table.create(TRACK_TICKS) :: { Record }
        for t = 1, TRACK_TICKS do
            local rec = new_bitset()
            ring[t] = rec
            table.insert(track_rings, rec)
            table.insert(track_words, rec.words)
        end
        tracked[CREATED] = { created = ring }
        mark_created = function(slot: number)
            track_mark(ring[current_tick % TRACK_TICKS + 1], slot)
        end
    end

    -- Debug mode (ecs.world(true)): set/add/remove/delete/clear raise an error for an entity
    -- that is not alive (an outdated handle) or an id that is not alive, instead of ignoring
    -- the call. Internal calls (cascades) are not checked. Patched match lists are checked by
    -- iteration_mode (verify_list), the lists taken as they are by the loops (list_stamp).
    if debug then
        world.set = function(_: any, entity: i53, id: i53, value: any)
            debug_check_entity(alive, entity, 3)
            debug_check_id(alive, id, 3, false)
            world_set(world, entity, id, value)
        end
        world.add = function(_: any, entity: i53, id: i53)
            debug_check_entity(alive, entity, 3)
            debug_check_id(alive, id, 3, false)
            world_add(world, entity, id)
        end
        world.remove = function(_: any, entity: i53, id: i53)
            debug_check_entity(alive, entity, 3)
            debug_check_id(alive, id, 3, true)
            world_remove(world, entity, id)
        end
        world.delete = function(_: any, entity: i53)
            debug_check_entity(alive, entity, 3)
            world_delete(world, entity)
        end
        world.clear = function(_: any, entity: i53)
            debug_check_entity(alive, entity, 3)
            world_clear(world, entity)
        end
        function Query.add_all(self: QueryHandle, id: i53)
            debug_check_id(alive, id, 3, false)
            if not selects(self.state) then
                error(NO_TERMS, 2)
            end
            query_insert(self.state, id, nil, false)
        end
        function Query.set_all(self: QueryHandle, id: i53, value: any)
            debug_check_id(alive, id, 3, false)
            if not selects(self.state) then
                error(NO_TERMS, 2)
            end
            query_insert(self.state, id, value, true)
        end
        function Query.remove_all(self: QueryHandle, id: i53)
            debug_check_id(alive, id, 3, true)
            if not selects(self.state) then
                error(NO_TERMS, 2)
            end
            query_remove(self.state, id)
        end
    end

    -- The builtin ids and the pre-registered ones: a function of its own, whose loops and
    -- calls take no registers of world_new (see the helpers before world_new), called at once
    -- without a local (world_new has used all its registers).
    (function()
        -- ids 1..EcsRest (and pre-registered tags) exist as entities
        for _ = 1, preregistered_tags do
            new_slot()
        end
        component_words = record_create(EcsComponent).words
        for id = 1, preregistered_components do
            world_add(world, id, EcsComponent)
        end
        for _, id in { EcsOnAdd, EcsOnChange, EcsOnRemove, EcsName, EcsWildcard, EcsRest } do
            world_add(world, id, EcsComponent)
        end

        -- An internal hook of a builtin id (see internal_hooks): it stays in front of the hooks
        -- and signals that users give the id.
        local function set_internal_hook(id: i53, field: string, hook: Hook)
            if records[id] == nil then
                record_create(id)
            end
            internal_hooks[field][id] = hook
            install_hook(id, field, dispatchers[field][id] or hook_of(HOOK_IDS[field], id % ENTITY_MASK))
        end

        -- hook components apply their values to the record they are set on
        local hook_fields: { [i53]: string } =
            { [EcsOnAdd] = "on_add", [EcsOnChange] = "on_change", [EcsOnRemove] = "on_remove" }
        for id, field in hook_fields do
            local function apply(entity: i53, _: i53, value: any?)
                apply_hook(entity, field, value)
            end
            set_internal_hook(id, "on_add", apply)
            set_internal_hook(id, "on_change", apply)
            set_internal_hook(id, "on_remove", function(entity: i53, _: i53, deleting: any?)
                -- a deleted id keeps its hooks until its members are cleaned up
                if not deleting then
                    apply_hook(entity, field, nil)
                end
            end)
        end

        world_set(world, EcsOnAdd, EcsName, "mercs.OnAdd")
        world_set(world, EcsOnRemove, EcsName, "mercs.OnRemove")
        world_set(world, EcsOnChange, EcsName, "mercs.OnChange")
        world_set(world, EcsWildcard, EcsName, "mercs.Wildcard")
        world_set(world, EcsChildOf, EcsName, "mercs.ChildOf")
        world_set(world, EcsComponent, EcsName, "mercs.Component")
        world_set(world, EcsOnDelete, EcsName, "mercs.OnDelete")
        world_set(world, EcsOnDeleteTarget, EcsName, "mercs.OnDeleteTarget")
        world_set(world, EcsDelete, EcsName, "mercs.Delete")
        world_set(world, EcsRemove, EcsName, "mercs.Remove")
        world_set(world, EcsName, EcsName, "mercs.Name")
        world_set(world, EcsExclusive, EcsName, "mercs.Exclusive")
        world_set(world, EcsRest, EcsName, "mercs.Rest")
        world_set(world, EcsDisabled, EcsName, "mercs.Disabled")

        -- Exclusive marks relations with one target per entity; keep existing pair records in sync.
        -- A relation that an entity has with several targets cannot take it: the add is undone
        -- before its error (slot_pairs lists the slots with several pairs, see pair_attach).
        set_internal_hook(EcsExclusive, "on_add", function(entity: i53)
            local wc = records[ECS_PAIR(entity, EcsWildcard)]
            if wc == nil then
                return
            end
            if next(wc.slot_pairs :: { [number]: { Record } }) ~= nil then
                local ok, problem = pcall(world_remove, world, entity, EcsExclusive)
                if not ok then
                    error(problem, 0)
                end
                error("the Exclusive trait cannot be added to a relation that an entity has with several targets", 0)
            end
            wc.exclusive = true
        end)
        set_internal_hook(EcsExclusive, "on_remove", function(entity: i53)
            local wc = records[ECS_PAIR(entity, EcsWildcard)]
            if wc then
                wc.exclusive = false
            end
        end)
        world_add(world, EcsOnDelete, EcsExclusive)
        world_add(world, EcsOnDeleteTarget, EcsExclusive)
        world_add(world, EcsChildOf, EcsExclusive)
        world_add(world, EcsChildOf, ECS_PAIR(EcsOnDeleteTarget, EcsDelete))

        for id, bundle in preregistered_meta do
            for trait, value in bundle do
                if value == NULL then
                    world_add(world, id, trait)
                else
                    world_set(world, id, trait, value)
                end
            end
        end

        -- Component decides whether the records of an id hold values when they are made: it
        -- cannot be added to or removed from an id used already (as an id, a relation or a
        -- target), whose records would not follow. The add is undone before its error. The
        -- removal is refused before it changes anything (in a clear too: the hook of Component
        -- runs first, its record is the oldest one with hooks), and it takes its entries off the
        -- removal stacks, which the error leaves.
        local undoing = false
        local function used(entity: i53): boolean
            return records[entity] ~= nil
                or records[ECS_PAIR(entity, EcsWildcard)] ~= nil
                or records[ECS_PAIR(EcsWildcard, entity)] ~= nil
        end
        set_internal_hook(EcsComponent, "on_add", function(entity: i53)
            if used(entity) then
                -- the undo runs the removal listeners of Component: one that raises an error
                -- must not leave the removal hook below off (a rare path: pcall costs nothing)
                undoing = true
                local ok, problem = pcall(world_remove, world, entity, EcsComponent)
                undoing = false
                if not ok then
                    error(problem, 0)
                end
                error("the Component trait cannot be added to an id used already: give it before the first use", 0)
            end
        end)
        set_internal_hook(EcsComponent, "on_remove", function(entity: i53, _: i53, deleting: any?)
            if deleting or undoing or not used(entity) then
                return
            end
            -- (world:remove runs the hook with its entry on the stack, a clear without one)
            local top = #removing
            if removing[top] == EcsComponent and removing[top - 1] == entity then
                removing[top] = nil
                removing[top - 1] = nil
            end
            local depth = clear_depth
            if depth > 0 and clearing[depth] == entity then
                table.clear(clear_buffers[depth])
                clearing[depth] = nil
                clear_depth = depth - 1
            end
            error("the Component trait cannot be removed from an id used already", 0)
        end)
    end)()

    return world :: World
end

-- Forgets all pre-registered ids (tests use it to isolate worlds).
local function ECS_META_RESET()
    preregistered_components = 0
    preregistered_tags = EcsRest
    preregistered_meta = {}
end

-- Alive entity of the first element of a pair, or 0.
local function pair_first(world: World, pair: i53): i53
    local entity = (world :: any).alive_table(world)[ECS_PAIR_FIRST(pair)]
    return if entity and entity > 0 then entity else 0
end

-- Alive entity of the second element of a pair, or 0.
local function pair_second(world: World, pair: i53): i53
    local entity = (world :: any).alive_table(world)[ECS_PAIR_SECOND(pair)]
    return if entity and entity > 0 then entity else 0
end

return {
    world = (world_new :: any) :: (debug: boolean?) -> World,
    component = (ECS_COMPONENT :: any) :: <T>() -> Component<T>,
    tag = (ECS_TAG :: any) :: () -> Entity,
    meta = (ECS_META :: any) :: <T>(id: Id, trait: Id<T>, value: T?) -> (),
    ECS_META_RESET = ECS_META_RESET,
    ECS_COMBINE = (function(id: number, generation: number): number
        return id + generation * ENTITY_MASK
    end :: any) :: (id: number, generation: number) -> Entity,

    pair = (ECS_PAIR :: any) :: <P, O>(first: Id<P>, second: Id<O>) -> Pair<P, O>,
    IS_PAIR = (ECS_IS_PAIR :: any) :: (id: Id) -> boolean,
    pair_first = (pair_first :: any) :: (world: World, pair: Id) -> Entity,
    pair_second = (pair_second :: any) :: (world: World, pair: Id) -> Entity,
    -- (generic: an id of any data type, also the result of a call, as `world:entity()`)
    ECS_PAIR_FIRST = (ECS_PAIR_FIRST :: any) :: <T>(pair: Id<T> | number) -> number,
    ECS_PAIR_SECOND = (ECS_PAIR_SECOND :: any) :: <T>(pair: Id<T> | number) -> number,
    ECS_ID = (ECS_ID :: any) :: <T>(entity: Id<T> | number) -> number,
    ECS_GENERATION = (ECS_GENERATION :: any) :: <T>(entity: Id<T> | number) -> number,
    ECS_GENERATION_INC = (ECS_GENERATION_INC :: any) :: <T>(entity: Id<T>) -> Id<T>,
    ENTITY_MASK = ENTITY_MASK,
    PAGE_SIZE = PAGE_SIZE,

    OnAdd = (EcsOnAdd :: any) :: Component<(entity: Entity, id: Id, value: any?) -> ()>,
    OnRemove = (EcsOnRemove :: any) :: Component<(entity: Entity, id: Id, delete: boolean?) -> ()>,
    OnChange = (EcsOnChange :: any) :: Component<(entity: Entity, id: Id, value: any?) -> ()>,
    Wildcard = (EcsWildcard :: any) :: Entity,
    ChildOf = (EcsChildOf :: any) :: Entity,
    Component = (EcsComponent :: any) :: Entity,
    OnDelete = (EcsOnDelete :: any) :: Entity,
    OnDeleteTarget = (EcsOnDeleteTarget :: any) :: Entity,
    Delete = (EcsDelete :: any) :: Entity,
    Remove = (EcsRemove :: any) :: Entity,
    Name = (EcsName :: any) :: Component<string>,
    Exclusive = (EcsExclusive :: any) :: Entity,
    Rest = (EcsRest :: any) :: Entity,
    Disabled = (EcsDisabled :: any) :: Entity,
}
