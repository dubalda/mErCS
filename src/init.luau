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
      (negative, with all 24 low bits set: iterators never take it for a slot).
    - Every id used on entities (component, tag, pair) has a record with presence bitsets:
      words[w] holds 32 slots (w = slot // 32 + 1), sums[sw] marks the non-empty words of
      1024 slots. Components also keep their values in pages of 256 slots.
    - Each entity has a signature: a bitset of the record indices it has (components, tags
      and relation records (R, *)). delete/clear use it to find all records of the entity
      without scanning; a mask of the signature bits with on_remove hooks tells whether the
      hooks have to run first.
    - Relationships: a pair (R, T) is a record of its own, reached from the relation record
      (R, *), which keeps the pairs of every entity (target() reads it). The target record
      (*, T) lists the pairs with target T for cleanup policies; its bitsets are computed
      only when a query or has() needs them.

    Queries AND the bitsets of the included ids and AND-NOT the excluded ones; full words are
    merged into runs and iterated sequentially. While the result of a query does not change
    and its matches are scattered, the query keeps a dense list of them. Queries created on
    every call share their state by shape (see query_state): an inline world:query allocates
    only a small handle, and iterating allocates nothing.
    Value pages of dense components are preallocated arrays, of sparse ones small hash tables.

    Also: Disabled (hidden from queries that do not name it), change tracking (world:track,
    world:tick, query:added/changed/removed), batch operations on the matches of a query
    (query:add_all/set_all/remove_all/delete_all), world:remove_all, world:ids.

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
    sig_word: number,
    sig_bit: number,
    sig_table: Words?,
    -- presence
    words: Words,
    sums: Words,
    word_count: number,
    version: number,
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
    -- (*, T): version of the materialized words (see target_materialize)
    built: number?,
}

type QueryState = {
    world: any,
    ids: { i53 },
    filter_with: { i53 },
    filter_without: { i53 }?,
    -- OR terms (see Query.any) and their merged bitsets
    any_groups: { { i53 } }?,
    any_merged: { any }?,
    is_cached: boolean,
    observed: { any },
    versions: { number },
    mode: number,
    -- list mode: matches (entity, local page index), grouped by page: list_ends[g] is the
    -- last match of group g, list_pages[column][g] the page of the column for group g
    list_entities: { i53 },
    list_locals: { number },
    list_ends: { number },
    list_pages: { { Page } },
    list_count: number,
    list_groups: number,
    -- the query does not name Disabled: disabled entities are excluded
    skip_disabled: boolean,
    -- list mode: the reusable iterator (step, reset) and whether it is running, and the
    -- number of loops over the current list that have not finished
    list_step: (() -> ...any)?,
    list_reset: (() -> ())?,
    list_busy: boolean?,
    list_readers: number,
    -- records_generation when the query observed its records, and how many it observed
    observed_generation: number?,
    observed_records: number?,
    -- shared query (see world_query): modifiers return shared variants, never change it
    shared: boolean?,
    variants: { [any]: any }?,
    -- reusable iteration contexts of a cached query (see new_direct and query_each)
    direct: any?,
    each_ctx: any?,
    -- change filters: { kind, id } pairs, and the first tick not seen yet by this query
    tracking: { { any } }?,
    seen_tick: number?,
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
        spans: (self: Query<T...>) -> () -> (number?, number?, number),
        -- batch operations on the entities that match now
        count: (self: Query<T...>) -> number,
        add_all: (self: Query<T...>, id: Id<any>) -> (),
        set_all: <V>(self: Query<T...>, id: Id<V>, value: V) -> (),
        remove_all: (self: Query<T...>, id: Id<any>) -> (),
        delete_all: (self: Query<T...>) -> (),
    },
    {} :: {
        __iter: (self: Query<T...>) -> () -> (Entity, T...),
    }
))

export type World = {
    entity: ((self: World) -> Entity) & (<T>(self: World, id: Id<T>) -> Id<T>) & ((self: World, id: number) -> Entity),
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
    handle) instead of ignoring the call.
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
    `has` or `remove` stands for every target of `Likes`. A query returns the value of the
    first target.
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
    The trait of ids that hold data. [World:component] adds it.
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
    the first: `world:add(Targeting, ecs.Exclusive)`.
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
    A new entity. With `id`, makes that id alive and returns it (the entity of its slot, if
    it has another generation, is deleted).
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
    a tag: `local Frozen = world:entity()`.
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
    Removes `id` from the entity; [mErCS.OnRemove] runs first.
]=]

--[=[
    @method delete
    @within World
    @param entity Id
    Removes every id of the entity (their [mErCS.OnRemove] hooks run first), applies the
    cleanup policies of the entity used as an id or a target, and frees the slot. Cascades
    of any depth work (past 100 nested levels the rest is queued).
]=]

--[=[
    @method clear
    @within World
    @param entity Id
    Removes every id of the entity; the entity stays alive.
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
    Whether the slot of the entity was ever used, also after the delete.
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
    Iterates the entities that have `(ChildOf, parent)`.
]=]

--[=[
    @method each
    @within World
    @param id Id
    @return () -> Entity? -- an iterator
    Iterates the entities that have `id`.
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
    through a table). See [Query].
]=]

--[=[
    @method added
    @within World
    @param id Id<T>
    @param listener (entity: Entity, id: Id<T>, value: T) -> ()
    @return () -> () -- disconnects the listener
    Connects a listener that runs when `id` is added to an entity. A listener may connect or
    disconnect listeners, itself included, while it runs: the change applies from the next
    event.
]=]

--[=[
    @method changed
    @within World
    @param id Id<T>
    @param listener (entity: Entity, id: Id<T>, value: T) -> ()
    @return () -> () -- disconnects the listener
    Connects a listener that runs when the value of `id` is set again on an entity.
]=]

--[=[
    @method removed
    @within World
    @param id Id<T>
    @param listener (entity: Entity, id: Id<T>, deleting: boolean?) -> ()
    @return () -> () -- disconnects the listener
    Connects a listener that runs before `id` is removed from an entity; `deleting` is true
    when the entity itself is being deleted.
]=]

--[=[
    @method track
    @within World
    @param id Id
    Starts recording additions, value changes and removals of `id` per tick, for the change
    filters [Query:added], [Query:changed] and [Query:removed]. Untracked ids cost nothing; a
    tracked id costs a call per add, change or remove.
]=]

--[=[
    @method tick
    @within World
    @return number -- the new tick
    Advances the tick: the changes recorded so far become visible to change filters. Call it
    once per frame.
]=]

--[=[
    @method range
    @within World
    @param first number
    @param last number?
    The entity ids of this world start at `first` and stay below `last` (networked worlds).
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
      state, so an inline query allocates only a small handle, and an iteration of a stored
      query allocates nothing.
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
    (without a concrete pair and without change filters) are cached already; call it on a
    query with a concrete pair or change filters that is stored and iterated many times.
]=]

--[=[
    @method added
    @within Query
    @param id Id -- a tracked id (see [World:track])
    @return Query
    Change filter: the entities that got `id` added since the previous iteration of this
    query. Each query keeps the first tick it has not seen, up to the last 8 ticks.
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
    entities at a time; pairs and ids with hooks go entity by entity, and every hook runs.
]=]

