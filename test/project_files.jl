module ProjectFilesTests

using Test, UUIDs, Dates
import ..Pkg
using Pkg.Types: PkgError
using ..Utils

@testset "generate" begin
    # Test generate . (issue #2821)
    isolate(loaded_depot = true) do
        cd_tempdir() do dir
            mkdir("MyNewPkg")
            cd("MyNewPkg") do
                Pkg.generate(".")
                @test isfile("Project.toml")
                @test isfile("src/MyNewPkg.jl")
                @test Pkg.Types.read_project("Project.toml").name == "MyNewPkg"
            end

            mkdir("NonEmpty")
            write("NonEmpty/existing.txt", "content")
            cd("NonEmpty") do
                @test_throws Pkg.Types.PkgError Pkg.generate(".")
            end
        end
    end
end

@testset "project files" begin
    # reading corrupted project files
    isolate(loaded_depot = true) do
        dir = joinpath(@__DIR__, "project", "bad")
        for bad_project in joinpath.(dir, readdir(dir))
            @test_throws PkgError Pkg.Types.read_project(bad_project)
        end
    end
    # reading corrupted manifest files
    isolate(loaded_depot = true) do
        dir = joinpath(@__DIR__, "manifest", "bad")
        for bad_manifest in joinpath.(dir, readdir(dir))
            @test_throws PkgError Pkg.Types.read_manifest(bad_manifest)
        end
    end
    # pruning manifest
    dir = joinpath(@__DIR__, "manifest", "unpruned")
    isolate(loaded_depot = true) do
        mktempdir() do tmp
            cp(dir, joinpath(tmp, "unpruned"))
            Pkg.activate(joinpath(tmp, "unpruned"))
            Pkg.resolve()
            @test !occursin("Crayons", read(joinpath(tmp, "unpruned", "Manifest.toml"), String))
        end
    end
    # manifest read/write
    isolate() do # TODO rewrite using IOBuffer
        manifestdir = joinpath(@__DIR__, "manifest", "good")
        temp = joinpath(mktempdir(), "x.toml")
        for testfile in joinpath.(manifestdir, readdir(manifestdir))
            a = Pkg.Types.read_manifest(testfile)
            Pkg.Types.write_manifest(a, temp)
            b = Pkg.Types.read_manifest(temp)
            for (uuid, x) in a
                y = b[uuid]
                for property in propertynames(x)
                    # `other` caches the *whole* input dictionary. its ok to mutate the fields of
                    # the input dictionary if that field will eventually be overwritten on `write_manifest`
                    property == :other && continue
                    @test getproperty(x, property) == getproperty(y, property)
                end
            end
        end
        rm(dirname(temp); recursive = true, force = true)
    end
    # project read/write
    isolate() do
        projectdir = joinpath(@__DIR__, "project", "good")
        temp = joinpath(mktempdir(), "x.toml")
        for testfile in joinpath.(projectdir, readdir(projectdir))
            a = Pkg.Types.read_project(testfile)
            Pkg.Types.write_project(a, temp)
            b = Pkg.Types.read_project(temp)
            for property in propertynames(a)
                @testset let property = property
                    @test getproperty(a, property) == getproperty(b, property)
                end
            end
            @test a == b
        end
        rm(dirname(temp); recursive = true, force = true)
    end
    # canonicalized relative paths in manifest
    isolate() do
        mktempdir() do tmp
            cd(tmp) do
                write(
                    "Manifest.toml",
                    """
                    [[Foo]]
                    path = "bar/Foo"
                    uuid = "824dc81a-29a7-11e9-3958-fba342a32644"
                    version = "0.1.0"
                    """
                )
                manifest = Pkg.Types.read_manifest("Manifest.toml")
                package = manifest[Base.UUID("824dc81a-29a7-11e9-3958-fba342a32644")]
                @test package.path == (Sys.iswindows() ? "bar\\Foo" : "bar/Foo")
                Pkg.Types.write_manifest(manifest, "Manifest.toml")
                @test occursin("path = \"bar/Foo\"", read("Manifest.toml", String))
            end
        end
    end
    # create manifest file similar to project file
    isolate(loaded_depot = true) do
        cd_tempdir() do dir
            touch(joinpath(dir, "Project.toml"))
            Pkg.activate(".")
            Pkg.add("Example")
            @test isfile(joinpath(dir, "Manifest.toml"))
            @test !isfile(joinpath(dir, "JuliaManifest.toml"))
        end
        cd_tempdir() do dir
            touch(joinpath(dir, "JuliaProject.toml"))
            Pkg.activate(".")
            Pkg.add("Example")
            @test !isfile(joinpath(dir, "Manifest.toml"))
            @test isfile(joinpath(dir, "JuliaManifest.toml"))
        end
    end
