# This file is a part of Julia. License is MIT: https://julialang.org/license

# Runs one of stock Pkg's test files (test/*.jl, unchanged from Pkg 1.12 (release-1.12)) the way stock
# Pkg's test/runtests.jl does, against a chosen target:
#
#     julia --project=test test/stock/runfile.jl <pkgwasm|stock> <file.jl> <out.toml>
#
# `pkgwasm`: every `using`/`import` of `Pkg` in the file (and in the files it includes) is
# rewritten to `PkgWasm`, and `Pkg` in the enclosing module is `PkgWasm`, so the file tests the
# fork. `stock`: the file runs unchanged against the stdlib Pkg. Code that the file writes to
# disk and loads in a `julia` subprocess still uses stock Pkg in both modes.
#
# Every non-passing result is written to <out.toml> with its testset path and source line.

module PkgTestsOuter

const TARGET = ARGS[1]
const FILE = ARGS[2]
const OUT = ARGS[3]
TARGET in ("pkgwasm", "stock") || error("target must be pkgwasm or stock, got $TARGET")

original_depot_path = copy(Base.DEPOT_PATH)
original_load_path = copy(Base.LOAD_PATH)
original_env = copy(ENV)
original_project = Base.active_project()

module Recording

using Test
import Test: record, finish

# Collects non-passing results with their testset path; nested testsets inherit the type.
mutable struct RecordingTestSet <: Test.AbstractTestSet
    description::String
    path::Vector{String}
    npass::Int
    nonpass::Vector{Tuple{Vector{String}, Any}}
end

function RecordingTestSet(desc::AbstractString; kwargs...)
    parent = Test.get_testset_depth() == 0 ? String[] : Test.get_testset().path
    return RecordingTestSet(String(desc), [parent; String(desc)], 0, Tuple{Vector{String}, Any}[])
end

record(ts::RecordingTestSet, ::Test.Pass) = (ts.npass += 1; nothing)
function record(ts::RecordingTestSet, t::Test.Result) # Fail, Error, Broken, LogTestFailure, ...
    push!(ts.nonpass, (ts.path, t))
    if !(t isa Test.Broken)
        printstyled(join(ts.path, " > "), ": "; bold = true)
        print(t)
        println()
    end
    return t
end
function record(ts::RecordingTestSet, child::RecordingTestSet)
    ts.npass += child.npass
    append!(ts.nonpass, child.nonpass)
    return child
end
function finish(ts::RecordingTestSet)
    Test.get_testset_depth() > 0 && record(Test.get_testset(), ts)
    return ts
end

kind(::Test.Result) = "fail"
kind(t::Test.Error) = t.test_type === :nontest_error ? "nontest_error" : "error"
kind(::Test.Broken) = "broken"

function message(t)
    s = replace(sprint(show, t; context = :color => false), r"\e\[[0-9;]*m" => "")
    return length(s) > 2000 ? first(s, 2000) * " …" : s
end

end # module Recording

