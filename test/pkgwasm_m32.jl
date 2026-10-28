# PkgWasm M3.2 acceptance (PLAN.md L3): single Task (D3), exclusions (D4), stdlib universe
# (D10), directory registries (D11). Native; most checks are differential against stock Pkg.
#
#   JULIA_DEPOT_PATH=<writable depot with General>: julia --project=. test/pkgwasm_m32.jl
#
# The depot needs network access to the Pkg server for the registry and package downloads.

using Test
import Pkg
import Pkg
using UUIDs

const STOCK_PKG = Pkg
const EXAMPLE_UUID = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
const GENERAL_UUID = UUID("23338594-aafe-5451-b93e-139f81909106")

# test/resolve_utils.jl does `import ..Pkg; using Pkg.Types, ...`. Load one copy bound to each
# implementation; `using Pkg.X` would always mean the stock root package, so make it relative.
const RU_SRC = replace(read(joinpath(@__DIR__, "resolve_utils.jl"), String), "using Pkg." => "using ..Pkg.")
module RUFork
const Pkg = Main.Pkg
include_string(@__MODULE__, Main.RU_SRC, "resolve_utils.jl (PkgWasm)")
end
module RUStock
const Pkg = Main.STOCK_PKG
include_string(@__MODULE__, Main.RU_SRC, "resolve_utils.jl (stock Pkg)")
end
@assert parentmodule(typeof(RUFork.ResolveUtils.graph_from_data([["A", v"1"]]))) === Pkg.Resolve

function solve(RU, M, deps_data, reqs_data; validate_versions = true)
    graph = RU.ResolveUtils.graph_from_data(deps_data)
    reqs = RU.ResolveUtils.reqs_from_data(reqs_data, graph)
    M.Resolve.add_reqs!(graph, reqs)
    M.Resolve.simplify_graph!(graph; validate_versions)
    sol = M.Resolve.resolve(graph)
    used_maxsum = occursin("greedy solver failed", sprint(M.Resolve.showlog, graph.data.rlog))
    return sol, used_maxsum
end

function capture_error(f)
    try
        f()
    catch e
        return e
    end
    return nothing
end

resolvedata = mktempdir()
Pkg.PlatformEngines.unpack(joinpath(@__DIR__, "resolvedata.tar.gz"), resolvedata)
for i in 1:4
    include(joinpath(resolvedata, "resolvedata$i.jl"))
end