end

temp_pkg_dir() do project_path
    @testset "test entryfile entries" begin
        mktempdir() do dir
            path = copy_test_package(dir, "ProjectPath")
            cd(path) do
                with_current_env() do
                    Pkg.resolve()
                    # no Pkg code runs in the subprocesses, so don't inherit coverage
                    julia = `$(Base.julia_cmd()) --startup-file=no --code-coverage=none`
                    @test success(run(`$(julia) --project -e 'using ProjectPath'`))
                    @test success(run(`$(julia) --project -e 'using ProjectPathDep'`))
                end
            end
        end
    end
end

temp_pkg_dir() do project_path
    @testset "valid project file names" begin
        extract_uuid(toml_path) = begin
            uuid = ""
            for line in eachline(toml_path)
                m = match(r"uuid = \"(.+)\"", line)
                if m !== nothing
                    uuid = m.captures[1]
                    break
                end
            end
            return uuid
        end

        cd(project_path) do
            target_dir = mktempdir()
            uuid = nothing
            mktempdir() do tmp
                cd(tmp) do
                    pkg_name = "FooBar"
                    # create a project and grab its uuid
                    Pkg.generate(pkg_name)
                    uuid = extract_uuid(joinpath(pkg_name, "Project.toml"))
                    # activate project env
                    Pkg.activate(abspath(pkg_name))
                    # add an example project to populate manifest file
                    Pkg.add("Example")
                    # change away from default names
                    ## note: this is written awkwardly because a `mv` here causes failures on AppVeyor
                    cp(joinpath(pkg_name, "src"), joinpath(target_dir, "src"))
                    cp(joinpath(pkg_name, "Project.toml"), joinpath(target_dir, "JuliaProject.toml"))
                    cp(joinpath(pkg_name, "Manifest.toml"), joinpath(target_dir, "JuliaManifest.toml"))
                end
            end
            Pkg.activate()
            # make sure things still work
            Pkg.REPLMode.pkgstr("dev $target_dir")
            @test isinstalled((name = "FooBar", uuid = UUID(uuid)))
            Pkg.rm("FooBar")
            @test !isinstalled((name = "FooBar", uuid = UUID(uuid)))
        end # cd project_path
    end # @testset
end
#issue #876
@testset "targets should survive add/rm" begin
    temp_pkg_dir() do project_path
        cd_tempdir() do tmpdir
            cp(joinpath(@__DIR__, "project", "good", "pkg.toml"), "Project.toml")
            mkdir("src")
            touch("src/Pkg.jl")
            targets = deepcopy(Pkg.Types.read_project("Project.toml").targets)
            Pkg.activate(".")
            Pkg.add("Example")
            Pkg.rm("Example")
            @test targets == Pkg.Types.read_project("Project.toml").targets
        end
    end
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
    @test isempty(dynamic_calls(Types.parse_project, (Dict{String, Any}, Nothing)))
    @test isempty(dynamic_calls(Types.parse_project, (Dict{String, Any}, String)))
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
    @test p.uuid == UUID(uuid)
    @test p.version == v"1.2.3"
    @test p.deps == Dict("Example" => UUID(uuid))
    @test p.exts == Dict("ExtA" => "Example", "ExtB" => ["Example"], "ExtC" => String[])
    @test p.sources == Dict("Example" => Dict("url" => "https://example.com/Example.jl", "rev" => "main"))
    @test p.workspace == Dict("projects" => ["test"])
    @test p.apps["a"].julia_flags == ["--threads=2"]
    @test_throws PkgError read_toml("uuid = 1")
    @test_throws PkgError read_toml("version = 1")
    @test_throws PkgError read_toml("deps = 1")
    @test_throws PkgError read_toml("[deps]\nExample = 1")
    @test_throws PkgError read_toml("[extensions]\nExtA = 1")
    @test_throws PkgError read_toml("[sources]\nExample = {rev = 1}")
    @test_throws PkgError read_toml("[workspace]\nprojects = [1]")
    @test_throws PkgError read_toml("[apps.a]\nsubmodule = 1")

    # the latest usage time is kept, and an entry without one counts as used now
    t1, t2 = DateTime(2020), DateTime(2021)
    @test Types.latest_usage_time(Any[Dict{String, Any}("time" => t1), Dict{String, Any}("time" => t2)], "", "") == t2
    @test Types.latest_usage_time(Any[Dict{String, Any}()], "", "") > t2
    @test Types.latest_usage_time("not a list", "", "") > t2
end

end # module
