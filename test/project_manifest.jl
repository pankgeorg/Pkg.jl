module ProjectManifestTest

import ..Pkg # ensure we are using the correct Pkg
using Test, Pkg, UUIDs
using ..Utils

temp_pkg_dir() do project_path
    @testset "test Project.toml manifest" begin
        mktempdir() do dir
            path = copy_test_package(dir, "monorepo")
            cd(path) do
                with_current_env() do
                    Pkg.develop(path = "packages/B")
                end
            end
            # test subpackage instantiates/tests
            # the order of operations here is important
            # when we instantiate and dev a dependency to the C subpackage
            # the changes are being written to the monorepo/Manifest.toml
            # but are not "sticky" in that if we ran a resolve at the monorepo/
            # level, the C & D packages would be pruned since there's no direct
            # dependency at the monorepo project level yet, so we first build up
            # C's dependencies, then at the monorepo level, we need to dev C *first*
            # to make those Manifest changes "stick" before adding Test.
            cd(joinpath(dir, "monorepo", "packages", "C")) do
                with_current_env() do
                    Pkg.develop(path = "../D") # add unregistered local dependency
                    Pkg.test()
                end
            end
            m = Pkg.Types.read_manifest(joinpath(dir, "monorepo", "Manifest.toml"))
            @test haskey(m, UUID("dd0d8fba-d7c4-4f8e-a2bb-3a090b3e34f2")) # B subpackage
            @test haskey(m, UUID("4ee78ca3-4e78-462f-a078-747ed543fa86")) # C subpackage
            @test haskey(m, UUID("bf733257-898a-45a0-b2f2-c1c188bdd870")) # D subpackage, but no direct dependency
            pkgC = m[UUID("4ee78ca3-4e78-462f-a078-747ed543fa86")]
            @test haskey(pkgC.deps, "D")
            cd(joinpath(dir, "monorepo")) do
                with_current_env() do
                    Pkg.develop(path = "packages/C")
                    Pkg.add("Test")
                    Pkg.test()
                end
            end
            # now test removing a dependency from subpackage correctly updates root manifest
            cd(joinpath(dir, "monorepo", "packages", "C")) do
                with_current_env() do
                    Pkg.rm("D")
                    Pkg.test()
                end
            end
            m = Pkg.Types.read_manifest(joinpath(dir, "monorepo", "Manifest.toml"))
            # currently, we don't prune dependencies from the root manifest since when rm-ing a dep
            # in a subpackage, we don't also do a full resolve at the root level
            # https://github.com/JuliaLang/Pkg.jl/issues/3590
            @test_broken !haskey(m, UUID("bf733257-898a-45a0-b2f2-c1c188bdd870")) # D subpackage, but no direct dependency
            pkgC = m[UUID("4ee78ca3-4e78-462f-a078-747ed543fa86")]
            @test !haskey(pkgC.deps, "D")
        end
    end
end