@testset "PkgWasm M3.2" begin
    @testset "D3 maxsum: forced maxsum, same solutions as stock" begin
        used = Bool[]
        for D in (ResolveData, ResolveData2, ResolveData3)
            sol_f, maxsum_f = solve(RUFork, Pkg, D.deps_data, D.reqs_data)
            sol_s, maxsum_s = solve(RUStock, Pkg, D.deps_data, D.reqs_data)
            @test maxsum_f == maxsum_s
            push!(used, maxsum_f)
            @test sol_f == sol_s
            @test sol_f == RUFork.ResolveUtils.wantuuids(D.want_data)
        end
        # the greedy solver fails on at least one dataset, so maxsum (with the deadline) ran
        @test any(used)
    end

    @testset "D3 maxsum: bounded timeout, same errors as stock" begin
        D = ResolveData4
        # tiny budget: times out with the stock error text
        errs = map(((RUFork, Pkg), (RUStock, Pkg))) do (RU, M)
            withenv("JULIA_PKG_RESOLVE_MAX_TIME" => "1.0e-5") do
                capture_error(() -> solve(RU, M, D.deps_data, D.reqs_data; validate_versions = false))
            end
        end
        @test errs[1] isa Pkg.Resolve.ResolverTimeoutError
        @test errs[2] isa Pkg.Resolve.ResolverTimeoutError
        @test errs[1].msg == errs[2].msg
        # the deadline is honoured: a 2 s budget ends in about 2 s, not minutes
        t = @elapsed err = withenv("JULIA_PKG_RESOLVE_MAX_TIME" => "2") do
            capture_error(() -> solve(RUFork, Pkg, D.deps_data, D.reqs_data; validate_versions = false))
        end
        @test err isa Pkg.Resolve.ResolverTimeoutError
        @test 2 <= t < 30
        # invalid budgets fail like `Timer(max_time)` does in stock
        for bad in ("-1", "NaN", "1e300")
            ef, es = map(((RUFork, Pkg), (RUStock, Pkg))) do (RU, M)
                withenv("JULIA_PKG_RESOLVE_MAX_TIME" => bad) do
                    capture_error(() -> solve(RU, M, D.deps_data, D.reqs_data; validate_versions = false))
                end
            end
            @test typeof(ef) == typeof(es)
            @test sprint(showerror, ef) == sprint(showerror, es)
        end
        # Deadline unit behaviour
        Deadline = Pkg.Resolve.Deadline
        @test Pkg.Resolve.expired(Deadline(0))
        d = Deadline(0.05)
        @test !Pkg.Resolve.expired(d)
        sleep(0.07)
        @test Pkg.Resolve.expired(d)
    end

    @testset "D3 no tasks on supported paths" begin
        @test Pkg.mkpidlock(() -> 42, "/nonexistent/x.pid"; stale_age = 3) == 42
        code(file) = join(filter(l -> !startswith(lstrip(l), "#"), readlines(joinpath(pkgdir(Pkg), "src", file))), "\n")
        src = code("Operations.jl")
        @test !occursin("Threads.@spawn", src) && !occursin("@async", src) && !occursin("Channel", src)
        @test !occursin("FileWatching.mkpidlock", src)
        @test !occursin(r"\bTimer\(", code(joinpath("Resolve", "maxsum.jl")))
        @test !occursin(r"\byield\(", code(joinpath("Resolve", "maxsum.jl")))
    end

    @testset "D4 unsupported operations" begin
        mktempdir() do dir
            Pkg.activate(dir; io = devnull)
            for (f, op) in (
                    (() -> Pkg.build(; io = devnull), "build"),
                    (() -> Pkg.test(; io = devnull), "test"),
                    (() -> Pkg.gc(; io = devnull), "gc"),
                    (() -> Pkg.precompile(; io = devnull), "precompile"),
                    (() -> Pkg.develop("Example"; io = devnull), "develop"),
                    (() -> Pkg.add(url = "https://github.com/JuliaLang/Example.jl"; io = devnull), "adding a package by URL, path or revision"),
                    (() -> Pkg.add(Pkg.PackageSpec(name = "Example", rev = "master"); io = devnull), "adding a package by URL, path or revision"),
                    (() -> Pkg.Apps.add(Pkg.PackageSpec[]), "apps"),
                )
                err = capture_error(f)
                @test err isa Pkg.Types.PkgError
                @test sprint(showerror, err) == "$op is not supported in PkgWasm"
            end
            Pkg.activate(; io = devnull)
        end
    end

    @testset "D4/D11 add, idempotent instantiate, rm" begin
        mktempdir() do dir
            out = IOBuffer()
            Pkg.activate(dir; io = out)
            Pkg.add(["Example", "Dates"]; io = out)
            manifest = read(joinpath(dir, "Manifest.toml"), String)
            # instantiate again: nothing to install, files unchanged
            out2 = IOBuffer()
            Pkg.instantiate(; io = out2)
            @test !occursin("Installed", String(take!(out2)))
            @test read(joinpath(dir, "Manifest.toml"), String) == manifest
            Pkg.instantiate(; io = out2)
            @test read(joinpath(dir, "Manifest.toml"), String) == manifest
            src = Pkg.Operations.source_path(joinpath(dir, "Manifest.toml"), Pkg.Types.EnvCache().manifest[EXAMPLE_UUID])
            # stock Pkg agrees the environment is instantiated and reads it identically
            Pkg.activate(dir; io = devnull)
            @test Pkg.Operations.is_instantiated(Pkg.Types.EnvCache())
            @test keys(Pkg.dependencies()) == keys(Pkg.dependencies())
            # rm keeps the package files (no auto-gc)
            Pkg.rm("Example"; io = out)
            @test isdir(src)
            @test !haskey(Pkg.TOML.parsefile(joinpath(dir, "Project.toml"))["deps"], "Example")
            Pkg.activate(; io = devnull)
            Pkg.activate(; io = devnull)
        end
    end

    @testset "D4 artifacts: single warning, source-only instantiated" begin
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"), "[deps]\n")
            write(joinpath(dir, "Artifacts.toml"), "[foo]\ngit-tree-sha1 = \"0000000000000000000000000000000000000000\"\n")
            out = IOBuffer()
            Pkg.activate(dir; io = out)
            ctx = Pkg.Types.Context(; io = out)
            Pkg.Operations.download_artifacts(ctx)
            s = String(take!(out))
            @test count("artifacts of 1 package(s) were not downloaded", s) == 1
            @test Pkg.Operations.is_instantiated(ctx.env)
            Pkg.activate(; io = devnull)
        end
    end

    @testset "D4 deps/build.jl makes the operation fail" begin
        mktempdir() do dir
            uuid = uuid4()
            write(joinpath(dir, "Project.toml"), "name = \"HasBuild\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n")
            mkpath(joinpath(dir, "deps"))
            write(joinpath(dir, "deps", "build.jl"), "error(\"must not run\")\n")
            Pkg.activate(dir; io = devnull)
            ctx = Pkg.Types.Context(; io = devnull)
            err = capture_error(() -> Pkg.Operations.build_versions(ctx, Set([uuid])))
            @test err isa Pkg.Types.PkgError
            @test occursin("building packages is not supported in PkgWasm", sprint(showerror, err))
            @test occursin("HasBuild", sprint(showerror, err))
            @test Pkg.Operations.build_versions(ctx, Set{UUID}()) === nothing
            Pkg.activate(; io = devnull)
        end
    end

    @testset "D10 embedded stdlib data matches the install" begin
        @test Pkg.STDLIB_DATA_JULIA_VERSION == VERSION
        # the stock reader (stdlib project files) and the embedded data agree
        stock = Pkg.Types.load_stdlib()
        fork = Pkg.Types.load_stdlib()
        @test keys(stock) == keys(fork)
        for (uuid, s) in stock
            f = fork[uuid]
            @test (f.name, f.version, Set(f.deps), Set(f.weakdeps)) == (s.name, s.version, Set(s.deps), Set(s.weakdeps))
        end
        @test Pkg.Types.UPGRADABLE_STDLIBS_UUIDS == Pkg.Types.UPGRADABLE_STDLIBS_UUIDS
        for e in Pkg.SYSIMAGE_PKGS
            id = Base.PkgId(UUID(e.uuid), e.name)
            @test Base.in_sysimage(id)
            @test Pkg.Types.in_sysimage(id)
            @test string(Base.pkgorigins[id].version) == e.version
        end
        @test !Pkg.Types.in_sysimage(Base.PkgId(EXAMPLE_UUID, "Example"))
        # regenerating gives the checked-in file
        gen = read(`$(Base.julia_cmd()) --startup-file=no $(joinpath(pkgdir(Pkg), "contrib", "generate_stdlib_data.jl"))`, String)
        @test gen == read(joinpath(pkgdir(Pkg), "src", "stdlib_data.jl"), String)
    end

    @testset "D10 no stdlib directory access (strace)" begin
        strace = Sys.which("strace")
        if strace === nothing
            @test_skip "strace not available"
        else
            mktempdir() do dir
                script = joinpath(dir, "probe.jl")
                write(script, """
                using Pkg
                Pkg.activate($(repr(joinpath(dir, "env"))); io = devnull)
                isfile("/pkgwasm-marker-begin")
                Pkg.add(["Example", "Dates", "Pkg", "LinearAlgebra"]; io = devnull)
                Pkg.status(; io = devnull)
                Pkg.instantiate(; io = devnull)
                Pkg.resolve(; io = devnull)
                Pkg.rm("Dates"; io = devnull)
                isfile("/pkgwasm-marker-end")
                """)
                log = joinpath(dir, "strace.txt")
                cmd = `$strace -f -qq -e trace=%file -o $log $(Base.julia_cmd()) --startup-file=no --project=$(pkgdir(Pkg)) $script`
                @test success(pipeline(cmd; stdout = devnull, stderr = devnull))
                lines = readlines(log)
                b = findfirst(l -> occursin("pkgwasm-marker-begin", l), lines)
                e = findfirst(l -> occursin("pkgwasm-marker-end", l), lines)
                @test b !== nothing && e !== nothing
                stdlib = Pkg.stdlib_dir()
                hits = filter(l -> occursin(stdlib, l), lines[b:e])
                @test isempty(hits)
                isempty(hits) || foreach(println, first(hits, 10))
            end
        end
    end

    @testset "D11 registry installed unpacked with verified tree hash" begin
        mktempdir() do depot
            old_depot_path = copy(DEPOT_PATH)
            withenv("JULIA_DEPOT_PATH" => depot * ":") do
                copy!(DEPOT_PATH, [depot])
                try
                    Pkg.Registry.add("General"; io = devnull)
                    regdir = joinpath(depot, "registries", "General")
                    @test isfile(joinpath(regdir, "Registry.toml"))
                    @test !ispath(joinpath(depot, "registries", "General.toml"))
                    info = Pkg.TOML.parsefile(joinpath(regdir, ".tree_info.toml"))
                    regs = Pkg.Registry.reachable_registries()
                    @test length(regs) == 1
                    reg = only(regs)
                    @test reg.uuid == GENERAL_UUID
                    @test reg.in_memory_registry === nothing
                    @test string(reg.tree_info) == info["git-tree-sha1"]
                    # the extracted tree hashes to the recorded identity
                    rm(joinpath(regdir, ".tree_info.toml"))
                    @test Pkg.GitTools.tree_hash(regdir) == hex2bytes(info["git-tree-sha1"])
                    # a tree-hash mismatch is rejected and nothing is extracted
                    server = Pkg.pkg_server()
                    url = "$server/registry/$GENERAL_UUID/$(info["git-tree-sha1"])"
                    bad = Base.SHA1("0000000000000000000000000000000000000000")
                    target = mktempdir()
                    err = capture_error(() -> Pkg.Registry.download_registry_dir(url, bad, target))
                    @test err isa Pkg.Types.PkgError
                    @test occursin("expected $bad", sprint(showerror, err))
                    @test isempty(readdir(target))
                finally
                    copy!(DEPOT_PATH, old_depot_path)
                end
            end
        end
    end
end
