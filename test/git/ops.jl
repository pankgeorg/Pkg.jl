# One run of the git operations of test/pkgwasm_git.jl, in a fresh process:
#   julia ops.jl stock|pkgwasm <pkgwasm dir> <work dir>
# `stock` is Pkg (with JULIA_PKG_USE_CLI_GIT=true from the caller), `pkgwasm` PkgWasm. Both run
# the same sequence on the git repositories of fixture.jl, built afresh in <work>/src, with a
# fresh depot and no package server, and print each step's output, the manifests and the depot's
# files (path, mode, content hash). The caller runs both in the same <work> path, one after the
# other, so paths and commit ids are the same, and compares the two outputs.

which, pkgwasm_dir, work = ARGS
const P = if which == "stock"
    using Pkg
    Pkg
else
    push!(LOAD_PATH, pkgwasm_dir)
    using PkgWasm
    PkgWasm
end
using SHA, TOML
include(joinpath(@__DIR__, "fixture.jl"))

rm(work; recursive = true, force = true)
mkpath(work)
# hermetic: HOME and the git discovery ceiling are the run's own directory
ENV["HOME"] = work
ENV["GIT_CEILING_DIRECTORIES"] = work
ENV["GIT_CONFIG_NOSYSTEM"] = "1"
make_fixture(joinpath(work, "src"))
const FOO = joinpath(work, "src", "Foo")
const REG = joinpath(work, "src", "Reg")
const DEPOT = joinpath(work, "depot")
mkpath(DEPOT)
empty!(DEPOT_PATH)
push!(DEPOT_PATH, DEPOT)
ENV["JULIA_PKG_SERVER"] = ""
ENV["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
which == "stock" && (P._auto_gc_enabled[] = false)   # (gc is not part of PkgWasm)

out = IOBuffer()
norm(s) = replace(s, work => "<W>", r"\e\[[0-9;]*m" => "", r"last updated [0-9-]+ [0-9:]+" => "last updated <T>")
function step(f, name)
    io = IOBuffer()
    r = try
        f(io)
        "ok"
    catch e
        e isa P.Types.PkgError || rethrow()
        "PkgError: " * e.msg
    end
    println(out, "## ", name, ": ", norm(r))
    print(out, norm(String(take!(io))))
    return nothing
end
function manifest(env)
    f = joinpath(env, "Manifest.toml")
    isfile(f) || return "(none)"
    return replace(read(f, String), r"project_hash = .*\n" => "")
end
show_manifest(env) = println(out, "### manifest\n", norm(manifest(env)))

env = joinpath(work, "env")
P.activate(env; io = devnull)
step(io -> P.Registry.add(P.RegistrySpec(url = REG); io), "registry add (git url)")
step(io -> P.Registry.status(io), "registry status")
step(io -> P.add("Foo"; io), "add Foo (registered, installed by git: no server)")
show_manifest(env)
step(io -> P.add(P.PackageSpec(url = FOO, rev = "dev"); io), "add url#dev (branch)")
show_manifest(env)
step(io -> P.add(P.PackageSpec(url = FOO, rev = "v0.1.0"); io), "add url#v0.1.0 (tag)")
show_manifest(env)
step(io -> P.add(P.PackageSpec(url = FOO, rev = commit_of(FOO, "dev")[1:10]); io), "add url#<short sha>")
show_manifest(env)
step(io -> P.add(P.PackageSpec(url = FOO, rev = "no-such-rev"); io), "add url#no-such-rev")
step(io -> P.add(P.PackageSpec(url = FOO, subdir = "sub/Bar"); io), "add url subdir")
show_manifest(env)
step(io -> P.add(P.PackageSpec(url = FOO, rev = "dev"); io), "add url#dev again")
new_commit!(FOO, "dev", "src/Foo.jl", "module Foo\nf() = 3\nend\n", "three")
step(io -> P.update(; io), "update (tracked branch moved)")
show_manifest(env)
step(io -> P.status(; io), "status")
step(io -> P.add(P.PackageSpec(path = FOO); io), "add path (local repo)")
show_manifest(env)
new_version!(REG, FOO, v"0.1.1")
sleep(1.5)  # (Registry.update skips a registry updated less than a second ago)
step(io -> P.Registry.update(; io), "registry update (new commit)")
step(io -> P.Registry.status(io), "registry status after update")

env2 = joinpath(work, "env2")
P.activate(env2; io = devnull)
step(io -> P.develop(P.PackageSpec(url = FOO); io), "develop url (a local path: by path)")
show_manifest(env2)
step(io -> P.develop(P.PackageSpec(url = "file://" * FOO); io), "develop url (file://: cloned into dev/)")
show_manifest(env2)
step(io -> P.develop(P.PackageSpec(path = joinpath(FOO, "sub", "Bar")); io), "develop path")
show_manifest(env2)

# status --diff against the git HEAD of a project in a git repository
env3 = joinpath(work, "env3")
P.activate(env3; io = devnull)
step(io -> P.add("Foo"; io), "add Foo (env3)")
git_init_commit!(env3)
step(io -> P.add(P.PackageSpec(url = FOO, rev = "dev"); io), "add url#dev (env3)")
step(io -> P.status(; io, diff = true), "status --diff")

println(out, "## registry Foo versions: ", sort!(collect(keys(TOML.parsefile(joinpath(DEPOT, "registries", "Reg", "F", "Foo", "Versions.toml"))))))
println(out, "## depot")
for (root, dirs, files) in walkdir(DEPOT)
    rel = relpath(root, DEPOT)
    (startswith(rel, "logs") || occursin(r"(^|/)\.git(/|$)", rel) || startswith(rel, "clones")) && continue
    for f in sort(files)
        p = joinpath(root, f)
        h = islink(p) ? "-> " * readlink(p) :
            f == "registry_updates.toml" ? join(sort!(collect(keys(TOML.parsefile(p)))), ",") : # (times)
            bytes2hex(open(sha1, p))
        println(out, joinpath(rel, f), " ", string(filemode(p) & 0o777; base = 8), " ", norm(h))
    end
end
println(out, "## clones: ", isdir(joinpath(DEPOT, "clones")) ? length(readdir(joinpath(DEPOT, "clones"))) : 0)
write(stdout, take!(out))
