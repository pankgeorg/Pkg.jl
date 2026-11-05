# PkgWasm M3.1 acceptance (PLAN.md L3): the renamed fork loads next to stock Pkg and can add a
# package natively. Run from the repo root with the fork on the load path:
#
#   JULIA_DEPOT_PATH=<fresh depot>:<depot with registries>: julia --project=. test/pkgwasm_m31.jl
#
# The first depot must be writable; registries may come from any depot on the path.

using Test
import Pkg
import PkgWasm
using UUIDs
import Sockets

const FORK_UUID = UUID("d562cdc0-5c7a-524d-b497-bb1ca2727331")
const STOCK_UUID = UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f")
const EXAMPLE_UUID = UUID("7876af07-990d-54b4-ab0e-23690620f79a")

@testset "PkgWasm M3.1" begin
    @testset "loads next to stock Pkg" begin
        @test PkgWasm !== Pkg
        @test nameof(PkgWasm) === :PkgWasm
        @test Base.PkgId(PkgWasm) == Base.PkgId(FORK_UUID, "PkgWasm")
        @test Base.PkgId(Pkg) == Base.PkgId(STOCK_UUID, "Pkg")
        @test parentmodule(PkgWasm.Types) === PkgWasm
        @test PkgWasm.Operations.PkgUUID == string(FORK_UUID)
        # stdlib Pkg is still an ordinary stdlib to the fork
        @test PkgWasm.Types.is_stdlib(STOCK_UUID)
        @test PkgWasm.pkgwasm_abi_version() === Int32(3)
    end

    @testset "add Example" begin
        mktempdir() do dir
            proj = joinpath(dir, "env")
            mkpath(proj)
            out = IOBuffer()
            PkgWasm.activate(proj; io = out)
            PkgWasm.add("Example"; io = out)
            m = PkgWasm.TOML.parsefile(joinpath(proj, "Manifest.toml"))
            @test haskey(m["deps"], "Example")
            @test m["deps"]["Example"][1]["uuid"] == string(EXAMPLE_UUID)
            @test PkgWasm.TOML.parsefile(joinpath(proj, "Project.toml"))["deps"] == Dict("Example" => string(EXAMPLE_UUID))
            # a dependency on the stdlib Pkg is the real Pkg, not the fork
            PkgWasm.add("Pkg"; io = out)
            m = PkgWasm.TOML.parsefile(joinpath(proj, "Manifest.toml"))
            @test m["deps"]["Pkg"][1]["uuid"] == string(STOCK_UUID)
            @test !haskey(m["deps"], "PkgWasm")
            PkgWasm.rm("Pkg"; io = out)
            # and stock Pkg reads the result identically
            Pkg.activate(proj; io = devnull)
            @test haskey(Pkg.dependencies(), EXAMPLE_UUID)
            Pkg.activate(; io = devnull)
            PkgWasm.activate(; io = devnull)
        end
    end

    @testset "Host seam (native)" begin
        Host = PkgWasm.Host
        mktempdir() do dir
            payload = repeat("PkgWasm host seam\n", 1000)
            raw = joinpath(dir, "raw")
            write(raw, payload)
            for (fmt, cmd) in (
                    ("gz", `$(PkgWasm.PlatformEngines.exe7z()) a -tgzip $(raw).gz $raw`),
                    ("zst", `$(PkgWasm.PlatformEngines.exezstd()) -q $raw -o $(raw).zst`),
                )
                run(pipeline(cmd; stdout = devnull))
                out = joinpath(dir, "out-$fmt")
                @test Host.decompress("$raw.$fmt", out) === nothing
                @test read(out, String) == payload
                @test !isfile(out * ".partial")
            end
            err = try
                Host.decompress(raw, joinpath(dir, "bad"))
            catch e
                e
            end
            @test err isa Host.HostError && err.status == 25
            @test !ispath(joinpath(dir, "bad")) && !ispath(joinpath(dir, "bad.partial"))

            # failure paths: everything is a HostError and no partial output survives
            err = try
                Host.decompress(joinpath(dir, "nonexistent.gz"), joinpath(dir, "ne"))
            catch e
                e
            end
            @test err isa Host.HostError && err.status == 29
            @test !ispath(joinpath(dir, "ne.partial"))
            write(joinpath(dir, "bad2.partial"), "stale")
            @test_throws Host.HostError Host.decompress(raw, joinpath(dir, "bad2"))
            @test !ispath(joinpath(dir, "bad2.partial"))
            if !Sys.iswindows() && Libc.getuid() != 0
                # publishing fails: `dst` is a directory whose contents cannot be removed
                pdst = joinpath(dir, "pdst")
                mkpath(joinpath(pdst, "locked", "x"))
                chmod(joinpath(pdst, "locked"), 0o500)
                try
                    err = try
                        Host.decompress("$raw.gz", pdst)
                    catch e
                        e
                    end
                    @test err isa Host.HostError
                    @test !ispath(pdst * ".partial")
                    @test isdir(joinpath(pdst, "locked", "x"))
                finally
                    chmod(joinpath(pdst, "locked"), 0o700)
                end
            end

        end
    end

    @testset "Host.init_runtime seam runs first in pkgwasm_init" begin
        @test PkgWasm.Host.init_runtime() === nothing
        # stand-in for the Wasm patch: init_runtime sets up the environment the PkgWasm globals
        # are then read from, so init_globals! must see what it did
        @eval PkgWasm.Host init_runtime() = (ENV["JULIA_PKG_OFFLINE"] = "true"; nothing)
        try
            withenv("JULIA_PKG_OFFLINE" => nothing) do
                @test PkgWasm.pkgwasm_init() == 0
                @test PkgWasm.OFFLINE_MODE[]
            end
        finally
            @eval PkgWasm.Host init_runtime() = nothing
            PkgWasm.pkgwasm_init()
        end
        @test !PkgWasm.OFFLINE_MODE[]
        # a failing init_runtime is reported as an init error (exit status 1)
        @eval PkgWasm.Host init_runtime() = error("runtime init failed")
        try
            @test PkgWasm.pkgwasm_init() == 1
        finally
            @eval PkgWasm.Host init_runtime() = nothing
            PkgWasm.pkgwasm_init()
        end
    end

    @testset "entry point driver" begin
        mktempdir() do dir
            withenv("JULIA_PROJECT" => nothing) do
                PkgWasm.activate(dir; io = devnull)
                @test PkgWasm.pkgwasm_init() == 0
                @test PkgWasm.pkgwasm_main(["add", "Example"]) == 0
                @test PkgWasm.pkgwasm_main(["status"]) == 0
                @test PkgWasm.pkgwasm_main(["rm", "Example"]) == 0
                @test PkgWasm.pkgwasm_main(["frobnicate"]) == 1
                @test PkgWasm.pkgwasm_main(String[]) == 1
                # the failures above must be reported PkgErrors, not incidental exceptions
                @test_throws PkgWasm.Types.PkgError PkgWasm.run_command(["frobnicate"])
                @test_throws PkgWasm.Types.PkgError PkgWasm.run_command(String[])
                @test_throws PkgWasm.Types.PkgError PkgWasm.run_command(["add"])
                PkgWasm.activate(; io = devnull)
            end
        end
    end
end
