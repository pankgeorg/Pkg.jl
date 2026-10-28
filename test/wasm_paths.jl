# e2e G2 B15-B18: the typed paths built for Wasm give what stock gives.
# dropbuild and `julia_version === VERSION` through the version string (B15, B17); the TOML
# writer's typed tables (B18) and destructure's typed copy (B16) in a process with the Wasm
# preference, byte-identical to stock Pkg.

module WasmPathsTests
using Test
import Pkg
O = Pkg.Operations

const EDGE = ["0.0.0", "1.2.3", "1.2.3-rc1", "2.0.1-rc1.21321", "1.0.0-alpha-1.2", "1.0.0-1", "1.0.0-1.2.3", "1.0.0-0",
              "1.0.0+build", "1.0.0+b.1", "1.0.0-rc.1+b.2", "1.0.0-a.b.c+x-y.z", "1.0.0-x-y-z", "1.13.0-DEV.123",
              "1.13.2-beta2.0", "4294967295.0.0", "1.0.0-18446744073709551615", "1.0.0-alpha.beta-gamma"]
stock_dropbuild(v) = VersionNumber(v.major, v.minor, v.patch, isempty(v.prerelease) ? () : (v.prerelease[1],))

@testset "B15/B17: version string paths" begin
    vs = [VersionNumber.(EDGE); VERSION; VersionNumber(1, 2, 3, ("a", UInt64(1)), ("b",));
          VersionNumber(1, 2, 3, (UInt64(7),), (UInt64(8), "x")); VersionNumber(1, 2, 3, ("a-b", "c")); VersionNumber(1, 2, 3, ("x",), ("a-b",))]
    for v in vs
        a, b = stock_dropbuild(v), O.dropbuild_typed(v)
        @test a == b && typeof(a.prerelease) == typeof(b.prerelease) && string(a) == string(b)
    end
    n = 0
    for a in vs, b in vs
        @test (string(a) == string(b)) == (a === b)
        n += a === b
    end
    @test n == length(vs)
end

@testset "B21: VersionRange printing" begin
    stock = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))
    tuples = [(), (0,), (1,), (4294967295,), (0, 0), (2, 3), (1, 4294967295), (0, 0, 0), (1, 5, 9), (0, 0, 4294967295)]
    n = 0
    for lo in tuples, hi in tuples
        a = stock.Versions.VersionRange(stock.Versions.VersionBound(lo...), stock.Versions.VersionBound(hi...))
        b = Pkg.Versions.VersionRange(Pkg.Versions.VersionBound(lo...), Pkg.Versions.VersionBound(hi...))
        @test string(a) == string(b) && sprint(show, a) == sprint(show, b)
        n += occursin(" - ", string(b)) && occursin(".", string(b))
    end
    @test n > 10
end

const CHILD = raw"""
import Pkg; Pkg.instantiate(; io = devnull)
using Pkg
@assert Pkg.TARGET == "wasm"
dir = mktempdir()
write(joinpath(dir, "Project.toml"), '''
name = "P"
uuid = "8c9a2bd0-6b1e-4ac1-9d36-1d2f8a3b0c11"
version = "0.1.0"
stamp = 2026-10-28
custom = [{a = 1}, {a = 2}]

[deps]
A = "11111111-1111-1111-1111-111111111111"
B = "22222222-2222-2222-2222-222222222222"

[weakdeps]
W = "33333333-3333-3333-3333-333333333333"

[extensions]
E1 = "W"
E2 = ["W", "B"]

[sources]
A = {path = "../A"}
B = {url = "https://example.com/B.jl", rev = "main"}

[compat]
A = "1.2"
julia = "1.10"

[extras]
X = "44444444-4444-4444-4444-444444444444"

[targets]
test = ["X"]
''')
write(joinpath(dir, "Manifest.toml"), '''
julia_version = "1.13.2"
manifest_format = "2.0"
project_hash = "0123456789abcdef0123456789abcdef01234567"

[[deps.A]]
path = "../A"
uuid = "11111111-1111-1111-1111-111111111111"
version = "1.2.0"
weakdeps = ["W"]

    [deps.A.extensions]
    E1 = "W"
    E2 = ["W", "B"]

[[deps.B]]
deps = ["A"]
git-tree-sha1 = "0123456789abcdef0123456789abcdef01234567"
uuid = "22222222-2222-2222-2222-222222222222"
version = "0.3.1"

[[deps.W]]
git-tree-sha1 = "89abcdef0123456789abcdef0123456789abcdef"
uuid = "33333333-3333-3333-3333-333333333333"
version = "2.0.0"
''')
res(f) = try f() catch e; "ERR " * sprint(showerror, e) end
for mod in (Pkg, Pkg)
    T = mod.Types
    println("P=", repr(res(() -> sprint(T.write_project, T.destructure(T.read_project(joinpath(dir, "Project.toml")))))))
    println("M=", repr(res(() -> sprint(io -> T.write_manifest(io, T.destructure(T.read_manifest(joinpath(dir, "Manifest.toml"))))))))
end
"""

@testset "B16/B18: writing built for Wasm" begin
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
        write(script, replace(CHILD, "'''" => "\"\"\""))
        out, err = IOBuffer(), IOBuffer()
        cmd = addenv(`$(joinpath(Sys.BINDIR, Base.julia_exename())) --startup-file=no --project=$env $script`, "JULIA_PKG_PRECOMPILE_AUTO" => "0")
        p = run(pipeline(ignorestatus(cmd); stdout = out, stderr = err))
        p.exitcode == 0 || print(stderr, String(take!(err)))
        lines = split(String(take!(out)), '\n')
        ps = filter(startswith("P="), lines); ms = filter(startswith("M="), lines)
        haskey(ENV, "WASM_PATHS_DEBUG") && foreach(println, ms)
        @test length(ps) == 2 && ps[1] == ps[2] && !occursin("ERR", ps[1]) && occursin("[extensions]", ps[1]) && occursin("[sources]", ps[1])
        @test length(ms) == 2 && ms[1] == ms[2] && !occursin("ERR", ms[1]) && occursin("deps.A.extensions", ms[1])
    end
end
end # module
