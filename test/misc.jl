module PkgMisc
using ..Pkg
using Test

@testset "inference" begin
    f1() = Pkg.Types.STDLIBS_BY_VERSION
    @inferred f1()
    f2() = Pkg.Types.UNREGISTERED_STDLIBS
    @inferred f2()
end

@testset "hashing" begin
    @test hash(Pkg.Types.Project()) == hash(Pkg.Types.Project())
    @test hash(Pkg.Types.VersionBound()) == hash(Pkg.Types.VersionBound())
    @test hash(Pkg.Resolve.Fixed(VersionNumber(0, 1, 0))) == hash(Pkg.Resolve.Fixed(VersionNumber(0, 1, 0)))

    hash(Pkg.Types.VersionSpec()) # hash isn't stable
    hash(Pkg.Types.PackageEntry()) # hash isn't stable because the internal `repo` field is a mutable struct
end

@testset "safe_realpath" begin
    realpath(Sys.BINDIR) == Pkg.safe_realpath(Sys.BINDIR)
    # issue #3085
    for p in ("", "some-non-existing-path", "some-non-existing-drive:")
        @test p == Pkg.safe_realpath(p)
    end
end

@testset "normalize_path_for_toml" begin
    # Test that relative paths with backslashes are normalized to forward slashes on Windows
    # and left unchanged on other platforms
    if Sys.iswindows()
        @test Pkg.normalize_path_for_toml("foo\\bar\\baz") == "foo/bar/baz"
        @test Pkg.normalize_path_for_toml("..\\parent\\dir") == "../parent/dir"
        @test Pkg.normalize_path_for_toml(".\\current") == "./current"
        # Absolute paths should not be normalized (they're platform-specific)
        @test Pkg.normalize_path_for_toml("C:\\absolute\\path") == "C:\\absolute\\path"
        @test Pkg.normalize_path_for_toml("\\\\network\\share") == "\\\\network\\share"
    else
        # On Unix-like systems, paths should be unchanged
        @test Pkg.normalize_path_for_toml("foo/bar/baz") == "foo/bar/baz"
        @test Pkg.normalize_path_for_toml("../parent/dir") == "../parent/dir"
        @test Pkg.normalize_path_for_toml("./current") == "./current"
        @test Pkg.normalize_path_for_toml("/absolute/path") == "/absolute/path"
    end
end

@test eltype([PackageSpec(a) for a in []]) == PackageSpec

@testset "PackageSpec version default" begin
    # Test that PackageSpec without explicit version gets set to VersionSpec("*")
    # This behavior is relied upon by BinaryBuilderBase.jl for dependency filtering
    # See: https://github.com/JuliaPackaging/BinaryBuilderBase.jl/blob/master/src/Prefix.jl
    ps = PackageSpec(name = "Example")
    @test ps.version == Pkg.Types.VersionSpec("*")

    # Test with UUID as well
    ps_uuid = PackageSpec(name = "Example", uuid = Base.UUID("7876af07-990d-54b4-ab0e-23690620f79a"))
    @test ps_uuid.version == Pkg.Types.VersionSpec("*")

    # Test that explicitly set version is preserved
    ps_versioned = PackageSpec(name = "Example", version = v"1.0.0")
    @test ps_versioned.version == v"1.0.0"

    # Test that explicitly set versionspec (string format) is preserved
    ps_versioned = PackageSpec(name = "Example", version = "1.0.0")
    @test ps_versioned.version == "1.0.0"
end

@testset "atomic_toml_write" begin
    mktempdir() do dir
        path = joinpath(dir, "Foo.toml")
        Pkg.atomic_toml_write(path, Dict("a" => "b"))
        @test Pkg.TOML.parsefile(path) == Dict("a" => "b")
        # no temporary files or directories are left behind
        @test readdir(dir) == ["Foo.toml"]

        # files are written with the default permissions of the process, not with
        # `mktemp`'s 0o600, since e.g. registry files may need to be readable by others
        reference = joinpath(dir, "reference")
        close(open(reference, "w"))
        @test filemode(path) & 0o777 == filemode(reference) & 0o777

        private_path = joinpath(dir, "Private.toml")
        Pkg.atomic_toml_write(private_path, Dict("a" => "b"), private = true)
        # Windows has no real file modes, `chmod` there only toggles the read-only bit
        if !Sys.iswindows()
            @test filemode(private_path) & 0o777 == 0o600

            # the permissions of an existing file are preserved
            chmod(path, 0o664)
            Pkg.atomic_toml_write(path, Dict("a" => "c"))
            @test filemode(path) & 0o777 == 0o664
            @test Pkg.TOML.parsefile(path) == Dict("a" => "c")
        end
    end
end

