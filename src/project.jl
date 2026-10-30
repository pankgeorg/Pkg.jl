#########
# UTILS #
#########
listed_deps(project::Project; include_weak::Bool) =
    vcat(collect(keys(project.deps)), collect(keys(project.extras)), include_weak ? collect(keys(project.weakdeps)) : String[])

function get_path_repo(project::Project, project_file::String, manifest_file::String, name::String)
    source = get(project.sources, name, nothing)
    if source === nothing
        return nothing, GitRepo()
    end
    path = get(source, "path", nothing)::Union{String, Nothing}
    url = get(source, "url", nothing)::Union{String, Nothing}
    rev = get(source, "rev", nothing)::Union{String, Nothing}
    subdir = get(source, "subdir", nothing)::Union{String, Nothing}
    if path !== nothing && url !== nothing
        pkgerror("`path` and `url` are conflicting specifications")
    end
    repo = GitRepo(url, rev, subdir)
    # Convert path from project-relative to manifest-relative
    if path !== nothing
        path = project_path_to_manifest_path(project_file, manifest_file, path)
    end
    return path, repo
end

###########
# READING #
###########
read_project_uuid(::Nothing) = nothing
function read_project_uuid(uuid::String)
    try
        uuid = UUID(uuid)
    catch err
        err isa ArgumentError || rethrow()
        pkgerror("Could not parse project UUID as a UUID")
    end
    return uuid
end
read_project_uuid(uuid) = pkgerror("Expected project UUID to be a string")

read_project_version(::Nothing) = nothing
function read_project_version(version::String)
    return try
        version = VersionNumber(version)
    catch err
        err isa ArgumentError || rethrow()
        pkgerror("Could not parse project version as a version")
    end
end
read_project_version(version) = pkgerror("Expected project version to be a string")

read_project_deps(::Nothing, section::String) = Dict{String, UUID}()
function read_project_deps(raw::Dict{String, Any}, section_name::String)
    deps = Dict{String, UUID}()
    for (name, uuid) in raw
        try
            uuid = toml_uuid(uuid)
        catch err
            err isa ArgumentError || rethrow()
            pkgerror("Malformed value for `$name` in `$(section_name)` section.")
        end
        deps[name] = uuid
    end
    return deps
end
function read_project_deps(raw, section_name::String)
    pkgerror("Expected `$(section_name)` section to be a key-value list")
end

read_project_targets(::Nothing, project::Project) = Dict{String, Any}()
function read_project_targets(raw::Dict{String, Any}, project::Project)
    for (target, deps) in raw
        deps isa Vector{String} || pkgerror(
            """
                Expected value for target `$target` to be a list of dependency names.
            """
        )
    end
    return raw
end
read_project_targets(raw, project::Project) =
    pkgerror("Expected `targets` section to be a key-value list")

read_project_apps(::Nothing, project::Project) = Dict{String, Any}()
function read_project_apps(raw::Dict{String, Any}, project::Project)
    other = raw
    appinfos = Dict{String, AppInfo}()
    for (name, info) in raw
        info isa Dict{String, Any} || pkgerror(
            """
                Expected value for app `$name` to be a dictionary.
            """
        )
        submodule = toml_string_or_nothing(get(info, "submodule", nothing))
        julia_flags_raw = get(info, "julia_flags", nothing)
        julia_flags = if julia_flags_raw === nothing
            String[]
        elseif julia_flags_raw isa Vector
            toml_strings(julia_flags_raw)
        else
            pkgerror("Expected `julia_flags` for app `$name` to be an array of strings")
        end
        appinfos[name] = AppInfo(name, nothing, submodule, julia_flags, other)
    end
    return appinfos
end

read_project_compat(::Nothing, project::Project) = Dict{String, Compat}()
function read_project_compat(raw::Dict{String, Any}, project::Project)
    compat = Dict{String, Compat}()
    for (name, version) in raw
        version = version::String
        try
            compat[name] = Compat(semver_spec(version), version)
        catch err
            pkgerror("Could not parse compatibility version for dependency `$name`")
        end
    end
    return compat
end
read_project_compat(raw, project::Project) =
    pkgerror("Expected `compat` section to be a key-value list")

read_project_sources(::Nothing, project::Project) = Dict{String, Any}()
function read_project_sources(raw::Dict{String, Any}, project::Project)
    valid_keys = ("path", "url", "rev", "subdir")
    sources = Dict{String, Any}()
    for (name, source) in raw
        if !(source isa AbstractDict)
            pkgerror("Expected `source` section to be a table")
        end
        # (the table, told apart as a parsed TOML table: M4.2)
        sources[name] = with_toml_dict(source) do source
            for key in keys(source)
                key in valid_keys || pkgerror("Invalid key `$key` in `source` section")
            end
            if haskey(source, "path") && (haskey(source, "url") || haskey(source, "rev"))
                pkgerror("Both `path` and `url` or `rev` are specified in `source` section")
            end
            # (G3 row 47: built for Wasm the values are checked one by one; natively stock's
            # convert, including its MethodError for a non-String value)
            WASM_TARGET || return convert(Dict{String, String}, source)
            d = Dict{String, String}()
            for (k, v) in source
                v isa String || pkgerror("Expected `$k` in the `source` section of `$name` to be a string")
                d[k] = v
            end
            d
        end::Dict{String, String}
    end
    return sources
