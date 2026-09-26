--!strict
--[=[
    @class jabby

    The adapter for [jabby](https://github.com/alicesaidhi/jabby), the ECS debugger written
    against jecs internals. mErCS keeps no archetypes and no entity index, and the library
    has nothing that exists only for jabby: this module adds what jabby reads.

    `require(mErCS.jabby)(ecs)` returns a jecs-like module for jabby: the exports of
    [mErCS] plus [jabby.attach], [jabby.entity_index_try_get] and [jabby.is_tag].

    1. The jabby package requires jecs through a module of its own (with Wally:
       `Packages/_Index/alicesaidhi_jabby@<version>/jecs`). Replace its source with

       ```lua
       local mErCS = game:GetService("ReplicatedStorage").mErCS -- the ModuleScript
       return require(mErCS.jabby)(require(mErCS))
       ```

    2. Attach every world before registering it:

       ```lua
       require(mErCS.jabby)(ecs).attach(world)
       jabby.register({ applet = jabby.applets.world, name = "World", configuration = { world = world } })
       ```
]=]

-- The adapter takes the library as an argument instead of requiring its parent module: a
-- path to the parent is not resolved the same way by Roblox, the luau CLI and luau-lsp.

type World = any

-- A stateful iterator over a query, like query:iter() of jecs.
local function iter(query: any): () -> ...any
    local step, state, control = getmetatable(query).__iter(query)
    local prev = control
    local function remember(entity: any, ...: any): ...any
        prev = entity
        return entity, ...
    end
    return function(): ...any
        return remember(step(state, prev))
    end
end

-- One pseudo archetype with the entities that match the query (jabby reads its entities and
-- gets the values with world:get).
local function archetypes(query: any): { { entities: { number } } }
    local entities: { number } = {}
    for entity in query do
        table.insert(entities, entity)
    end
    if #entities == 0 then
        return {}
    end
    return { { entities = entities } }
end

--[=[
    @function attach
    @within jabby
    @param world World
    @return World -- the same world
    Gives the world `world.entity_index` and gives its queries `iter()` (a stateful iterator)
    and `archetypes()` (one pseudo archetype `{ entities = {...} }` with the matches).
    Attaching a world again changes nothing; other worlds are not affected.
]=]
local function attach(world: World): World
    if world.entity_index == nil then
        world.entity_index = { world = world }
        -- the queries of a world share one method table: the metatable of every query object
        local query: any = world:query()
        local methods: any = getmetatable(query)
        methods.iter = iter
        methods.archetypes = archetypes
    end
    return world
end

return function(ecs: any): any
    local Component = ecs.Component
    local IS_PAIR = ecs.IS_PAIR
    local pair_first = ecs.pair_first
    local pair_second = ecs.pair_second

    --[=[
        @function is_tag
        @within jabby
        @param world World
        @param id Id
        @return boolean
        Whether the id carries no data: an entity without the [mErCS.Component] trait, or a
        pair whose relation and target are both tags.
    ]=]
    local function is_tag(world: World, id: number): boolean
        if IS_PAIR(id) then
            local first, second = pair_first(world, id), pair_second(world, id)
            return not ((first ~= 0 and world:has(first, Component)) or (second ~= 0 and world:has(second, Component)))
        end
        return not world:has(id, Component)
    end

    --[=[
        @function entity_index_try_get
        @within jabby
        @param entity_index { world: World } -- world.entity_index of an attached world
        @param entity Id
        @return { archetype: { types: { Id } } }? -- nil when the entity is not alive
        The record of an entity as jabby reads it: its archetype lists the ids of the entity
        (see [World:ids]).
    ]=]
    local function entity_index_try_get(entity_index: { world: World }, entity: number): any
        local world = entity_index.world
        if not world:contains(entity) then
            return nil
        end
        return { archetype = { types = world:ids(entity) }, row = 0, dense = 0 }
    end

    local module = table.clone(ecs)
    module.is_tag = is_tag
    module.entity_index_try_get = entity_index_try_get
    module.attach = attach
    return module
end
