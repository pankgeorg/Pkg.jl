# "Precompiling" is the longest operation
const pkgstyle_indent = textwidth(string(:Precompiling))

function printpkgstyle(io::IO, cmd::Symbol, text::String, ignore_indent::Bool = false; color = :green)
    indent = ignore_indent ? 0 : pkgstyle_indent
    return @lock io begin
        printstyled(io, lpad(string(cmd), indent), color = color, bold = true)
        println(io, " ", text)
    end
end

function linewrap(str::String; io = stdout_f(), padding = 0, width = Base.displaysize(io)[2])
    text_chunks = split(str, ' ')
    lines = String[""]
    for chunk in text_chunks
        new_line_attempt = string(last(lines), chunk, " ")
        if length(strip(new_line_attempt)) > width - padding
            lines[end] = strip(last(lines))
            push!(lines, string(chunk, " "))
        else
            lines[end] = new_line_attempt
        end
    end
    return lines
end

"""
    atomic_toml_write(path::String, data; kws...)

Write TOML data to a file atomically by first writing to a temporary file and then moving it into place.
This prevents "teared" writes if the process is interrupted or if multiple processes write to the same file.

The `kws` are passed to `TOML.print`.
"""
function atomic_toml_write(path::String, data; kws...)
    dir = dirname(path)
    isempty(dir) && (dir = pwd())

    temp_path, temp_io = mktemp(dir)
    return try
        TOMLWriter.print(temp_io, data; kws...)
        close(temp_io)
        mv(temp_path, path; force = true)
    catch
        close(temp_io)
        rm(temp_path; force = true)
        rethrow()
    end
end

const URL_regex = r"((file|git|ssh|http(s)?)|([\w\-\.]+@[\w\-\.]+))(:(//)?)([\w\.@\:/\-~]+)(\.git)?(/)?"x
isurl(r::String) = occursin(URL_regex, r)

stdlib_dir() = normpath(joinpath(Sys.BINDIR::String, "..", "share", "julia", "stdlib", "v$(VERSION.major).$(VERSION.minor)"))
stdlib_path(stdlib::String) = joinpath(stdlib_dir(), stdlib)

function pathrepr(path::String)
    # print stdlib paths as @stdlib/Name
    if startswith(path, stdlib_dir())
        path = "@stdlib/" * basename(path)
    end
    return "`" * Base.contractuser(path) * "`"
end

"""
    normalize_path_for_toml(path::String)

Normalize a path for writing to TOML files (Project.toml/Manifest.toml).
On Windows, converts relative paths to use forward slashes for cross-platform compatibility.
Absolute paths are left unchanged as they are platform-specific by nature.
"""
function normalize_path_for_toml(path::String)
    if Sys.iswindows() && !isabspath(path)
        return join(splitpath(path), "/")
    end
    return path
end

function set_readonly(path)
    for (root, dirs, files) in walkdir(path)
        for file in files
            filepath = joinpath(root, file)
            # `chmod` on a link would change the permissions of the target.  If
            # the link points to a file within the same root, it will be
            # chmod'ed anyway, but we don't want to make directories read-only.
            # It's better not to mess with the other cases (links to files
            # outside of the root, links to non-file/non-directories, etc...)
            islink(filepath) && continue
            fmode = filemode(filepath)
            @static if Sys.iswindows()
                if Sys.isexecutable(filepath)
                    fmode |= 0o111
                end
            end
            try
                chmod(filepath, fmode & (typemax(fmode) ⊻ 0o222))
            catch
            end
        end
    end
    return nothing
end
set_readonly(::Nothing) = nothing

# try to call realpath on as much as possible
function safe_realpath(path)
    if ispath(path)
        try
            return realpath(path)
        catch
            return path
        end
    end
    a, b = splitdir(path)
    # path cannot be reduced at the root or drive, avoid stack overflow
    isempty(b) && return path
    return joinpath(safe_realpath(a), b)
end

# Windows sometimes throw on `isdir`...
function isdir_nothrow(path::String)
    return try
        isdir(path)
    catch e
        false
    end
end

function isfile_nothrow(path::String)
    return try
        isfile(path)
    catch e
        false
    end
end


## ordering of UUIDs ##
if VERSION < v"1.2.0-DEV.269"  # Defined in Base as of #30947
    Base.isless(a::UUID, b::UUID) = a.value < b.value
end

function discover_repo(path::AbstractString)
    dir = abspath(path)
    stop_dir = homedir()
    depot = PkgWasm.depots1()

    while true
        dir == depot && return nothing
        gitdir = joinpath(dir, ".git")
        if isdir(gitdir) || isfile(gitdir)
            return dir
        end
        dir == stop_dir && return nothing
        parent = dirname(dir)
        parent == dir && return nothing
        dir = parent
    end
    return
