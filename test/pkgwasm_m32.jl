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

# A tiny HTTP/1.1 server: `routes(path) -> (status, body)`. Returns (base_url, server).
import Sockets
function serve(routes)
    server = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(server)[2])
    phrases = Dict(200 => "OK", 404 => "Not Found", 500 => "Internal Server Error")
    @async while isopen(server)
        sock = try
            Sockets.accept(server)
        catch
            break
        end
        @async try
            line = readline(sock)
            while !isempty(readline(sock)) end
            status, body = routes(String(split(line)[2]))
            write(sock, "HTTP/1.1 $status $(phrases[status])\r\nContent-Length: $(sizeof(body))\r\nConnection: close\r\n\r\n", body)
        catch
        finally
            close(sock)
        end
    end
    return "http://127.0.0.1:$port", server
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

    @testset "D13 host platform from the runtime seam" begin
        BP = Base.BinaryPlatforms
        @test Pkg.Host.platform() isa BP.Platform
        @test BP.triplet(Pkg.Host.platform()) == BP.triplet(BP.HostPlatform())
        # natively, loading the module initialised it (__init__)
        @test BP.triplet(Pkg.host_platform()) == BP.triplet(BP.HostPlatform())
        hdrs = Dict(Pkg.PlatformEngines.get_metadata_headers("https://pkg.julialang.org/registries"))
        @test hdrs["Julia-System"] == BP.triplet(BP.HostPlatform())
        @test hdrs == Dict(Pkg.PlatformEngines.get_metadata_headers("https://pkg.julialang.org/registries"))
        @test Pkg.BinaryPlatformsCompat.platform_key_abi() === Pkg.HOST_PLATFORM[]
        frozen_file = joinpath(@__DIR__, "..", "..", "..", "fixtures", "frozen.toml") # wt/<lane>/test -> wasm-pkg/fixtures
        if isfile(frozen_file) # the native baselines' platform is this host's
            @test BP.triplet(Pkg.host_platform()) == Pkg.TOML.parsefile(frozen_file)["platform_triplet"]
        end
        # sanitised (image state): placeholder, and use fails loudly; init answers it again
        Pkg.sanitize_globals!()
        @test Pkg.HOST_PLATFORM[] === Pkg.HOST_PLATFORM_PLACEHOLDER
        @test_throws ErrorException Pkg.host_platform()
        @test_throws ErrorException Pkg.PlatformEngines.get_metadata_headers("https://pkg.julialang.org/registries")
        @test Pkg.pkgwasm_init() == 0
        @test BP.triplet(Pkg.host_platform()) == BP.triplet(BP.HostPlatform())
        code(file) = join(filter(l -> !startswith(lstrip(l), "#"), readlines(joinpath(pkgdir(Pkg), "src", file))), "\n")
        for file in ("API.jl", "Operations.jl", "PlatformEngines.jl", "Artifacts.jl")
            @test !occursin("HostPlatform()", code(file))
        end
        @test !isdefined(Pkg, :PKGWASM_PLATFORM)
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
                    (() -> Pkg.Apps.add(Pkg.PackageSpec(name = "Example")), "apps"),
                    (() -> Pkg.Apps.develop(Pkg.PackageSpec(path = joinpath(dir, "missing"))), "apps"),
                    (() -> Pkg.Apps.update(), "apps"),
                    (() -> Pkg.Apps.update("Example"), "apps"),
                    (() -> Pkg.Apps.rm(Pkg.PackageSpec(name = "Absent")), "apps"),
                    (() -> Pkg.Apps.rm("Absent"), "apps"),
                    (() -> Pkg.Apps.status(), "apps"),
                    (() -> Pkg.Apps.precompile(), "apps"),
                )
                err = capture_error(f)
                @test err isa Pkg.Types.PkgError
                @test sprint(showerror, err) == "$op is not supported in PkgWasm"
            end
            @test !ispath(Pkg.Apps.app_env_folder()) || isempty(readdir(Pkg.Apps.app_env_folder()))
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

    @testset "D4 build scripts: retry and prepopulated depot still fail (review-2 #1)" begin
        mktempdir() do dir
            Pkg.activate(dir; io = devnull)
            Pkg.add("Example"; io = devnull)
            src = Pkg.Operations.source_path(joinpath(dir, "Manifest.toml"), Pkg.Types.EnvCache().manifest[EXAMPLE_UUID])
            # simulate an installed package with a build script (as left by another process)
            chmod(src, 0o755)
            mkpath(joinpath(src, "deps"))
            build = joinpath(src, "deps", "build.jl")
            write(build, "error(\"must not run\")\n")
            try
                is_build_error(e) = e isa Pkg.Types.PkgError && occursin("building packages is not supported in PkgWasm", e.msg) && occursin("Example", e.msg)
                @test Pkg.Operations.is_instantiated(Pkg.Types.EnvCache()) # sources present
                @test is_build_error(capture_error(() -> Pkg.instantiate(; io = devnull)))
                @test is_build_error(capture_error(() -> Pkg.instantiate(; io = devnull))) # retry
                @test is_build_error(capture_error(() -> Pkg.add("Dates"; io = devnull)))
                @test is_build_error(capture_error(() -> Pkg.add("Dates"; io = devnull))) # retry
                @test Pkg.pkgwasm_main(["instantiate"]) == 1
            finally
                rm(joinpath(src, "deps"); recursive = true)
                Pkg.set_readonly(src)
            end
            @test Pkg.instantiate(; io = devnull) === nothing
            Pkg.activate(; io = devnull)
        end
    end

    @testset "D4 git unreachable from supported commands (review-2 #2)" begin
        is_git_error(e) = e isa Pkg.Types.PkgError && occursin("is not supported in PkgWasm", e.msg) && startswith(e.msg, "git (")
        # repo-tracked manifest entry whose source is missing: instantiate
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"), "[deps]\nExample = \"$EXAMPLE_UUID\"\n")
            write(joinpath(dir, "Manifest.toml"), """
            julia_version = "1.13.2"
            manifest_format = "2.0"

            [[deps.Example]]
            git-tree-sha1 = "0000000000000000000000000000000000000001"
            repo-rev = "master"
            repo-url = "https://github.com/JuliaLang/Example.jl.git"
            uuid = "$EXAMPLE_UUID"
            version = "0.5.5"
            """)
            Pkg.activate(dir; io = devnull)
            @test is_git_error(capture_error(() -> Pkg.instantiate(; io = devnull)))
            Pkg.activate(; io = devnull)
        end
        # server lists no registries: the default-registry install would clone General
        base, server = serve(path -> path == "/registries" ? (200, "") : (404, ""))
        mktempdir() do depot
            old = copy(DEPOT_PATH)
            copy!(DEPOT_PATH, [depot])
            try
                withenv("JULIA_PKG_SERVER" => base) do
                    Pkg.activate(joinpath(depot, "env"); io = devnull)
                    @test is_git_error(capture_error(() -> Pkg.add("Dates"; io = devnull)))
                    @test !isdir(joinpath(depot, "registries", "General"))
                end
            finally
                copy!(DEPOT_PATH, old)
                Pkg.activate(; io = devnull)
            end
        end
        close(server)
        # an existing git registry is reported as not updatable, without touching git
        mktempdir() do depot
            reg = joinpath(depot, "registries", "Foo")
            mkpath(joinpath(reg, ".git"))
            write(joinpath(reg, "Registry.toml"), "name = \"Foo\"\nuuid = \"$(uuid4())\"\nrepo = \"https://example.invalid/Foo.git\"\n\n[packages]\n")
            @test_logs (:error, r"updating a git registry is not supported in PkgWasm") match_mode = :any Pkg.Registry.update(; depots = [depot], io = devnull)
        end
        # status --diff against git HEAD (G3 clean compile: LibGit2 unreachable). Repository
        # discovery (discover_repo, as stock) walks up from the project directory to the home
        # directory; HOME is the test's own temp root, so a stray `.git` above it (e.g. /tmp/.git
        # from another process) cannot be found.
        mktempdir() do root
            dir = joinpath(root, "proj")
            mkpath(dir)
            write(joinpath(dir, "Project.toml"), "[deps]\n")
            withenv("HOME" => root) do
                @test homedir() == root
                Pkg.activate(dir; io = devnull)
                @test Pkg.discover_repo(dir) === nothing
                # not a git repository: stock's warning, as before
                @test_logs (:warn, r"diff option only available") match_mode = :any Pkg.status(; diff = true, io = IOBuffer())
                mkpath(joinpath(dir, ".git"))
                @test Pkg.discover_repo(dir) == dir
                @test is_git_error(capture_error(() -> Pkg.status(; diff = true, io = IOBuffer())))
                Pkg.activate(; io = devnull)
            end
        end
        # explicit repo tracking through the Types entry points
        ctx = Pkg.Types.Context(; io = devnull)
        @test is_git_error(capture_error(() -> Pkg.Types.handle_repo_add!(ctx, Pkg.PackageSpec(url = "https://example.invalid/X.jl"))))
        @test is_git_error(capture_error(() -> Pkg.GitTools.clone(devnull, "https://example.invalid/X.jl", mktempdir())))
    end

    @testset "D11 stale compressed descriptor does not hide the directory registry (review-2 #3)" begin
        # PkgWasm installs registries as stock does (D11 update 2); this tests the unpacked
        # install path, i.e. JULIA_PKG_UNPACK_REGISTRY=true
        withenv("JULIA_PKG_UNPACK_REGISTRY" => "true") do
            mktempdir() do depot
                old = copy(DEPOT_PATH)
                copy!(DEPOT_PATH, [depot])
                try
                    regdir = joinpath(depot, "registries")
                    mkpath(regdir)
                    write(joinpath(regdir, "General.toml"), "uuid = \"$GENERAL_UUID\"\ngit-tree-sha1 = \"0000000000000000000000000000000000000000\"\npath = \"General.tar.gz\"\n")
                    @test isempty(Pkg.Registry.reachable_registries())
                    Pkg.Registry.add("General"; io = devnull)
                    regs = Pkg.Registry.reachable_registries()
                    @test length(regs) == 1 && only(regs).uuid == GENERAL_UUID
                    @test isdir(joinpath(regdir, "General")) && !ispath(joinpath(regdir, "General.toml"))
                    # review-3: a damaged descriptor naming another file next to the installed
                    # directory. With JULIA_PKG_UNPACK_REGISTRY=true descriptors are not read (as in
                    # stock), so the directory stays reachable; adding again changes nothing and
                    # no archive is deleted
                    write(joinpath(regdir, "Other.tar.gz"), "not ours")
                    write(joinpath(regdir, "General.toml"), "uuid = \"$GENERAL_UUID\"\npath = \"Other.tar.gz\"\n")
                    regs = Pkg.Registry.reachable_registries()
                    @test length(regs) == 1 && only(regs).uuid == GENERAL_UUID && isdir(only(regs).path)
                    Pkg.Registry.add("General"; io = devnull)
                    regs = Pkg.Registry.reachable_registries()
                    @test length(regs) == 1 && only(regs).uuid == GENERAL_UUID
                    @test read(joinpath(regdir, "Other.tar.gz"), String) == "not ours"
                    # a descriptor for a different registry with the same name is a conflict
                    rm(joinpath(regdir, "General"); recursive = true)
                    write(joinpath(regdir, "General.toml"), "uuid = \"$(uuid4())\"\ngit-tree-sha1 = \"0000000000000000000000000000000000000000\"\npath = \"General.tar.gz\"\n")
                    err = capture_error(() -> Pkg.Registry.add("General"; io = devnull))
                    @test err isa Pkg.Types.PkgError && occursin("conflicts with the existing compressed registry descriptor", err.msg)
                finally
                    copy!(DEPOT_PATH, old)
                end
            end
        end
    end

    @testset "HTTP failure text equals stock (review-2 #4)" begin
        base, server = serve(path -> (404, ""))
        mktempdir() do dir
            ef = capture_error(() -> Pkg.PlatformEngines.download("$base/missing", joinpath(dir, "f")))
            es = capture_error(() -> Pkg.PlatformEngines.download("$base/missing", joinpath(dir, "s")))
            @test sprint(showerror, ef) == sprint(showerror, es)
            @test sprint(showerror, ef) == "RequestError: HTTP/1.1 404 Not Found while requesting $base/missing"
            @test !ispath(joinpath(dir, "f"))
        end
        close(server)
        # through a supported operation: the registry tarball is listed but missing
        base, server = serve(path -> path == "/registries" ? (200, "/registry/$GENERAL_UUID/0000000000000000000000000000000000000002\n") : (404, ""))
        msgs = map((Pkg, Pkg)) do M
            mktempdir() do depot
                old = copy(DEPOT_PATH)
                copy!(DEPOT_PATH, [depot])
                try
                    withenv("JULIA_PKG_SERVER" => base) do
                        e = capture_error(() -> M.Registry.add("General"; io = devnull))
                        e isa Exception ? e.msg : repr(e)
                    end
                finally
                    copy!(DEPOT_PATH, old)
                end
            end
        end
        @test msgs[1] == msgs[2]
        @test occursin("RequestError: HTTP/1.1 404 Not Found", msgs[1])
        close(server)
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
            # public instantiate on an already-instantiated env still says so (review-2 #7)
            write(joinpath(dir, "Manifest.toml"), "julia_version = \"1.13.2\"\nmanifest_format = \"2.0\"\n\n[deps]\n")
            out = IOBuffer()
            Pkg.instantiate(; io = out)
            @test count("artifacts of 1 package(s) were not downloaded", String(take!(out))) == 1
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
            # the whole environment is checked, not only the newly installed set (review-2 #1)
            @test capture_error(() -> Pkg.Operations.build_versions(ctx, Set{UUID}())) isa Pkg.Types.PkgError
            rm(joinpath(dir, "deps"); recursive = true)
            @test Pkg.Operations.build_versions(ctx, Set([uuid])) === nothing
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
                # historical julia_version (review-2 #8): artifact scan must not probe stdlibs
                push!(Pkg.Types.STDLIBS_BY_VERSION, v"1.13.1" => Pkg.Types.stdlib_infos())
                ctx = Pkg.Types.Context(; io = devnull)
                ctx.julia_version = v"1.13.1"
                Pkg.Operations.download_artifacts(ctx; julia_version = ctx.julia_version)
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

    @testset "D8 globals: sanitize and init" begin
        mktempdir() do dir
            Pkg.activate(dir; io = devnull)
            Pkg.status(; io = devnull) # fills registry/TOML/stdlib caches
            @test !isempty(Pkg.Registry.REGISTRY_CACHE) || !isempty(Pkg.Registry.TOML_CACHE.d) || Pkg.Types.STDLIB[] !== nothing
            Pkg.DEFAULT_IO[] = devnull
            Pkg.UPDATED_REGISTRY_THIS_SESSION[] = true
            sentinel = joinpath(dir, "sentinel.toml")
            write(sentinel, "secret = \"build-host\"\n")
            Pkg.Types.parse_toml(sentinel)
            Pkg.Registry._parsefile(sentinel)
            handler = (url, svr, err) -> error("must not run")
            Pkg.PlatformEngines.register_auth_error_handler("https://", handler)
            Pkg.sanitize_globals!()
            for cache in (Pkg.Types.TOML_CACHE, Pkg.Registry.TOML_CACHE)
                @test cache.p.str == "" && cache.p.filepath === nothing && isempty(cache.p.root)
            end
            @test isempty(Pkg.PlatformEngines.AUTH_ERROR_HANDLERS)
            @test Pkg.DEFAULT_IO[] === nothing
            @test !Pkg.UPDATED_REGISTRY_THIS_SESSION[]
            @test isempty(Pkg.Registry.REGISTRY_CACHE) && isempty(Pkg.Registry.TOML_CACHE.d) && isempty(Pkg.Types.TOML_CACHE.d)
            @test Pkg.Types.STDLIB[] === nothing && isempty(Pkg.Types.UPGRADABLE_STDLIBS_UUIDS)
            withenv("JULIA_PKG_OFFLINE" => "true") do
                @test Pkg.pkgwasm_init() == 0
                @test Pkg.OFFLINE_MODE[]
            end
            @test Pkg.pkgwasm_init() == 0
            @test !Pkg.OFFLINE_MODE[]
            # caches rebuild transparently
            @test Pkg.pkgwasm_main(["status"]) == 0
            @test Pkg.Types.is_stdlib(UUID("ade2ca70-3891-5945-98fb-dc099432e06a"))
            Pkg.activate(; io = devnull)
        end
    end

    @testset "D8 sanitize_globals! as pre-image hook: no build-host state reachable" begin
        # Poison PkgWasm the way runner/build.jl does (decoy registry in REGISTRY_CACHE with its
        # package info parsed, session flags set), plus every other PkgWasm cache, then check
        # that nothing reachable from any PkgWasm global holds a marker string afterwards.
        mktempdir() do root
            depot = joinpath(root, "depot")
            r = joinpath(depot, "registries", "General")
            mkpath(joinpath(r, "E", "Example"))
            write(joinpath(r, "Registry.toml"), """
                name = "General"
                uuid = "$GENERAL_UUID"
                repo = "https://pkgwasm-sentinel.invalid/decoy-General.git"
                description = "DECOY registry from the build host"
                [packages]
                $EXAMPLE_UUID = { name = "Example", path = "E/Example" }
                """)
            write(joinpath(r, "E", "Example", "Package.toml"), "name = \"Example\"\nuuid = \"$EXAMPLE_UUID\"\nrepo = \"https://pkgwasm-sentinel.invalid/Example.jl.git\"\n")
            write(joinpath(r, "E", "Example", "Versions.toml"), "[\"9.9.9\"]\ngit-tree-sha1 = \"0000000000000000000000000000000000000000\"\n")
            write(joinpath(r, ".tree_info.toml"), "git-tree-sha1 = \"bf156f1d33580ac1fadbb60976e2a8577a66ed42\"\n")
            regs = Pkg.Registry.reachable_registries(; depots = [depot])
            for reg in regs, (uuid, pkg) in reg
                Pkg.Registry.registry_info(reg, pkg)
            end
            @test !isempty(Pkg.Registry.REGISTRY_CACHE)
            Pkg.UPDATED_REGISTRY_THIS_SESSION[] = true
            Pkg.OFFLINE_MODE[] = true
            Pkg.DEFAULT_IO[] = IOBuffer("pkgwasm-sentinel-io")
            Pkg.PREV_ENV_PATH[] = joinpath(root, "pkgwasm-sentinel-prev")
            Pkg.PlatformEngines.EXE7Z[] = joinpath(root, "pkgwasm-sentinel-7z")
            Pkg.PlatformEngines.register_auth_error_handler("https://pkgwasm-sentinel", (u, s, e) -> nothing)
            Pkg.Types.parse_toml(joinpath(r, "Registry.toml"))
            Pkg.GitTools.GIT_USERS["pkgwasm-sentinel"] = "x"
            markers = ["DECOY registry from the build host", "decoy-General.git", "pkgwasm-sentinel", root]

            function reachable_markers(roots)
                seen = Base.IdSet{Any}()
                stack = Any[roots...]
                found = Set{String}()
                while !isempty(stack)
                    x = pop!(stack)
                    (x isa Module || x isa Type || x isa Function || x isa Method || x isa Core.MethodInstance) && continue
                    x isa Symbol && continue
                    if x isa AbstractString
                        for m in markers
                            occursin(m, x) && push!(found, m)
                        end
                        continue
                    end
                    isbits(x) && continue
                    x in seen && continue
                    push!(seen, x)
                    if x isa IOBuffer
                        push!(stack, String(copy(x.data)))
                    elseif x isa AbstractDict
                        for (k, v) in x
                            push!(stack, k, v)
                        end
                    elseif x isa AbstractArray || x isa Tuple || x isa AbstractSet
                        for (i, v) in pairs(x isa AbstractSet ? collect(x) : x)
                            (x isa AbstractArray && !isassigned(x, i)) || push!(stack, v)
                        end
                    else
                        for i in 1:nfields(x)
                            isdefined(x, i) && push!(stack, getfield(x, i))
                        end
                    end
                end
                return found
            end
            function pkgwasm_global_values()
                vals = Any[]
                mods = Module[Pkg]
                while !isempty(mods)
                    m = pop!(mods)
                    for n in names(m; all = true, imported = false)
                        isdefined(m, n) || continue
                        Base.isdeprecated(m, n) && continue
                        v = getfield(m, n)
                        if v isa Module
                            v !== m && parentmodule(v) === m && push!(mods, v)
                        else
                            push!(vals, v)
                        end
                    end
                end
                return vals
            end
            @test !isempty(reachable_markers(pkgwasm_global_values())) # the walker sees the poison
            Pkg.sanitize_globals!()
            @test isempty(reachable_markers(pkgwasm_global_values()))
            @test !Pkg.UPDATED_REGISTRY_THIS_SESSION[] && !Pkg.OFFLINE_MODE[]
            @test Pkg.HOST_PLATFORM[] === Pkg.HOST_PLATFORM_PLACEHOLDER
            # idempotent, and init restores a usable session
            Pkg.sanitize_globals!()
            @test isempty(reachable_markers(pkgwasm_global_values()))
            @test Pkg.pkgwasm_init() == 0
            @test Pkg.host_platform() isa Base.BinaryPlatforms.Platform
        end
    end

    @testset "compressed registry in a depot is read in memory as stock reads it (registry-tar (a))" begin
        mktempdir() do depot
            # stock 1.13 default layout: <name>.toml descriptor + <name>.tar.gz, with one package
            src = mktempdir()
            mini_uuid = uuid4()
            foo_uuid = uuid4()
            bar_uuid = uuid4()
            write(joinpath(src, "Registry.toml"), """
                name = "Mini"
                uuid = "$mini_uuid"
                repo = "https://example.invalid/Mini.git"

                [packages]
                $foo_uuid = { name = "Foo", path = "F/Foo" }
                $bar_uuid = { name = "Bar", path = "B/Bar" }
                """)
            bar = mkpath(joinpath(src, "B", "Bar"))
            write(joinpath(bar, "Package.toml"), "name = \"Bar\"\nuuid = \"$bar_uuid\"\nrepo = \"https://example.invalid/Bar.jl.git\"\n")
            write(joinpath(bar, "Versions.toml"), "[\"1.0.0\"]\ngit-tree-sha1 = \"$(repeat("3", 40))\"\n")
            foo = mkpath(joinpath(src, "F", "Foo"))
            write(joinpath(foo, "Package.toml"), "name = \"Foo\"\nuuid = \"$foo_uuid\"\nrepo = \"https://example.invalid/Foo.jl.git\"\n")
            write(joinpath(foo, "Versions.toml"), """
                ["0.1.0"]
                git-tree-sha1 = "$(repeat("1", 40))"

                ["0.2.0"]
                git-tree-sha1 = "$(repeat("2", 40))"
                yanked = true
                """)
            write(joinpath(foo, "Deps.toml"), "[\"0.2-0\"]\nBar = \"$bar_uuid\"\n")
            write(joinpath(foo, "Compat.toml"), "[\"0.2-0\"]\nBar = \"1\"\njulia = \"1.6.0-1\"\n")
            regdir = joinpath(depot, "registries")
            mkpath(regdir)
            tar = Pkg.Registry.Tar.create(src)
            hash = Pkg.Registry.Tar.tree_hash(tar)
            run(pipeline(`$(Pkg.PlatformEngines.exe7z()) a -tgzip $(joinpath(regdir, "Mini.tar.gz")) $tar`; stdout = devnull))
            desc = joinpath(regdir, "Mini.toml")
            write(desc, "git-tree-sha1 = \"$hash\"\npath = \"Mini.tar.gz\"\nuuid = \"$mini_uuid\"\n")
            before = Dict(f => read(joinpath(regdir, f)) for f in readdir(regdir))
            stock = only(Pkg.Registry.reachable_registries(; depots = [depot]))
            ours = only(Pkg.Registry.reachable_registries(; depots = [depot]))
            @test ours.path == stock.path == desc
            @test ours.tree_info == stock.tree_info == Base.SHA1(hash)
            @test ours.compressed_file == stock.compressed_file == "Mini.tar.gz"
            @test (ours.name, ours.uuid, ours.repo) == (stock.name, stock.uuid, stock.repo)
            @test ours.in_memory_registry == stock.in_memory_registry  # (before package info frees entries)
            @test sort!(collect(keys(ours))) == sort!(collect(keys(stock))) == sort!([foo_uuid, bar_uuid])
            si = Pkg.Registry.registry_info(stock, stock[foo_uuid])
            oi = Pkg.Registry.registry_info(ours, ours[foo_uuid])
            @test oi.repo == si.repo
            @test Dict(k => (v.git_tree_sha1, v.yanked) for (k, v) in oi.version_info) ==
                Dict(k => (v.git_tree_sha1, v.yanked) for (k, v) in si.version_info)
            # (VersionRange/VersionSpec are different types in Pkg and PkgWasm: compared as strings)
            norm_deps(d) = Dict(string(k) => sort!(collect(v)) for (k, v) in d)
            norm_compat(d) = Dict(string(k) => Dict(u => string(s) for (u, s) in v) for (k, v) in d)
            @test norm_deps(oi.deps) == norm_deps(si.deps)
            @test norm_compat(oi.compat) == norm_compat(si.compat)
            @test any(v -> haskey(v, bar_uuid), values(oi.compat))
            # the registry is reported as packed, as stock does
            @test Pkg.Registry.get_registry_type(ours) == Pkg.Registry.get_registry_type(stock) == :packed
            # resolution against it equals stock's (resolve_versions!, without installing Foo), and
            # status through the entry point works
            old = copy(DEPOT_PATH)
            copy!(DEPOT_PATH, [depot])
            try
                mktempdir() do env
                    write(joinpath(env, "Project.toml"), "[deps]\nFoo = \"$foo_uuid\"\n\n[compat]\nFoo = \"0.1\"\n")
                    function resolved(P)
                        e = P.Types.EnvCache(joinpath(env, "Project.toml"))
                        pkgs = [P.Types.PackageSpec(; name = "Foo", uuid = foo_uuid)]
                        P.Operations.resolve_versions!(e, P.Registry.reachable_registries(; depots = [depot]), pkgs, VERSION, false)
                        return Dict(p.uuid => (p.version, p.tree_hash) for p in pkgs)
                    end
                    @test resolved(Pkg) == resolved(Pkg) == Dict(foo_uuid => (v"0.1.0", Base.SHA1(repeat("1", 40))))
                    Pkg.activate(env; io = devnull)
                    @test Pkg.pkgwasm_main(["status"]) == 0
                end
            finally
                copy!(DEPOT_PATH, old)
                Pkg.activate(; io = devnull)
            end
            # the depot is left as stock wrote it: descriptor and tarball unchanged, nothing added
            @test Dict(f => read(joinpath(regdir, f)) for f in readdir(regdir)) == before
            # without a Pkg server, stock ignores descriptors and so does PkgWasm
            withenv("JULIA_PKG_SERVER" => "") do
                @test isempty(Pkg.Registry.reachable_registries(; depots = [depot]))
            end
        end
    end

    @testset "D11 update 2: default registry install is compressed, as stock" begin
        mktempdir() do depot
            old = copy(DEPOT_PATH)
            copy!(DEPOT_PATH, [depot])
            try
                withenv("JULIA_PKG_UNPACK_REGISTRY" => nothing) do
                    Pkg.Registry.add("General"; io = devnull)
                    regdir = joinpath(depot, "registries")
                    desc = Pkg.TOML.parsefile(joinpath(regdir, "General.toml"))
                    @test desc["uuid"] == string(GENERAL_UUID)
                    @test isfile(joinpath(regdir, desc["path"]))
                    @test !isdir(joinpath(regdir, "General"))
                    regs = Pkg.Registry.reachable_registries()
                    @test length(regs) == 1 && only(regs).uuid == GENERAL_UUID
                    @test string(only(regs).tree_info) == desc["git-tree-sha1"]
                    @test haskey(only(regs).pkgs, EXAMPLE_UUID) # read in memory
                end
            finally
                copy!(DEPOT_PATH, old)
            end
        end
    end

    @testset "D11 registry installed unpacked with verified tree hash" begin
        # PkgWasm installs registries as stock does (D11 update 2); this tests the unpacked
        # install path, i.e. JULIA_PKG_UNPACK_REGISTRY=true
        withenv("JULIA_PKG_UNPACK_REGISTRY" => "true") do
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
end