end

# `[extensions]`: natively stock's conversion to the field type (including its MethodError for an
# invalid value); built for Wasm each value checked as a String or a list of Strings (G3, wcg-event
# 04:14), a PkgError otherwise (stock accepts exactly String and Vector{String} values)
function read_project_exts(x)
    WASM_TARGET || return convert(Dict{String, Union{Vector{String}, String}}, x)
    x isa AbstractDict || pkgerror("Expected `extensions` section to be a table")
    exts = Dict{String, Union{Vector{String}, String}}()
    for (name, v) in x::Dict{String, Any}
        if v isa String
            exts[name] = v
        elseif v isa Vector{String}
            exts[name] = v
        else # (as stock's conversion: a Vector{Any}, even of Strings or empty, is rejected)
            pkgerror("Expected the value of `$name` in the `extensions` section to be a string or a list of strings")
        end
    end
    return exts
end

read_project_workspace(::Nothing, project::Project) = Dict{String, Any}()
function read_project_workspace(raw::Dict, project::Project)
    workspace_table = Dict{String, Any}()
    for (key, val) in raw
        if key == "projects"
            # (`for path in val`, over the parsed value's type: M4.2)
            toml_foreach(val) do path
                path isa String || pkgerror("Expected entry in `projects` to be strings")
            end
        else
            pkgerror("Invalid key `$key` in `workspace`")
        end
        workspace_table[key] = val
    end
    return workspace_table
end
read_project_workspace(raw, project::Project) =
    pkgerror("Expected `workspace` section to be a key-value list")


function validate(project::Project; file = nothing)
    # deps
    location_string = file === nothing ? "" : " at $(repr(file))."
    dep_uuids = collect(values(project.deps))
    if length(dep_uuids) != length(unique(dep_uuids))
        pkgerror("Two different dependencies can not have the same uuid" * location_string)
    end
    weak_dep_uuids = collect(values(project.weakdeps))
    if length(weak_dep_uuids) != length(unique(weak_dep_uuids))
        pkgerror("Two different weak dependencies can not have the same uuid" * location_string)
    end
    # extras
    extra_uuids = collect(values(project.extras))
    if length(extra_uuids) != length(unique(extra_uuids))
        pkgerror("Two different `extra` dependencies can not have the same uuid" * location_string)
    end
    # TODO decide what to do in when `add`ing a dep that is already in `extras`
    #   also, reintroduce test files for this
    #=
    dep_names = keys(project.deps)
    for (name, uuid) in project.extras
        name in dep_names && pkgerror("name `$name` is listed in both `deps` and `extras`")
        uuid in dep_uuids && pkgerror("uuid `$uuid` is listed in both `deps` and `extras`")
    end
    =#
    # targets
    listed = listed_deps(project; include_weak = true)
    for (target, deps) in project.targets, dep in deps
        if length(deps) != length(unique(deps))
            pkgerror("A dependency was named twice in target `$target`")
        end
        dep in listed || pkgerror(
            """
            Dependency `$dep` in target `$target` not listed in `deps`, `weakdeps` or `extras` section
            """ * location_string
        )
    end
    # compat
    for name in keys(project.compat)
        name == "julia" && continue
        name in listed ||
            pkgerror("Compat `$name` not listed in `deps`, `weakdeps` or `extras` section" * location_string)
    end
    # sources
    listed_nonweak = listed_deps(project; include_weak = false)
    for name in keys(project.sources)
        name in listed_nonweak ||
            pkgerror("Sources for `$name` not listed in `deps` or `extras` section" * location_string)
    end
    return
end

function Project(raw::Dict; file = nothing)
    project = Project()
    project.other = raw
    project.name = get(raw, "name", nothing)::Union{String, Nothing}
    project.manifest = get(raw, "manifest", nothing)::Union{String, Nothing}
    project.entryfile = get(raw, "path", nothing)::Union{String, Nothing}
    if project.entryfile === nothing
        project.entryfile = get(raw, "entryfile", nothing)::Union{String, Nothing}
    end
    project.uuid = with_toml_type(read_project_uuid, get(raw, "uuid", nothing))
    project.version = with_toml_type(read_project_version, get(raw, "version", nothing))
    project.deps = with_toml_type(x -> read_project_deps(x, "deps"), get(raw, "deps", nothing))
    project.weakdeps = with_toml_type(x -> read_project_deps(x, "weakdeps"), get(raw, "weakdeps", nothing))
    # (as `get(Dict{String, String}, raw, "extensions")`, converted to the field's type)
    project.exts = !haskey(raw, "extensions") ? Dict{String, String}() :
        with_toml_type(read_project_exts, raw["extensions"])
    project.sources = with_toml_type(x -> read_project_sources(x, project), get(raw, "sources", nothing))
    project.extras = with_toml_type(x -> read_project_deps(x, "extras"), get(raw, "extras", nothing))
    project.compat = with_toml_type(x -> read_project_compat(x, project), get(raw, "compat", nothing))
    project.targets = with_toml_type(x -> read_project_targets(x, project), get(raw, "targets", nothing))
    project.workspace = with_toml_type(x -> read_project_workspace(x, project), get(raw, "workspace", nothing))
    project.apps = with_toml_type(x -> read_project_apps(x, project), get(raw, "apps", nothing))

    # Handle deps in both [deps] and [weakdeps]
    project._deps_weak = Dict(intersect(project.deps, project.weakdeps))
    filter!(p -> !haskey(project._deps_weak, p.first), project.deps)
    validate(project; file)
    return project
