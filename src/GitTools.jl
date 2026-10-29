# This file is a part of Julia. License is MIT: https://julialang.org/license

module GitTools
import ..Pkg: @pkg_debug, @pkg_info, @pkg_warn, @pkg_error  # (logging: logging.jl)

using ..Pkg
using ..MiniProgressBars
import ..can_fancyprint, ..printpkgstyle, ..stdout_f, ..ispath_nothrow
using SHA
import Base: SHA1
import ..GitCLI as LibGit2 # PkgWasm (D14): LibGit2's API on the git command line
using Printf

# PkgWasm (D14): always the git command line (stock Pkg's `JULIA_PKG_USE_CLI_GIT=true` mode;
# there is no LibGit2). The other operations go through `GitCLI`, bound as `LibGit2`.
use_cli_git() = true
const RESOLVING_DELTAS_HEADER = "Resolving Deltas:"

# Shallow clones and fetches (stock: LibGit2 >= 1.7, which Julia 1.13 has; not on Windows)
supports_shallow_clone() = !Sys.iswindows()

# Check if a URL is a local path or file:// URL
# Shallow clones are only supported for network protocols (HTTP, HTTPS, Git, SSH)
function is_local_repo(url::AbstractString)
    # Check if it's a local filesystem path
    ispath_nothrow(url) && return true
    # Check if it uses file:// protocol
    startswith(url, "file://") && return true
    return false
end

# Check if a repository is a shallow clone
isshallow(repo::LibGit2.GitRepo) = LibGit2.isshallow(repo)

# Stock's GIT_REGEX, r"^(?:(?<proto>git|ssh|https)://)?(?:[\w\.\+\-:]+@)?(?<hostname>.+?)(?(<proto>)/|:)(?<path>.+?)(?:\.git)?$",
# as its two branches tried in PCRE's order (PkgWasm, D14: the Wasm regex translator has no
# conditional groups): with a protocol, `/` after the host; without, `:` (scp-like)
const GIT_REGEX_PROTO = r"^(?:(?<proto>git|ssh|https)://)(?:[\w\.\+\-:]+@)?(?<hostname>.+?)/(?<path>.+?)(?:\.git)?$"
const GIT_REGEX_SCP = r"^(?:[\w\.\+\-:]+@)?(?<hostname>.+?):(?<path>.+?)(?:\.git)?$"
git_url_match(url::AbstractString) = (m = match(GIT_REGEX_PROTO, url); m === nothing ? match(GIT_REGEX_SCP, url) : m)
const GIT_PROTOCOLS = Dict{String, Union{Nothing, String}}()
const GIT_USERS = Dict{String, Union{Nothing, String}}()

@deprecate setprotocol!(proto::Union{Nothing, AbstractString}) setprotocol!(protocol = proto) false

function setprotocol!(;
        domain::AbstractString = "github.com",
        protocol::Union{Nothing, AbstractString} = nothing,
        user::Union{Nothing, AbstractString} = (protocol == "ssh" ? "git" : nothing)
    )
    domain = lowercase(domain)
    GIT_PROTOCOLS[domain] = protocol
    return GIT_USERS[domain] = user
end

function normalize_url(url::AbstractString)
    # LibGit2 is fussy about trailing slash. Make sure there is none.
    url = rstrip(url, '/')
    m = git_url_match(url)
    m === nothing && return url

    host = m[:hostname]
    path = "$(m[:path]).git"

    proto = get(GIT_PROTOCOLS, lowercase(host), nothing)

    return if proto === nothing
        url
    else
        user = get(GIT_USERS, lowercase(host), nothing)
        user = user === nothing ? "" : "$user@"

        "$proto://$user$host/$path"
    end
end

function ensure_clone(io::IO, target_path, url; kwargs...)
    if ispath(target_path)
        return LibGit2.GitRepo(target_path)
    else
        return GitTools.clone(io, url, target_path; kwargs...)
    end
end

function checkout_tree_to_path(repo::LibGit2.GitRepo, tree::LibGit2.GitObject, path::String)
    return LibGit2.checkout_tree(repo, tree, path) # (stock: CHECKOUT_FORCE into target_directory)
end

# libgit2 does not show the message the server sends with an authentication failure (#2701)
function auth_hint(err::LibGit2.GitError)
    auth_failed = err.code == LibGit2.Error.EAUTH ||
        (err.class == LibGit2.Error.HTTP && occursin(r"\b40[13]\b", err.msg))
    auth_failed || return ""
    return "\nAuthentication failed or access was denied. Note that GitHub and other hosts do not accept \
        account passwords for git over HTTPS: use a personal access token as the password, use an SSH URL, \
        or set `JULIA_PKG_USE_CLI_GIT=true` to use the `git` command line client and its credential helpers."
end

