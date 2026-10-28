# PkgWasm.TOMLWriter (M4.2) against TOML.print: the same bytes, the same errors.

module TOMLWriterTests
using Test, Random, Dates, UUIDs
import TOML
const PKGWASM_ID = Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg")
const Pkg = let m = Base.maybe_root_module(PKGWASM_ID)
    m === nothing ? Base.require(PKGWASM_ID) : m
end
const W = Pkg.TOMLWriter

outcome(f) = try
    (:ok, f())
catch err
    (:error, typeof(err), sprint(showerror, err))
end
both(args...; kw...) = (outcome(() -> sprint(io -> W.print(args[1:end-1]..., io, args[end]; kw...))),
                        outcome(() -> sprint(io -> TOML.print(args[1:end-1]..., io, args[end]; kw...))))
# (`print(f, io, d)` or `print(io, d)`: the dict is last, the function first if any)
function same(d; f = nothing, kw...)
    a, b = f === nothing ? both(d; kw...) : both(f, d; kw...)
    a == b || @info "TOML writer mismatch" d a b
    return a == b
end
idset(v) = (s = Base.IdSet{Dict}(); foreach(x -> push!(s, x), v); s)

tostr(x) = (x isa UUID || x isa VersionNumber || x isa Base.SHA1 || x === nothing) ? string(x) : error("unhandled type `$(typeof(x))`")
key_order(key) = something(findfirst(==(key), ["name", "uuid", "version", "deps", "compat"]), 100)

# a random table of the kinds of values Pkg's tables hold (and a few it does not)
function gen_value(rng, depth)
    k = rand(rng, 1:(depth > 2 ? 10 : 15))
    k == 1 && return rand(rng, ["", "a", "é ü", "line\nbreak", "q\"uote", "back\\slash", "\t\x01\x7f", "日本"])
    k == 2 && return rand(rng, Bool)
    k == 3 && return rand(rng, -5:typemax(Int) >> 60)
    k == 4 && return rand(rng, [0.0, -1.5, 1e300, NaN, Inf, -Inf, 3.0])
    k == 5 && return rand(rng, Bool) ? String[gen_key(rng) for _ in 1:rand(rng, 0:3)] :
        rand(rng, [Int64[1, 2], Float64[1.5, NaN], Bool[true], [DateTime(2026, 1, 1)], [Date(2026, 1, 1)], [Time(1, 2)]])
    k == 6 && return Any[gen_value(rng, depth + 1) for _ in 1:rand(rng, 0:3)]
    k == 7 && return rand(rng, [uuid4(rng), v"1.2.3", v"0.1.0-rc1+b", Base.SHA1(rand(rng, UInt8, 20))])
    k == 8 && return DateTime(2026, 10, 28, rand(rng, 0:23), 5, 6, rand(rng, 0:999))
    k == 9 && return rand(rng, [Date(2026, 1, 2), Time(1, 2, 3, 4)])
    k == 10 && return Dict{String, String}(gen_key(rng) => gen_key(rng) for _ in 1:rand(rng, 0:3))
    k <= 13 && return gen_table(rng, depth + 1)
    return Dict{String, Any}[gen_table(rng, depth + 1) for _ in 1:rand(rng, 1:3)]
end
gen_key(rng) = rand(rng, ["a", "b", "name", "uuid", "deps", "compat", "x.y", "with space", "", "ü", "version", "z9"])
gen_table(rng, depth) = Dict{String, Any}(gen_key(rng) => gen_value(rng, depth) for _ in 1:rand(rng, 0:5))

const TOML_FILES = let dirs = [joinpath(@__DIR__), joinpath(dirname(@__DIR__), "src")]
    fixtures = "/home/pgeorgakopoulos/wasm-pkg/fixtures"  # (the e2e fixtures, where present)
    isdir(fixtures) && push!(dirs, fixtures)
    files = String[]
    for d in dirs, (root, _, fs) in walkdir(d), f in fs
        endswith(f, ".toml") && push!(files, joinpath(root, f))
    end
    files
end

