# This file is a part of Julia. License is MIT: https://julialang.org/license

# PkgWasm: the registry unpack cache (Registry/registry_instance.jl) and the request driver
# (wasm_request.jl), natively. No network: a small registry is built and compressed here.

using Test, TOML, Tar, UUIDs
import Pkg
const R = Pkg.Registry

const REG_UUID = "aaaaaaaa-0000-4000-8000-000000000001"
const PKG_UUID = "aaaaaaaa-0000-4000-8000-000000000002"

# A registry with one package `Foo` at the given versions, compressed with gzip into
# <depot>/registries/Test.tar.gz with its descriptor Test.toml; returns the descriptor path.
function write_compressed_registry(depot, versions)
    src = mktempdir()
    write(joinpath(src, "Registry.toml"), """
        name = "Test"
        uuid = "$REG_UUID"
        repo = "https://example.com/Test.git"
        [packages]
        $PKG_UUID = { name = "Foo", path = "F/Foo" }
        """)
    mkpath(joinpath(src, "F", "Foo"))
    write(joinpath(src, "F", "Foo", "Package.toml"), "name = \"Foo\"\nuuid = \"$PKG_UUID\"\nrepo = \"https://example.com/Foo.jl.git\"\n")
    write(joinpath(src, "F", "Foo", "Versions.toml"),
        join(["[\"$v\"]\ngit-tree-sha1 = \"$(repeat(string(i), 40))\"\n" for (i, v) in enumerate(versions)]))
    regs = joinpath(depot, "registries")
    mkpath(regs)
    tar = tempname()
    Tar.create(src, tar)
    hash = open(Tar.tree_hash, tar)
    tarball = joinpath(regs, "Test.tar.gz")
    run(pipeline(`gzip -9 -n -c $tar`; stdout = tarball))
    rm(tar); rm(src; recursive = true)
    desc = joinpath(regs, "Test.toml")
    write(desc, "git-tree-sha1 = \"$hash\"\nuuid = \"$REG_UUID\"\npath = \"Test.tar.gz\"\n")
    return desc, hash
end

function load_versions(desc)
    empty!(R.REGISTRY_CACHE)
    reg = R.RegistryInstance(desc)
    info = R.registry_info(reg, reg.pkgs[UUID(PKG_UUID)])
    return reg, sort!(collect(keys(info.version_info)))
end

const CACHE_SUBDIR = ("scratchspaces", "44cfe95a-1eb2-52ea-b672-e2afdf69b78f", "registry_cache")
cache_dir(depot) = joinpath(depot, CACHE_SUBDIR...)
cache_files(depot) = isdir(cache_dir(depot)) ? sort(readdir(cache_dir(depot))) : String[]
# the cache entries of tree hash `h`: its index and the one tar generation it names
function is_entry(files, h)
    length(files) == 2 || return false
    return files[2] == "$h.idx" && startswith(files[1], "$h-") && endswith(files[1], ".tar")
end
cached_tar(depot, h) = joinpath(cache_dir(depot), only(f for f in cache_files(depot) if startswith(f, "$h-")))

