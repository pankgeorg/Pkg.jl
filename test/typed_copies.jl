# The typed copies of M4.2 (Types.copy_project, copy_manifest, deepcopy_toml) against deepcopy:
# equal, and sharing no mutable object with the original.

module TypedCopiesTests
using Test, Dates
import TOML
const PKGWASM_ID = Base.PkgId(Base.UUID("d562cdc0-5c7a-524d-b497-bb1ca2727331"), "PkgWasm")
const PkgWasm = let m = Base.maybe_root_module(PKGWASM_ID)
    m === nothing ? Base.require(PKGWASM_ID) : m
end
const T = PkgWasm.Types

# every mutable object reachable from x (through fields and elements)
function mutables!(seen::Base.IdSet{Any}, x)
    isbits(x) && return seen
    x isa Union{String, Symbol, Module, DataType} && return seen
    if ismutable(x)
        x in seen && return seen
        push!(seen, x)
    end
    if x isa AbstractDict
        for (k, v) in x
            mutables!(seen, k); mutables!(seen, v)
        end
    elseif x isa AbstractArray
        for i in eachindex(x)
            isassigned(x, i) && mutables!(seen, x[i])
        end
    else
        for i in 1:nfields(x)
            isdefined(x, i) && mutables!(seen, getfield(x, i))
        end
    end
    return seen
end
mutables(x) = mutables!(Base.IdSet{Any}(), x)
shares_nothing(a, b) = isempty(intersect(mutables(a), mutables(b)))

# equality by structure (`==` is identity for immutable structs holding vectors, as AppInfo)
function structeq(a, b)
    typeof(a) === typeof(b) || return false
    a isa Union{Number, AbstractString, Symbol, Nothing, Base.UUID, Base.SHA1, VersionNumber} && return isequal(a, b)
    if a isa AbstractDict
        return length(a) == length(b) && all(k -> haskey(b, k) && structeq(a[k], b[k]), keys(a))
    elseif a isa AbstractArray
        return size(a) == size(b) && all(i -> structeq(a[i], b[i]), eachindex(a))
    end
    return all(i -> structeq(getfield(a, i), getfield(b, i)), 1:nfields(a))
end

const TOML_FILES = let dirs = [@__DIR__]
    fixtures = "/home/pgeorgakopoulos/wasm-pkg/fixtures"  # (the e2e fixtures, where present)
    isdir(fixtures) && push!(dirs, fixtures)
    files = String[]
    for d in dirs, (root, _, fs) in walkdir(d), f in fs
        endswith(f, ".toml") && push!(files, joinpath(root, f))
    end
    files
end

@testset "typed copies" begin
    np = nm = 0
    for file in TOML_FILES
        base = basename(file)
        if startswith(base, "Project") || startswith(base, "JuliaProject")
            p = try T.read_project(file) catch; continue end
            c = T.copy_project(p)
            d = deepcopy(p)
            @test structeq(c, d)
            # what Pkg observes: the comparison with the original, as with deepcopy
            @test (c == p) == (d == p)
            @test (c != p) == (d != p)
            @test shares_nothing(c, p)
            np += 1
        elseif startswith(base, "Manifest") || startswith(base, "JuliaManifest")
            m = try T.read_manifest(file) catch; continue end
            c = T.copy_manifest(m)
            d = deepcopy(m)
            @test structeq(c, d)
            @test (c == m) == (d == m)
            @test (c.deps == m.deps) == (d.deps == m.deps)
            @test c.other == m.other
            @test all(c.deps[k].other == m.deps[k].other for k in keys(m.deps))
            @test shares_nothing(c, m)
            nm += 1
        end
    end
    @test np > 20
    @test nm > 20
    # copy_packagespecs (API's deepcopy(pkgs)): equal fields, nothing mutable shared with the
    # input, and what is shared in the input shared in the copy
    PS = PkgWasm.Types.PackageSpec
    a = PS(name = "A", version = PkgWasm.Versions.VersionSpec("1.2")); b = PS(name = "B", url = "u", rev = "r")
    b.repo = a.repo
    pkgs = [a, b, a]
    c, d = T.copy_packagespecs(pkgs), deepcopy(pkgs)
    @test all(structeq(c[i], d[i]) for i in 1:3)
    @test c[1] === c[3] && c[1].repo === c[2].repo
    @test shares_nothing(c, pkgs)
    # review-5 #2: programmatic metadata (not TOML-parser types) is deep-copied, as deepcopy
    p = T.Project(Dict{String, Any}("custom" => Dict("value" => "before"), "n" => Any[Dict("k" => 1)]))
    c = T.copy_project(p)
    p.other["custom"]["value"] = "after"; p.other["n"][1]["k"] = 2
    @test c.other["custom"]["value"] == "before" && c.other["n"][1]["k"] == 1
    @test (c == p) == (deepcopy(T.Project(Dict{String, Any}("custom" => Dict("value" => "before"), "n" => Any[Dict("k" => 1)]))) == p)
    # review-5 #3: a present `extensions = nothing` throws as stock; a missing one is empty
    stock = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))
    err(f) = try f(); nothing catch e; (typeof(e), sprint(showerror, e)) end
    @test err(() -> T.Project(Dict{String, Any}("extensions" => nothing))) ==
          err(() -> stock.Types.Project(Dict{String, Any}("extensions" => nothing)))
    @test err(() -> T.Project(Dict{String, Any}("extensions" => nothing))) !== nothing
    @test isempty(T.Project(Dict{String, Any}()).exts)
    # deepcopy_toml on parsed tables of every kind of TOML value
    n = 0
    for file in TOML_FILES
        d = try TOML.parsefile(file) catch; continue end
        c = T.deepcopy_toml(d)
        @test c == d
        @test shares_nothing(c, d)
        (n += 1) > 2000 && break
    end
    d = TOML.parse("a = [1, 2]\nb = [\"x\"]\nc = [1.5]\nd = [true]\ne = 1979-05-27T07:32:00Z\nf = [[1], [\"y\"]]\n[[g]]\nh = 1\n[i]\nj = {k = [2]}\n")
    c = T.deepcopy_toml(d)
    @test c == d && typeof(c) == typeof(d)
    @test all(typeof(c[k]) == typeof(d[k]) for k in keys(d))
    @test shares_nothing(c, d)
end
end # module