function clone(io::IO, url, source_path; @nospecialize(header::Union{Nothing, AbstractString} = nothing), credentials = nothing, isbare = false, depth::Integer = 0, kwargs...)
    url = String(url)::String
    source_path = String(source_path)::String
    @assert !isdir(source_path) || isempty(readdir(source_path))
    url = normalize_url(url)

    # Disable shallow clones for local repos (not supported)
    if depth > 0 && (is_local_repo(url) || !supports_shallow_clone())
        depth = 0
    end

    printpkgstyle(io, :Cloning, header === nothing ? "git-repo `$url`" : header)
    bar = MiniProgressBar(header = "Cloning:", color = Base.info_color())
    fancyprint = can_fancyprint(io)
    fancyprint && start_progress(io, bar)
    # (stock's JULIA_PKG_USE_CLI_GIT branch; credentials are git's own)
    return try
        args = ["--quiet"]
        depth > 0 && push!(args, "--depth=$depth")
        isbare && push!(args, "--bare")
        push!(args, url, source_path)
        cmd = `git clone $args`
        try
            run(pipeline(cmd; stdout = devnull))
        catch err
            Pkg.Types.pkgerror("The command $(cmd) failed, error: $(error_string(err))")
        end
        return LibGit2.GitRepo(source_path)
    catch err
        rm(source_path; force = true, recursive = true)
        err isa LibGit2.GitError || err isa InterruptException || rethrow()
        if err isa InterruptException
            Pkg.Types.pkgerror("git clone of `$url` interrupted")
        elseif (err.class == LibGit2.Error.Net && err.code == LibGit2.Error.EINVALIDSPEC) ||
                (err.class == LibGit2.Error.Repository && err.code == LibGit2.Error.ENOTFOUND)
            Pkg.Types.pkgerror("git repository not found at `$(url)`: ($(err.msg))")
        else
            Pkg.Types.pkgerror("failed to clone from $(url): ($(err.msg))", auth_hint(err))
        end
    finally
        fancyprint && end_progress(io, bar)
    end
end

geturl(repo) = LibGit2.remote_url(repo, "origin")

# `string(err)` of what `run` throws, typed (PkgWasm, G3): the same text as Base's default
# `show` of ProcessFailedException and IOError; any other error as its message
function error_string(@nospecialize(err))
    Pkg.WASM_TARGET || return string(err)   # (natively stock's interpolation)
    if err isa ProcessFailedException
        return string("ProcessFailedException(Base.Process[", join([sprint(show, p) for p in err.procs], ", "), "])")
    elseif err isa Base.IOError
        return string("Base.IOError(", repr(err.msg), ", ", err.code, ")")
    end
    return Pkg.error_text(err)
end

function fetch(io::IO, repo::LibGit2.GitRepo, @nospecialize(remoteurl::Union{Nothing, AbstractString} = nothing); @nospecialize(header::Union{Nothing, AbstractString} = nothing), credentials = nothing, refspecs::Vector{String} = [""], depth::Integer = 0, kwargs...)
    remoteurl = remoteurl === nothing ? geturl(repo) : String(remoteurl)::String

    # Disable shallow fetches for local repos (not supported)
    if depth > 0 && (is_local_repo(remoteurl) || !supports_shallow_clone())
        depth = 0
    end

    fancyprint = can_fancyprint(io)
    remoteurl = normalize_url(remoteurl)
    printpkgstyle(io, :Updating, header === nothing ? "git-repo `$remoteurl`" : header)
    bar = MiniProgressBar(header = "Fetching:", color = Base.info_color())
    fancyprint && start_progress(io, bar)
    # (stock's JULIA_PKG_USE_CLI_GIT branch)
    return try
        let remoteurl = remoteurl
            args = ["-C", LibGit2.path(repo), "fetch", "-q"]
            depth > 0 && push!(args, "--depth=$depth")
            push!(args, remoteurl, only(refspecs))
            cmd = `git $args`
            errbuf = IOBuffer()
            try
                run(pipeline(cmd; stdout = devnull, stderr = errbuf))
            catch err
                git_err = strip(String(take!(errbuf)))
                msg = "The command $(cmd) failed, error: $(error_string(err))"
                isempty(git_err) || (msg *= "\n$(git_err)")
                Pkg.Types.pkgerror(msg)
            end
        end
    catch err
        err isa LibGit2.GitError || rethrow()
        if (err.class == LibGit2.Error.Repository && err.code == LibGit2.Error.ERROR)
            Pkg.Types.pkgerror("Git repository not found at '$(remoteurl)': ($(err.msg))")
        else
            Pkg.Types.pkgerror("failed to fetch from $(remoteurl): ($(err.msg))", auth_hint(err))
        end
    finally
        fancyprint && end_progress(io, bar)
    end
end


# This code gratefully adapted from https://github.com/simonbyrne/GitX.jl
@enum GitMode mode_dir = 0o040000 mode_normal = 0o100644 mode_executable = 0o100755 mode_symlink = 0o120000 mode_submodule = 0o160000
Base.string(mode::GitMode) = string(UInt32(mode); base = 8)
Base.print(io::IO, mode::GitMode) = print(io, string(mode))

