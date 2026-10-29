# PkgWasm (PLAN.md D14): the subset of LibGit2's API that Pkg uses, on the git command line.
#
# Stock Pkg with `JULIA_PKG_USE_CLI_GIT=true` clones and fetches with `git`, but opens
# repositories, resolves revisions, checks out trees and reads blobs with LibGit2. PkgWasm has no
# LibGit2 (in Wasm there is no libgit2), so these operations are git plumbing commands here, run
# through Base's process API (in Wasm: the julia_io process extension, ABI.md §4c). The modules
# that used LibGit2 bind this one as `LibGit2` (`import ..GitCLI as LibGit2`), so their code
# stays stock Pkg's. Every operation follows LibGit2 1.9.7's results (Julia 1.13's), including
# the error codes Pkg tests (ENOTFOUND vs. the others it rethrows); test/gitcli.jl compares them.
#
# Commands are built as `Cmd(::Vector{String})` and capture stdout/stderr in IOBuffers.

module GitCLI

import Base: SHA1

## errors (LibGit2's codes and classes, LibGit2/src/error.jl)

module Error
@enum Code::Cint begin
    GIT_OK = 0
    ERROR = -1
    ENOTFOUND = -3
    EEXISTS = -4
    EAMBIGUOUS = -5
    EUNBORNBRANCH = -9
    EINVALIDSPEC = -12
    ELOCKED = -14
    EAUTH = -16
end
@enum Class::Cint begin
    None = 0
    OS = 2
    Invalid = 3
    Reference = 4
    Repository = 6
    Config = 7
    Odb = 9
    Object = 11
    Net = 12
    Tree = 14
    Checkout = 20
    Merge = 22
    Rebase = 29
    HTTP = 34
end
end

struct GitError <: Exception
    class::Error.Class
    code::Error.Code
    msg::String
end
Base.show(io::IO, err::GitError) = print(io, "GitError(Code:", err.code, ", Class:", err.class, ", ", err.msg, ")")

module Consts
const FETCH_DEPTH_UNSHALLOW = Cint(2147483647)
@enum GIT_RESET_TYPE RESET_SOFT = 1 RESET_MIXED = 2 RESET_HARD = 3
end

## running git

# `git <args>` (in `dir` when given): exit code, stdout, stderr
function git(args::Vector{String}; dir::Union{Nothing, String} = nothing)
    cmd = Cmd(vcat(["git"], args))
    dir === nothing || (cmd = Cmd(cmd; dir = dir))
    out, err = IOBuffer(), IOBuffer()
    p = run(pipeline(ignorestatus(cmd); stdout = out, stderr = err))
    return p.exitcode, String(take!(out)), String(take!(err))
end
# stdout without its final newline, or `nothing` when git exits nonzero
function try_git(args::Vector{String}; dir::Union{Nothing, String} = nothing)
    code, out, _ = git(args; dir)
    return code == 0 ? String(chomp(out)) : nothing
end

## hashes

struct GitHash
    sha::SHA1
end
GitHash(bytes::Union{Vector{UInt8}, NTuple{20, UInt8}}) = GitHash(SHA1(bytes))
GitHash(s::AbstractString) = GitHash(SHA1(String(s)))
Base.string(h::GitHash) = string(h.sha)
Base.print(io::IO, h::GitHash) = print(io, string(h))
Base.:(==)(a::GitHash, b::GitHash) = a.sha == b.sha
Base.hash(h::GitHash, x::UInt) = hash(h.sha, x)

## repositories

struct GitRepo
    path::String     # what `path(repo)` gives: the work tree, or the git dir of a bare repository
    gitdir::String
end

"""
    GitRepo(path)

`git_repository_open`: `path` is the git dir itself (bare), or a work tree with its `.git`
(a directory, or a file as in linked worktrees and submodules) directly in it; no upward search.
"""
function GitRepo(path::AbstractString)
    p = String(path)
    gd = isdir(p) ? try_git(["-C", p, "rev-parse", "--absolute-git-dir"]) : nothing
    ok = false
    if gd !== nothing
        rp = realpath(p)
        dotgit = joinpath(rp, ".git")
        ok = gd == rp || (ispath(dotgit) && (isfile(dotgit) || gd == realpath(dotgit)))
    end
    ok || throw(GitError(Error.Repository, Error.ENOTFOUND, "could not find repository at '$p'"))
    gd::String
    return GitRepo(basename(gd) == ".git" ? dirname(gd) : gd, gd)
