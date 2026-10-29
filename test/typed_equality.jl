# M4.2 (e2e B14): Project/Manifest `==` compare field by field with each comparison typed;
# TOML tables by `toml_eq`. Both must give what stock's `==` gives.

module TypedEqualityTests
using Test, Random, Dates
import Pkg
T = Pkg.Types

# TOML values of the parser's types, small, with near-misses and shared shapes
function rand_toml(rng, depth = 0)
    k = rand(rng, 1:(depth < 3 ? 14 : 7))
    k == 13 && return rand(rng, Any[Date(2026, 10, 28), DateTime(2026, 10, 28), DateTime(2026, 10, 28, 1), Time(12), Time(0)])
    k == 14 && return rand(rng, Any[[Date(2026, 1, 1)], [DateTime(2026, 1, 1)], [Time(1), Time(2)], Date[]])
    k == 1 && return rand(rng, ["a", "b", "", "1"])
    k == 2 && return rand(rng, Int64[0, 1, 2, -1])
    k == 3 && return rand(rng, [0.0, 1.0, -0.0, NaN, 2.5])
    k == 4 && return rand(rng, Bool)
    k == 5 && return rand(rng, [String[], ["a"], ["a", "b"]])
    k == 6 && return rand(rng, [Int64[], Int64[1], Int64[1, 2]])
    k == 7 && return rand(rng, [Float64[1.0], Bool[true], Bool[]])
    k <= 9 && return Any[rand_toml(rng, depth + 1) for _ in 1:rand(rng, 0:2)]
    k == 10 && return Dict{String, Any}[Dict{String, Any}("x" => rand_toml(rng, depth + 1)) for _ in 1:rand(rng, 0:2)]
    return Dict{String, Any}(rand(rng, ["x", "y", "z"]) => rand_toml(rng, depth + 1) for _ in 1:rand(rng, 0:3))
end

@testset "typed equality" begin
    rng = Xoshiro(14)
    n = 0
    for _ in 1:20000
        a = rand_toml(rng)
        b = rand(rng, Bool) ? deepcopy(a) : rand(rng, Bool) ? rand_toml(rng) : Dict{String, Any}("x" => a)
        for (x, y) in ((a, b), (b, a), (a, deepcopy(a)))
            r = try x == y catch e; e end
            if r isa Bool
                @test T.toml_eq(x, y) === r
                n += 1
            elseif r isa Exception
                @test_throws typeof(r) T.toml_eq(x, y)
            end
        end
    end
    @test n > 50000
    # (review-10 F1/F2: dates and times; values of different kinds are unequal)
    @test T.toml_eq(Date(2026, 10, 28), Date(2026, 10, 28)) && T.toml_eq(Date(2026, 10, 28), DateTime(2026, 10, 28))
    @test !T.toml_eq("x", Any[]) && !T.toml_eq(Any[], 1) && !T.toml_eq(Dict{String, Any}(), "x") && !T.toml_eq(1, Dict{String, Any}())
    @test_throws Exception T.toml_eq(Date(2026, 10, 28), Time(12))
    # (equal and unequal results both seen)
    @test T.toml_eq(Dict{String, Any}("a" => Any[1, "x"]), Dict{String, Any}("a" => Any[1, "x"]))
    @test !T.toml_eq(Dict{String, Any}("a" => Any[1, "x"]), Dict{String, Any}("a" => Any[1.0, "y"]))
    @test T.toml_eq(Any[1, true], Any[1.0, 1])
    # Project and Manifest: stock's `all(x -> getfield == getfield, fieldnames)`
    stock_eq(x, y) = all(f -> (getfield(x, f) == getfield(y, f))::Bool, fieldnames(typeof(x)))
    versions = Any[nothing, v"1.2.3", Pkg.Versions.VersionSpec("1"), T.UPLEVEL_MINOR]
    m = 0
    for v1 in versions, v2 in versions, o in (false, true), w in (false, true)
        p1 = T.Project(; name = "P", version = v1, other = Dict{String, Any}("name" => "P", "k" => Any[1]))
        p2 = T.Project(; name = "P", version = v2, other = Dict{String, Any}("name" => "P", "k" => Any[o ? 2 : 1]))
        w && (p2.workspace = Dict{String, Any}("projects" => ["a"]))
        @test (p1 == p2) === stock_eq(p1, p2)
        m += (p1 == p2)
    end
    @test 0 < m < 64
    # PackageSpec == (e2e B22): stock's field comparisons, `version` of every type of its Union
    stock_ps_eq(a, b) = a.name == b.name && a.uuid == b.uuid && a.version == b.version &&
        a.tree_hash == b.tree_hash && a.repo == b.repo && a.path == b.path && a.pinned == b.pinned
    pversions = Any[nothing, v"1.2.3", v"1.2.3", Pkg.Versions.VersionSpec("1"), Pkg.Versions.VersionSpec("1"),
                    Pkg.Versions.VersionSpec("2"), T.UPLEVEL_MINOR, T.UPLEVEL_MAJOR, "1.2.3", "x"]
    k = 0
    for v1 in pversions, v2 in pversions, nm in ("A", "B"), pin in (false, true)
        a = T.PackageSpec(; name = "A", version = v1); b = T.PackageSpec(; name = nm, version = v2, pinned = pin)
        @test (a == b) === stock_ps_eq(a, b)
        k += (a == b)
    end
    @test 0 < k < 400
    e = T.PackageEntry(; name = "A", version = v"1.0.0")
    for (o1, o2) in ((Dict{String, Any}(), Dict{String, Any}()), (Dict{String, Any}("a" => 1), Dict{String, Any}("a" => 1.0)),
                     (Dict{String, Any}("a" => 1), Dict{String, Any}("a" => "1")))
        m1 = T.Manifest(; julia_version = v"1.13.2", deps = Dict(Base.UUID(1) => e), other = o1)
        m2 = T.Manifest(; julia_version = v"1.13.2", deps = Dict(Base.UUID(1) => deepcopy(e)), other = o2)
        @test (m1 == m2) === stock_eq(m1, m2)
    end