end

function read_project(f_or_io::Union{String, IO})
    raw = try
        if f_or_io isa IO
            TOML.parse(read(f_or_io, String))
        else
            isfile(f_or_io) ? parse_toml(f_or_io) : return Project()
        end
    catch e
        # (typed: the parser error as such, any other through error_text; G3)
        if e isa TOML.ParserError
            pkgerror("Could not parse project: ", sprint(showerror, e::TOML.ParserError))
        end
        # (`$f_or_io` typed, G3: Base's default show of devnull, the only IO passed here besides
        # an IOBuffer of a git blob)
        what = !WASM_TARGET ? string(f_or_io) : f_or_io isa AbstractString ? String(f_or_io) :
            f_or_io isa Base.DevNull ? "Base.DevNull()" : f_or_io isa IOBuffer ? sprint(show, f_or_io::IOBuffer) : "(an IO)"
        pkgerror("Errored when reading $what, got: ", PkgWasm.error_text(e))
    end
    return Project(raw; file = f_or_io isa IO ? nothing : f_or_io)
end


###########
# WRITING #
###########
function destructure(project::Project)::Dict
    raw = WASM_TARGET ? snapshot_copy(project.other) : deepcopy(project.other)  # (typed built for Wasm: e2e B16)

    # sanity check for consistency between compat value and string representation
    for (name, compat) in project.compat
        if compat.val != semver_spec(compat.str)
            pkgerror("inconsistency between compat values and string representation")
        end
    end

    # if a field is set to its default value, don't include it in the write
    function entry!(key::String, src)
        should_delete(x::Dict) = isempty(x)
        should_delete(x) = x === nothing
        return should_delete(src) ? delete!(raw, key) : (raw[key] = src)
    end

    entry!("name", project.name)
    entry!("uuid", project.uuid)
    entry!("version", project.version)
    entry!("workspace", project.workspace)
    entry!("manifest", project.manifest)
    entry!("entryfile", project.entryfile)
    entry!("deps", merge(project.deps, project._deps_weak))
    entry!("weakdeps", project.weakdeps)

    # Normalize paths in sources to use forward slashes on Windows (matching Manifest.toml behavior)
    normalized_sources = project.sources
    if !isempty(project.sources)
        normalized_sources = Dict{String, Dict{String, String}}()
        for (name, source) in project.sources
            normalized_source = copy(source)
            path = get(source, "path", nothing)
            if path !== nothing
                normalized_source["path"] = normalize_path_for_toml(path)
            end
            normalized_sources[name] = normalized_source
        end
    end
    entry!("sources", normalized_sources)
    entry!("extras", project.extras)
    entry!("compat", Dict(name => x.str for (name, x) in project.compat))
    entry!("targets", project.targets)
    return raw
end

const _project_key_order = ["name", "uuid", "keywords", "license", "desc", "version", "workspace", "deps", "weakdeps", "sources", "extensions", "compat"]
project_key_order(key::String) =
    something(findfirst(x -> x == key, _project_key_order), length(_project_key_order) + 1)

function write_project(env::EnvCache)
    return write_project(env.project, env.project_file)
end
write_project(project::Project, project_file::AbstractString) =
    write_project(destructure(project), project_file)
function write_project(io::IO, project::Dict)
    inline_tables = Any[] # (compared by identity, as an IdSet)
    if haskey(project, "sources")
        # (the sources table, as destructure makes it or as parsed, told apart by type: M4.2)
        collect_sources!(sources) = for source in values(sources)
            source isa Dict || error("Expected `sources` to be a table")
            push!(inline_tables, source)
        end
        sources = project["sources"]
        if sources isa Dict{String, Dict{String, String}}
            collect_sources!(sources)
        elseif sources isa Dict{String, Any}
            collect_sources!(sources)
        elseif WASM_TARGET
            error("PkgWasm: unsupported sources table")
        else
            Base.inferencebarrier(collect_sources!)(sources)
        end
    end
    TOMLWriter.print(io, project; inline_tables, sorted = true, by = key -> (project_key_order(key), key)) do x
        x isa UUID || x isa VersionNumber || pkgerror("unhandled type `$(typeof(x))`")
        return string(x)
    end
    return nothing
end
function write_project(project::Dict, project_file::AbstractString)
    str = sprint(write_project, project)
    mkpath(dirname(project_file))
    return write(project_file, str)
end
