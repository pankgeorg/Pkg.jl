# This file is a part of Julia. License is MIT: https://julialang.org/license

# PkgWasm test entry point. The stock Pkg test files in this directory test module `Pkg` and
# are not run: the fork is verified by its own acceptance tests (below) and by the frozen
# end-to-end fixtures (runner/compare.jl) against stock Pkg 1.13.2. Each file is
# self-contained and can also be run on its own.

using Test

# The test files activate temporary environments; each starts from the project this was run with.
const TEST_PROJECT = Base.ACTIVE_PROJECT[]

@testset "Pkg" begin
    for file in ("pkgwasm_m31.jl", "pkgwasm_m32.jl", "pkgwasm_registry.jl", "pkgwasm_resolve.jl", "toml_writer.jl", "typed_copies.jl", "typed_equality.jl", "wasm_paths.jl", "status_order.jl", "d9_target.jl", "pkgwasm_request.jl")
        @testset "$file" begin
            Base.ACTIVE_PROJECT[] = TEST_PROJECT
            include(joinpath(@__DIR__, file))
        end
    end
end
