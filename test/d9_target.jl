# D9 (M4.2): PkgWasm built for Wasm (the compile-time preference target = "wasm") has a
# concrete Context.io, IOContext{StdStream}, and prints what the native target prints.
# Runs natively, in subprocesses: one environment with the preference, one without.

module D9TargetTests
using Test

const FORK = dirname(@__DIR__)
const JULIA = joinpath(Sys.BINDIR, Base.julia_exename())

function run_in_env(target::Union{Nothing, String}, code::String)
    mktempdir() do env
        prefs = target === nothing ? "" : "\n[preferences.Pkg]\ntarget = \"$target\"\n"
        write(joinpath(env, "Project.toml"), """
            [deps]
            Pkg = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"

            [sources]
            Pkg = {path = "$(escape_string(FORK))"}
            $prefs""")
        script = joinpath(env, "script.jl")
        write(script, code)
        out, err = IOBuffer(), IOBuffer()
        cmd = addenv(`$JULIA --startup-file=no --project=$env $script`, "JULIA_PKG_PRECOMPILE_AUTO" => "0")
        p = run(pipeline(ignorestatus(cmd); stdout = out, stderr = err))
        return (p.exitcode, String(take!(out)), String(take!(err)))
    end
end

# instantiate the env (the fork by path), then: the target, Context.io's type, and the
# output of status and of an error, for a project of our own
const CODE = raw"""
import Pkg; Pkg.instantiate(; io = devnull)
using Pkg
# (an empty depot of our own once loaded: no registries of the build host)
empty!(DEPOT_PATH); push!(DEPOT_PATH, mktempdir())
println("TARGET=", Pkg.TARGET)
println("IO=", typeof(Pkg.Types.Context().io))
proj = mktempdir()
write(joinpath(proj, "Project.toml"), "name = " * repr("P") * "\nuuid = " * repr("8c9a2bd0-6b1e-4ac1-9d36-1d2f8a3b0c11") * "\n")
Pkg.activate(proj; io = devnull)
Pkg.status()
# showerror_known: stock showerror natively, typed copies built for Wasm, the same text
for e in Any[Pkg.Types.PkgError("pkg message"), ErrorException("plain"), ArgumentError("bad arg"),
             Base.IOError("could not open ~/x", Base.UV_ENOENT), Base.IOError("other", -5),
             SystemError("opening", 2), SystemError("opening", 2, "info"),
             Pkg.Host.HostError(Int32(29), "boom"),
             Base.TOML.tryparse(Base.TOML.Parser{Nothing}("a = = 1"))]
    println("SE=", repr(sprint(Pkg.showerror_known, e)))
end
# a DEFAULT_IO override: honoured natively, an error built for Wasm
Base.ScopedValues.@with Pkg.DEFAULT_IO => IOBuffer() begin
    println("OVERRIDE=", try Pkg.stderr_f() === something(Base.ScopedValues.get(Pkg.DEFAULT_IO)) catch e; sprint(showerror, e) end)
end
# logging: the stock logger natively, the direct print built for Wasm, the same text
module LogProbe
    import Main.Pkg: @pkg_warn, @pkg_info, @pkg_debug
    f(x) = (@pkg_warn "single line"; @pkg_warn "two\nlines" x; @pkg_info "an info"; @pkg_info "info with" key = x;
            @pkg_debug "never"; for _ in 1:3; @pkg_warn "once" maxlog = 1; end; nothing)
end
redirect_stdout(stderr) do
    LogProbe.f([1, 2])
end
try
    Pkg.rm("NoSuchPackage")
catch e
    Pkg.report_error(e)
end
"""

@testset "D9: the Wasm target, natively" begin
    nat = run_in_env(nothing, CODE)
    wasm = run_in_env("wasm", CODE)
    @test nat[1] == 0 && wasm[1] == 0
    @test occursin("TARGET=native", nat[2]) && occursin("IO=IOContext{IO}", nat[2])
    @test occursin("TARGET=wasm", wasm[2]) && occursin("IO=IOContext{Pkg.StdStream}", wasm[2])
    # the same status and error output but for those two lines (and the temp project's path)
    @test occursin("OVERRIDE=true", nat[2])
    se(s) = filter(l -> startswith(l, "SE="), split(s, '\n'))
    @test length(se(nat[2])) == 9 && se(nat[2]) == se(wasm[2])
    @test occursin("OVERRIDE=PkgWasm built for Wasm: DEFAULT_IO is not supported", wasm[2])
    norm(s) = replace(join(filter(l -> !startswith(l, "TARGET=") && !startswith(l, "IO=") && !startswith(l, "OVERRIDE="), split(s, '\n')), '\n'),
                      r"[^\s`]*jl_\w+" => "TMP", r"/tmp/claude[^\s`]*" => "TMP")   # (any TMPDIR)
    @test norm(nat[2]) == norm(wasm[2])
    @test norm(nat[3]) == norm(wasm[3])
    @test occursin("NoSuchPackage", nat[3])
    @test occursin("┌ Warning: two", nat[3]) && occursin("│ lines", nat[3]) && occursin("[ Info: an info", nat[3])
    @test count("once", nat[3]) == 1 && count("once", wasm[3]) == 1
end
end # module