end

Base.close(::GitRepo) = nothing
path(r::GitRepo) = r.path
gitdir(r::GitRepo) = r.gitdir
"`git_repository_is_bare`: the repository has no work tree (its path is the git dir)."
isbare(r::GitRepo) = r.path == r.gitdir

rgit(r::GitRepo, args::Vector{String}) = git(vcat(["--git-dir=" * r.gitdir], args); dir = r.path)
try_rgit(r::GitRepo, args::Vector{String}) = try_git(vcat(["--git-dir=" * r.gitdir], args); dir = r.path)

with(f, x) = try f(x) finally close(x) end
with(f, ::Type{T}, args...) where {T} = with(f, T(args...))

## objects

abstract type GitObject end
struct GitCommit <: GitObject
    repo::GitRepo
    oid::GitHash
end
struct GitTree <: GitObject
    repo::GitRepo
    oid::GitHash
end
struct GitBlob <: GitObject
    repo::GitRepo
    oid::GitHash
end
struct GitTag <: GitObject
    repo::GitRepo
    oid::GitHash
end
Base.close(::GitObject) = nothing
GitHash(o::GitObject) = o.oid

object_type(r::GitRepo, spec::String) = try_rgit(r, ["cat-file", "-t", spec])

function make_object(r::GitRepo, oid::String, t::String)::GitObject
    h = GitHash(oid)
    t == "commit" && return GitCommit(r, h)
    t == "tree" && return GitTree(r, h)
    t == "blob" && return GitBlob(r, h)
    return GitTag(r, h)
end

# What LibGit2 1.9.7's `git_revparse_single` rejects (EINVALIDSPEC) but git accepts, from the
# differential corpus of test/pkgwasm_git.jl: empty; ranges (`..`); unterminated `^{`/`@{`;
# `^{type}` other than `^{}`/commit/tree/blob/tag/`^{/text}`; `@{x}` other than a number,
# upstream/u or a date-like word (libgit2 has no `@{push}`); a ref part ending in `/` before a
# suffix. (`@{upstream}` of a ref that is not a local branch: see `GitObject`.)
const PEEL_TYPES = ("", "commit", "tree", "blob", "tag")
function valid_spec(spec::String)
    isempty(spec) && return false
    startswith(spec, ":/") && return true       # (a commit-message search: the rest is its text)
    head = String(split(spec, ':'; limit = 2)[1])  # (`rev:path`: only the rev part has syntax)
    bare = replace(head, r"\^\{/[^}]*\}" => "^{}") # (`..` in a search is text)
    occursin("..", bare) && return false
    occursin(r"[\^@]\{[^}]*$", bare) && return false
    for m in eachmatch(r"\^\{([^}]*)\}", head)
        t = String(something(m.captures[1]))
        (t in PEEL_TYPES || startswith(t, "/")) || return false
    end
    base = String(something(match(r"^[^~^@:]*", head)).match)
    for m in eachmatch(r"@\{([^}]*)\}", head)
        t = String(something(m.captures[1]))
        datelike = occursin(r"^[0-9]{4}-|ago$|^(yesterday|today|now|noon|midnight|tea)$", t)
        (occursin(r"^-?[0-9]+$", t) || t in ("upstream", "u") || datelike) || return false
    end
    endswith(base, "/") && length(base) < length(spec) && return false
    return true
end

