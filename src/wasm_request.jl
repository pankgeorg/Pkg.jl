# PkgWasm request driver: one Pkg API call described in a TOML file (lane t2-wasm).
#
#   pkgwasm request <request.toml> <result.toml>
#
# The CLI commands of wasm_entry.jl take package names only. A request carries a full API call,
# as a native caller made it, so the stock Pkg test files can run each of their API calls in
# the Wasm module (runner/t2): the function, its PackageSpecs or RegistrySpecs, its keyword
# arguments, and the Pkg/Base session state the call depends on. No ABI change: it is read
# through ARGS and the preopened filesystem like any other command.
#
#   function = "add"   # add, rm, resolve, instantiate, status, update,
#                      # registry.add, registry.rm, registry.update, registry.status
#   [session]          # all optional; absent keys keep this session's defaults
#   active_project = "/abs/Project.toml"     # Base.ACTIVE_PROJECT[]; "" = nothing
#   depot_path = ["/abs/depot", ...]         # DEPOT_PATH
#   load_path = ["@", "@v#.#", "@stdlib"]    # LOAD_PATH
#   offline = false                          # Pkg.offline()
#   updated_registry_this_session = false
#   respect_sysimage_versions = true
#   [[session.default_registries]]           # Registry.DEFAULT_REGISTRIES (replaced)
#   name = "General"; uuid = "..."; url = "..."; path = "..."; linked = true
#   [[pkgs]]                                 # PackageSpecs (or RegistrySpecs for registry.*)
#   name = "Example"; uuid = "..."; url = ...; rev = ...; path = ...; subdir = ...
#   tree_hash = "..."; pinned = false
#   version = "=0.5.1"                       # with version_kind = "number" | "spec" (a list
#                                            # of VersionRange strings) | "string" | "level"
#   [kwargs]                                 # keyword arguments, typed per function below
#   preserve = "PRESERVE_ALL"; level = "UPLEVEL_MINOR"; mode = "PKGMODE_MANIFEST"
#   julia_version = "1.6.0" | "nothing"; ...
#
# The result file records the outcome (`status = "ok"` or `"error"`, with `error_type`,
# `message` from `showerror` and the exception's fields in `[error_fields]`; the error is not
# printed, the exit code is 1) and the session
# state after the call
# (`updated_registry_this_session`), so the caller can rethrow the error as the same exception
# type and carry the session flag over. The call's output goes to stdout/stderr as for the CLI.
# Every keyword argument is passed with a concrete type (defaults as in API.jl), so each
# function is one statically known call; an unknown key is a PkgError.

const REQUEST_FUNCTIONS = ("add", "rm", "resolve", "instantiate", "status", "update",
    "registry.add", "registry.rm", "registry.update", "registry.status")
const REQUEST_FUNCTIONS_LIST = join(REQUEST_FUNCTIONS, ", ") # computed at load time

const REQUEST_KWARGS = Dict{String, Vector{String}}(
    "add" => ["preserve", "target", "allow_autoprecomp", "julia_version", "use_git_for_all_downloads", "use_only_tarballs_for_downloads"],
    "rm" => ["mode", "all_pkgs"],
    "resolve" => ["julia_version"],
    "instantiate" => ["manifest", "update_registry", "verbose", "allow_build", "allow_autoprecomp", "workspace", "julia_version_strict", "julia_version"],
    "status" => ["diff", "mode", "workspace", "outdated", "deprecated", "compat", "extensions"],
    "update" => ["level", "mode", "preserve", "update_registry", "workspace"],
    "registry.add" => String[],
    "registry.rm" => String[],
    "registry.update" => ["update_cooldown_ms"],
    "registry.status" => String[],
)

const PRESERVE_LEVELS = Dict{String, Types.PreserveLevel}(
    "PRESERVE_ALL_INSTALLED" => Types.PRESERVE_ALL_INSTALLED, "PRESERVE_ALL" => Types.PRESERVE_ALL,
    "PRESERVE_DIRECT" => Types.PRESERVE_DIRECT, "PRESERVE_SEMVER" => Types.PRESERVE_SEMVER,
    "PRESERVE_TIERED" => Types.PRESERVE_TIERED, "PRESERVE_TIERED_INSTALLED" => Types.PRESERVE_TIERED_INSTALLED,
    "PRESERVE_NONE" => Types.PRESERVE_NONE,
)
const UPGRADE_LEVELS = Dict{String, Types.UpgradeLevel}(
    "UPLEVEL_FIXED" => Types.UPLEVEL_FIXED, "UPLEVEL_PATCH" => Types.UPLEVEL_PATCH,
    "UPLEVEL_MINOR" => Types.UPLEVEL_MINOR, "UPLEVEL_MAJOR" => Types.UPLEVEL_MAJOR,
)
const PACKAGE_MODES = Dict{String, Types.PackageMode}(
    "PKGMODE_PROJECT" => Types.PKGMODE_PROJECT, "PKGMODE_MANIFEST" => Types.PKGMODE_MANIFEST,
    "PKGMODE_COMBINED" => Types.PKGMODE_COMBINED,
)

