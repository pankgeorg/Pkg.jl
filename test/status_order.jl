# The order of print_status's rows (M4.2: indices sorted by status_isless) against the
# stock `sort!(xs, by = ...)`, with equal keys (stability), stdlibs and _jll packages.

module StatusOrderTests
using Test, Random, UUIDs
const PKGWASM_ID = Base.PkgId(Base.UUID("d562cdc0-5c7a-524d-b497-bb1ca2727331"), "PkgWasm")
const PkgWasm = let m = Base.maybe_root_module(PKGWASM_ID)
    m === nothing ? Base.require(PKGWASM_ID) : m
end
const O = PkgWasm.Operations
const PS = PkgWasm.Types.PackageSpec

stock_order(xs) = sort(xs, by = (x -> (O.is_stdlib(x[1]), endswith(something(x[3], x[2]).name, "_jll"), something(x[3], x[2]).name, x[1])))
function new_order(xs)
    ys = copy(xs)
    perm = sort!(collect(eachindex(ys)); lt = (i, j) -> O.status_isless(ys, i, j))
    return permute!(ys, perm)
end

@testset "status row order" begin
    rng = Xoshiro(0x57a7)
    stdlibs = [UUID("ade2ca70-3891-5945-98fb-dc099432e06a"), UUID("37e2e46d-f89d-539d-b4ee-838fcccc9c8e")]  # Dates, LinearAlgebra
    names = ["Example", "JSON", "Zlib_jll", "A", "a", "Dates", "OpenSSL_jll", "Parsers"]
    for _ in 1:2000
        n = rand(rng, 0:12)
        T = Tuple{Union{Nothing, UUID}, Union{Nothing, PS}, Union{Nothing, PS}}
        xs = T[]
        for _ in 1:n
            id = rand(rng, Bool) ? rand(rng, stdlibs) : rand(rng, [uuid4(rng), UUID(UInt128(rand(rng, 1:3)))])
            nm = rand(rng, names)
            old = rand(rng, Bool) ? PS(name = nm) : nothing
            new = old === nothing || rand(rng, Bool) ? PS(name = rand(rng, Bool) ? nm : rand(rng, names)) : nothing
            push!(xs, (id, old, new))
        end
        @test map(x -> (x[1], something(x[3], x[2]).name), new_order(xs)) ==
              map(x -> (x[1], something(x[3], x[2]).name), stock_order(xs))
        @test map(objectid, new_order(xs)) == map(objectid, stock_order(xs))  # (the same elements, in the same order)
    end
end
end # module