"""
    GitObject(repo, spec)

`git_revparse_single`: the object, or a `GitError` with LibGit2's code: ENOTFOUND (no such
object), EINVALIDSPEC, EAMBIGUOUS.
"""
function GitObject(r::GitRepo, spec0::AbstractString)::GitObject
    spec = String(spec0)
    valid_spec(spec) || throw(GitError(Error.Invalid, Error.EINVALIDSPEC, "invalid revision spec '$spec'"))
    spec == "@{0}" && (spec = "HEAD")             # (libgit2 reads position 0 without a reflog)
    endswith(spec, "@{0}") && (spec = spec[1:(end - 4)])
    # a short hex string is an object id prefix (too short: EAMBIGUOUS) unless it names a reference,
    # in libgit2's lookup order (spec, refs/, refs/tags/, refs/heads/, refs/remotes/, .../HEAD)
    if occursin(r"^[0-9a-fA-F]{1,3}$", spec)
        names = (spec, "refs/" * spec, "refs/tags/" * spec, "refs/heads/" * spec, "refs/remotes/" * spec,
                 "refs/remotes/" * spec * "/HEAD")
        any(n -> startswith(n, "refs/") && rgit(r, ["show-ref", "--verify", "-q", n])[1] == 0, names) ||
            throw(GitError(Error.Object, Error.EAMBIGUOUS, "the OID prefix '$spec' is too short"))
    end
    # `ref@{...}`: the ref must exist (else ENOTFOUND). `@{upstream}` is of a local branch only
    # (else EINVALIDSPEC), which git wants by its short name; a reflog entry (`@{n}`, `@{date}`)
    # needs the reflog of HEAD or a local branch, which git does not (it also reads other refs'
    # reflogs, and answers from the oldest entry when there is none)
    if occursin("@{", spec) && !startswith(spec, ":/")
        base, suffix = split(spec, "@{"; limit = 2)
        full = startswith(base, "-") ? nothing : # (an option: no such ref)
            try_rgit(r, ["rev-parse", "--symbolic-full-name", isempty(base) ? "HEAD" : String(base)])
        (full === nothing || isempty(full)) &&
            throw(GitError(Error.Reference, Error.ENOTFOUND, "revspec '$spec' not found"))
        if occursin(r"^(upstream|u)\}", suffix)
            startswith(full, "refs/heads/") ||
                throw(GitError(Error.Invalid, Error.EINVALIDSPEC, "'$base' is not a local branch"))
            spec = full[(length("refs/heads/") + 1):end] * "@{" * suffix
        elseif !(base in ("", "HEAD") || startswith(full, "refs/heads/")) || rgit(r, ["reflog", "exists", full])[1] != 0
            # (libgit2 reads the reflogs of HEAD and local branches only)
            throw(GitError(Error.Reference, Error.ENOTFOUND, "revspec '$spec' not found"))
        end
    end
    code, out, err = rgit(r, ["rev-parse", "--verify", "--end-of-options", spec])
    if code == 0
        oid = String(chomp(out))
        t = object_type(r, oid)     # (`rev-parse` echoes any full hex id: the object must exist)
        t === nothing || return make_object(r, oid, t)
    elseif occursin("ambiguous", err)
        throw(GitError(Error.Object, Error.EAMBIGUOUS, String(strip(err))))
    end
    throw(GitError(Error.Reference, Error.ENOTFOUND, "revspec '$spec' not found"))
end
function GitObject(r::GitRepo, h::GitHash)::GitObject
    t = object_type(r, string(h))
    t === nothing && throw(GitError(Error.Odb, Error.ENOTFOUND, "object not found - no match for id ($(string(h)))"))
    return make_object(r, string(h), t)
end
# LibGit2's typed constructors: an object of another type is an `ERROR` of class Object
function typed(::Type{T}, o::GitObject) where {T <: GitObject}
    o isa T || throw(GitError(Error.Object, Error.ERROR, "Expected object of type $T, received object of type $(typeof(o))"))
    return o::T
end
GitTree(r::GitRepo, spec::Union{AbstractString, GitHash}) = typed(GitTree, GitObject(r, spec))
GitBlob(r::GitRepo, spec::Union{AbstractString, GitHash}) = typed(GitBlob, GitObject(r, spec))
GitCommit(r::GitRepo, spec::Union{AbstractString, GitHash}) = typed(GitCommit, GitObject(r, spec))

"`peel(GitTree, obj)`: the tree of a commit or tag; a blob does not peel."
function peel(::Type{GitTree}, o::GitObject)
    oid = try_rgit(o.repo, ["rev-parse", "--verify", "-q", string(o.oid) * "^{tree}"])
    oid === nothing && throw(GitError(Error.Object, Error.EINVALIDSPEC, "the git object cannot be peeled to a tree"))
    return GitTree(o.repo, GitHash(oid))
end

"`tree[path]`: the entry (tree or blob) at `path`; `KeyError` when there is none."
function Base.getindex(t::GitTree, p::AbstractString)
    spec = string(t.oid) * ":" * p
    ty = object_type(t.repo, spec)
    ty === nothing && throw(KeyError(p))
    oid = try_rgit(t.repo, ["rev-parse", "--verify", "-q", spec])
    oid === nothing && throw(KeyError(p))
    return make_object(t.repo, oid, ty)
end