request_error(msg::String) = Types.pkgerror("pkgwasm request: " * msg)

function lookup_enum(table::Dict{String, T}, d::Dict{String, Any}, key::String, default::T) where {T}
    haskey(d, key) || return default
    s = d[key]
    s isa String || request_error("`" * key * "` must be a string")
    haskey(table, s) || request_error("unknown value `" * s * "` for `" * key * "`")
    return table[s]
end
function get_bool(d::Dict{String, Any}, key::String, default::Bool)
    haskey(d, key) || return default
    v = d[key]
    v isa Bool || request_error("`" * key * "` must be a boolean")
    return v
end
function get_string(d::Dict{String, Any}, key::String)::Union{Nothing, String}
    haskey(d, key) || return nothing
    v = d[key]
    v isa String || request_error("`" * key * "` must be a string")
    return v
end
function get_strings(d::Dict{String, Any}, key::String)::Vector{String}
    v = d[key]
    v isa Vector{Any} || v isa Vector{String} || request_error("`" * key * "` must be an array of strings")
    out = String[]
    for x in v
        x isa String || request_error("`" * key * "` must be an array of strings")
        push!(out, x)
    end
    return out
end
function get_tables(d::Dict{String, Any}, key::String)::Vector{Dict{String, Any}}
    haskey(d, key) || return Dict{String, Any}[]
    v = d[key]
    out = Dict{String, Any}[]
    v isa Vector{Any} || v isa Vector{Dict{String, Any}} || request_error("`" * key * "` must be an array of tables")
    for x in v
        x isa Dict{String, Any} || request_error("`" * key * "` must be an array of tables")
        push!(out, x)
    end
    return out
end
function get_table(d::Dict{String, Any}, key::String)::Dict{String, Any}
    haskey(d, key) || return Dict{String, Any}()
    v = d[key]
    v isa Dict{String, Any} || request_error("`" * key * "` must be a table")
    return v
end
# `julia_version`: a version, or "nothing" for `julia_version = nothing`; absent: VERSION
function get_julia_version(d::Dict{String, Any})::Union{Nothing, VersionNumber}
    s = get_string(d, "julia_version")
    s === nothing && return VERSION
    s == "nothing" && return nothing
    return VersionNumber(s)
end

function request_package(d::Dict{String, Any})::PackageSpec
    uuid = get_string(d, "uuid")
    tree_hash = get_string(d, "tree_hash")
    kind = get_string(d, "version_kind")
    version = if kind === nothing
        Versions.VersionSpec()
    elseif kind == "nothing"
        nothing
    elseif kind == "number"
        VersionNumber(get_string(d, "version")::String)
    elseif kind == "spec"
        Versions.VersionSpec(get_strings(d, "version"))
    elseif kind == "string"
        get_string(d, "version")::String
    elseif kind == "level"
        lookup_enum(UPGRADE_LEVELS, d, "version", Types.UPLEVEL_MAJOR)
    else
        request_error("unknown version_kind `" * kind * "`")
    end
    return PackageSpec(
        get_string(d, "name"), uuid === nothing ? nothing : Base.UUID(uuid), version,
        tree_hash === nothing ? nothing : Base.SHA1(tree_hash), Types.GitRepo(), get_string(d, "path"),
        get_bool(d, "pinned", false), get_string(d, "url"), get_string(d, "rev"), get_string(d, "subdir"),
    )
end

function request_registry(d::Dict{String, Any})::Registry.RegistrySpec
    uuid = get_string(d, "uuid")
    linked = haskey(d, "linked") ? get_bool(d, "linked", false) : nothing
    return Registry.RegistrySpec(
        get_string(d, "name"), uuid === nothing ? nothing : Base.UUID(uuid), get_string(d, "url"), get_string(d, "path"), linked,
    )
end

function apply_session!(s::Dict{String, Any})
    if haskey(s, "active_project")
        p = get_string(s, "active_project")::String
        Base.ACTIVE_PROJECT[] = isempty(p) ? nothing : p
    end
    haskey(s, "depot_path") && (empty!(DEPOT_PATH); append!(DEPOT_PATH, get_strings(s, "depot_path")))
    haskey(s, "load_path") && (empty!(LOAD_PATH); append!(LOAD_PATH, get_strings(s, "load_path")))
    OFFLINE_MODE[] = get_bool(s, "offline", OFFLINE_MODE[])
    UPDATED_REGISTRY_THIS_SESSION[] = get_bool(s, "updated_registry_this_session", UPDATED_REGISTRY_THIS_SESSION[])
    RESPECT_SYSIMAGE_VERSIONS[] = get_bool(s, "respect_sysimage_versions", RESPECT_SYSIMAGE_VERSIONS[])
    if haskey(s, "default_registries")
        regs = Registry.RegistrySpec[request_registry(r) for r in get_tables(s, "default_registries")]
        empty!(Registry.DEFAULT_REGISTRIES)
        append!(Registry.DEFAULT_REGISTRIES, regs)
    end
    return nothing
