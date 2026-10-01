--!strict
--# selene: allow(empty_loop, unused_variable) -- each line exists for its type error only
--[[
    Misuses of the public types that the analyzer must reject. tools/typecheck.py analyzes this
    file (tools/check.sh runs it): every line marked `-- error: <text>` must get an error whose
    message contains <text>, and no other line may get one. The file is not run, and it is not
    part of the analysis of test/*.luau, which must find no error.

    The lines keep one statement each (stylua ignores them), so that an error lands on its line.
]]

local ecs = require("@lib")

local world = ecs.world()
local Health = world:component() :: ecs.Component<number>
local Label = world:component() :: ecs.Component<string>
local Owns = world:component() :: ecs.Component<number>
local Likes = world:entity()
local item = world:entity()
local e = world:entity()

-- stylua: ignore start

-- a value of another type than the component's
world:set(e, Health, "full") -- error: Expected this to be 'number', but got 'string'
world:set(e, Label, 5) -- error: Expected this to be 'string', but got 'number'
world:set(e, Health, nil) -- error: Expected this to be 'number', but got 'nil'
world:query(Health):set_all(Health, "full") -- error: Expected this to be 'number', but got 'string'

-- a data pair takes the type of its relation, or of its target when the relation is a tag
world:set(e, ecs.pair(Owns, item), "five") -- error: Expected this to be 'number', but got 'string'
world:set(e, ecs.pair(Likes, Health), "five") -- error: Expected this to be 'number', but got 'string'

-- values read into variables of another type, also in another order
local wrong: string? = world:get(e, Health) -- error: Expected this to be 'string?', but got 'number?'
local swapped_h: number?, swapped_l: string? = world:get(e, Label, Health) -- error: Expected this to be 'number?', but got 'string?'

-- callbacks and loops that take a value of another type
world:query(Health):each(function(_entity, _value: string) end) -- error: Expected the 2nd parameter to be a supertype of
for _entity, _value: string in world:query(Health) do end -- error: Expected the 2nd return value to be
world:added(Health, function(_entity, _id, _value: string) end) -- error: No valid instantiation could be inferred
world:changed(Label, function(_entity, _id, _value: number) end) -- error: No valid instantiation could be inferred

-- a string or a number where an id goes
world:set(e, "Health", 1) -- error: but got 'string'
world:add(e, 5) -- error: Expected this to be 'Component<any>', but got 'number'
world:has(e, "Health") -- error: but got 'string'
world:query("Health") -- error: typeof(string)
world:toggle(e, "Health") -- error: but got 'string'
world:query(Health):toggle_all("Health") -- error: but got 'string'

-- results read as another type
local toggled: string = world:toggle(e, Health) -- error: Expected this to be 'string', but got 'boolean'

-- a typed id widened to accept any value
local raw: ecs.Id<unknown> = Health -- error: to be exactly `unknown`
local wide: ecs.Component<number | string> = Health -- error: to be exactly `string`

-- stylua: ignore end