@testset "TOMLWriter" begin
    @testset "TOML files of the tests and fixtures ($(length(TOML_FILES)))" begin
        @test length(TOML_FILES) > 50
        nparsed = 0
        for file in TOML_FILES
            d = try
                TOML.parsefile(file)
            catch
                continue
            end
            nparsed += 1
            @test same(d)
            @test same(d; sorted = true)
            @test same(d; sorted = true, by = key -> (key_order(key), key))
        end
        @test nparsed > 50
    end
    @testset "write_project and write_manifest as stock" begin
        n = 0
        for file in TOML_FILES
            base = basename(file)
            if startswith(base, "Project") || startswith(base, "JuliaProject")
                p = try Pkg.Types.read_project(file) catch; continue end
                rawp = try Pkg.Types.destructure(p) catch; continue end  # (as stock: some fixtures are invalid)
                ours = sprint(Pkg.Types.write_project, rawp)
                # stock's writer, with an IdSet of the inline tables
                inline_tables = idset(haskey(rawp, "sources") ? collect(values(rawp["sources"])) : [])
                theirs = sprint(io -> TOML.print(io, rawp; inline_tables, sorted = true,
                                                 by = key -> (Pkg.Types.project_key_order(key), key)) do x
                    x isa UUID || x isa VersionNumber || error("unhandled type `$(typeof(x))`")
                    string(x)
                end)
                @test ours == theirs
                n += 1
            elseif startswith(base, "Manifest") || startswith(base, "JuliaManifest")
                m = try Pkg.Types.read_manifest(file) catch; continue end
                rawm = try Pkg.Types.destructure(m) catch; continue end  # (unknown manifest formats, as stock)
                ours = sprint(Pkg.Types.write_manifest, rawm)
                theirs = "# This file is machine-generated - editing it directly is not advised\n\n" *
                         sprint(io -> TOML.print(tostr, io, rawm; sorted = true))
                @test ours == theirs
                n += 1
            end
        end
        @test n > 20
    end
    @testset "generated tables" begin
        rng = Xoshiro(0x7031)
        for _ in 1:20_000
            d = gen_table(rng, 0)
            @test same(d; f = tostr, sorted = rand(rng, Bool))
        end
        # inline tables: some subtables of a table, by identity
        for _ in 1:2_000
            d = gen_table(rng, 0)
            subs = [v for v in values(d) if v isa Dict{String, Any}]
            pick = [s for s in subs if rand(rng, Bool)]
            a = outcome(() -> sprint(io -> W.print(tostr, io, d; sorted = true, inline_tables = Any[pick...])))
            b = outcome(() -> sprint(io -> TOML.print(tostr, io, d; sorted = true, inline_tables = idset(pick))))
            @test a == b
        end
    end
    @testset "atomic_toml_write with an IdSet of inline tables, as stock (review-5 #1)" begin
        stock = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))
        mktempdir() do dir
            inner = Dict{String, Any}("a" => 1)
            data = Dict{String, Any}("x" => inner, "y" => Dict{String, Any}("b" => 2))
            stock.atomic_toml_write(joinpath(dir, "stock.toml"), data; inline_tables = Base.IdSet{Dict}([inner]))
            Pkg.atomic_toml_write(joinpath(dir, "fork.toml"), data; inline_tables = Base.IdSet{Dict}([inner]))
            @test read(joinpath(dir, "fork.toml"), String) == read(joinpath(dir, "stock.toml"), String)
            @test occursin("x = {a = 1}", read(joinpath(dir, "fork.toml"), String))
        end
    end
    @testset "errors as stock" begin
        @test same(Dict{String, Any}("u" => uuid4()))          # no conversion function
        @test same(Dict{String, Any}("u" => uuid4()); f = x -> x)  # it returns a non-TOML value
        @test same(Dict{String, Any}("a" => Any[Dict{String, Any}("x" => 1), 2]))
        @test same(Dict{String, Any}("s" => "bad\xff"))
        @test same(Dict{String, Any}("i" => Int32(3), "u" => UInt8(7), "f" => 1.5f0, "v" => [1, 2]))  # other types, natively
    end
end
end # module
