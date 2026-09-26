--!strict
--[[
    Stub of jecs' entity visualiser: it prints archetype internals that mErCS does not
    have. Tests that use it are not applicable and fail on purpose.
]]
return {
    stringify = function(_world: any): any
        error("entity_visualiser: archetypes do not exist in mErCS")
    end,
}
