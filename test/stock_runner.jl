# test/stock's summary (runnable.jl): a file whose worker died before recording its results
# (the record runtests.jl's `run_file` writes for it) has no clean testsets, unlike a file
# that ran with all its tests passing.

module StockRunnerTests
using Test, TOML

@testset "stock runner: a crashed worker is not clean coverage" begin
    mktempdir() do dir
        for target in ("stock", "pkgwasm"); mkpath(joinpath(dir, target)); end
        ok(file) = Dict("target" => "pkgwasm", "file" => file, "pass" => 3, "fail" => 0, "error" => 0,
            "broken" => 0, "results" => Dict{String, Any}[])
        crashed(file) = Dict("target" => "pkgwasm", "file" => file, "pass" => 0, "fail" => 0, "error" => 1,
            "broken" => 0, "crash" => "exit code 1 without results", "results" => Dict{String, Any}[])
        for (file, w) in (("good.jl", ok("good.jl")), ("dies.jl", crashed("dies.jl")))
            open(io -> TOML.print(io, merge(ok(file), Dict("target" => "stock"))), joinpath(dir, "stock", file * ".toml"), "w")
            open(io -> TOML.print(io, w), joinpath(dir, "pkgwasm", file * ".toml"), "w")
        end
        testsets = [Dict("file" => f, "line" => l, "path" => "$f > $name", "calls" => Dict("add" => 1),
            "flags" => String[]) for f in ("good.jl", "dies.jl") for (l, name) in ((10, "first"), (20, "second"))]
        apicalls = joinpath(dir, "apicalls.toml")
        open(io -> TOML.print(io, Dict("testset" => testsets)), apicalls, "w")
        out = read(`$(Base.julia_cmd()) --startup-file=no $(joinpath(@__DIR__, "stock", "runnable.jl")) $dir $apicalls`, String)
        summary(f) = only(l for l in split(out, '\n') if startswith(l, "| $f | 3 | ")) # stock passed 3
        @test occursin("| all pass (as stock) | 2/2 |", summary("good.jl"))
        @test occursin("| worker crashed: exit code 1 without results | 0/2 |", summary("dies.jl"))
        # and none of its testsets is listed as clean
        @test !occursin("| dies.jl | first |", out) && !occursin("| dies.jl | second |", out)
        @test occursin("| good.jl | first |", out)
    end
end
end # module
