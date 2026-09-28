--!strict
--# selene: allow(empty_loop) -- the loops iterate for their cost only
--!optimize 2
--!native
--[[
    Benchmarker: 10 passes of a 4-component query over 4096 entities that have random
    subsets of 8 components (many archetypes in jecs, scattered bits here). The worlds are
    built once, when the module is required, the same for both libraries; the queries are
    cached.
]]

-- Benchmarker requires a clone of this module, which has no parent: relative requires cannot
-- work here, so the helpers are reached from ReplicatedStorage
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local libs = require(
    ReplicatedStorage:WaitForChild("mErCSCheck"):WaitForChild("bench"):WaitForChild("visual"):WaitForChild("libs")
) :: any

local N = 4096

type Setup = { world: any, query: any }

-- The same random layout in both worlds.
local function build(): (Setup, Setup)
    local random = Random.new(12345)
    local jw, lw = libs.jecs.world(), libs.lib.world()
    local jc, lc = table.create(8), table.create(8)
    for i = 1, 8 do
        jc[i] = jw:component()
        lc[i] = lw:component()
    end
    for _ = 1, N do
        local je, le = jw:entity(), lw:entity()
        for i = 1, 8 do
            if random:NextNumber() >= 0.5 then
                jw:set(je, jc[i], { value = i })
                lw:set(le, lc[i], { value = i })
            end
        end
    end
    return { world = jw, query = jw:query(jc[1], jc[2], jc[3], jc[4]):cached() }, {
        world = lw,
        query = lw:query(lc[1], lc[2], lc[3], lc[4]):cached(),
    }
end

-- Built when the module is required: Benchmarker calls every function once (a check that it
-- does not yield and runs within 40 ms) before BeforeAll
local jecs_setup, lib_setup = build()

return {
    ParameterGenerator = function()
        return
    end,

    BeforeAll = function() end,
    AfterAll = function() end,
    BeforeEach = function() end,
    AfterEach = function() end,

    Functions = {
        [libs.jecs_label] = function(_Profiler: any)
            for _ = 1, 10 do
                for _entity, _a, _b, _c, _d in jecs_setup.query do
                end
            end
        end,

        [libs.lib_label] = function(_Profiler: any)
            for _ = 1, 10 do
                for _entity, _a, _b, _c, _d in lib_setup.query do
                end
            end
        end,

        -- the fastest loop of mErCS: a callback per entity
        [`{libs.lib_label} each`] = function(_Profiler: any)
            local function visit(_entity: any, _a: any, _b: any, _c: any, _d: any) end
            for _ = 1, 10 do
                lib_setup.query:each(visit)
            end
        end,
    },
}