end

function run_request(args::Vector{String})
    length(args) == 2 || Types.pkgerror("usage: pkgwasm request <request.toml> <result.toml>")
    req_file, res_file = args[1], args[2]
    status, err_type, msg, fields = try
        req = Base.TOML.parse(Base.TOML.Parser{Dates}(read(req_file, String); filepath = req_file))
        call_request(req)
        ("ok", "", "", Pair{String, Union{String, Int}}[])
    catch e
        # not printed: the caller rethrows it, as the native call would have thrown it
        ("error", request_error_type(e), sprint(showerror_known, e), request_error_fields(e))
    end
    write_request_result(res_file, status, err_type, msg, fields)
    status == "ok" || throw(RequestFailed())
    return nothing
end

# the error is in the result file: `pkgwasm_main` returns 1 without printing it
struct RequestFailed <: Exception end

function request_error_type(@nospecialize(e))::String
    return e isa Types.PkgError ? "PkgError" :
        e isa Resolve.ResolverError ? "ResolverError" :
        e isa ArgumentError ? "ArgumentError" :
        e isa ErrorException ? "ErrorException" :
        e isa Base.IOError ? "IOError" :
        e isa SystemError ? "SystemError" :
        e isa Host.HostError ? "HostError" : "Exception"
end

# The fields an exception is rebuilt from (beyond the message): the caller rethrows the same
# type with the same field values
function request_error_fields(@nospecialize(e))::Vector{Pair{String, Union{String, Int}}}
    F = Pair{String, Union{String, Int}}
    if e isa Base.IOError
        return F["msg" => e.msg, "code" => Int(e.code)]
    elseif e isa SystemError
        return F["prefix" => e.prefix, "errnum" => Int(e.errnum)]
    elseif e isa Host.HostError
        return F["msg" => e.msg, "status" => e.status]
    elseif e isa Types.PkgError || e isa ErrorException
        return F["msg" => typed_msg(e.msg)]
    elseif e isa ArgumentError
        return F["msg" => typed_msg(e.msg)]
    elseif e isa Resolve.ResolverError
        return F["msg" => typed_msg(e.msg)]
    end
    return F[]
end

function toml_string(io::IO, s::String)
    print(io, '"')
    for c in s
        if c == '"' || c == '\\'
            print(io, '\\', c)
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\t'
            print(io, "\\t")
        elseif c < ' ' || c == '\x7f'
            print(io, "\\u", string(UInt32(c); base = 16, pad = 4))
        else
            print(io, c)
        end
    end
    print(io, '"')
    return nothing
end

function write_request_result(file::String, status::String, err_type::String, msg::String,
        fields::Vector{Pair{String, Union{String, Int}}} = Pair{String, Union{String, Int}}[])
    io = IOBuffer()
    print(io, "status = "); toml_string(io, status); println(io)
    if status != "ok"
        print(io, "error_type = "); toml_string(io, err_type); println(io)
        print(io, "message = "); toml_string(io, msg); println(io)
    end
    if !isempty(fields)
        println(io, "[error_fields]")
        for (k, v) in fields
            print(io, k, " = ")
            v isa String ? toml_string(io, v) : print(io, v::Int)
            println(io)
        end
    end
    println(io, "[session]")
    println(io, "updated_registry_this_session = ", UPDATED_REGISTRY_THIS_SESSION[] ? "true" : "false")
    println(io, "offline = ", OFFLINE_MODE[] ? "true" : "false")
    write(file, take!(io))
    return nothing
end