@testset "typed copies and `==` of projects, manifests and package specs" begin
    # `deepcopy` and a `==` over `fieldnames` go through fields of `Union` types with calls
    # dispatched at run time, which ahead-of-time compilation without Julia's runtime (e.g.
    # `juliac --trim`) cannot handle; the typed copies and `==` name each field.
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
    for (f, types) in (
            (Types.copy_project, (Types.Project,)), (Types.copy_manifest, (Types.Manifest,)), (Types.copy_packagespec, (Types.PackageSpec,)),
            (==, (Types.Project, Types.Project)), (==, (Types.Manifest, Types.Manifest)), (==, (Types.PackageEntry, Types.PackageEntry)),
            (==, (Types.PackageSpec, Types.PackageSpec)), (deepcopy, (Vector{Types.PackageSpec},)),
        )
        @test isempty(dynamic_calls(f, types))
    end

    project = Types.read_project(joinpath(pkgdir(Pkg), "test", "project", "good", "pkg.toml"))
    project.sources["Example"] = Dict("path" => "x")
    project.workspace["projects"] = ["test"]
    manifest = Types.read_manifest(joinpath(pkgdir(Pkg), "test", "manifest", "good", "withversion.toml"))
    spec = Pkg.PackageSpec(name = "Example", version = Types.VersionSpec("1"), repo = Types.GitRepo(source = "https://x"))
    @test project.name !== nothing && length(manifest.deps) == 2
    # the copies are equal and share no mutable part but strings (as with `deepcopy`)
    function shares_nothing(a, b)
        for f in fieldnames(typeof(a))
            x, y = getfield(a, f), getfield(b, f)
            ismutable(x) && !(x isa String) && x === y && return false
            x isa AbstractDict && any(k -> ismutable(x[k]) && !(x[k] isa String) && x[k] === y[k], keys(x)) && return false
        end
        return true
    end
    for (x, copier) in ((project, Types.copy_project), (manifest, Types.copy_manifest), (spec, Types.copy_packagespec))
        c = copier(x)
        @test c == x
        @test c == deepcopy(x)
        @test shares_nothing(c, x)
    end
    specs = deepcopy([spec, spec])
    @test specs == [spec, spec] && specs[1] === specs[2] && shares_nothing(specs[1], spec)
    for (uuid, entry) in manifest
        @test shares_nothing(Types.copy_entry(entry), entry)
    end

    # `==` tells apart a change of each field (but `comments`)
    uuid = UUID("7876af07-990d-54b4-ab0e-23690620f79a")
    project_changes = Dict{Symbol, Function}(
        :other => p -> (p.other["x"] = 1), :name => p -> (p.name = "Other"), :uuid => p -> (p.uuid = uuid),
        :version => p -> (p.version = v"9.9.9"), :manifest => p -> (p.manifest = "M.toml"),
        :entryfile => p -> (p.entryfile = "e.jl"), :julia_syntax_version => p -> (p.julia_syntax_version = v"1.99"),
        :deps => p -> (p.deps["Z"] = uuid), :_deps_weak => p -> (p._deps_weak["Z"] = uuid),
        :weakdeps => p -> (p.weakdeps["Z"] = uuid), :exts => p -> (p.exts["E"] = "Z"),
        :extras => p -> (p.extras["Z"] = uuid), :targets => p -> (p.targets["t"] = ["Z"]),
        :apps => p -> (p.apps["a"] = Types.AppInfo("a", nothing, nothing, String[], Dict{String, Any}())),
        :compat => p -> (p.compat["Z"] = Types.Compat(Types.semver_spec("1"), "1")),
        :compat_overrides => p -> (p.compat_overrides["Z"] = Types.Compat(Types.semver_spec("1"), "1")),
        :sources => p -> (p.sources["Z"] = Dict("path" => "z")), :workspace => p -> (p.workspace["projects"] = ["z"]),
        :readonly => p -> (p.readonly = !p.readonly),
    )
    @test Set(keys(project_changes)) == setdiff(Set(fieldnames(Types.Project)), [:comments])
    for (field, change!) in project_changes
        c = Types.copy_project(project)
        change!(c)
        @test c != project
    end
    manifest_changes = Dict{Symbol, Function}(
        :julia_version => m -> (m.julia_version = v"0.1"), :project_hash => m -> (m.project_hash = Base.SHA1(zeros(UInt8, 20))),
        :environment_id => m -> (m.environment_id = uuid), :environment_name => m -> (m.environment_name = "env"),
        :manifest_format => m -> (m.manifest_format = v"9.0.0"), :deps => m -> empty!(m.deps),
        :registries => m -> (m.registries["r"] = Types.ManifestRegistryEntry("r", uuid, nothing)),
        :other => m -> (m.other["x"] = 1),
    )
    @test Set(keys(manifest_changes)) == Set(fieldnames(Types.Manifest))
    for (field, change!) in manifest_changes
        c = Types.copy_manifest(manifest)
        change!(c)
        @test c != manifest
    end
    @test Types.toml_eq(Dict{String, Any}("a" => Any[1, "b", Dict{String, Any}("c" => 2.0)]), Dict{String, Any}("a" => Any[1, "b", Dict{String, Any}("c" => 2)]))
    @test !Types.toml_eq(Dict{String, Any}("a" => ["b"]), Dict{String, Any}("a" => ["c"]))
    @test Types.version_eq(Types.VersionSpec("1"), Types.VersionSpec("1")) && !Types.version_eq(v"1.0.0", Types.VersionSpec("1"))
end

end # module