function gitmode(path::AbstractString)
    # Windows doesn't deal with executable permissions in quite the same way,
    # `stat()` gives a different answer than we actually want, so we use
    # `isexecutable()` which uses `uv_fs_access()` internally.  On other
    # platforms however, we just want to check via `stat()`.
    function isexec(p)
        @static if Sys.iswindows()
            return Sys.isexecutable(p)
        end
        return !iszero(filemode(p) & 0o100)
    end
    if islink(path)
        return mode_symlink
    elseif isdir(path)
        return mode_dir
    elseif isexec(path)
        return mode_executable
    else
        return mode_normal
    end
end

"""
    blob_hash(HashType::Type, path::AbstractString)

Calculate the git blob hash of a given path.
"""
function blob_hash(::Type{HashType}, path::AbstractString) where {HashType}
    ctx = HashType()
    if islink(path)
        datalen = length(readlink(path))
    else
        datalen = filesize(path)
    end

    # First, the header
    SHA.update!(ctx, Vector{UInt8}("blob $(datalen)\0"))

    # Next, read data in in chunks of 4KB
    buff = Vector{UInt8}(undef, 4 * 1024)

    try
        if islink(path)
            update!(ctx, Vector{UInt8}(readlink(path)))
        else
            open(path, "r") do io
                while !eof(io)
                    num_read = readbytes!(io, buff)
                    update!(ctx, buff, num_read)
                end
            end
        end
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        @pkg_warn("Unable to open $(path) for hashing; git-tree-sha1 likely suspect")
    end

    # Finish it off and return the digest!
    return SHA.digest!(ctx)
end
blob_hash(path::AbstractString) = blob_hash(SHA1_CTX, path)

"""
    contains_files(root::AbstractString)

Helper function to determine whether a directory contains files; e.g. it is a
direct parent of a file or it contains some other directory that itself is a
direct parent of a file. This is used to exclude directories from tree hashing.
"""
function contains_files(path::AbstractString)
    st = lstat(path)
    ispath(st) || throw(ArgumentError("non-existent path: $(repr(path))"))
    isdir(st) || return isfile(st) || islink(st)
    for p in readdir(path)
        contains_files(joinpath(path, p)) && return true
    end
    return false
end


"""
    tree_hash(HashType::Type, root::AbstractString)

Calculate the git tree hash of a given path.
"""
function tree_hash(::Type{HashType}, root::AbstractString; debug_out::Union{IO, Nothing} = nothing, indent::Int = 0) where {HashType}
    entries = Tuple{String, Vector{UInt8}, GitMode}[]
    for f in sort(readdir(root; join = true); by = f -> gitmode(f) == mode_dir ? f * "/" : f)
        # Skip `.git` directories
        if basename(f) == ".git"
            continue
        end
        # Like git, skip special files (devices, FIFOs, sockets)
        st = lstat(f)
        isfile(st) || isdir(st) || islink(st) || continue

        filepath = abspath(f)
        mode = gitmode(filepath)
        if mode == mode_dir
            # If this directory contains no files, then skip it
            contains_files(filepath) || continue

            # Otherwise, hash it up!
            child_stream = nothing
            if debug_out !== nothing
                child_stream = IOBuffer()
            end
            hash = tree_hash(HashType, filepath; debug_out = child_stream, indent = indent + 1)
            if debug_out !== nothing
                indent_str = "| "^indent
                println(debug_out, "$(indent_str)+ [D] $(basename(filepath)) - $(bytes2hex(hash))")
                print(debug_out, String(take!(child_stream::IOBuffer)))
                println(debug_out, indent_str)
            end
        else
            hash = blob_hash(HashType, filepath)
            if debug_out !== nothing
                indent_str = "| "^indent
                mode_str = mode == mode_normal ? "F" : "X"
                println(debug_out, "$(indent_str)[$(mode_str)] $(basename(filepath)) - $(bytes2hex(hash))")
            end
        end
        push!(entries, (basename(filepath), hash, mode))
    end

    content_size = 0
    for (n, h, m) in entries
        content_size += ndigits(UInt32(m); base = 8) + 1 + sizeof(n) + 1 + sizeof(h)
    end

    # Return the hash of these entries
    ctx = HashType()
    SHA.update!(ctx, Vector{UInt8}("tree $(content_size)\0"))
    for (name, hash, mode) in entries
        SHA.update!(ctx, Vector{UInt8}("$(mode) $(name)\0"))
        SHA.update!(ctx, hash)
    end
    return SHA.digest!(ctx)
end
tree_hash(root::AbstractString; debug_out::Union{IO, Nothing} = nothing) = tree_hash(SHA.SHA1_CTX, root; debug_out)

function check_valid_HEAD(repo)
    return try
        LibGit2.head(repo)
    catch err
        url = try
            geturl(repo)
        catch
            "(unknown url)"
        end
        Pkg.Types.pkgerror("invalid git HEAD in $url ($(err isa LibGit2.GitError ? err.msg : Pkg.error_text(err)))")
    end
end

function git_file_stream(repo::LibGit2.GitRepo, spec::String; fakeit::Bool = false)::IO
    blob = try
        LibGit2.GitBlob(repo, spec)
    catch err
        err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow()
        fakeit && return devnull
    end
    iob = IOBuffer(LibGit2.content(blob))
    close(blob)
    return iob
end

end # module