--[=[
    @method set_all
    @within Query
    @param id Id<V>
    @param value V -- the same value for every match
    Sets `id` to `value` on every entity that matches now.
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

local TOO_MANY_IDS = "at most 8 ids can be passed; use get_list/has_all for more"

local function NOOP(): any
    return nil
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
-- World
--------------------------------------------------------------------------------

local function world_new(debug: boolean?): World
    -- entity index
    local alive: { number } = table.create(1024) :: { number }
    local free: { number } = {}
    local free_count = 0
    local max_slot = 0
    local range_end: number? = nil

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

    local clear_buffers: { { Record } } = {}
    local clear_depth = 0
    -- clearing[slot]: on_remove hooks of the slot are running
    local clearing: { [number]: boolean } = {}
    -- the first ChildOf pair of every slot (slot_pair of the (ChildOf, *) record), for parent()
    local childof_pairs: { [number]: Record }? = nil

    -- id_used[slot]: the entity of the slot is (or was) a component, tag, relation or target
    local id_used: { [number]: boolean } = {}

    local world = {} :: any
    -- the presence words of the Component trait (set when its record is created)
    local component_words: Words = EMPTY_WORDS_TABLE

    ----------------------------------------------------------------------------
    -- entity index
    ----------------------------------------------------------------------------

    local function new_slot(): i53
        if free_count > 0 then
            local e = free[free_count]
            free[free_count] = nil
            free_count -= 1
            alive[e % ENTITY_MASK] = e
            return e
        end
        local slot = max_slot + 1
        if range_end and slot >= range_end then
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

    local function bit_test(rec: Record, slot: number): boolean
        local word = rec.words[slot // 32 + 1]
        return word ~= nil and band(word, lshift(1, slot % 32)) ~= 0
    end

    -- Rare path of bit_set: the first bit of word w.
    local function bit_set_word(rec: Record, w: number, bit: number)
        rec.words[w] = bit
        rec.word_count += 1
        local sums = rec.sums
        local sw = (w - 1) // 32 + 1
        local sbit = lshift(1, (w - 1) % 32)
        local sum = sums[sw]
        sums[sw] = if sum then sum + sbit else sbit
        rec.version += 1
    end

    -- Sets the bit of a slot that is known to be clear.
    local function bit_set(rec: Record, slot: number)
        local words = rec.words
        local w = slot // 32 + 1
        local word = words[w]
        if word then
            words[w] = word + lshift(1, slot % 32)
            rec.version += 1
        else
            bit_set_word(rec, w, lshift(1, slot % 32))
        end
    end

    -- Rare path of bit_clear: the last bit of word w.
    local function bit_clear_word(rec: Record, w: number)
        rec.words[w] = nil
        rec.word_count -= 1
        local sums = rec.sums
        local sw = (w - 1) // 32 + 1
        local sum = sums[sw] - lshift(1, (w - 1) % 32)
        sums[sw] = if sum == 0 then nil else sum
        rec.version += 1
    end

    -- Clears the bit of a slot that is known to be set.
    local function bit_clear(rec: Record, slot: number)
        local words = rec.words
        local w = slot // 32 + 1
        local word = words[w] - lshift(1, slot % 32)
        if word ~= 0 then
            words[w] = word
            rec.version += 1
        else
            bit_clear_word(rec, w)
        end
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

    -- Number of set bits of a word.
    local function popcount(x: number): number
        x -= band(rshift(x, 1), 0x55555555)
        x = band(x, 0x33333333) + band(rshift(x, 2), 0x33333333)
        x = band(x + rshift(x, 4), 0x0F0F0F0F)
        return rshift(x * 0x01010101, 24)
    end

    -- Creates the value page of a record. A page is preallocated as an array when the record
    -- is dense around it (at least a quarter of the slots of this and the previous page are
    -- members): a page with 25-50 % of its slots used would otherwise stay in the hash part
    -- of the table, which is slower to read. Sparse records keep small hash pages.
    local function new_page(rec: Record, page_index: number): Page
        local dense = false
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
                dense = bits >= PAGE_SIZE // 4
            end
        end
        local page: Page = if dense then table.create(PAGE_SIZE) else {}
        (rec.pages :: Pages)[page_index] = page
        -- a value can be set on a member that had none (world:add of a component): the match
        -- lists of cached queries keep page references and must see the new page
        rec.version += 1
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

    -- changes when a record is created or freed (cached queries skip their lookups otherwise)
    local records_generation = 0

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
            sig_word = sig_word,
            sig_bit = if index > 0 then lshift(1, (index - 1) % 32) else 0,
            sig_table = sig_table,
            words = {},
            sums = {},
            word_count = 0,
            version = 0,
        } :: any
        if with_values then
            rec.pages = {}
        end
        records[id] = rec
        records_generation += 1
        pwords[id] = rec.words
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
        if band(mask, bit) ~= 0 then
            mask -= bit
        end
        hooked[k] = if on then mask + bit else mask
        local cell = dispatched_hooks.on_remove[if rec.kind == KIND_RELATION then rec.relation :: i53 else rec.id]
        local loud = on and (cell == nil or cell.hook ~= nil or cell.loud > 0)
        mask = hooked_delete[k] or 0
        if band(mask, bit) ~= 0 then
            mask -= bit
        end
        hooked_delete[k] = if loud then mask + bit else mask
    end

    local function set_on_remove(rec: Record, hook: Hook?)
        rec.on_remove = hook
        set_hooked(rec, hook ~= nil)
    end

    local function free_record(rec: Record)
        local id = rec.id
        if records[id] ~= rec then
            return
        end
        records[id] = nil
        records_generation += 1
        pwords[id] = nil
        columns[id] = nil
        local index = rec.index
        if index > 0 then
            set_hooked(rec, false)
            by_index[index] = nil :: any
            table.insert(free_indices, index)
        end
        if rec.kind == KIND_RELATION and rec.relation == EcsChildOf then
            childof_pairs = nil
        end
        local wc_rel, wc_tgt = rec.wc_rel, rec.wc_tgt
        if wc_rel and wc_rel.pairs then
            wc_rel.pairs[id] = nil
        end
        if wc_tgt and wc_tgt.pairs then
            wc_tgt.pairs[id] = nil
        end
    end

    -- Record of a plain id (component or tag).
    local function record_create(id: i53): Record
        local slot = id % ENTITY_MASK
        id_used[slot] = true
        local rec = new_record(id, KIND_PLAIN, has_component_trait(slot))
        rec.on_add = hook_for("on_add", EcsOnAdd, id)
        rec.on_change = hook_for("on_change", EcsOnChange, id)
        set_on_remove(rec, hook_for("on_remove", EcsOnRemove, id))
        return rec
    end

    local world_has_pair: (entity: i53, id: i53) -> boolean

    -- (*, T) records are not updated per entity: pair add and remove only bump their version.
    -- has() reads them through lazy words, queries and iterations materialize the words.
    local function target_lazy_words(rec: Record): Words
        return setmetatable({}, {
            __index = function(_: any, w: number): number?
                local m = 0
                for _, pair_rec in rec.pairs :: { [i53]: Record } do
                    local word = pair_rec.words[w]
                    if word then
                        m = bor(m, word)
                    end
                end
                return if m == 0 then nil else m
            end,
        }) :: any
    end

    local function target_materialize(rec: Record)
        if rec.built == rec.version then
            return
        end
        local words: Words = {}
        local sums: Words = {}
        local count = 0
        for _, pair_rec in rec.pairs :: { [i53]: Record } do
            for w, word in pair_rec.words do
                local old = words[w]
                if old then
                    words[w] = bor(old, word)
                else
                    words[w] = word
                    count += 1
                    local sw = (w - 1) // 32 + 1
                    sums[sw] = bor(sums[sw] or 0, lshift(1, (w - 1) % 32))
                end
            end
        end
        rec.words = words
        rec.sums = sums
        rec.word_count = count
        rec.built = rec.version
    end

    -- Whether the slot has any pair with the target of a (*, T) record.
    local function target_has(rec: Record, slot: number): boolean
        for _, pair_rec in rec.pairs :: { [i53]: Record } do
            if bit_test(pair_rec, slot) then
                return true
            end
        end
        return false
    end

    -- Record of a wildcard id: (R, *) is part of entity signatures, (*, T) is not.
    local function wildcard_record(id: i53, relation: i53?, target: i53?): Record
        local rec = records[id]
        if rec then
            return rec
        end
        rec = new_record(id, if relation then KIND_RELATION else KIND_TARGET, false)
        rec.pairs = {}
        rec.relation = relation
        rec.target = target
        id_used[(relation or target :: i53) % ENTITY_MASK] = true
        if relation then
            rec.slot_pair = {}
            rec.slot_pairs = {}
            if relation == EcsChildOf then
                childof_pairs = rec.slot_pair
            end
            rec.exclusive = world_has_pair(relation, EcsExclusive)
            set_hooked(rec, hook_for("on_remove", EcsOnRemove, relation) ~= nil)
        else
            rec.built = -1
            pwords[id] = target_lazy_words(rec)
        end
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
        rec.relation = relation
        rec.target = target
        local wc_rel = wildcard_record(ECS_PAIR(relation, EcsWildcard), relation, nil)
        local wc_tgt = wildcard_record(ECS_PAIR(EcsWildcard, target), nil, target)
        rec.wc_rel = wc_rel
        rec.wc_tgt = wc_tgt;
        (wc_rel.pairs :: { [i53]: Record })[id] = rec;
        (wc_tgt.pairs :: { [i53]: Record })[id] = rec
        rec.on_add = hook_for("on_add", EcsOnAdd, relation)
        rec.on_change = hook_for("on_change", EcsOnChange, relation)
        rec.on_remove = hook_for("on_remove", EcsOnRemove, relation)
        return rec
    end

    -- Adds a second or later pair of a relation to the slot: the pairs of a slot are kept in
    -- a list ordered by target slot, and slot_pair holds the first one.
    local function pair_attach_more(rec: Record, wc_rel: Record, slot: number, first: Record)
        local slot_pairs = wc_rel.slot_pairs :: { [number]: { Record } }
        local list = slot_pairs[slot]
        if list == nil then
            list = { first }
            slot_pairs[slot] = list
        end
        local target_slot = (rec.target :: i53) % ENTITY_MASK
        local at = #list + 1
        for i, other in list do
            if (other.target :: i53) % ENTITY_MASK > target_slot then
                at = i
                break
            end
        end
        table.insert(list, at, rec);
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
            local at = table.find(list, rec)
            if at then
                table.remove(list, at)
            end
            slot_pair[slot] = list[1]
            if #list == 1 then
                slot_pairs[slot] = nil
            end
        end
        local wc_tgt = rec.wc_tgt :: Record
        wc_tgt.version += 1
    end

    ----------------------------------------------------------------------------
    -- set / add / remove
    ----------------------------------------------------------------------------

    local world_remove: (_: any, entity: i53, id: i53) -> ()

    -- Adds a pair (world_set has already replaced an existing value in place). `existing` is
    -- the record of the pair when the caller has looked it up.
    local function pair_add(entity: i53, slot: number, id: i53, value: any, with_value: boolean, existing: Record?)
        local rec = existing or records[id] or pair_record_create(id)
        if rec.pairs then
            error("wildcard pairs can only be used in queries", 3)
        end
        local words = rec.words
        local w = slot // 32 + 1
        local bit = lshift(1, slot % 32)
        local word = words[w]
        if word ~= nil and band(word, bit) ~= 0 then
            if with_value and rec.pages then
                set_value(rec, slot, value)
                local on_change = rec.on_change
                if on_change then
                    on_change(entity, id, value)
                end
            end
            return
        end
        local wc_rel = rec.wc_rel :: Record
        local slot_pair = wc_rel.slot_pair :: { [number]: Record }
        local first = slot_pair[slot]
        if first ~= nil and wc_rel.exclusive then
            world_remove(world, entity, first.id)
            if alive[slot] ~= entity or records[id] ~= rec then
                return
            end
            -- the hooks of the removal may have changed the entity
            word = words[w]
            if word ~= nil and band(word, bit) ~= 0 then
                return
            end
            first = slot_pair[slot]
        end
        if word then
            words[w] = word + bit
            rec.version += 1
        else
            bit_set_word(rec, w, bit)
        end
        if rec.pages and with_value then
            set_value(rec, slot, value)
        end
        -- attach to the relation record (R, *); the target record (*, T) is lazy
        if first == nil then
            slot_pair[slot] = rec
            bit_set(wc_rel, slot)
            sig_add(wc_rel, slot)
        else
            pair_attach_more(rec, wc_rel, slot, first)
        end
        (rec.wc_tgt :: Record).version += 1
        if with_value and value ~= nil and not rec.pages then
            error("cannot set a value on a tag pair; the relation or the target must be a component", 3)
        end
        local on_add = rec.on_add
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
        if word then
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
            words[w] = bit
            rec.word_count += 1
            local sums = rec.sums
            local sw = slot // 1024 + 1
            local sbit = lshift(1, (w - 1) % 32)
            local sum = sums[sw]
            sums[sw] = if sum then sum + sbit else sbit
        end
        rec.version += 1
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
        if not pages and value ~= nil then
            -- the tag stays added, the value is rejected
            error("cannot set a value on a tag; add the Component trait (world:component()) to store data", 2)
        end
        local on_add = rec.on_add
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
        local rec = records[id] or record_create(id)
        local words = rec.words
        local w = slot // 32 + 1
        local bit = lshift(1, slot % 32)
        local word = words[w]
        if word then
            if band(word, bit) ~= 0 then
                return
            end
            words[w] = word + bit
        else
            words[w] = bit
            rec.word_count += 1
            local sums = rec.sums
            local sw = slot // 1024 + 1
            local sbit = lshift(1, (w - 1) % 32)
            local sum = sums[sw]
            sums[sw] = if sum then sum + sbit else sbit
        end
        rec.version += 1
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
        if wc == nil or not (if wc.kind == KIND_TARGET then target_has(wc, slot) else bit_test(wc, slot)) then
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
            on_remove(entity, id)
            -- the hook may have changed the entity already
            if alive[slot] ~= entity or not bit_test(rec, slot) then
                return
            end
            word = words[w]
        end
        word -= bit
        if word == 0 then
            words[w] = nil
            rec.word_count -= 1
            local sums = rec.sums
            local sw = slot // 1024 + 1
            local sum = sums[sw] - lshift(1, (w - 1) % 32)
            sums[sw] = if sum == 0 then nil else sum
        else
            words[w] = word
        end
        rec.version += 1
        local pages = rec.pages
        if pages then
            local page = pages[slot // PAGE_SIZE + 1]
            if page then
                page[slot % PAGE_SIZE + 1] = nil
            end
        end
        if id > PAIR_OFFSET then
            pair_detach(rec, slot)
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

    -- Value of id for the slot, including wildcard pairs (value of the first matching pair).
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
                return if pair_rec then value_of(pair_rec.id, slot) else nil
            elseif rec and rec.kind == KIND_TARGET then
                for pair_id, pair_rec in rec.pairs :: { [i53]: Record } do
                    if pair_rec.pages and bit_test(pair_rec, slot) then
                        return value_of(pair_id, slot)
                    end
                end
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

    local function has_bit(id: i53?, w: number, bit: number): boolean
        if id == nil then
            return true
        end
        local words = pwords[id]
        return words ~= nil and band(words[w] or 0, bit) ~= 0
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
        if words == nil or band(words[w] or 0, bit) == 0 then
            return false
        end
        if b == nil then
            return true
        end
        words = pw[b]
        if words == nil or band(words[w] or 0, bit) == 0 then
            return false
        end
        if c == nil then
            return true
        end
        words = pw[c]
        if words == nil or band(words[w] or 0, bit) == 0 then
            return false
        end
        if d == nil then
            return true
        end
        words = pw[d]
        if words == nil or band(words[w] or 0, bit) == 0 then
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

    -- Appends the records with on_remove hooks among the ids of a slot to buffer.
    local function collect_hooked(slot: number, buffer: { Record }, n: number, k: number, mask: number): number
        local base = (k - 1) * 32 + 1
        repeat
            local rec = by_index[base + countrz(mask)]
            mask = band(mask, mask - 1)
            if rec.kind == KIND_RELATION then
                local list = (rec.slot_pairs :: { [number]: { Record } })[slot]
                    or { (rec.slot_pair :: { [number]: Record })[slot] }
                for _, pair_rec in list do
                    if pair_rec.on_remove then
                        n += 1
                        buffer[n] = pair_rec
                    end
                end
            elseif rec.on_remove then
                n += 1
                buffer[n] = rec
            end
        until mask == 0
        return n
    end

    -- Runs the on_remove hooks of the ids of a slot. Returns false when a hook deleted the
    -- entity. A hook that clears or deletes the same entity again does not run the hooks again.
    local function run_remove_hooks(entity: i53, slot: number, deleting: boolean?): boolean
        if clearing[slot] then
            return true
        end
        clear_depth += 1
        local buffer = clear_buffers[clear_depth]
        if not buffer then
            buffer = {}
            clear_buffers[clear_depth] = buffer
        end
        local n = 0
        local masks = if deleting then hooked_delete else hooked
        for k = 1, sig_flat_used do
            local mask = sig_flat[k][slot]
            if mask then
                mask = band(mask, masks[k])
                if mask ~= 0 then
                    n = collect_hooked(slot, buffer, n, k, mask)
                end
            end
        end
        local more = sig_more[slot]
        if more then
            for k, mask in more do
                mask = band(mask, masks[k] or 0)
                if mask ~= 0 then
                    n = collect_hooked(slot, buffer, n, k, mask)
                end
            end
        end
        clearing[slot] = true
        for i = 1, n do
            local rec = buffer[i]
            buffer[i] = nil :: any
            local on_remove = rec.on_remove
            -- an earlier hook may have removed the id (its hook ran then) or the entity
            if on_remove and alive[slot] == entity and bit_test(rec, slot) then
                on_remove(entity, rec.id, deleting)
            end
        end
        clearing[slot] = nil
        clear_depth -= 1
        return alive[slot] == entity
    end

    -- Removes a pair of a slot from its record (the relation and target records are updated
    -- by the caller).
    local function drop_pair(rec: Record, slot: number)
        bit_clear(rec, slot)
        local pages = rec.pages
        if pages then
            local page = pages[slot // PAGE_SIZE + 1]
            if page then
                page[slot % PAGE_SIZE + 1] = nil
            end
        end
        local wc_tgt = rec.wc_tgt :: Record
        wc_tgt.version += 1
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
        else
            drop_pair((rec.slot_pair :: { [number]: Record })[slot], slot)
        end
        (rec.slot_pair :: { [number]: Record })[slot] = nil
        bit_clear(rec, slot)
    end

    -- Removes a plain id of a slot (rare path of clear_slot: records beyond the shared
    -- signature tables).
    local function drop_record(rec: Record, slot: number)
        if rec.kind == KIND_RELATION then
            drop_relation(rec, slot)
            return
        end
        bit_clear(rec, slot)
        local pages = rec.pages
        if pages then
            local page = pages[slot // PAGE_SIZE + 1]
            if page then
                page[slot % PAGE_SIZE + 1] = nil
            end
        end
    end

    -- Removes every id of the slot. on_remove hooks run first, while all values are present;
    -- the removal then reads the signature again, because hooks may change the entity.
    local function clear_slot(entity: i53, slot: number, deleting: boolean?)
        local more = sig_more[slot]
        local masks = if deleting then hooked_delete else hooked
        for k = 1, sig_flat_used do
            local mask = sig_flat[k][slot]
            if mask and band(mask, masks[k]) ~= 0 then
                if not run_remove_hooks(entity, slot, deleting) then
                    return
                end
                more = sig_more[slot]
                break
            end
        end
        if more then
            for k, mask in more do
                if band(mask, masks[k] or 0) ~= 0 then
                    if not run_remove_hooks(entity, slot, deleting) then
                        return
                    end
                    more = sig_more[slot]
                    break
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
                                drop_pair(pair_rec, slot)
                            end
                        else
                            local slot_pair = rec.slot_pair :: { [number]: Record }
                            local pair_rec = slot_pair[slot]
                            slot_pair[slot] = nil
                            local words = pair_rec.words
                            local word = words[w] - bit
                            if word ~= 0 then
                                words[w] = word
                                pair_rec.version += 1
                            else
                                bit_clear_word(pair_rec, w)
                            end
                            local pages = pair_rec.pages
                            if pages then
                                local page = pages[page_index]
                                if page then
                                    page[page_slot] = nil
                                end
                            end
                            local wc_tgt = pair_rec.wc_tgt :: Record
                            wc_tgt.version += 1
                        end
                    end
                    local words = rec.words
                    local word = words[w] - bit
                    if word ~= 0 then
                        words[w] = word
                        rec.version += 1
                    else
                        bit_clear_word(rec, w)
                    end
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
                    drop_record(rec, slot)
                end
            end
        end
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
        rec.version += 1
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

    -- Removes the id of a record from all its members before the record is freed: only the
    -- member side (signature, relation and target records) is updated; values go with the record.
    local function strip_members(rec: Record)
        local id = rec.id
        local is_pair = rec.kind == KIND_PAIR
        local on_remove = rec.on_remove
        for _, member in members_of(rec) do
            local slot = member % ENTITY_MASK
            if on_remove then
                on_remove(member, id)
                if alive[slot] ~= member or not bit_test(rec, slot) then
                    continue
                end
                -- keep the record consistent for the hooks of the next members
                bit_clear(rec, slot)
            end
            if is_pair then
                pair_detach(rec, slot)
            else
                sig_remove(rec, slot)
            end
        end
    end

    -- Cascading deletes recurse: the members of a deleted id are deleted inside the delete of
    -- the id. Past MAX_DELETE_DEPTH nested levels the members are queued instead and deleted
    -- once the outermost delete has cleaned up, so deleting a very deep hierarchy cannot
    -- overflow the stack.
    local MAX_DELETE_DEPTH = 100
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
        if delete then
            if delete_depth >= MAX_DELETE_DEPTH then
                for _, member in members_of(rec) do
                    table.insert(deferred, member)
                end
            else
                delete_depth += 1
                for _, member in members_of(rec) do
                    world_delete(world, member)
                end
                delete_depth -= 1
            end
        else
            strip_members(rec)
        end
        free_record(rec)
    end

    local function has_policy(entity: i53, policy: i53, action: i53): boolean
        return world_has_pair(entity, ECS_PAIR(policy, action))
    end

    -- Applies cleanup policies for an entity that is used as an id, relation or target.
    local function cleanup_ids(entity: i53, delete_policy: boolean)
        -- the entity used as a component or tag
        local rec = records[entity]
        if rec then
            cleanup_record(rec, delete_policy)
        end

        -- the entity used as a relation: pairs (entity, *)
        local relation_rec = records[ECS_PAIR(entity, EcsWildcard)]
        if relation_rec then
            local list: { Record } = {}
            for _, pair_rec in relation_rec.pairs :: { [i53]: Record } do
                table.insert(list, pair_rec)
            end
            for _, pair_rec in list do
                cleanup_record(pair_rec, delete_policy)
            end
            free_record(relation_rec)
        end

        -- the entity used as a target: pairs (*, entity)
        local target_rec = records[ECS_PAIR(EcsWildcard, entity)]
        if target_rec then
            local list: { Record } = {}
            for _, pair_rec in target_rec.pairs :: { [i53]: Record } do
                table.insert(list, pair_rec)
            end
            for _, pair_rec in list do
                cleanup_record(pair_rec, has_policy(pair_rec.relation :: i53, EcsOnDeleteTarget, EcsDelete))
            end
            free_record(target_rec)
        end
    end

    function world_delete(_: any, entity: i53)
        local slot = entity % ENTITY_MASK
        if alive[slot] ~= entity then
            return
        end
        if id_used[slot] then
            -- the cleanup policy of the entity itself is one of its own ids: read it first
            local delete_policy = has_policy(entity, EcsOnDelete, EcsDelete)
            clear_slot(entity, slot, true)
            if alive[slot] ~= entity then
                return -- deleted by a hook
            end
            cleanup_ids(entity, delete_policy)
            id_used[slot] = nil
            if delete_depth == 0 and deferred[1] ~= nil then
                drain_deferred()
            end
            -- a hook of the cascade may have given the entity ids again (a child that writes
            -- into its parent while the parent is deleted): they go as well, or the freed slot
            -- would keep them for the entity that reuses it
            if alive[slot] == entity and slot_has_ids(slot) then
                clear_slot(entity, slot, true)
            end
        else
            clear_slot(entity, slot, true)
        end
        if alive[slot] ~= entity then
            return -- deleted by a hook
        end
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
                        bit_clear_word(rec, w)
                    else
                        rec.words[w] = word - bit
                        rec.version += 1
                    end
                end
            end
        end
        alive[slot] = -1 - slot * ENTITY_MASK
        local generation = entity // ENTITY_MASK + 1
        if generation >= GENERATION_MASK then
            generation = 0
        end
        free_count += 1
        free[free_count] = slot + generation * ENTITY_MASK
    end

    ----------------------------------------------------------------------------
    -- entities and ids
    ----------------------------------------------------------------------------

    local function world_entity(_: any, id: i53?): i53
        if id == nil then
            return new_slot()
        end
        local slot = id % ENTITY_MASK
        if alive[slot] == id then
            return id
        end
        if slot > max_slot then
            for s = max_slot + 1, slot - 1 do
                alive[s] = -1 - s * ENTITY_MASK
                free_count += 1
                free[free_count] = s
            end
            max_slot = slot
        else
            for i = free_count, 1, -1 do
                if free[i] % ENTITY_MASK == slot then
                    table.remove(free, i)
                    free_count -= 1
                    break
                end
            end
            local current = alive[slot]
            if current > 0 then
                world_delete(world, current)
                for i = free_count, 1, -1 do
                    if free[i] % ENTITY_MASK == slot then
                        table.remove(free, i)
                        free_count -= 1
                        break
                    end
                end
            end
        end
        alive[slot] = id
        return id
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

    local function world_range(_: any, range_begin: number, range_end_: number?)
        range_end = range_end_
        if range_begin > max_slot then
            for s = max_slot + 1, range_begin do
                alive[s] = -1 - s * ENTITY_MASK
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

    -- Iterates the entities that have a record.
    local function iterate_record(rec: Record?): () -> i53?
        if rec and rec.kind == KIND_TARGET then
            target_materialize(rec)
        end
        if rec == nil or rec.word_count == 0 then
            return NOOP
        end
        local list = members_of(rec)
        local i = 0
        return function(): i53?
            i += 1
            return list[i]
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

    -- Gives the records of an id (and of its pairs, for a relation) their callback.
    local function install_hook(entity: i53, field: string, value: Hook?)
        local rec = records[entity]
        if rec then
            (rec :: any)[field] = value
            if field == "on_remove" then
                set_hooked(rec, value ~= nil)
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

    -- The hooked masks of the records of an id after its dispatcher changed.
    local function refresh_hooked(id: i53)
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
            if field == "on_remove" then
                refresh_hooked(entity)
            end
        else
            install_hook(entity, field, value)
        end
    end

    local hook_ids = { on_add = EcsOnAdd, on_change = EcsOnChange, on_remove = EcsOnRemove }

    -- Signals: the first listener of an id installs a dispatcher that calls the hook of the id
    -- (if any) and then the listeners, so hooks and signals (and change tracking) coexist.
    -- The listener list is copied on write: a listener that connects or disconnects others (or
    -- itself) during a dispatch changes the next dispatches only. A quiet listener has nothing
    -- to do when an entity is deleted (change tracking).
    local function connect(field: string, id: i53, listener: Hook, quiet: boolean?): () -> ()
        local cell = dispatched_hooks[field][id]
        if cell == nil then
            local created: Dispatch = { hook = hook_of(hook_ids[field], id % ENTITY_MASK), listeners = {}, loud = 0 }
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
                if field == "on_remove" then
                    refresh_hooked(id)
                end
            end
        end
    end

    local function world_added(_: any, id: i53, listener: Hook): () -> ()
        return connect("on_add", id, listener)
    end

    local function world_changed(_: any, id: i53, listener: Hook): () -> ()
        return connect("on_change", id, listener)
    end

    local function world_removed(_: any, id: i53, listener: Hook): () -> ()
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
    local TRACK_KINDS = { "added", "changed", "removed" }

    local function new_track_slot(): Record
        return { words = {}, sums = {}, word_count = 0, version = 0, kind = KIND_PLAIN, index = 0 } :: any
    end

    local function track_mark(rec: Record, slot: number)
        last_marked[slot] = current_tick
        local words = rec.words
        local w = slot // 32 + 1
        local bit = lshift(1, slot % 32)
        local word = words[w]
        if word == nil then
            bit_set_word(rec, w, bit)
        elseif band(word, bit) == 0 then
            words[w] = word + bit
            rec.version += 1
        end
    end

    local function world_track(_: any, id: i53)
        if tracked[id] then
            return
        end
        local rings: { [string]: { Record } } = {}
        for _, kind in TRACK_KINDS do
            local ring: { Record } = table.create(TRACK_TICKS) :: { Record }
            for t = 1, TRACK_TICKS do
                local rec = new_track_slot()
                ring[t] = rec
                table.insert(track_rings, rec)
                table.insert(track_words, rec.words)
            end
            rings[kind] = ring
        end
        tracked[id] = rings
        local added, changed, removed = rings.added, rings.changed, rings.removed
        connect("on_add", id, function(entity: i53)
            track_mark(added[current_tick % TRACK_TICKS + 1], entity % ENTITY_MASK)
        end)
        connect("on_change", id, function(entity: i53)
            track_mark(changed[current_tick % TRACK_TICKS + 1], entity % ENTITY_MASK)
        end)
        connect("on_remove", id, function(entity: i53, _: i53, deleting: any?)
            -- not for a deleted entity: world_delete forgets all changes of its slot
            if not deleting then
                track_mark(removed[current_tick % TRACK_TICKS + 1], entity % ENTITY_MASK)
            end
        end, true)
    end

    local function world_tick(_: any): number
        current_tick += 1
        local index = current_tick % TRACK_TICKS + 1
        for _, rings in tracked do
            for _, ring in rings do
                local rec = ring[index]
                if rec.word_count > 0 then
                    table.clear(rec.words)
                    table.clear(rec.sums)
                    rec.word_count = 0
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
            error("change filters need a tracked id: call world:track(id) first", 4)
        end
        local ring = rings[kind]
        if first == last then
            return ring[first % TRACK_TICKS + 1]
        end
        local merged = new_track_slot()
        for t = first, last do
            local rec = ring[t % TRACK_TICKS + 1]
            for w, word in rec.words do
                local old = merged.words[w]
                if old then
                    merged.words[w] = bor(old, word)
                else
                    bit_set_word(merged, w, word)
                end
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
        local merged: Record =
            { words = {}, sums = {}, word_count = 0, version = 0, kind = KIND_PLAIN, index = 0 } :: any
        local versions: { number } = {}
        for i, id in group do
            local rec = records[id]
            versions[i] = if rec then rec.version else -1
            if rec then
                if rec.kind == KIND_TARGET then
                    target_materialize(rec)
                end
                local words = merged.words
                for w, word in rec.words do
                    local old = words[w]
                    if old then
                        words[w] = bor(old, word)
                    else
                        bit_set_word(merged, w, word)
                    end
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
        return driver, others, without
    end

    -- Word tests of the general case (more than three other terms, or excluded ids):
    -- the bits of word w that match every term, and whether all of them do.
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
                if without[k][w] ~= nil then
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
    -- new_advance returns the generator and a function that binds it to a plan; a bound
    -- generator can be bound again for the next iteration.
    local function new_advance(): (() -> (number?, number?, number), (Record, { Words }, { Words }) -> ())
        local dsums: Words, dwords: Words = EMPTY_WORDS_TABLE, EMPTY_WORDS_TABLE
        local o1: Words?, o2: Words?, o3: Words? = nil, nil, nil
        -- up to three other terms and no excluded ones: the word tests are inline
        local simple = true
        local word_mask: (w: number) -> number, word_full: (w: number) -> boolean
        local max_sw = 0
        local sw, smask = 0, 0

        local function bind(driver: Record, others: { Words }, without: { Words })
            dsums, dwords = driver.sums, driver.words
            o1, o2, o3 = others[1], others[2], others[3]
            simple = #others <= 3 and #without == 0
            if not simple then
                word_mask, word_full = make_word_tests(dwords, others, without)
            end
            max_sw = max_slot // 1024 + 1
            sw, smask = 0, 0
        end

        return function(): (number?, number?, number)
            local mask = smask
            while true do
                while mask == 0 do
                    local next_sw = sw + 1
                    sw = next_sw
                    if next_sw > max_sw then
                        smask = 0
                        return nil, nil, 0
                    end
                    mask = dsums[next_sw] or 0
                end
                local b = countrz(mask)
                mask = band(mask, mask - 1)
                local w = (sw - 1) * 32 + b + 1
                local m: number
                if simple then
                    local x1, x2, x3 = o1, o2, o3
                    local d = dwords[w]
                    if d == nil then
                        continue -- emptied during the iteration
                    end
                    m = d
                    local o = if x1 then x1[w] else FULL_WORD
                    if o == nil then
                        continue
                    end
                    m = band(m, o)
                    o = if x2 then x2[w] else FULL_WORD
                    if o == nil then
                        continue
                    end
                    m = band(m, o)
                    o = if x3 then x3[w] else FULL_WORD
                    if o == nil then
                        continue
                    end
                    m = band(m, o)
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
                        local d, x1, x2, x3 = dwords, o1, o2, o3
                        while last_w < page_last_w do
                            local nw = last_w + 1
                            if
                                d[nw] ~= FULL_WORD
                                or (x1 and x1[nw] ~= FULL_WORD)
                                or (x2 and x2[nw] ~= FULL_WORD)
                                or (x3 and x3[nw] ~= FULL_WORD)
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

    -- Queries that return wildcard values read them through value_of (generic iterator).
    local function query_needs_generic(query: QueryState): boolean
        for _, id in query.ids do
            if columns[id] == nil and is_wildcard(id) then
                return true
            end
        end
        return false
    end

    local function value_pages(query: QueryState): { Pages }
        local list: { Pages } = {}
        for i, id in query.ids do
            list[i] = columns[id] or EMPTY_PAGES
        end
        return list
    end

    -- Generic iterator: more than 8 values, or wildcard values (read through value_of).
    local function generic_iter(query: QueryState): (any, any, any)
        local driver, others, without = plan_query(query)
        if driver == nil then
            return NOOP, nil, nil
        end
        local advance = make_advance(driver, others, without)
        local ids = query.ids
        local n = #ids
        local column_pages: { Pages | false } = table.create(n) :: { Pages | false }
        for k, id in ids do
            column_pages[k] = columns[id] or (if is_wildcard(id) then false else EMPTY_PAGES)
        end
        local current: { Page } = table.create(n) :: { Page }
        local out = table.create(n)
        local cur_page = 0
        local page_offset = 0
        local base, mask, run_last = 0, 0, -1
        local s = 0
        return function(): ...any
            while true do
                if s < run_last then
                    s += 1
                    break
                elseif mask ~= 0 then
                    s = base + countrz(mask)
                    mask = band(mask, mask - 1)
                    break
                end
                local first, last, m = advance()
                if first == nil then
                    return nil
                end
                local page = first // PAGE_SIZE + 1
                if page ~= cur_page then
                    cur_page = page
                    page_offset = (page - 1) * PAGE_SIZE - 1
                    for k = 1, n do
                        local pages = column_pages[k]
                        current[k] = if pages then pages[page] or EMPTY else EMPTY
                    end
                end
                if m == FULL_WORD then
                    s = first
                    run_last = last :: number
                    mask = 0
                    break
                end
                run_last = -1
                base = first
                mask = m
            end
            local li = s - page_offset
            for k = 1, n do
                if column_pages[k] then
                    out[k] = current[k][li]
                else
                    out[k] = value_of(ids[k], s)
                end
            end
            return alive[s], table.unpack(out, 1, n)
        end,
            nil,
            nil
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

    local function direct_iter(query: QueryState): (any, any, any)
        if query_needs_generic(query) then
            return generic_iter(query)
        end
        local ctx = query.direct
        if ctx == nil or ctx.busy then
            -- first iteration, or the previous loop was left early or is still running
            ctx = new_direct(#query.ids)
            if query.is_cached then
                query.direct = ctx
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

    -- Builds the match list of a cached query: entities and local page indices, grouped by
    -- page with the value page of every returned id per group.
    local function build_list(query: QueryState)
        local driver, others, without = plan_query(query)
        if query.list_readers > 0 then
            -- a loop over the current list has not finished (a nested iteration of the query
            -- after a change, or a loop left early): it keeps the old tables
            query.list_entities = {}
            query.list_locals = {}
            query.list_ends = {}
            query.list_pages = {}
            query.list_count = 0
            query.list_groups = 0
            query.list_step = nil
            query.list_reset = nil
        end
        local entities = query.list_entities
        local locals = query.list_locals
        local ends = query.list_ends
        local cols = value_pages(query)
        local n_cols = #cols
        local pages_lists = query.list_pages
        for k = 1, n_cols do
            if pages_lists[k] == nil then
                pages_lists[k] = {}
            end
        end
        local n, groups, current_page = 0, 0, 0
        if driver then
            local advance = make_advance(driver, others, without)
            while true do
                local first, last, m = advance()
                if first == nil then
                    break
                end
                local page = first // PAGE_SIZE + 1
                if page ~= current_page then
                    if groups > 0 then
                        ends[groups] = n
                    end
                    groups += 1
                    current_page = page
                    for k = 1, n_cols do
                        pages_lists[k][groups] = cols[k][page] or EMPTY
                    end
                end
                local offset = (page - 1) * PAGE_SIZE - 1
                if m == FULL_WORD then
                    for s = first, last :: number do
                        n += 1
                        entities[n] = alive[s]
                        locals[n] = s - offset
                    end
                else
                    repeat
                        local s = first + countrz(m)
                        m = band(m, m - 1)
                        n += 1
                        entities[n] = alive[s]
                        locals[n] = s - offset
                    until m == 0
                end
            end
            if groups > 0 then
                ends[groups] = n
            end
        end
        for i = n + 1, query.list_count do
            entities[i] = nil
            locals[i] = nil
        end
        for g = groups + 1, query.list_groups do
            ends[g] = nil
            for k = 1, n_cols do
                pages_lists[k][g] = nil :: any
            end
        end
        query.list_count = n
        query.list_groups = groups
    end

    local function list_iter(query: QueryState): (() -> ...any, () -> ())
        local entities = query.list_entities
        local locals = query.list_locals
        local ends = query.list_ends
        local pages_lists = query.list_pages
        local n = #query.ids
        local g1, g2, g3, g4 = pages_lists[1], pages_lists[2], pages_lists[3], pages_lists[4]
        local g5, g6, g7, g8 = pages_lists[5], pages_lists[6], pages_lists[7], pages_lists[8]

        -- @generated list_iterators begin
        if n == 0 then
            local j, done = 0, false
            return function(): ...any
                local k = j + 1
                j = k
                local e = entities[k]
                if e == nil and not done then
                    done = true
                    query.list_busy = false
                    query.list_readers -= 1
                end
                return e
            end, function()
                j, done = 0, false
            end
        elseif n == 1 then
            local j, g, group_last = 0, 0, 0
            local p1 = EMPTY
            return function(): ...any
                local k = j + 1
                j = k
                if k > group_last then
                    local next_g = g + 1
                    local last = ends[next_g]
                    if last == nil then
                        if g >= 0 then
                            g = -1 -- the end is counted once
                            query.list_busy = false
                            query.list_readers -= 1
                        end
                        return nil
                    end
                    g = next_g
                    group_last = last
                    p1 = g1[next_g]
                end
                local li = locals[k]
                return entities[k], p1[li]
            end, function()
                j, g, group_last = 0, 0, 0
            end
        elseif n == 2 then
            local j, g, group_last = 0, 0, 0
            local p1, p2 = EMPTY, EMPTY
            return function(): ...any
                local k = j + 1
                j = k
                if k > group_last then
                    local next_g = g + 1
                    local last = ends[next_g]
                    if last == nil then
                        if g >= 0 then
                            g = -1 -- the end is counted once
                            query.list_busy = false
                            query.list_readers -= 1
                        end
                        return nil
                    end
                    g = next_g
                    group_last = last
                    p1 = g1[next_g]
                    p2 = g2[next_g]
                end
                local li = locals[k]
                return entities[k], p1[li], p2[li]
            end, function()
                j, g, group_last = 0, 0, 0
            end
        elseif n == 3 then
            local j, g, group_last = 0, 0, 0
            local p1, p2, p3 = EMPTY, EMPTY, EMPTY
            return function(): ...any
                local k = j + 1
                j = k
                if k > group_last then
                    local next_g = g + 1
                    local last = ends[next_g]
                    if last == nil then
                        if g >= 0 then
                            g = -1 -- the end is counted once
                            query.list_busy = false
                            query.list_readers -= 1
                        end
                        return nil
                    end
                    g = next_g
                    group_last = last
                    p1 = g1[next_g]
                    p2 = g2[next_g]
                    p3 = g3[next_g]
                end
                local li = locals[k]
                return entities[k], p1[li], p2[li], p3[li]
            end, function()
                j, g, group_last = 0, 0, 0
            end
        elseif n == 4 then
            local j, g, group_last = 0, 0, 0
            local p1, p2, p3, p4 = EMPTY, EMPTY, EMPTY, EMPTY
            return function(): ...any
                local k = j + 1
                j = k
                if k > group_last then
                    local next_g = g + 1
                    local last = ends[next_g]
                    if last == nil then
                        if g >= 0 then
                            g = -1 -- the end is counted once
                            query.list_busy = false
                            query.list_readers -= 1
                        end
                        return nil
                    end
                    g = next_g
                    group_last = last
                    p1 = g1[next_g]
                    p2 = g2[next_g]
                    p3 = g3[next_g]
                    p4 = g4[next_g]
                end
                local li = locals[k]
                return entities[k], p1[li], p2[li], p3[li], p4[li]
            end, function()
                j, g, group_last = 0, 0, 0
            end
        elseif n == 5 then
            local j, g, group_last = 0, 0, 0
            local p1, p2, p3, p4, p5 = EMPTY, EMPTY, EMPTY, EMPTY, EMPTY
            return function(): ...any
                local k = j + 1
                j = k
                if k > group_last then
                    local next_g = g + 1
                    local last = ends[next_g]
                    if last == nil then
                        if g >= 0 then
                            g = -1 -- the end is counted once
                            query.list_busy = false
                            query.list_readers -= 1
                        end
                        return nil
                    end
                    g = next_g
                    group_last = last
                    p1 = g1[next_g]
                    p2 = g2[next_g]
                    p3 = g3[next_g]
                    p4 = g4[next_g]
                    p5 = g5[next_g]
                end
                local li = locals[k]
                return entities[k], p1[li], p2[li], p3[li], p4[li], p5[li]
            end, function()
                j, g, group_last = 0, 0, 0
            end
        elseif n == 6 then
            local j, g, group_last = 0, 0, 0
            local p1, p2, p3, p4, p5, p6 = EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY
            return function(): ...any
                local k = j + 1
                j = k
                if k > group_last then
                    local next_g = g + 1
                    local last = ends[next_g]
                    if last == nil then
                        if g >= 0 then
                            g = -1 -- the end is counted once
                            query.list_busy = false
                            query.list_readers -= 1
                        end
                        return nil
                    end
                    g = next_g
                    group_last = last
                    p1 = g1[next_g]
                    p2 = g2[next_g]
                    p3 = g3[next_g]
                    p4 = g4[next_g]
                    p5 = g5[next_g]
                    p6 = g6[next_g]
                end
                local li = locals[k]
                return entities[k], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li]
            end, function()
                j, g, group_last = 0, 0, 0
            end
        elseif n == 7 then
            local j, g, group_last = 0, 0, 0
            local p1, p2, p3, p4, p5, p6, p7 = EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY
            return function(): ...any
                local k = j + 1
                j = k
                if k > group_last then
                    local next_g = g + 1
                    local last = ends[next_g]
                    if last == nil then
                        if g >= 0 then
                            g = -1 -- the end is counted once
                            query.list_busy = false
                            query.list_readers -= 1
                        end
                        return nil
                    end
                    g = next_g
                    group_last = last
                    p1 = g1[next_g]
                    p2 = g2[next_g]
                    p3 = g3[next_g]
                    p4 = g4[next_g]
                    p5 = g5[next_g]
                    p6 = g6[next_g]
                    p7 = g7[next_g]
                end
                local li = locals[k]
                return entities[k], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li]
            end, function()
                j, g, group_last = 0, 0, 0
            end
        elseif n == 8 then
            local j, g, group_last = 0, 0, 0
            local p1, p2, p3, p4, p5, p6, p7, p8 = EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY
            return function(): ...any
                local k = j + 1
                j = k
                if k > group_last then
                    local next_g = g + 1
                    local last = ends[next_g]
                    if last == nil then
                        if g >= 0 then
                            g = -1 -- the end is counted once
                            query.list_busy = false
                            query.list_readers -= 1
                        end
                        return nil
                    end
                    g = next_g
                    group_last = last
                    p1 = g1[next_g]
                    p2 = g2[next_g]
                    p3 = g3[next_g]
                    p4 = g4[next_g]
                    p5 = g5[next_g]
                    p6 = g6[next_g]
                    p7 = g7[next_g]
                    p8 = g8[next_g]
                end
                local li = locals[k]
                return entities[k], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li], p8[li]
            end, function()
                j, g, group_last = 0, 0, 0
            end
        end
        -- @generated list_iterators end
        error("list mode supports at most 8 values") -- choose_mode never picks it for more
    end

    -- Updates the observed records and versions; returns true when something changed.
    local function observe(query: QueryState): boolean
        local observed = query.observed
        local versions = query.versions
        if query.observed_generation == records_generation then
            -- the same records as last time: only their versions can differ
            local changed = false
            for k = 1, query.observed_records :: number do
                local rec = observed[k]
                if rec then
                    local version = rec.version
                    if versions[k] ~= version then
                        versions[k] = version
                        changed = true
                    end
                end
            end
            return changed
        end
        query.observed_generation = records_generation
        local changed = false
        local i = 0
        for _, id in query.filter_with do
            i += 1
            local rec: any = records[id] or false
            local version = if rec then rec.version else -1
            if observed[i] ~= rec or versions[i] ~= version then
                observed[i] = rec
                versions[i] = version
                changed = true
            end
        end
        local filter_without = query.filter_without
        if filter_without then
            for _, id in filter_without do
                i += 1
                local rec: any = records[id] or false
                local version = if rec then rec.version else -1
                if observed[i] ~= rec or versions[i] ~= version then
                    observed[i] = rec
                    versions[i] = version
                    changed = true
                end
            end
        end
        if query.skip_disabled then
            i += 1
            local rec: any = records[EcsDisabled] or false
            local version = if rec then rec.version else -1
            if observed[i] ~= rec or versions[i] ~= version then
                observed[i] = rec
                versions[i] = version
                changed = true
            end
        end
        local any_groups = query.any_groups
        if any_groups then
            for _, group in any_groups do
                for _, id in group do
                    i += 1
                    local rec: any = records[id] or false
                    local version = if rec then rec.version else -1
                    if observed[i] ~= rec or versions[i] ~= version then
                        observed[i] = rec
                        versions[i] = version
                        changed = true
                    end
                end
            end
        end
        query.observed_records = i
        for _, id in query.ids do
            i += 1
            local pages: any = columns[id] or false
            if observed[i] ~= pages then
                observed[i] = pages
                changed = true
            end
        end
        return changed
    end

    -- How a stable cached query is iterated: 1 = direct bitsets, 2 = dense list.
    local function choose_mode(query: QueryState): number
        if #query.ids > 8 or query_needs_generic(query) then
            return 1
        end
        local driver, others, without = plan_query(query)
        if driver == nil then
            return 1
        end
        -- direct iteration is fastest over runs of full words, the list over scattered matches
        local advance = make_advance(driver, others, without)
        local in_runs, scattered = 0, 0
        while true do
            local first, last, m = advance()
            if first == nil then
                break
            end
            if m == FULL_WORD then
                in_runs += (last :: number) - first + 1
            else
                repeat
                    scattered += 1
                    m = band(m, m - 1)
                until m == 0
            end
        end
        if scattered <= in_runs or scattered > LIST_MAX then
            return 1
        end
        build_list(query)
        return 2
    end

    -- Mode of a query for this iteration: 1 = direct, 2 = dense list.
    local function iteration_mode(query: QueryState): number
        if not query.is_cached or query.tracking then
            return 1
        end
        if observe(query) then
            query.mode = 0
            return 1
        end
        if query.mode == 0 then
            query.mode = choose_mode(query)
        end
        return query.mode
    end

    local function query_iter(query: QueryState): (any, any, any)
        if iteration_mode(query) == 2 then
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
        local entities = query.list_entities
        local locals = query.list_locals
        local ends = query.list_ends
        local count = query.list_count
        local groups = query.list_groups
        local pages_lists = query.list_pages
        local g1, g2, g3, g4 = pages_lists[1], pages_lists[2], pages_lists[3], pages_lists[4]
        local g5, g6, g7, g8 = pages_lists[5], pages_lists[6], pages_lists[7], pages_lists[8]

        -- @generated list_each begin
        if n == 0 then
            for j = 1, count do
                callback(entities[j])
            end
            return
        elseif n == 1 then
            local k = 0
            for g = 1, groups do
                local p1 = g1[g]
                local last = ends[g]
                for j = k + 1, last do
                    local li = locals[j]
                    callback(entities[j], p1[li])
                end
                k = last
            end
            return
        elseif n == 2 then
            local k = 0
            for g = 1, groups do
                local p1, p2 = g1[g], g2[g]
                local last = ends[g]
                for j = k + 1, last do
                    local li = locals[j]
                    callback(entities[j], p1[li], p2[li])
                end
                k = last
            end
            return
        elseif n == 3 then
            local k = 0
            for g = 1, groups do
                local p1, p2, p3 = g1[g], g2[g], g3[g]
                local last = ends[g]
                for j = k + 1, last do
                    local li = locals[j]
                    callback(entities[j], p1[li], p2[li], p3[li])
                end
                k = last
            end
            return
        elseif n == 4 then
            local k = 0
            for g = 1, groups do
                local p1, p2, p3, p4 = g1[g], g2[g], g3[g], g4[g]
                local last = ends[g]
                for j = k + 1, last do
                    local li = locals[j]
                    callback(entities[j], p1[li], p2[li], p3[li], p4[li])
                end
                k = last
            end
            return
        elseif n == 5 then
            local k = 0
            for g = 1, groups do
                local p1, p2, p3, p4, p5 = g1[g], g2[g], g3[g], g4[g], g5[g]
                local last = ends[g]
                for j = k + 1, last do
                    local li = locals[j]
                    callback(entities[j], p1[li], p2[li], p3[li], p4[li], p5[li])
                end
                k = last
            end
            return
        elseif n == 6 then
            local k = 0
            for g = 1, groups do
                local p1, p2, p3, p4, p5, p6 = g1[g], g2[g], g3[g], g4[g], g5[g], g6[g]
                local last = ends[g]
                for j = k + 1, last do
                    local li = locals[j]
                    callback(entities[j], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li])
                end
                k = last
            end
            return
        elseif n == 7 then
            local k = 0
            for g = 1, groups do
                local p1, p2, p3, p4, p5, p6, p7 = g1[g], g2[g], g3[g], g4[g], g5[g], g6[g], g7[g]
                local last = ends[g]
                for j = k + 1, last do
                    local li = locals[j]
                    callback(entities[j], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li])
                end
                k = last
            end
            return
        elseif n == 8 then
            local k = 0
            for g = 1, groups do
                local p1, p2, p3, p4, p5, p6, p7, p8 = g1[g], g2[g], g3[g], g4[g], g5[g], g6[g], g7[g], g8[g]
                local last = ends[g]
                for j = k + 1, last do
                    local li = locals[j]
                    callback(entities[j], p1[li], p2[li], p3[li], p4[li], p5[li], p6[li], p7[li], p8[li])
                end
                k = last
            end
            return
        end
        -- @generated list_each end
    end

    local function query_each(query: QueryState, callback: (...any) -> ())
        local n = #query.ids
        if iteration_mode(query) == 2 then
            query.list_readers += 1
            list_each(query, callback)
            query.list_readers -= 1
            return
        end
        if query_needs_generic(query) then
            local step = generic_iter(query)
            local function pass(e: i53?, ...: any): boolean
                if e == nil then
                    return false
                end
                callback(e, ...)
                return true
            end
            repeat
                local more = pass(step())
            until not more
            return
        end
        local ctx = query.each_ctx
        if ctx == nil or ctx.busy then
            local advance, bind = new_advance()
            ctx = { busy = false, others = {}, without = {}, advance = advance, bind = bind }
            if query.is_cached then
                query.each_ctx = ctx
            end
        end
        local driver = plan_query(query, ctx.others, ctx.without)
        if driver == nil then
            return
        end
        ctx.bind(driver, ctx.others, ctx.without)
        ctx.busy = true
        local advance = ctx.advance
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
        local w = slot // 32 + 1
        local bit = lshift(1, slot % 32)
        for _, id in query.filter_with do
            if not has_bit(id, w, bit) then
                return false
            end
        end
        local filter_without = query.filter_without
        if filter_without then
            for _, id in filter_without do
                local words = pwords[id]
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
                    local words = pwords[id]
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
        local rec = if id > PAIR_OFFSET then nil else records[id] or record_create(id)
        if rec == nil or rec.on_add or (set and rec.on_change) then
            for _, entity in matched_entities(n) do
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
        local words, sums = rec.words, rec.sums
        local st, sig_bit = rec.sig_table, rec.sig_bit
        local added = false
        for i = 1, n, 2 do
            local w, m = buffer[i], buffer[i + 1]
            local base = (w - 1) * 32
            local old = words[w]
            local fresh = if old then m - band(m, old) else m
            if fresh ~= 0 then
                added = true
                if old then
                    words[w] = old + fresh
                else
                    words[w] = fresh
                    rec.word_count += 1
                    local sw = (w - 1) // 32 + 1
                    local sbit = lshift(1, (w - 1) % 32)
                    local sum = sums[sw]
                    sums[sw] = if sum then sum + sbit else sbit
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
            rec.version += 1
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
        local words, sums = rec.words, rec.sums
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
                        words[w] = nil
                        rec.word_count -= 1
                        local sw = (w - 1) // 32 + 1
                        local sum = sums[sw] - lshift(1, (w - 1) % 32)
                        sums[sw] = if sum == 0 then nil else sum
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
            rec.version += 1
        end
    end

    local function query_delete(query: QueryState)
        for _, entity in matched_entities(match_words(query)) do
            world_delete(world, entity)
        end
    end

    local Query = {}
    Query.__index = Query

    function Query.__iter(self: QueryHandle): (any, any, any)
        return query_iter(self.state)
    end

    -- Shared queries: world:query returns one query object per shape (the returned ids, then
    -- the ids of :with and :without), kept in a tree of shapes. A shared query is cached and
    -- never changes; its modifiers return the shared variant (or a new query when the variant
    -- cannot be shared). Pairs with a concrete target are not shared: their number is unbounded.
    local shapes: { [any]: any } = {}
    local shape_count = 0
    local MAX_SHAPES = 1024

    local function shareable(id: i53): boolean
        return id < PAIR_OFFSET or is_wildcard(id)
    end

    local function make_cached(query: QueryState): QueryState
        if not query.is_cached then
            query.is_cached = true
            query.observed = {}
            query.versions = {}
            query.list_entities = {}
            query.list_locals = {}
            query.list_ends = {}
            query.list_pages = {}
        end
        return query
    end

    local function new_query(ids: { i53 }): QueryState
        -- the state of cached queries is created by make_cached; uncached queries share empty
        -- frozen tables (they never write to them)
        return {
            world = world,
            ids = ids,
            filter_with = ids,
            filter_without = nil,
            is_cached = false,
            observed = NO_STATE,
            versions = NO_STATE,
            mode = 0,
            list_entities = NO_STATE,
            list_locals = NO_STATE,
            list_ends = NO_STATE,
            list_pages = NO_STATE,
            list_count = 0,
            list_groups = 0,
            list_readers = 0,
            skip_disabled = table.find(ids, EcsDisabled) == nil,
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
        for _, group in query.any_groups or {} do
            if table.find(group, EcsDisabled) then
                return true
            end
        end
        return false
    end

    -- The terms of a query changed in place: what a cached query observed no longer covers
    -- them (the next iteration observes the records of the new terms and plans again).
    local function forget_plan(query: QueryState)
        query.mode = 0
        query.observed_generation = nil
    end

    local function apply_with(query: QueryState, ...: i53): QueryState
        local with = table.clone(query.ids)
        for i = 1, select("#", ...) do
            table.insert(with, (select(i, ...)))
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
        local copy = new_query(query.ids)
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

    -- The shared variant of a shared query for `kind` ("with" or "without") and the given ids.
    local function shared_variant(
        query: QueryState,
        kind: string,
        apply: (QueryState, ...i53) -> QueryState,
        ...: i53
    ): QueryState
        local variants = query.variants
        if variants == nil then
            variants = {}
            query.variants = variants
        end
        local node: any = (variants :: any)[kind]
        if node == nil then
            node = {}
            (variants :: any)[kind] = node
        end
        for i = 1, select("#", ...) do
            local id = select(i, ...)
            if not shareable(id) then
                return apply(copy_query(query), ...)
            end
            local child = node[id]
            if child == nil then
                child = {}
                node[id] = child
            end
            node = child
        end
        local variant: QueryState? = node.query
        if variant == nil then
            if shape_count >= MAX_SHAPES then
                return apply(copy_query(query), ...)
            end
            shape_count += 1
            local created = make_cached(apply(copy_query(query), ...))
            created.shared = true
            (node :: any).query = created
            return created
        end
        return variant
    end

    function Query.with(self: QueryHandle, ...: i53): QueryHandle
        local state = self.state
        if state.shared then
            self.state = shared_variant(state, "with", apply_with, ...)
        else
            apply_with(state, ...)
        end
        return self
    end

    function Query.without(self: QueryHandle, ...: i53): QueryHandle
        local state = self.state
        if state.shared then
            self.state = shared_variant(state, "without", apply_without, ...)
        else
            apply_without(state, ...)
        end
        return self
    end

    function Query.any(self: QueryHandle, ...: i53): QueryHandle
        local state = self.state
        if state.shared then
            self.state = shared_variant(state, "any", apply_any, ...)
        else
            apply_any(state, ...)
        end
        return self
    end

    local function add_tracking(self: QueryState, kind: string, id: i53): QueryState
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

    -- A cached query keeps what it observed and its match list between iterations (shared
    -- queries are cached already).
    function Query.cached(self: QueryHandle): QueryHandle
        make_cached(self.state)
        return self
    end

    function Query.each(self: QueryHandle, callback: (...any) -> ())
        query_each(self.state, callback)
    end

    function Query.has(self: QueryHandle, entity: i53): boolean
        return query_has(self.state, entity)
    end

    -- Batch operations on the entities that match the query at the time of the call.
    function Query.count(self: QueryHandle): number
        return query_count(self.state)
    end

    function Query.add_all(self: QueryHandle, id: i53)
        query_insert(self.state, id, nil, false)
    end

    function Query.set_all(self: QueryHandle, id: i53, value: any)
        query_insert(self.state, id, value, true)
    end

    function Query.remove_all(self: QueryHandle, id: i53)
        query_remove(self.state, id)
    end

    function Query.delete_all(self: QueryHandle)
        query_delete(self.state)
    end

    -- Fast path: iterator of (first_slot, last_slot, mask), see make_advance.
    function Query.spans(self: QueryHandle): () -> (number?, number?, number)
        local driver, others, without = plan_query(self.state)
        if driver == nil then
            return function(): (number?, number?, number)
                return nil, nil, 0
            end
        end
        return make_advance(driver, others, without)
    end

    -- The state for the ids of world:query: shared by shape when possible.
    local function query_state(...: i53): QueryState
        local n = select("#", ...)
        local node: any = shapes[n]
        if node == nil then
            node = {}
            shapes[n] = node
        end
        for i = 1, n do
            local id = select(i, ...)
            if not shareable(id) then
                return new_query({ ... })
            end
            local child = node[id]
            if child == nil then
                child = {}
                node[id] = child
            end
            node = child
        end
        local state: QueryState? = node.query
        if state == nil then
            if shape_count >= MAX_SHAPES then
                return new_query({ ... })
            end
            shape_count += 1
            local created = make_cached(new_query({ ... }))
            created.shared = true
            (node :: any).query = created
            return created
        end
        return state
    end

    local function world_query(_: any, ...: i53): QueryHandle
        return setmetatable({ state = query_state(...) }, Query) :: any
    end

    -- Fast path: page table of a component (page index -> values of PAGE_SIZE slots).
    local function world_column(_: any, id: i53): Pages
        return columns[id] or EMPTY_PAGES
    end

    local function world_alive_table(_: any): { number }
        return alive
    end

    ----------------------------------------------------------------------------
    -- assembly and bootstrap
    ----------------------------------------------------------------------------

    world.entity = world_entity
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
    world.column = world_column
    world.alive_table = world_alive_table
    world.ids = world_ids

    -- Debug mode (ecs.world(true)): set/add/remove/delete/clear raise an error for an entity
    -- that is not alive (an outdated handle) or an id that is not alive, instead of ignoring
    -- the call. Internal calls (cascades) are not checked.
    if debug then
        local function check_entity(entity: i53, level: number)
            if type(entity) ~= "number" or alive[entity % ENTITY_MASK] ~= entity then
                error(`entity {entity} is not alive: an outdated handle or a deleted entity`, level)
            end
        end
        local function check_id(id: i53, level: number, allow_wildcard: boolean)
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
        world.set = function(_: any, entity: i53, id: i53, value: any)
            check_entity(entity, 3)
            check_id(id, 3, false)
            world_set(world, entity, id, value)
        end
        world.add = function(_: any, entity: i53, id: i53)
            check_entity(entity, 3)
            check_id(id, 3, false)
            world_add(world, entity, id)
        end
        world.remove = function(_: any, entity: i53, id: i53)
            check_entity(entity, 3)
            check_id(id, 3, true)
            world_remove(world, entity, id)
        end
        world.delete = function(_: any, entity: i53)
            check_entity(entity, 3)
            world_delete(world, entity)
        end
        world.clear = function(_: any, entity: i53)
            check_entity(entity, 3)
            world_clear(world, entity)
        end
        function Query.add_all(self: QueryHandle, id: i53)
            check_id(id, 3, false)
            query_insert(self.state, id, nil, false)
        end
        function Query.set_all(self: QueryHandle, id: i53, value: any)
            check_id(id, 3, false)
            query_insert(self.state, id, value, true)
        end
        function Query.remove_all(self: QueryHandle, id: i53)
            check_id(id, 3, true)
            query_remove(self.state, id)
        end
    end

    -- ids 1..EcsRest (and pre-registered tags) exist as entities
    for _ = 1, preregistered_tags do
        new_slot()
    end
    local component_record = record_create(EcsComponent)
    component_words = component_record.words
    for id = 1, preregistered_components do
        world_add(world, id, EcsComponent)
    end
    for _, id in { EcsOnAdd, EcsOnChange, EcsOnRemove, EcsName, EcsWildcard, EcsRest } do
        world_add(world, id, EcsComponent)
    end

    -- hook components apply their values to the record they are set on
    local hook_fields: { [i53]: string } =
        { [EcsOnAdd] = "on_add", [EcsOnChange] = "on_change", [EcsOnRemove] = "on_remove" }
    for id, field in hook_fields do
        local rec = records[id] or record_create(id)
        local function apply(entity: i53, _: i53, value: any?)
            apply_hook(entity, field, value)
        end
        rec.on_add = apply
        rec.on_change = apply
        set_on_remove(rec, function(entity: i53, _: i53, deleting: any?)
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
    world_set(world, EcsDisabled, EcsName, "Disabled")

    -- Exclusive marks relations with one target per entity; keep existing pair records in sync
    local exclusive_record = records[EcsExclusive] or record_create(EcsExclusive)
    exclusive_record.on_add = function(entity: i53)
        local wc = records[ECS_PAIR(entity, EcsWildcard)]
        if wc then
            wc.exclusive = true
        end
    end
    set_on_remove(exclusive_record, function(entity: i53)
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
    ECS_PAIR_FIRST = (ECS_PAIR_FIRST :: any) :: (pair: Id<any> | number) -> number,
    ECS_PAIR_SECOND = (ECS_PAIR_SECOND :: any) :: (pair: Id<any> | number) -> number,
    ECS_ID = (ECS_ID :: any) :: (entity: Id<any> | number) -> number,
    ECS_GENERATION = (ECS_GENERATION :: any) :: (entity: Id<any> | number) -> number,
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
