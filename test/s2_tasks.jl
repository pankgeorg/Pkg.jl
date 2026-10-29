# S2 (lane s2-pkg): the compile-time preference `tasks` of PkgWasm. "none" (default) keeps the
# serial download loop (PLAN.md D3); "jspi" runs stock Pkg's concurrent download pool.
# Runs natively, in subprocesses with and without the preference (as d9_target.jl).

module S2TasksTests
using Test

const FORK = dirname(@__DIR__)
const JULIA = joinpath(Sys.BINDIR, Base.julia_exename())

function run_in_env(tasks::Union{Nothing, String}, code::String)
    mktempdir() do env
        prefs = tasks === nothing ? "" : "\n[preferences.PkgWasm]\ntasks = \"$tasks\"\n"
        write(joinpath(env, "Project.toml"), """
            [deps]
            PkgWasm = "d562cdc0-5c7a-524d-b497-bb1ca2727331"

            [sources]
            PkgWasm = {path = "$(escape_string(FORK))"}
            $prefs""")
        script = joinpath(env, "script.jl")
        write(script, code)
        out, err = IOBuffer(), IOBuffer()
        cmd = addenv(`$JULIA --startup-file=no --project=$env $script`, "JULIA_PKG_PRECOMPILE_AUTO" => "0")
        p = run(pipeline(ignorestatus(cmd); stdout = out, stderr = err))
        return (p.exitcode, String(take!(out)), String(take!(err)))
    end
end

const CODE = raw"""
import Pkg; Pkg.instantiate(; io = devnull)
using PkgWasm
println("TASKS=", PkgWasm.TASKS, " CONCURRENT=", PkgWasm.CONCURRENT)
# the text the pool's consumer reports for an install error: stock's `sprint(showerror, err, bt)`
err = try error("boom") catch e; e end
bt = catch_backtrace()
println("TEXT=", PkgWasm.Operations.install_error_text(err, bt) == sprint(showerror, err, bt))
"""

@testset "S2: the tasks preference" begin
    none = run_in_env(nothing, CODE)
    jspi = run_in_env("jspi", CODE)
    @test none[1] == 0 && occursin("TASKS=none CONCURRENT=false", none[2])
    @test jspi[1] == 0 && occursin("TASKS=jspi CONCURRENT=true", jspi[2])
    @test occursin("TEXT=true", none[2]) && occursin("TEXT=true", jspi[2])
    bad = run_in_env("threads", CODE)
    @test bad[1] != 0 && occursin("invalid preference tasks = \"threads\"", bad[3])
end

end # module