module PkgTestsInner

    import ..TARGET, ..FILE, ..OUT
    using ..Recording: RecordingTestSet, kind, message

    original_wd = pwd()

    if TARGET == "pkgwasm"
        import PkgWasm
        const Pkg = PkgWasm
    else
        import Pkg
    end
    import REPL # stock: should precompile REPLExt (PkgWasm has no REPL extension)
    TARGET == "stock" && @assert Base.get_extension(Pkg, :REPLExt) !== nothing
    using Test, Logging, TOML

    # `Pkg` -> `PkgWasm` in import paths; nested `include`s get the same rewrite.
    rewrite_path(p) = (p isa Expr && p.head === :. && !isempty(p.args) && p.args[1] === :Pkg) ?
        Expr(:., :PkgWasm, p.args[2:end]...) : p
    function rewrite_import(ex::Expr)
        if ex.head === :using && !any(a -> a isa Expr && a.head === :(:), ex.args)
            # `using A, B, ...`: one statement per module, so the others stay `using`
            stmts = Any[]
            for a in ex.args
                if a == Expr(:., :Pkg) # `using Pkg` binds `Pkg` and brings the exported names
                    push!(stmts, Expr(:import, Expr(:as, Expr(:., :PkgWasm), :Pkg)), Expr(:using, Expr(:., :PkgWasm)))
                elseif a isa Expr && a.head === :. && length(a.args) > 1 && a.args[1] === :. && a.args[end] === :Pkg
                    # `using ..Pkg` binds the module's own name (`PkgWasm`); bind `Pkg` as well
                    push!(stmts, Expr(:using, a), Expr(:import, a))
                else
                    push!(stmts, Expr(:using, rewrite_path(a)))
                end
            end
            return Expr(:toplevel, stmts...)
        end
        # `import ...` and `using X: names`
        args = map(ex.args) do a
            if a isa Expr && a.head === :(:)
                Expr(:(:), rewrite_path(a.args[1]), a.args[2:end]...)
            elseif a isa Expr && a.head === :as
                Expr(:as, rewrite_path(a.args[1]), a.args[2])
            elseif a == Expr(:., :Pkg) # bare `import Pkg` must still bind the name `Pkg`
                Expr(:as, Expr(:., :PkgWasm), :Pkg)
            else
                rewrite_path(a)
            end
        end
        return Expr(ex.head, args...)
    end
    # HistoricalStdlibVersions fills in the tables of the module it loads as `Pkg` (stock Pkg);
    # its register!/unregister! are pointed at PkgWasm's tables instead.
    function retarget_hsv!(HSV::Module)
        T = PkgWasm.Types
        conv(d) = T.DictStdLibs(u => T.StdlibInfo(i.name, i.uuid, i.version, i.deps, i.weakdeps) for (u, i) in d)
        Core.eval(HSV, :(unregister!() = (empty!($T.STDLIBS_BY_VERSION); empty!($T.UNREGISTERED_STDLIBS); nothing)))
        Core.eval(HSV, :(register!() = (unregister!();
            append!($T.STDLIBS_BY_VERSION, [v => $conv(d) for (v, d) in STDLIBS_BY_VERSION]);
            merge!($T.UNREGISTERED_STDLIBS, $conv(UNREGISTERED_STDLIBS)); nothing)))
        get(ENV, "HISTORICAL_STDLIB_VERSIONS_AUTO_REGISTER", "true") == "true" && Base.invokelatest(HSV.register!)
        return
    end
    function to_pkgwasm(ex)
        ex isa Expr || return ex
        if ex.head === :using && ex.args == [Expr(:., :HistoricalStdlibVersions)]
            return Expr(:toplevel, ex, Expr(:call, retarget_hsv!, :HistoricalStdlibVersions))
        elseif ex.head === :using || ex.head === :import
            return rewrite_import(ex)
        elseif ex.head === :call && length(ex.args) == 2 && ex.args[1] === :include
            return Expr(:call, :include, to_pkgwasm, ex.args[2])
        end
        return Expr(ex.head, map(to_pkgwasm, ex.args)...)
    end
    # STOCK_TESTSETS="name|name...": only these top-level testsets of the file run (for checking
    # one testset without the state that earlier ones leave behind); other code runs as usual.
    const SELECTED = filter(!isempty, split(get(ENV, "STOCK_TESTSETS", ""), '|'))
    is_dropped(ex) = !isempty(SELECTED) && ex isa Expr && ex.head === :macrocall &&
        ex.args[1] === Symbol("@testset") && any(a -> a isa String && a ∉ SELECTED, ex.args)
    function select_testsets(ex)
        is_dropped(ex) && return nothing
        if ex isa Expr && ex.head === :module
            body = ex.args[3]
            return Expr(:module, ex.args[1], ex.args[2], Expr(:block, filter(!is_dropped, body.args)...))
        end
        return ex
    end
    const MAPEXPR = TARGET == "pkgwasm" ? to_pkgwasm ∘ select_testsets : select_testsets

    ENV["JULIA_PKG_PRECOMPILE_AUTO"] = 0
    ENV["JULIA_PKG_DISALLOW_PKG_PRECOMPILATION"] = 1

    # stock: the stdlib's own test directory (its files are those of test/, checked by runtests.jl),
    # so that "this Pkg" (the parent of the test directory) is the stdlib Pkg, as on Pkg's CI
    const TESTDIR = TARGET == "stock" ? joinpath(pkgdir(Pkg), "test") : dirname(@__DIR__)
    logfile = OUT * ".pkg.log"
    Pkg.DEFAULT_IO[] = open(logfile, "w")

    include(MAPEXPR, joinpath(TESTDIR, "utils.jl"))
    @assert Utils.Pkg === Pkg

    const STOCK_PKG = Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg")

    ts = Logging.with_logger(Logging.ConsoleLogger(Pkg.DEFAULT_IO[])) do
        Utils.check_init_reg()
        @testset RecordingTestSet "$FILE" begin
            Pkg.activate(; temp = true) # make sure we're in an active project and that it's clean
            try
                include(MAPEXPR, joinpath(TESTDIR, FILE))
            finally
                flush(Pkg.DEFAULT_IO[])
                cd(original_wd)
            end
        end
    end
    close(Pkg.DEFAULT_IO[])

    results = [
        Dict(
            "path" => join(path, " > "),
            "source" => hasproperty(t, :source) ? string(something(t.source, "?")) : "",
            "kind" => kind(t),
            "message" => message(t),
        ) for (path, t) in ts.nonpass
    ]
    open(OUT, "w") do io
        TOML.print(io, Dict(
            "target" => TARGET, "file" => FILE, "pass" => ts.npass,
            # pkgwasm mode: true if something in-process loaded the stock Pkg module anyway
            "stock_pkg_loaded" => haskey(Base.loaded_modules, STOCK_PKG),
            "fail" => count(r -> r["kind"] == "fail", results),
            "error" => count(r -> r["kind"] in ("error", "nontest_error"), results),
            "broken" => count(r -> r["kind"] == "broken", results),
            "results" => results,
        ))
    end
    println("$TARGET $FILE: pass $(ts.npass), non-pass $(length(results)) -> $OUT")

    Base.Filesystem.temp_cleanup_purge(force = true)

end # module

empty!(Base.DEPOT_PATH)
empty!(Base.LOAD_PATH)
append!(Base.DEPOT_PATH, original_depot_path)
append!(Base.LOAD_PATH, original_load_path)
for k in setdiff(collect(keys(ENV)), collect(keys(original_env)))
    delete!(ENV, k)
end
for (k, v) in pairs(original_env)
    ENV[k] = v
end
Base.set_active_project(original_project)

end # module