@testset "registry unpack cache" begin
    depot = mktempdir()
    old_depots = copy(DEPOT_PATH)
    try
        empty!(DEPOT_PATH); push!(DEPOT_PATH, depot)
        desc, hash = write_compressed_registry(depot, ["1.0.0", "1.1.0"])
        tarball = joinpath(depot, "registries", "Test.tar.gz")

        withenv("JULIA_PKG_REGISTRY_CACHE" => "false") do
            reg, vs = load_versions(desc)
            @test reg.in_memory_registry isa Dict{String, String} # the stock in-memory read
            @test vs == [v"1.0.0", v"1.1.0"]
            @test isempty(cache_files(depot))
        end
        withenv("JULIA_PKG_REGISTRY_CACHE" => "true") do
            reg, vs = load_versions(desc)
            @test reg.in_memory_registry isa R.RegistryTarIndex
            @test vs == [v"1.0.0", v"1.1.0"]
            @test R.get_registry_type(reg) === :packed # still the stock compressed layout
            @test reg.name == "Test" && reg.repo == "https://example.com/Test.git"
            @test is_entry(cache_files(depot), hash)
            # the registry directory itself is untouched
            @test sort(readdir(joinpath(depot, "registries"))) == ["Test.tar.gz", "Test.toml"]
            idx = joinpath(cache_dir(depot), "$hash.idx")
            before = read(idx)

            # a second load reads the cache as is
            reg2, vs2 = load_versions(desc)
            @test reg2.in_memory_registry isa R.RegistryTarIndex && vs2 == vs
            @test read(idx) == before

            # streams are closed explicitly (no finalizers in Wasm); a later read reopens
            @test !isempty(R.REGISTRY_CACHE_STREAMS)
            R.close_registry_cache_streams!()
            @test isempty(R.REGISTRY_CACHE_STREAMS)
            @test occursin("Test", reg2.in_memory_registry["Registry.toml"])

            # the same tarball rewritten (new mtime): the index no longer matches and is rebuilt
            sleep(0.01); touch(tarball)
            _, vs3 = load_versions(desc)
            @test vs3 == vs
            @test read(idx) != before && is_entry(cache_files(depot), hash)

            # rewritten in place with the same size and a restored mtime: ctime still changes
            before = read(idx)
            mt = mtime(tarball)
            ref = tempname(); cp(tarball, ref); run(`touch -r $tarball $ref`)
            bytes = read(tarball)
            sleep(0.01)
            open(io -> write(io, bytes), tarball, "r+")
            run(`touch -m -r $ref $tarball`); rm(ref)
            @test mtime(tarball) == mt
            load_versions(desc)
            @test read(idx) != before

            # a truncated cache tar is not used when the index is read
            ctar = cached_tar(depot, hash)
            write(ctar, read(ctar)[1:100])
            reg4, vs4 = load_versions(desc)
            @test reg4.in_memory_registry isa R.RegistryTarIndex && vs4 == vs
            @test filesize(cached_tar(depot, hash)) > 100

            # a cache tar that fails after its index was read: the stock in-memory read
            empty!(R.REGISTRY_CACHE)
            reg5 = R.RegistryInstance(desc)
            reg5.name # loads Registry.toml through the index
            files = reg5.in_memory_registry
            R.close_registry_cache_streams!()
            rm(cached_tar(depot, hash))
            info = R.registry_info(reg5, reg5.pkgs[UUID(PKG_UUID)])
            @test sort!(collect(keys(info.version_info))) == vs
            @test files.fallback isa Dict{String, String}

            # an orphan tar generation (a build interrupted before its index was published)
            # is never read
            write(joinpath(cache_dir(depot), "$hash-orphan.tar"), "junk")
            _, vs6 = load_versions(desc)
            @test vs6 == vs
            rm(joinpath(cache_dir(depot), "$hash-orphan.tar"))

            # the registry changes (as after `Registry.update`): new tree hash, new entry,
            # the stale entry of the same tarball removed
            desc2, hash2 = write_compressed_registry(depot, ["1.0.0", "1.1.0", "2.0.0"])
            @test desc2 == desc && hash2 != hash
            _, vs7 = load_versions(desc)
            @test vs7 == [v"1.0.0", v"1.1.0", v"2.0.0"]
            @test is_entry(cache_files(depot), hash2)

            # an unwritable cache location falls back to the in-memory read
            R.close_registry_cache_streams!()
            empty!(DEPOT_PATH); push!(DEPOT_PATH, joinpath(depot, "registries", "Test.toml", "not-a-dir"))
            reg8, vs8 = load_versions(desc)
            @test reg8.in_memory_registry isa Dict{String, String} && vs8 == vs7
        end
    finally
        R.close_registry_cache_streams!()
        empty!(DEPOT_PATH); append!(DEPOT_PATH, old_depots)
        empty!(R.REGISTRY_CACHE)
        rm(depot; recursive = true, force = true)
    end
end

