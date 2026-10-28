# This file is a part of Julia. License is MIT: https://julialang.org/license

# PkgWasm test entry point. The stock Pkg test files in this directory test module `Pkg` and
# are not run: the fork is verified by its own acceptance tests (below) and by the frozen
# end-to-end fixtures (runner/compare.jl) against stock Pkg 1.13.2. Each file is
# self-contained and can also be run on its own.

using Test

@testset "Pkg" begin
    for file in ("pkgwasm_m31.jl",)
        @testset "$file" begin
            include(joinpath(@__DIR__, file))
        end
    end
end
