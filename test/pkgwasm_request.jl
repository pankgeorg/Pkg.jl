# This file is a part of Julia. License is MIT: https://julialang.org/license

# PkgWasm: the request driver (wasm_request.jl), natively.

using Test, TOML, Tar, UUIDs
import PkgWasm
const R = PkgWasm.Registry

const REG_UUID = "aaaaaaaa-0000-4000-8000-000000000001"
const PKG_UUID = "aaaaaaaa-0000-4000-8000-000000000002"

@testset "request driver" begin
    depot = mktempdir()
    proj = mktempdir()
    write(joinpath(proj, "Project.toml"), "")
    old = (copy(DEPOT_PATH), Base.ACTIVE_PROJECT[], PkgWasm.OFFLINE_MODE[])
    function request(text)
        req, res = tempname() * ".toml", tempname() * ".toml"
        write(req, text * """
            [session]
            active_project = "$(escape_string(joinpath(proj, "Project.toml")))"
            depot_path = ["$(escape_string(depot))"]
            offline = true
            """)
        rc = redirect_stdio(stdout = devnull, stderr = devnull) do
            PkgWasm.pkgwasm_main(["request", req, res])
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

        @test PkgWasm.request_package(Dict{String, Any}("name" => "A", "version_kind" => "number", "version" => "1.2.3")).version == v"1.2.3"
        @test PkgWasm.request_package(Dict{String, Any}("name" => "A", "version_kind" => "spec", "version" => Any["0.5 - 0.7", "1.2"])).version ==
            PkgWasm.Types.VersionSpec(["0.5-0.7", "1.2"])
        @test PkgWasm.request_package(Dict{String, Any}("name" => "A", "version_kind" => "level", "version" => "UPLEVEL_MINOR")).version == PkgWasm.UPLEVEL_MINOR
        @test PkgWasm.request_package(Dict{String, Any}("name" => "A")).version == PkgWasm.Types.VersionSpec()

        # exception fields for rebuilding the error natively
        @test PkgWasm.request_error_fields(Base.IOError("boom", -17)) == ["msg" => "boom", "code" => -17]
        @test PkgWasm.request_error_fields(SystemError("open", 2)) == ["prefix" => "open", "errnum" => 2]
        @test PkgWasm.request_error_fields(PkgWasm.Host.HostError(29, "x")) == ["msg" => "x", "status" => 29]
        f = tempname()
        PkgWasm.write_request_result(f, "error", "IOError", "IOError: boom", PkgWasm.request_error_fields(Base.IOError("boom", -17)))
        @test TOML.parsefile(f)["error_fields"] == Dict("msg" => "boom", "code" => -17)

        # the result file is valid TOML for any message
        f = tempname()
        PkgWasm.write_request_result(f, "error", "PkgError", "a \"quoted\" \\ message\n\twith\u0001 control")
        @test TOML.parsefile(f)["message"] == "a \"quoted\" \\ message\n\twith\u0001 control"
    finally
        empty!(DEPOT_PATH); append!(DEPOT_PATH, old[1])
        Base.ACTIVE_PROJECT[] = old[2]
        PkgWasm.OFFLINE_MODE[] = old[3]
        rm(depot; recursive = true, force = true); rm(proj; recursive = true, force = true)
    end
end

@testset "Context! with several keywords" begin
    ctx = PkgWasm.Types.Context()
    PkgWasm.Types.Context!(ctx; julia_version = nothing, use_git_for_all_downloads = true)
    @test ctx.julia_version === nothing && ctx.use_git_for_all_downloads
    @test_throws FieldError PkgWasm.Types.Context!(ctx; no_such_field = 1)
end
