# M4.2 (e2e B14): Project/Manifest `==` compare field by field with each comparison typed;
# TOML tables by `toml_eq`. Both must give what stock's `==` gives.

module TypedEqualityTests
using Test, Random
import Pkg
T = Pkg.Types

# TOML values of the parser's types, small, with near-misses and shared shapes
function rand_toml(rng, depth = 0)
    k = rand(rng, 1:(depth < 3 ? 12 : 7))
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
            r = x == y
            r isa Bool || continue
            @test T.toml_eq(x, y) === r
            n += 1
        end
    end
    @test n > 50000
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
    e = T.PackageEntry(; name = "A", version = v"1.0.0")
    for (o1, o2) in ((Dict{String, Any}(), Dict{String, Any}()), (Dict{String, Any}("a" => 1), Dict{String, Any}("a" => 1.0)),
                     (Dict{String, Any}("a" => 1), Dict{String, Any}("a" => "1")))
        m1 = T.Manifest(; julia_version = v"1.13.2", deps = Dict(Base.UUID(1) => e), other = o1)
        m2 = T.Manifest(; julia_version = v"1.13.2", deps = Dict(Base.UUID(1) => deepcopy(e)), other = o2)
        @test (m1 == m2) === stock_eq(m1, m2)
    end
end
end # module