@testset "request driver" begin
    depot = mktempdir()
    proj = mktempdir()
    write(joinpath(proj, "Project.toml"), "")
    old = (copy(DEPOT_PATH), Base.ACTIVE_PROJECT[], Pkg.OFFLINE_MODE[])
    function request(text)
        req, res = tempname() * ".toml", tempname() * ".toml"
        write(req, text * """
            [session]
            active_project = "$(escape_string(joinpath(proj, "Project.toml")))"
            depot_path = ["$(escape_string(depot))"]
            offline = true
            """)
        rc = redirect_stdio(stdout = devnull, stderr = devnull) do
            Pkg.pkgwasm_main(["request", req, res])
        end
        return rc, TOML.parsefile(res)
    end
    try
        rc, r = request("function = \"status\"\n[kwargs]\nmode = \"PKGMODE_MANIFEST\"\ndiff = false\n")
        @test rc == 0 && r["status"] == "ok"
        @test r["session"]["offline"] == true
        @test Base.ACTIVE_PROJECT[] == joinpath(proj, "Project.toml")
        @test DEPOT_PATH == [depot]

        rc, r = request("function = \"status\"\n[kwargs]\nplatform = \"x86_64-linux-gnu\"\n")
        @test rc == 1 && r["status"] == "error" && r["error_type"] == "PkgError"
        @test occursin("unsupported keyword argument `platform` for status", r["message"])

        rc, r = request("function = \"develop\"\n")
        @test rc == 1 && r["error_type"] == "PkgError" && occursin("unsupported function `develop`", r["message"])

        rc, r = request("function = \"rm\"\n[[pkgs]]\nname = \"Nope\"\n")
        @test rc == 1 && r["error_type"] == "PkgError" && occursin("Nope", r["message"])

        rc, r = request("function = \"add\"\n[[pkgs]]\nname = \"Example\"\nversion_kind = \"spec\"\nversion = [\"0.5\"]\n[kwargs]\npreserve = \"PRESERVE_NONE\"\n")
        @test rc == 1 # offline, no registry in the depot

        @test Pkg.request_package(Dict{String, Any}("name" => "A", "version_kind" => "number", "version" => "1.2.3")).version == v"1.2.3"
        @test Pkg.request_package(Dict{String, Any}("name" => "A", "version_kind" => "spec", "version" => Any["0.5 - 0.7", "1.2"])).version ==
            Pkg.Types.VersionSpec(["0.5-0.7", "1.2"])
        @test Pkg.request_package(Dict{String, Any}("name" => "A", "version_kind" => "level", "version" => "UPLEVEL_MINOR")).version == Pkg.UPLEVEL_MINOR
        @test Pkg.request_package(Dict{String, Any}("name" => "A")).version == Pkg.Types.VersionSpec()

        # exception fields for rebuilding the error natively
        @test Pkg.request_error_fields(Base.IOError("boom", -17)) == ["msg" => "boom", "code" => -17]
        @test Pkg.request_error_fields(SystemError("open", 2)) == ["prefix" => "open", "errnum" => 2]
        @test Pkg.request_error_fields(Pkg.Host.HostError(29, "x")) == ["msg" => "x", "status" => 29]
        f = tempname()
        Pkg.write_request_result(f, "error", "IOError", "IOError: boom", Pkg.request_error_fields(Base.IOError("boom", -17)))
        @test TOML.parsefile(f)["error_fields"] == Dict("msg" => "boom", "code" => -17)

        # the result file is valid TOML for any message
        f = tempname()
        Pkg.write_request_result(f, "error", "PkgError", "a \"quoted\" \\ message\n\twith\u0001 control")
        @test TOML.parsefile(f)["message"] == "a \"quoted\" \\ message\n\twith\u0001 control"
    finally
        empty!(DEPOT_PATH); append!(DEPOT_PATH, old[1])
        Base.ACTIVE_PROJECT[] = old[2]
        Pkg.OFFLINE_MODE[] = old[3]
        rm(depot; recursive = true, force = true); rm(proj; recursive = true, force = true)
    end
end

@testset "Context! with several keywords" begin
    ctx = Pkg.Types.Context()
    Pkg.Types.Context!(ctx; julia_version = nothing, use_git_for_all_downloads = true)
    @test ctx.julia_version === nothing && ctx.use_git_for_all_downloads
    @test_throws FieldError Pkg.Types.Context!(ctx; no_such_field = 1)
end