function call_request(req::Dict{String, Any})
    f = get_string(req, "function")
    f === nothing && request_error("no `function`")
    f in REQUEST_FUNCTIONS || request_error("unsupported function `" * f * "`; supported: " * REQUEST_FUNCTIONS_LIST)
    apply_session!(get_table(req, "session"))
    kw = get_table(req, "kwargs")
    allowed = REQUEST_KWARGS[f]
    for k in keys(kw)
        k in allowed || request_error("unsupported keyword argument `" * k * "` for " * f)
    end
    specs = get_tables(req, "pkgs")
    if startswith(f, "registry.")
        regs = Registry.RegistrySpec[request_registry(r) for r in specs]
        return call_registry_request(f, regs, kw)
    end
    pkgs = PackageSpec[request_package(p) for p in specs]
    if f == "add"
        preserve = lookup_enum(PRESERVE_LEVELS, kw, "preserve", Operations.default_preserve())
        target = Symbol(something(get_string(kw, "target"), "deps"))
        target in (:deps, :weakdeps, :extras) || request_error("unknown target `" * String(target) * "`")
        jv = get_julia_version(kw)
        allow_autoprecomp = get_bool(kw, "allow_autoprecomp", true)
        git = get_bool(kw, "use_git_for_all_downloads", false)
        tarballs = get_bool(kw, "use_only_tarballs_for_downloads", false)
        if jv === nothing
            API.add(pkgs; preserve, target, allow_autoprecomp, julia_version = nothing,
                use_git_for_all_downloads = git, use_only_tarballs_for_downloads = tarballs)
        else
            API.add(pkgs; preserve, target, allow_autoprecomp, julia_version = jv,
                use_git_for_all_downloads = git, use_only_tarballs_for_downloads = tarballs)
        end
    elseif f == "rm"
        API.rm(pkgs; mode = lookup_enum(PACKAGE_MODES, kw, "mode", Types.PKGMODE_PROJECT), all_pkgs = get_bool(kw, "all_pkgs", false))
    elseif f == "resolve"
        isempty(pkgs) || request_error("resolve takes no packages")
        jv = get_julia_version(kw)
        jv === nothing ? API.resolve(; julia_version = nothing) : API.resolve(; julia_version = jv)
    elseif f == "instantiate"
        isempty(pkgs) || request_error("instantiate takes no packages")
        update_registry = get_bool(kw, "update_registry", true)
        verbose = get_bool(kw, "verbose", false)
        allow_build = get_bool(kw, "allow_build", true)
        allow_autoprecomp = get_bool(kw, "allow_autoprecomp", true)
        workspace = get_bool(kw, "workspace", false)
        julia_version_strict = get_bool(kw, "julia_version_strict", false)
        jv = get_julia_version(kw)
        manifest = haskey(kw, "manifest") ? get_bool(kw, "manifest", false) : nothing
        if manifest === nothing
            if jv === nothing
                API.instantiate(; manifest = nothing, update_registry, verbose, allow_build, allow_autoprecomp, workspace, julia_version_strict, julia_version = nothing)
            else
                API.instantiate(; manifest = nothing, update_registry, verbose, allow_build, allow_autoprecomp, workspace, julia_version_strict, julia_version = jv)
            end
        else
            if jv === nothing
                API.instantiate(; manifest = manifest::Bool, update_registry, verbose, allow_build, allow_autoprecomp, workspace, julia_version_strict, julia_version = nothing)
            else
                API.instantiate(; manifest = manifest::Bool, update_registry, verbose, allow_build, allow_autoprecomp, workspace, julia_version_strict, julia_version = jv)
            end
        end
    elseif f == "status"
        API.status(pkgs;
            diff = get_bool(kw, "diff", false), mode = lookup_enum(PACKAGE_MODES, kw, "mode", Types.PKGMODE_PROJECT),
            workspace = get_bool(kw, "workspace", false), outdated = get_bool(kw, "outdated", false),
            deprecated = get_bool(kw, "deprecated", false), compat = get_bool(kw, "compat", false),
            extensions = get_bool(kw, "extensions", false),
        )
    else # update
        level = lookup_enum(UPGRADE_LEVELS, kw, "level", Types.UPLEVEL_MAJOR)
        mode = lookup_enum(PACKAGE_MODES, kw, "mode", Types.PKGMODE_PROJECT)
        update_registry = get_bool(kw, "update_registry", true)
        workspace = get_bool(kw, "workspace", false)
        if haskey(kw, "preserve")
            preserve = lookup_enum(PRESERVE_LEVELS, kw, "preserve", Types.PRESERVE_ALL)
            API.up(pkgs; level, mode, preserve, update_registry, workspace)
        else
            API.up(pkgs; level, mode, update_registry, workspace)
        end
    end
    return nothing
end

function call_registry_request(f::String, regs::Vector{Registry.RegistrySpec}, kw::Dict{String, Any})
    if f == "registry.add"
        Registry.add(regs)
    elseif f == "registry.rm"
        Registry.rm(regs)
    elseif f == "registry.update"
        cooldown = haskey(kw, "update_cooldown_ms") ? kw["update_cooldown_ms"] : 1000
        cooldown isa Int64 || request_error("`update_cooldown_ms` must be an integer")
        Registry.update(regs; update_cooldown = Dates.Millisecond(cooldown))
    else
        isempty(regs) || request_error("registry.status takes no registries")
        Registry.status()
    end
    return nothing
end
