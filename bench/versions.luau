--!strict
--[[
    The versions that the benchmarks print: jecs from the Wally dev packages (the `jecs` alias
    of .luaurc) and the current library. Keep `library` in step with `version` in wally.toml;
    the previous release names itself (bench/previous.luau).

    Usage:
        local versions = require("./versions")
        print(versions.jecs, versions.library)
]]

return {
    jecs = "jecs 0.11.0",
    library = "mErCS 0.2.4",
}
