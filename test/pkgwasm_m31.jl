# PkgWasm M3.1 acceptance (PLAN.md L3): the renamed fork loads next to stock Pkg and can add a
# package natively. Run from the repo root with the fork on the load path:
#
#   JULIA_DEPOT_PATH=<fresh depot>:<depot with registries>: julia --project=. test/pkgwasm_m31.jl
#
# The first depot must be writable; registries may come from any depot on the path.

using Test
import Pkg
import Pkg
using UUIDs
import Sockets

const FORK_UUID = UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f")
const STOCK_UUID = UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f")
const EXAMPLE_UUID = UUID("7876af07-990d-54b4-ab0e-23690620f79a")

@testset "PkgWasm M3.1" begin
    @testset "loads next to stock Pkg" begin
        @test Pkg !== Pkg
        @test nameof(Pkg) === :Pkg
        @test Base.PkgId(Pkg) == Base.PkgId(FORK_UUID, "Pkg")
        @test Base.PkgId(Pkg) == Base.PkgId(STOCK_UUID, "Pkg")
        @test parentmodule(Pkg.Types) === Pkg
        @test Pkg.Operations.PkgUUID == string(FORK_UUID)
        # stdlib Pkg is still an ordinary stdlib to the fork
        @test Pkg.Types.is_stdlib(STOCK_UUID)
        @test Pkg.pkgwasm_abi_version() === Int32(3)
    end

    @testset "add Example" begin
        mktempdir() do dir
            proj = joinpath(dir, "env")
            mkpath(proj)
            out = IOBuffer()
            Pkg.activate(proj; io = out)
            Pkg.add("Example"; io = out)
            m = Pkg.TOML.parsefile(joinpath(proj, "Manifest.toml"))
            @test haskey(m["deps"], "Example")
            @test m["deps"]["Example"][1]["uuid"] == string(EXAMPLE_UUID)
            @test Pkg.TOML.parsefile(joinpath(proj, "Project.toml"))["deps"] == Dict("Example" => string(EXAMPLE_UUID))
            # a dependency on the stdlib Pkg is the real Pkg, not the fork
            Pkg.add("Pkg"; io = out)
            m = Pkg.TOML.parsefile(joinpath(proj, "Manifest.toml"))
            @test m["deps"]["Pkg"][1]["uuid"] == string(STOCK_UUID)
            @test !haskey(m["deps"], "Pkg")
            Pkg.rm("Pkg"; io = out)
            # and stock Pkg reads the result identically
            Pkg.activate(proj; io = devnull)
            @test haskey(Pkg.dependencies(), EXAMPLE_UUID)
            Pkg.activate(; io = devnull)
            Pkg.activate(; io = devnull)
        end
    end

    @testset "Host seam (native)" begin
        Host = Pkg.Host
        mktempdir() do dir
            payload = repeat("PkgWasm host seam\n", 1000)
            raw = joinpath(dir, "raw")
            write(raw, payload)
            for (fmt, cmd) in (
                    ("gz", `$(Pkg.PlatformEngines.exe7z()) a -tgzip $(raw).gz $raw`),
                    ("zst", `$(Pkg.PlatformEngines.exezstd()) -q $raw -o $(raw).zst`),
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
                finally
                    chmod(joinpath(pdst, "locked"), 0o700)
                end
            end

            server = Pkg.pkg_server()
            dest = joinpath(dir, "registries")
            r = Host.download(server * "/registries", dest, Pair{String, String}[])
            @test r.status == 200
            @test occursin("/registry/23338594-aafe-5451-b93e-139f81909106/", read(dest, String))
            @test !isfile(dest * ".partial")
            dest404 = joinpath(dir, "missing")
            r = Host.download(server * "/no-such-resource-pkgwasm", dest404, Pair{String, String}[])
            @test r.status == 404
            @test !ispath(dest404) && !ispath(dest404 * ".partial")
            err = try
                Host.download("https://nonexistent.invalid/x", joinpath(dir, "x"), Pair{String, String}[])
            catch e
                e
            end
            @test err isa Host.HostError && err.status == 29
            @test !ispath(joinpath(dir, "x.partial"))
        end
    end

    @testset "Host.download redirect limit and cleanup (local server)" begin
        Host = Pkg.Host
        # minimal HTTP/1.1 server: /r/<n> redirects to /r/<n-1>, /r/0 is 200, /404 is 404
        server = Sockets.listen(Sockets.localhost, 0)
        port = Int(Sockets.getsockname(server)[2])
        task = @async while isopen(server)
            sock = try
                Sockets.accept(server)
            catch
                break
            end
            @async try
                line = readline(sock)
                while !isempty(readline(sock)) end
                path = split(line)[2]
                if startswith(path, "/r/")
                    n = parse(Int, path[4:end])
                    if n == 0
                        body = "done"
                        write(sock, "HTTP/1.1 200 OK\r\nContent-Length: $(sizeof(body))\r\nConnection: close\r\n\r\n$body")
                    else
                        write(sock, "HTTP/1.1 302 Found\r\nLocation: /r/$(n - 1)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                    end
                else
                    write(sock, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                end
            finally
                close(sock)
            end
        end
        base = "http://127.0.0.1:$port"
        mktempdir() do dir
            dest = joinpath(dir, "ok")
            r = Host.download("$base/r/10", dest, Pair{String, String}[])
            @test r.status == 200 && read(dest, String) == "done" && endswith(r.url, "/r/0")
            dest = joinpath(dir, "toomany")
            err = try
                Host.download("$base/r/11", dest, Pair{String, String}[])
            catch e
                e
            end
            @test err isa Host.HostError && err.status == 29
            @test !ispath(dest) && !ispath(dest * ".partial")
            # a previous complete destination survives a failed transfer
            write(dest, "previous")
            @test_throws Host.HostError Host.download("$base/r/11", dest, Pair{String, String}[])
            @test read(dest, String) == "previous"
            # >= 400 removes dest and returns the status
            r = Host.download("$base/404", dest, Pair{String, String}[])
            @test r.status == 404 && !ispath(dest) && !ispath(dest * ".partial")
            # publishing fails (`dest` is a directory whose contents cannot be removed):
            # HostError, no partial left
            if !Sys.iswindows() && Libc.getuid() != 0
                pdest = joinpath(dir, "pdest")
                mkpath(joinpath(pdest, "locked", "x"))
                chmod(joinpath(pdest, "locked"), 0o500)
                try
                    err = try
                        Host.download("$base/r/0", pdest, Pair{String, String}[])
                    catch e
                        e
                    end
                    @test err isa Host.HostError
                    @test !ispath(pdest * ".partial")
                finally
                    chmod(joinpath(pdest, "locked"), 0o700)
                end
            end
        end
        close(server)
    end

    @testset "entry point driver" begin
        mktempdir() do dir
            withenv("JULIA_PROJECT" => nothing) do
                Pkg.activate(dir; io = devnull)
                @test Pkg.pkgwasm_init() == 0
                @test Pkg.pkgwasm_main(["add", "Example"]) == 0
                @test Pkg.pkgwasm_main(["status"]) == 0
                @test Pkg.pkgwasm_main(["rm", "Example"]) == 0
                @test Pkg.pkgwasm_main(["frobnicate"]) == 1
                @test Pkg.pkgwasm_main(String[]) == 1
                # the failures above must be reported PkgErrors, not incidental exceptions
                @test_throws Pkg.Types.PkgError Pkg.run_command(["frobnicate"])
                @test_throws Pkg.Types.PkgError Pkg.run_command(String[])
                @test_throws Pkg.Types.PkgError Pkg.run_command(["add"])
                Pkg.activate(; io = devnull)
            end
        end
    end
end
