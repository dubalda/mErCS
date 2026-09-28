--!strict
--!optimize 2
--[[
    Benchmark entries for jecs and for modules with the library API (the library and its
    snapshots), shared by bench/impls.luau and the Roblox Studio check (studio/runner.luau).

    Each entry provides the module with the jecs-compatible API plus two helpers:
    - component(world): creates a component id without hitting implementation limits;
    - fast4(world, query, a, b, c, d): the fastest idiomatic loop over a prepared
      4-component query that reads all four values; returns the number of visited entities.
]]

local harness = require("./harness")

type Impl = harness.Impl

local FULL_WORD = 4294967295
local band = bit32.band
local countrz = bit32.countrz

local JECS_COMPONENT_LIMIT = 256

local function jecs_impl(jecs: any, label: string?): Impl
    return {
        name = "jecs",
        label = label,
        ecs = jecs,
        features = { pairs = true },
        component = function(world: any): any
            -- jecs allows 256 world:component() ids; beyond that entities marked as components are used.
            if world.max_component_id < JECS_COMPONENT_LIMIT then
                return world:component()
            end
            local id = world:entity()
            world:add(id, jecs.Component)
            return id
        end,
        fast4 = function(_world: any, query: any, a: any, b: any, c: any, d: any): number
            local n = 0
            for _, archetype in query:archetypes() do
                local columns_map = archetype.columns_map
                local ca, cb, cc, cd = columns_map[a], columns_map[b], columns_map[c], columns_map[d]
                for row in archetype.entities do
                    local _1, _2, _3, _4 = ca[row], cb[row], cc[row], cd[row]
                    n += 1
                end
            end
            return n
        end,
    }
end

-- Implementation entry for a module with the library API (the library and its releases).
local function library_impl(name: string, module: any, label: string?): Impl
    return {
        name = name,
        label = label,
        ecs = module,
        features = { many_ids = true, pairs = true, each = true },
        component = function(world: any): any
            return world:component()
        end,
        fast4 = function(world: any, query: any, a: any, b: any, c: any, d: any): number
            local ca, cb, cc, cd = world:column(a), world:column(b), world:column(c), world:column(d)
            local page_size = module.PAGE_SIZE
            local n = 0
            for first, last, mask in query:spans() do
                local page = first // page_size + 1
                local pa, pb, pc, pd = ca[page], cb[page], cc[page], cd[page]
                local offset = (page - 1) * page_size - 1
                if mask == FULL_WORD then
                    for li = first - offset, last - offset do
                        local _1, _2, _3, _4 = pa[li], pb[li], pc[li], pd[li]
                        n += 1
                    end
                else
                    repeat
                        local li = first + countrz(mask) - offset
                        mask = band(mask, mask - 1)
                        local _1, _2, _3, _4 = pa[li], pb[li], pc[li], pd[li]
                        n += 1
                    until mask == 0
                end
            end
            return n
        end,
    }
end

return {
    jecs = jecs_impl,
    library = library_impl,
}