@testset "is_local_repo" begin
    is_local_repo = Pkg.GitTools.is_local_repo

    @test is_local_repo(@__DIR__)
    @test is_local_repo("file:///tmp/some/repo")

    @test !is_local_repo("https://github.com/JuliaLang/Pkg.jl")
    @test !is_local_repo("git@github.com:JuliaLang/Pkg.jl.git")

    # Longer than PATH_MAX: must answer, not raise
    @test !is_local_repo("https://user:" * "x"^5000 * "@example.com/repo.git")
end

@testset "closures capture concretely typed values" begin
    # A closure's type has a parameter for each captured variable, so when a captured variable
    # is not concretely inferred (e.g. a `Union`) the closure's type can only be computed at
    # run time, which ahead-of-time compilation (e.g. `juliac --trim`) cannot do.
    function closures_built_at_runtime(@nospecialize(f), argtypes::Tuple, kwargtypes::Tuple = ())
        tt = if isempty(kwargtypes)
            Tuple{typeof(f), argtypes...}
        else
            Tuple{typeof(Base.bodyfunction(which(f, argtypes))), kwargtypes..., typeof(f), argtypes...}
        end
        types = Any[]
        for (ci, _) in Base.code_typed_by_type(tt; optimize = false)
            for stmt in ci.code
                Meta.isexpr(stmt, :(=)) && (stmt = stmt.args[2])
                Meta.isexpr(stmt, :new) || continue
                T = stmt.args[1]
                T isa Core.SSAValue && !(ci.ssavaluetypes[T.id] isa Core.Const) && push!(types, ci.ssavaluetypes[T.id])
            end
        end
        return types
    end
    Ops = Pkg.Operations
    Context, PackageSpec = Pkg.Types.Context, Pkg.Types.PackageSpec
    Platform = Base.BinaryPlatforms.Platform
    @test isempty(closures_built_at_runtime(Pkg.Resolve.build_eq_classes1!, (Pkg.Resolve.Graph, Int, BitMatrix, Vector{BitVector})))
    @test isempty(closures_built_at_runtime(Pkg.Types.handle_repo_add!, (Context, PackageSpec)))
    @test isempty(closures_built_at_runtime(Ops.download_source, (Context, Vector{PackageSpec}), (Bool,)))
    @test isempty(closures_built_at_runtime(Ops.add, (Context, Vector{PackageSpec}, Set{Base.UUID}), (Bool, Pkg.Types.PreserveLevel, Platform, Symbol, Bool)))
    @test isempty(closures_built_at_runtime(Ops.print_compat, (Context, Vector{PackageSpec}), (Nothing,)))
    @test isempty(closures_built_at_runtime(Ops.sandbox, (typeof(identity), Context, PackageSpec, String, Nothing), (Nothing, Bool, Bool, Bool)))
    @test isempty(closures_built_at_runtime(Pkg.PlatformEngines.download, (String, String), (Bool, Vector{Pair{String, String}}, Nothing, IOContext{IO}, Nothing)))
end

