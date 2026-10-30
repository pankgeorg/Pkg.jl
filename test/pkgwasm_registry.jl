# PkgWasm D15: the `registry` driver command against stock Pkg's REPL `registry` mode.
#
# Each step runs `pkg> registry <args>` through stock Pkg (REPLMode.pkgstr) in one depot and
# `pkgwasm registry <args>` (pkgwasm_main) in another, both against the frozen Pkg-server proxy
# (runner/pkgserver.mjs --offline), and compares the printed output (depot path and times
# normalised) and the resulting registries/ directories. Two starting layouts: an empty depot,
# and General installed by stock Pkg in its default compressed layout (descriptor + tarball).
#
# Needs the PkgWasm checkout inside wasm-pkg/wt/ (for runner/ and fixtures/) and node.

using Test
import Pkg
import PkgWasm
using UUIDs

const WASM_PKG = normpath(joinpath(@__DIR__, "..", "..", ".."))
const PKGSERVER = joinpath(WASM_PKG, "runner", "pkgserver.mjs")
const NODE = get(ENV, "NODE", something(Sys.which("node"), ""))
const GENERAL_UUID = "23338594-aafe-5451-b93e-139f81909106"

function start_proxy()
    log = tempname()
    p = open(`$NODE $PKGSERVER --offline --log $log`, "r")
    line = readline(p)
    startswith(line, "LISTENING ") || error("pkgserver did not start: $(repr(line))")
    return p, String(split(line)[2])
end

function capture_error(f)
    try
        f()
    catch e
        return e
    end
    return nothing
end

# Run `f` with `depot` as the only depot; returns what it printed through DEFAULT_IO.
function in_depot(f, M, depot)
    old = copy(DEPOT_PATH)
    copy!(DEPOT_PATH, [depot])
    buf = IOBuffer()
    M.DEFAULT_IO[] = buf
    try
        f()
    finally
        M.DEFAULT_IO[] = nothing
        copy!(DEPOT_PATH, old)
    end
    return String(take!(buf))
end

function stock_step(depot, words)
    err = nothing
    out = in_depot(Pkg, depot) do
        err = capture_error(() -> Pkg.REPLMode.pkgstr(join(["registry"; words], " ")))
    end
    return out, err
end

# through the export; a failure is printed as `ERROR: <message>` (report_error) and returns 1
function fork_step(depot, words)
    rc = Int32(-1)
    out = in_depot(PkgWasm, depot) do
        rc = PkgWasm.pkgwasm_main(["registry"; words])
    end
    return out, rc
end

normalize(s, depot) = replace(s, depot => "<DEPOT>", Base.contractuser(depot) => "<DEPOT>",
    r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?" => "<TIME>",
    r"last updated [^\n]*" => "last updated <AGO>")

# registries/ content: names, descriptor contents, tree_info, file kinds
function registry_state(depot)
    dir = joinpath(depot, "registries")
    isdir(dir) || return Dict{String, Any}()
    st = Dict{String, Any}()
    for f in readdir(dir)
        p = joinpath(dir, f)
        st[f] = isdir(p) ? ("dir", isfile(joinpath(p, ".tree_info.toml")) ? read(joinpath(p, ".tree_info.toml"), String) : nothing) :
            endswith(f, ".toml") ? ("toml", PkgWasm.TOML.parsefile(p)) :
            f == "CACHEDIR.TAG" ? ("file", read(p, String)) : ("file", filesize(p))
    end
    return st
end

if !isfile(PKGSERVER) || isempty(NODE)
    @testset "PkgWasm registry command (D15)" begin
        @test_skip "runner/pkgserver.mjs or node not available"
    end
else
    proxy, url = start_proxy()
    try
        withenv("JULIA_PKG_SERVER" => url, "JULIA_PKG_UNPACK_REGISTRY" => nothing) do
            @testset "PkgWasm registry command (D15)" begin
                # the differential sequence; the run is twice: from an empty depot, and from
                # General in stock's default compressed layout
                steps = [
                    ["status"],
                    ["add"],
                    ["status"],
                    ["update"],
                    ["update", "General"],
                    ["up", GENERAL_UUID],
                    ["st"],
                    ["rm", "General"],
                    ["status"],
                    ["add", "General"],
                    ["remove", "General=$GENERAL_UUID"],
                    ["add", GENERAL_UUID],
                    ["rm", "NoSuchRegistry"],
                    ["rm"],
                    ["status", "General"],
                ]
                # Both install registries as stock does (D11 update 2): compressed by default.
                for (layout, steps_here, stock_env) in (
                        (:empty, steps, nothing),
                        (:compressed, steps[3:end], nothing),
                        # stock's unpacked install (JULIA_PKG_UNPACK_REGISTRY=true) on both sides
                        (:unpacked, steps, "true"),
                    )
                    @testset "$layout depot" begin
                        sdepot, fdepot = mktempdir(), mktempdir()
                        if layout == :compressed
                            for d in (sdepot, fdepot)
                                in_depot(() -> Pkg.Registry.add("General"), Pkg, d)
                                @test isfile(joinpath(d, "registries", "General.toml"))
                            end
                        end
                        for words in steps_here
                            # get past the 1 s update cooldown so both sides do the same thing
                            words[1] in ("update", "up") && sleep(1.2)
                            sout, serr = withenv(() -> stock_step(sdepot, words), "JULIA_PKG_UNPACK_REGISTRY" => stock_env)
                            fout, rc = withenv(() -> fork_step(fdepot, words), "JULIA_PKG_UNPACK_REGISTRY" => stock_env)
                            # what the stock REPL shows: the output, then `ERROR: <message>`
                            serr === nothing || (sout *= "ERROR: " * sprint(showerror, serr) * "\n")
                            @testset "registry $(join(words, ' '))" begin
                                @test serr === nothing || serr isa Pkg.Types.PkgError
                                @test normalize(fout, fdepot) == normalize(sout, sdepot) ||
                                    (println("stock:\n", sout, "\npkgwasm:\n", fout); false)
                                @test rc == (serr === nothing ? 0 : 1)
                                @test registry_state(fdepot) == registry_state(sdepot)
                            end
                        end
                    end
                end

                @testset "a local path and a git registry (D14)" begin
                    for git in (false, true)
                        depot = mktempdir()
                        regsrc = mktempdir()
                        write(joinpath(regsrc, "Registry.toml"), "name = \"Mini\"\nuuid = \"$(uuid4())\"\n[packages]\n")
                        if git
                            env = ("GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@t", "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@t",
                                   "HOME" => regsrc, "GIT_CEILING_DIRECTORIES" => regsrc, "GIT_CONFIG_NOSYSTEM" => "1")
                            for a in (["init", "-q"], ["add", "-A"], ["commit", "-qm", "r"])
                                run(addenv(Cmd(["git", "-C", regsrc, a...]), env...))
                            end
                        end
                        local rc
                        in_depot(PkgWasm, depot) do
                            rc = PkgWasm.pkgwasm_main(["registry", "add", regsrc])
                        end
                        @test rc == 0
                        @test isfile(joinpath(depot, "registries", "Mini", "Registry.toml"))
                        @test isdir(joinpath(depot, "registries", "Mini", ".git")) == git
                    end
                    @test PkgWasm.pkgwasm_main(["registry"]) == 1
                    @test PkgWasm.pkgwasm_main(["registry", "frobnicate"]) == 1
                end
            end
        end
    finally
        kill(proxy)
    end
end