"The bytes of a blob."
function content(b::GitBlob)
    code, out, err = rgit(b.repo, ["cat-file", "blob", string(b.oid)])
    code == 0 || throw(GitError(Error.Object, Error.ERROR, String(strip(err))))
    return Vector{UInt8}(out)
end

## references and the work tree

struct GitReference
    oid::GitHash
end
Base.close(::GitReference) = nothing
GitHash(ref::GitReference) = ref.oid

function head(r::GitRepo)
    oid = try_rgit(r, ["rev-parse", "--verify", "-q", "HEAD"])
    if oid === nothing
        ref = try_rgit(r, ["symbolic-ref", "-q", "HEAD"])
        throw(GitError(Error.Reference, Error.EUNBORNBRANCH,
                       "reference '$(something(ref, "HEAD"))' not found"))
    end
    return GitReference(GitHash(oid))
end
head_oid(r::GitRepo) = GitHash(head(r))
isattached(r::GitRepo) = try_rgit(r, ["symbolic-ref", "-q", "HEAD"]) !== nothing
# (the branch's own name: `--short` abbreviates only as far as unambiguous, e.g. `heads/main`
# when a tag `main` exists)
function branch(r::GitRepo)
    ref = try_rgit(r, ["symbolic-ref", "-q", "HEAD"])
    (ref === nothing || !startswith(ref, "refs/heads/")) && return ""
    return ref[(length("refs/heads/") + 1):end]
end
function headname(r::GitRepo)
    h = head(r)
    isattached(r) && return branch(r)
    return "(detached from $(string(GitHash(h))[1:7]))"
end
remotes(r::GitRepo) = String[s for s in split(something(try_rgit(r, ["remote"]), ""), '\n') if !isempty(s)]
revparseid(r::GitRepo, spec::AbstractString) = GitHash(GitObject(r, spec))
isshallow(r::GitRepo) = try_rgit(r, ["rev-parse", "--is-shallow-repository"]) == "true"

"`isdirty(repo)`: the index or the work tree differs from HEAD (untracked files don't count)."
function isdirty(r::GitRepo)
    rgit(r, ["update-index", "-q", "--refresh"])     # (stat changes alone are not changes)
    code, _, err = rgit(r, ["diff-index", "--quiet", "HEAD", "--"])
    code <= 1 || throw(GitError(Error.Repository, Error.ERROR, String(strip(err))))
    return code == 1
end

function reset!(r::GitRepo, id::GitHash, mode::Consts.GIT_RESET_TYPE)
    flag = mode == Consts.RESET_HARD ? "--hard" : mode == Consts.RESET_SOFT ? "--soft" : "--mixed"
    code, _, err = wgit(r, ["reset", "-q", flag, string(id)])
    code == 0 || throw(GitError(Error.Repository, Error.ERROR, String(strip(err))))
    return nothing
end

"""
    merge!(repo; branch, fastforward = true)

LibGit2's `merge!` with a branch, fast-forward only: `true` when HEAD is up to date or was
fast-forwarded, `false` when no fast-forward is possible; ENOTFOUND for a missing branch.
"""
function merge!(r::GitRepo; branch::AbstractString, fastforward::Bool = true)
    fastforward || throw(ArgumentError("merge!: only fast-forward merges are supported"))
    target = try_rgit(r, ["rev-parse", "--verify", "-q", String(branch)])
    target === nothing && throw(GitError(Error.Reference, Error.ENOTFOUND, "reference '$branch' not found"))
    rgit(r, ["merge-base", "--is-ancestor", target, "HEAD"])[1] == 0 && return true
    rgit(r, ["merge-base", "--is-ancestor", "HEAD", target])[1] == 0 || return false
    code, _, err = wgit(r, ["merge", "-q", "--ff-only", target])
    code == 0 || throw(GitError(Error.Merge, Error.ERROR, String(strip(err))))
    return true
end

function rebase!(r::GitRepo, upstream::AbstractString)
    code, _, err = wgit(r, ["rebase", "-q", String(upstream)])
    if code != 0
        wgit(r, ["rebase", "--abort"])
        throw(GitError(Error.Rebase, Error.ERROR, String(strip(err))))
    end
    return nothing
end

"The URL of the remote `origin` as configured (as `LibGit2.url(GitRemote)`)."
function remote_url(r::GitRepo, name::AbstractString)
    url = try_rgit(r, ["config", "--get", "remote." * name * ".url"])
    url === nothing && throw(GitError(Error.Config, Error.ENOTFOUND, "remote '$name' does not exist"))
    return url