@testset "TOML data is read and written with static calls" begin
    # The values of a parsed TOML table are untyped. A call on such a value must check its
    # type first, or the callee is only known at run time, which ahead-of-time compilation
    # without Julia's runtime (e.g. `juliac --trim`) cannot handle.
    # Returns the calls in the code of `f` for argument types `types` (and keyword argument
    # types `kwtypes`, a `NamedTuple` type) that are dispatched at run time. The closures and
    # keyword-argument bodies of `f` are included: those it calls, and the ones without
    # arguments that it creates, e.g. for tasks, up to `maxdepth` levels.
    function dynamic_calls(@nospecialize(f), @nospecialize(types); kwtypes = nothing, maxdepth = 10)
        fname = String(nameof(f))
        ofname(@nospecialize(T)) = (T = Base.unwrap_unionall(T); T isa DataType && occursin(fname, String(T.name.name)))
        calls = String[]
        seen = Set{Any}()
        function visit(@nospecialize(tt), depth = 0)
            (tt in seen || depth > maxdepth) && return
            push!(seen, tt)
            for (ci, _) in Base.code_typed_by_type(tt; optimize = true)
                ci isa Core.CodeInfo || continue
                for stmt in ci.code
                    Meta.isexpr(stmt, :(=)) && (stmt = stmt.args[2])
                    if Meta.isexpr(stmt, :invoke)
                        mi = stmt.args[1]
                        mi isa Core.CodeInstance && (mi = mi.def)
                        isdefined(Core, :ABIOverride) && mi isa Core.ABIOverride && (mi = mi.def)
                        m = mi.def
                        if m isa Method && startswith(String(m.name), "#") && occursin(fname, String(m.name))
                            visit(mi.specTypes, depth + 1)
                        end
                        continue
                    elseif Meta.isexpr(stmt, :new)
                        T = stmt.args[1]
                        T isa Core.SSAValue && (T = ci.ssavaluetypes[T.id])
                        T isa Core.Const && (T = T.val)
                        T isa Type && T <: Function && ofname(T) && visit(Tuple{T}, depth + 1)
                        continue
                    end
                    Meta.isexpr(stmt, :call) || continue
                    callee = stmt.args[1]
                    ft = if callee isa GlobalRef
                        isdefined(callee.mod, callee.name) ? Core.Typeof(getglobal(callee.mod, callee.name)) : Any
                    elseif callee isa QuoteNode
                        Core.Typeof(callee.value)
                    elseif callee isa Core.SSAValue
                        Core.Compiler.widenconst(ci.ssavaluetypes[callee.id])
                    elseif callee isa Core.Argument
                        Core.Compiler.widenconst(ci.slottypes[callee.n])
                    elseif isdefined(Core, :BindingPartition) && callee isa Core.BindingPartition
                        Core.Typeof(callee.restriction)
                    else
                        Core.Typeof(callee)
                    end
                    # a builtin is called directly, unless it applies a function to splatted arguments
                    ft <: Core.Builtin && !(ft <: typeof(Core._apply_iterate)) && continue
                    push!(calls, string(stmt))
                end
            end
            return
        end
        visit(kwtypes === nothing ? Tuple{Core.Typeof(f), types...} : Tuple{typeof(Core.kwcall), kwtypes, Core.Typeof(f), types...})
        return calls
    end
    Types = Pkg.Types
    @test isempty(dynamic_calls(Types.Project, (Dict{String, Any},)))
    @test isempty(dynamic_calls(Types.Project, (Dict{String, Any},); kwtypes = @NamedTuple{file::String}))
    for reader in (Types.read_project_targets, Types.read_project_apps, Types.read_project_sources, Types.read_project_workspace)
        @test isempty(dynamic_calls(reader, (Any, Types.Project)))
    end
    @test isempty(dynamic_calls(Types.read_project_deps, (Any, String)))
    @test isempty(dynamic_calls(Types.read_project_exts, (Any,)))
    @test isempty(dynamic_calls(Types.destructure, (Types.Manifest,)))
    @test isempty(dynamic_calls(Types.write_project, (IOBuffer, Dict{String, Any})))
    @test isempty(dynamic_calls(Types.latest_usage_time, (Any, String, String)))
    @test isempty(dynamic_calls(Pkg.Operations.check_artifacts_downloaded, (String,)))

    # the checks keep the behavior for well-formed and malformed values
    read_toml(toml) = Types.read_project(IOBuffer(toml))
    uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
    p = read_toml(
        """
        name = "A"
        uuid = "$uuid"
        version = "1.2.3"
        [deps]
        Example = "$uuid"
        [weakdeps]
        [extensions]
        ExtA = "Example"
        ExtB = ["Example"]
        ExtC = []
        [sources]
        Example = {url = "https://example.com/Example.jl", rev = "main"}
        [workspace]
        projects = ["test"]
        [apps.a]
        julia_flags = ["--threads=2"]
        """
    )
    @test p.uuid == Base.UUID(uuid)
    @test p.version == v"1.2.3"
    @test p.deps == Dict("Example" => Base.UUID(uuid))
    @test p.exts == Dict("ExtA" => "Example", "ExtB" => ["Example"], "ExtC" => String[])
    @test p.sources == Dict("Example" => Dict("url" => "https://example.com/Example.jl", "rev" => "main"))
    @test p.workspace == Dict("projects" => ["test"])
    @test p.apps["a"].julia_flags == ["--threads=2"]
    @test_throws Types.PkgError read_toml("uuid = 1")
    @test_throws Types.PkgError read_toml("version = 1")
    @test_throws Types.PkgError read_toml("deps = 1")
    @test_throws Types.PkgError read_toml("[deps]\nExample = 1")
    @test_throws Types.PkgError read_toml("[extensions]\nExtA = 1")
    @test_throws Types.PkgError read_toml("[sources]\nExample = {rev = 1}")
    @test_throws Types.PkgError read_toml("[workspace]\nprojects = [1]")
    @test_throws Types.PkgError read_toml("[apps.a]\nsubmodule = 1")

    # the latest usage time is kept, and an entry without one counts as used now
    t1, t2 = Types.Dates.DateTime(2020), Types.Dates.DateTime(2021)
    @test Types.latest_usage_time(Any[Dict{String, Any}("time" => t1), Dict{String, Any}("time" => t2)], "", "") == t2
    @test Types.latest_usage_time(Any[Dict{String, Any}()], "", "") > t2
    @test Types.latest_usage_time("not a list", "", "") > t2
end

end # module