end
# the same comparison in a process with the Wasm preference (toml_eq's Wasm paths, and
# Project ==, which uses it only there); not again in that process, which includes this file
haskey(ENV, "PKGWASM_TYPED_EQ_CHILD") || @testset "typed equality, target = wasm" begin
    fork = dirname(@__DIR__)
    mktempdir() do env
        write(joinpath(env, "Project.toml"), """
            [deps]
            Pkg = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"
            [sources]
            Pkg = {path = "$(escape_string(fork))"}
            [preferences.Pkg]
            target = "wasm"
            """)
        script = joinpath(env, "script.jl")
        write(script, """
            import Pkg; Pkg.instantiate(; io = devnull)
            using Pkg, Random, Dates
            @assert Pkg.TARGET == "wasm"
            include($(repr(@__FILE__)))  # (rand_toml; the module's native testsets run here as well)
            function check()
            T = Pkg.Types; rng = Xoshiro(15); n = 0; bad = 0
            for _ in 1:20000
                a = TypedEqualityTests.rand_toml(rng); b = rand(rng, Bool) ? deepcopy(a) : TypedEqualityTests.rand_toml(rng)
                r = try a == b catch e; e end
                r isa Bool || continue
                p1 = T.Project(; other = Dict{String, Any}("x" => a)); p2 = T.Project(; other = Dict{String, Any}("x" => b))
                (T.toml_eq(a, b) === r && (p1 == p2) === r) || (bad += 1)
                n += 1
            end
            println("WASMEQ ", n, " ", bad)
            end
            check()
            """)
        out = IOBuffer()
        cmd = addenv(`$(joinpath(Sys.BINDIR, Base.julia_exename())) --startup-file=no --project=$env $script`, "JULIA_PKG_PRECOMPILE_AUTO" => "0", "PKGWASM_TYPED_EQ_CHILD" => "1")
        err = IOBuffer()
        p = run(pipeline(ignorestatus(cmd); stdout = out, stderr = err))
        p.exitcode == 0 || print(stderr, String(take!(err)))
        m = match(r"WASMEQ (\d+) (\d+)", String(take!(out)))
        @test m !== nothing && parse(Int, m[1]) > 15000 && m[2] == "0"
    end
end

# Loaded from source (no package images): the generated `fields_equal` runs in the world it
# was defined in, so what it calls (`field_eq_expr`) must be defined before it.
haskey(ENV, "PKGWASM_TYPED_EQ_CHILD") || @testset "typed equality, loaded from source" begin
    code = """
    import Pkg; T = Pkg.Types
    m = T.Manifest(); m.julia_version = v"1.13.2"
    p = T.Project(); p.name = "P"
    println("FROMSOURCE ", T.Project() == T.Project(), " ", T.Manifest() == T.Manifest(), " ", p == T.Project(), " ", m == T.Manifest())
    """
    out = IOBuffer()
    cmd = addenv(`$(joinpath(Sys.BINDIR, Base.julia_exename())) --startup-file=no --compiled-modules=no --pkgimages=no --project=$(pkgdir(Pkg)) -e $code`, "JULIA_PKG_PRECOMPILE_AUTO" => "0")
    @test success(pipeline(cmd; stdout = out, stderr = devnull))
    @test occursin("FROMSOURCE true true false false", String(take!(out)))
end
end # module