end

# Resolve a manifest-relative path to an absolute path
# Note: Despite the name "manifest_rel_path", this resolves relative to the manifest file
manifest_rel_path(env, path::String) = normpath(joinpath(dirname(env.manifest_file), path))

# PkgWasm (PLAN.md D3): one process and one Task, so pidfile locks are plain calls. Both forms
# used by Pkg (`mkpidlock(f, path; stale_age)` and the predicate form `mkpidlock(pred, path)`)
# just return `f()`. This is the only lock implementation the fork uses; FileWatching is not
# reached from supported paths.
mkpidlock(f::Function, ::AbstractString; kwargs...) = f()

"""
    with_toml_type(f, x)

`f(x)`, with `x` (a value from a parsed TOML table, or `nothing`) narrowed to the
concrete types TOML's parser makes (PLAN.md M4.2): the method of `f` is chosen statically.
Other types are an error built for Wasm, and a dynamic call natively.
"""
function with_toml_type(f::F, @nospecialize(x)) where {F}
    x === nothing && return f(nothing)
    x isa String && return f(x)
    x isa Dict{String, Any} && return f(x)
    x isa Bool && return f(x)
    x isa Int64 && return f(x)
    x isa Float64 && return f(x)
    x isa Vector{Any} && return f(x)
    x isa Vector{String} && return f(x)
    x isa Vector{Int64} && return f(x)
    x isa Vector{Float64} && return f(x)
    x isa Vector{Bool} && return f(x)
    x isa Dates.DateTime && return f(x)
    x isa Dates.Date && return f(x)
    x isa Dates.Time && return f(x)
    WASM_TARGET && error("PkgWasm: unsupported TOML value type")
    return Base.inferencebarrier(f)(x)
end

"`f(x)` for a TOML table `x` (a `Dict{String, Any}`); other values as `with_toml_type`."
function with_toml_dict(f::F, @nospecialize(x)) where {F}
    x isa Dict{String, Any} && return f(x)
    WASM_TARGET && error("PkgWasm: expected a TOML table")
    return Base.inferencebarrier(f)(x)
end

"`Float64(x)` for a number `x` from a TOML table."
function toml_float(@nospecialize(x))
    x isa Float64 && return x
    x isa Int64 && return Float64(x)
    WASM_TARGET && error("PkgWasm: expected a TOML number")
    return Base.inferencebarrier(Float64)(x)::Float64
end

"`UUID(x)` for a value from a TOML table (a String; an integer as UUID takes it)."
function toml_uuid(@nospecialize(x))
    x isa String && return Base.UUID(x)
    x isa Int64 && return Base.UUID(x)
    x isa Bool && return Base.UUID(x)
    WASM_TARGET && error("PkgWasm: a UUID must be a string")  # (natively a MethodError)
    return Base.inferencebarrier(Base.UUID)(x)::Base.UUID
end

"A TOML value as a `Union{String, Nothing}` field takes it (its `convert`)."
function toml_string_or_nothing(@nospecialize(x))
    x isa Union{String, Nothing} && return x
    WASM_TARGET && error("PkgWasm: expected a string")  # (natively convert's MethodError)
    return Base.inferencebarrier(convert)(Union{String, Nothing}, x)::Union{String, Nothing}
end

"`String[s::String for s in x]` for a TOML value `x`."
function toml_strings(@nospecialize(x))
    x isa Vector{String} && return String[s for s in x]
    x isa Vector{Any} && return String[s::String for s in x]
    if x isa Union{Vector{Int64}, Vector{Float64}, Vector{Bool}}
        isempty(x) && return String[]
        throw(TypeError(:typeassert, "", String, first(x)))
    end
    WASM_TARGET && error("PkgWasm: expected a TOML array of strings")
    return Base.inferencebarrier(v -> String[s::String for s in v])(x)::Vector{String}
end

"`for v in x; f(v); end` for a TOML value `x`, told apart by the types TOML's parser makes."
function toml_foreach(f::F, @nospecialize(x)) where {F}
    if x isa Vector{Any}
        foreach(f, x)
    elseif x isa Vector{String}
        foreach(f, x)
    elseif x isa Vector{Int64}
        foreach(f, x)
    elseif x isa Vector{Float64}
        foreach(f, x)
    elseif x isa Vector{Bool}
        foreach(f, x)
    elseif x isa String
        foreach(f, x)
    elseif x isa Dict{String, Any}
        foreach(f, x)
    elseif x isa Union{Int64, Float64, Bool}
        f(x)  # (a number is an iterable of itself)
    else
        WASM_TARGET && error("PkgWasm: unsupported TOML value type")
        Base.inferencebarrier(foreach)(f, x)
    end
    return nothing
end