end

"`getconfig(name, default)`: the user's global (or else the system) git configuration."
function getconfig(name::AbstractString, default::AbstractString)
    for scope in ("--global", "--system")
        v = try_git(["config", scope, "--get", String(name)])
        v === nothing || return v
    end
    return String(default)
end

## checkout

# What git applies to work-tree files and LibGit2 1.9.7 does not: configured filter drivers
# (neutralised per command by `libgit2_filters`) and the `working-tree-encoding` attribute (unset
# for every path by a line in the repository's own info/attributes, the highest-precedence
# attribute source; LibGit2 ignores that attribute, so this changes nothing for it)
const NO_ENCODING = "* -working-tree-encoding"
function libgit2_filters(r::GitRepo)
    f = joinpath(r.gitdir, "info", "attributes")
    lines = isfile(f) ? readlines(f) : String[]
    if !(NO_ENCODING in lines)
        mkpath(dirname(f))
        open(io -> println(io, NO_ENCODING), f, "a")
    end
    over = String[]
    for d in configured_drivers(r)
        append!(over, ["-c", "filter.$d.smudge=", "-c", "filter.$d.process=", "-c", "filter.$d.required=false"])
    end
    return over
end
# a git command that writes the work tree, with LibGit2's filtering
wgit(r::GitRepo, args::Vector{String}) = rgit(r, vcat(libgit2_filters(r), args))

# filter drivers configured for the repository (git runs them, LibGit2 does not)
function configured_drivers(r::GitRepo)
    out = try_rgit(r, ["config", "--name-only", "--get-regexp", "^filter[.].*[.](smudge|process|clean|required)\$"])
    out === nothing && return String[]
    return unique!(String[String(something(m.captures[1])) for m in eachmatch(r"^filter\.(.*)\.[a-z]+$"m, out)])
end

"""
    checkout_tree(repo, tree, path)

`checkout_tree` with `CHECKOUT_FORCE` into `target_directory = path`: the files of `tree`, as
LibGit2 writes them. Only LibGit2's built-in filters apply (configured filter drivers such as
git-lfs are neutralised); files are 0644/0755 and directories 0755 minus the umask (git uses
0666/0777: its modes are masked to LibGit2's); directories that exist already keep their modes.
"""
function checkout_tree(r::GitRepo, tree::GitObject, path::AbstractString)
    p = String(path)
    over = libgit2_filters(r)
    # the tree's entries (`<mode> <type> <oid>\t<raw path>`, NUL-terminated)
    code, out, err = rgit(r, ["ls-tree", "-r", "-t", "-z", string(tree.oid)])
    code == 0 || throw(GitError(Error.Tree, Error.ERROR, String(strip(err))))
    ents = Tuple{String, String}[]
    for rec in split(out, '\0'; keepempty = false)
        meta, rel = split(rec, '\t'; limit = 2)
        push!(ents, (String(split(meta, ' ')[1]), String(rel)))
    end
    existed = Set{String}(rel for (mode, rel) in ents if mode == "040000" && isdir(joinpath(p, rel)))
    index = tempname(r.gitdir; cleanup = false)
    try
        base = vcat(over, ["--git-dir=" * r.gitdir, "--work-tree=" * p])
        for args in (["read-tree", string(tree.oid)],
                     ["--literal-pathspecs", "checkout-index", "-a", "-f"])
            cmd = Cmd(Cmd(vcat(["git"], base, args)); dir = p, env = checkout_env(index))
            e = IOBuffer()
            pr = run(pipeline(ignorestatus(cmd); stdout = devnull, stderr = e))
            pr.exitcode == 0 || throw(GitError(Error.Checkout, Error.ERROR, String(strip(String(take!(e))))))
        end
    finally
        rm(index; force = true)
    end
    for (mode, rel) in ents
        mode == "120000" && continue                     # symlink
        mode == "160000" && continue                     # submodule (not checked out)
        mode == "040000" && rel in existed && continue
        f = joinpath(p, rel)
        want = mode == "100644" ? 0o644 : 0o755
        chmod(f, filemode(f) & 0o777 & want)
    end
    return nothing
end
# the environment with GIT_INDEX_FILE set (the parent's otherwise)
function checkout_env(index::String)
    env = String[string(k, "=", v) for (k, v) in ENV if k != "GIT_INDEX_FILE"]
    push!(env, "GIT_INDEX_FILE=" * index)
    return env
end

end # module
