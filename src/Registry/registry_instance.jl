using Base: UUID, SHA1
using TOML
using Dates
using Tar
using ..Versions: VersionSpec, VersionRange

# The content of a registry is assumed to be constant during the
# lifetime of a `Registry`. Create a new `Registry` if you want to have
# a new view on the current registry.

function to_tar_path_format(file::AbstractString)
    @static if Sys.iswindows()
        file = replace(file, "\\" => "/")
    end
    return file
end

# The files of a compressed registry read from the unpack cache (see `load_compressed_registry`)
mutable struct RegistryTarIndex
    const compressed::String # the compressed tarball the cache was built from
    const tar::String        # the cached decompressed tarball (an immutable generation)
    const entries::Dict{String, Tuple{Int64, Int64}} # entry path => (data offset, size)
    # opened when the index is read (so a later replacement or removal of the file cannot
    # change what this index reads) and closed by `close_registry_cache_streams!`
    io::Union{Nothing, IOStream}
    # the stock in-memory files, if reading the cache failed after it was selected
    fallback::Union{Nothing, Dict{String, String}}
end
Base.haskey(t::RegistryTarIndex, k::String) = haskey(t.entries, k)
Base.delete!(t::RegistryTarIndex, k::String) = (delete!(t.entries, k); t)
function Base.getindex(t::RegistryTarIndex, k::String)
    off, size = t.entries[k]
    fb = t.fallback
    fb === nothing || return fb[k]
    try
        io = t.io
        if io === nothing || !isopen(io)
            io = t.io = open_registry_cache_stream(t.tar)
        end
        seek(io, off)
        data = read(io, size)
        length(data) == size || error("registry cache $(repr(t.tar)): entry $(repr(k)) is truncated")
        return String(data)
    catch e
        # (the stock read of the compressed tarball, as if the cache had not been used)
        @pkg_debug "registry cache read failed, reading $(t.compressed) in memory" exception = e
        io = t.io
        io === nothing || close(io)
        t.io = nothing
        fb = t.fallback = uncompress_registry(t.compressed)
        return fb[k]
    end
end

# Streams of cached registries opened in this session. Closed explicitly at the end of a
# command (`pkgwasm_main`) and by `sanitize_globals!` (a Wasm build runs no finalizers); a
# `RegistryTarIndex` used afterwards reopens its file.
const REGISTRY_CACHE_STREAMS = IOStream[]
function open_registry_cache_stream(tar::String)
    io = open(tar)
    push!(REGISTRY_CACHE_STREAMS, io)
    return io
end
function close_registry_cache_streams!()
    for io in REGISTRY_CACHE_STREAMS
        close(io)
    end
    empty!(REGISTRY_CACHE_STREAMS)
    return nothing
end

# See loading.jl
const TOML_CACHE = Base.TOMLCache(Base.TOML.Parser{Dates}())
const TOML_LOCK = ReentrantLock()
_parsefile(toml_file::AbstractString) = Base.parsed_toml(toml_file, TOML_CACHE, TOML_LOCK)
function parsefile(in_memory_registry::Union{Dict, RegistryTarIndex, Nothing}, folder::AbstractString, file::AbstractString)
    if in_memory_registry === nothing
        return _parsefile(joinpath(folder, file))
    else
        content = in_memory_registry[to_tar_path_format(file)]
        parser = Base.TOML.Parser{Dates}(content; filepath = file)
        return Base.TOML.parse(parser)
    end
end

custom_isfile(in_memory_registry::Union{Dict, RegistryTarIndex, Nothing}, folder::AbstractString, file::AbstractString) =
    in_memory_registry === nothing ? isfile(joinpath(folder, file)) : haskey(in_memory_registry, to_tar_path_format(file))

# Info about each version of a package
mutable struct VersionInfo
    const git_tree_sha1::Base.SHA1
    const yanked::Bool
    uncompressed_compat::Dict{UUID, VersionSpec} # lazily initialized
    weak_uncompressed_compat::Dict{UUID, VersionSpec} # lazily initialized

    VersionInfo(git_tree_sha1::Base.SHA1, yanked::Bool) = new(git_tree_sha1, yanked)
end

# This is the information that exists in e.g. General/A/ACME
struct PkgInfo
    # Package.toml:
    repo::Union{String, Nothing}
    subdir::Union{String, Nothing}

    # Versions.toml:
    version_info::Dict{VersionNumber, VersionInfo}

    # Compat.toml
    compat::Dict{VersionRange, Dict{String, VersionSpec}}

    # Deps.toml
    deps::Dict{VersionRange, Dict{String, UUID}}

    # WeakCompat.toml
    weak_compat::Dict{VersionRange, Dict{String, VersionSpec}}

    # WeakDeps.toml
    weak_deps::Dict{VersionRange, Dict{String, UUID}}
end

isyanked(pkg::PkgInfo, v::VersionNumber) = pkg.version_info[v].yanked
treehash(pkg::PkgInfo, v::VersionNumber) = pkg.version_info[v].git_tree_sha1

function uncompress(compressed::Dict{VersionRange, Dict{String, T}}, vsorted::Vector{VersionNumber}) where {T}
    @assert issorted(vsorted)
    uncompressed = Dict{VersionNumber, Dict{String, T}}()
    for v in vsorted
        uncompressed[v] = Dict{String, T}()
    end
    for (vs, data) in compressed
        first = length(vsorted) + 1
        # We find the first and last version that are in the range
        # and since the versions are sorted, all versions in between are sorted
        for i in eachindex(vsorted)
            v = vsorted[i]
            v in vs && (first = i; break)
        end
        last = 0
        for i in reverse(eachindex(vsorted))
            v = vsorted[i]
            v in vs && (last = i; break)
        end
        for i in first:last
            v = vsorted[i]
            uv = uncompressed[v]
            for (key, value) in data
                if haskey(uv, key)
                    error("Overlapping ranges for $(key) for version $v in registry.")
                else
                    uv[key] = value
                end
            end
        end
    end
    return uncompressed
end

const JULIA_UUID = UUID("1222c4b2-2114-5bfd-aeef-88e4692bbb3e")
function initialize_uncompressed!(pkg::PkgInfo, versions = keys(pkg.version_info))
    # Only valid to call this with existing versions of the package
    # Remove all versions we have already uncompressed
    versions = filter!(v -> !isdefined(pkg.version_info[v], :uncompressed_compat), collect(versions))

    sort!(versions)

    uncompressed_compat = uncompress(pkg.compat, versions)
    uncompressed_deps = uncompress(pkg.deps, versions)

    for v in versions
        vinfo = pkg.version_info[v]
        compat = Dict{UUID, VersionSpec}()
        uncompressed_deps_v = uncompressed_deps[v]
        # Everything depends on Julia
        uncompressed_deps_v["julia"] = JULIA_UUID
        uncompressed_compat_v = uncompressed_compat[v]
        for (pkg, uuid) in uncompressed_deps_v
            vspec = get(uncompressed_compat_v, pkg, nothing)
            compat[uuid] = vspec === nothing ? VersionSpec() : vspec
        end
        @assert !isdefined(vinfo, :uncompressed_compat)
        vinfo.uncompressed_compat = compat
    end
    return pkg
end

function initialize_weak_uncompressed!(pkg::PkgInfo, versions = keys(pkg.version_info))
    # Only valid to call this with existing versions of the package
    # Remove all versions we have already uncompressed
    versions = filter!(v -> !isdefined(pkg.version_info[v], :weak_uncompressed_compat), collect(versions))

    sort!(versions)

    weak_uncompressed_compat = uncompress(pkg.weak_compat, versions)
    weak_uncompressed_deps = uncompress(pkg.weak_deps, versions)

    for v in versions
        vinfo = pkg.version_info[v]
        weak_compat = Dict{UUID, VersionSpec}()
        weak_uncompressed_deps_v = weak_uncompressed_deps[v]
        weak_uncompressed_compat_v = weak_uncompressed_compat[v]
        for (pkg, uuid) in weak_uncompressed_deps_v
            vspec = get(weak_uncompressed_compat_v, pkg, nothing)
            weak_compat[uuid] = vspec === nothing ? VersionSpec() : vspec
        end
        @assert !isdefined(vinfo, :weak_uncompressed_compat)
        vinfo.weak_uncompressed_compat = weak_compat
    end
    return pkg
end

function compat_info(pkg::PkgInfo)
    initialize_uncompressed!(pkg)
    return Dict(v => info.uncompressed_compat for (v, info) in pkg.version_info)
end

function weak_compat_info(pkg::PkgInfo)
    if isempty(pkg.weak_deps)
        return nothing
    end
    initialize_weak_uncompressed!(pkg)
    return Dict(v => info.weak_uncompressed_compat for (v, info) in pkg.version_info)
end

mutable struct PkgEntry
    # Registry.toml:
    const path::String
    const registry_path::String
    const name::String
    const uuid::UUID

    const in_memory_registry::Union{Dict{String, String}, RegistryTarIndex, Nothing}
    # Version.toml / (Compat.toml / Deps.toml):
    info::PkgInfo # lazily initialized

    PkgEntry(path, registry_path, name, uuid, in_memory_registry) = new(path, registry_path, name, uuid, in_memory_registry #= undef =#)
end

registry_info(pkg::PkgEntry) = init_package_info!(pkg)

# a Versions.toml entry: `VersionInfo(SHA1(v["git-tree-sha1"]::String), get(v, "yanked", false)::Bool)`,
# `v` told apart as a parsed TOML table (M4.2: static dispatch)
function version_info_entry(@nospecialize(v))
    if v isa Dict{String, Any}
        return VersionInfo(SHA1(v["git-tree-sha1"]::String), get(v, "yanked", false)::Bool)
    end
    Pkg.WASM_TARGET && error("PkgWasm: expected a table in Versions.toml")
    return Base.inferencebarrier(v -> VersionInfo(SHA1(v["git-tree-sha1"]::String), get(v, "yanked", false)::Bool))(v)::VersionInfo
end

function init_package_info!(pkg::PkgEntry)
    # Already uncompressed the info for this package, return early
    isdefined(pkg, :info) && return pkg.info
    path = pkg.registry_path

    d_p = parsefile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Package.toml"))
    name = d_p["name"]::String
    name != pkg.name && error("inconsistent name in Registry.toml ($(name)) and Package.toml ($(pkg.name)) for pkg at $(path)")
    repo = get(d_p, "repo", nothing)::Union{Nothing, String}
    subdir = get(d_p, "subdir", nothing)::Union{Nothing, String}

    # Versions.toml
    d_v = custom_isfile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Versions.toml")) ?
        parsefile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Versions.toml")) : Dict{String, Any}()
    version_info = Dict{VersionNumber, VersionInfo}(
        VersionNumber(k) =>
            version_info_entry(v) for (k, v) in d_v
    )

    # Compat.toml
    compat_data_toml = custom_isfile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Compat.toml")) ?
        parsefile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Compat.toml")) : Dict{String, Any}()
    compat = Dict{VersionRange, Dict{String, VersionSpec}}()
    for (v, data) in compat_data_toml
        data = data::Dict{String, Any}
        vr = VersionRange(v)
        d = Dict{String, VersionSpec}(dep => VersionSpec(vr_dep) for (dep, vr_dep::Union{String, Vector{String}}) in data)
        compat[vr] = d
    end

    # Deps.toml
    deps_data_toml = custom_isfile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Deps.toml")) ?
        parsefile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "Deps.toml")) : Dict{String, Any}()
    deps = Dict{VersionRange, Dict{String, UUID}}()
    for (v, data) in deps_data_toml
        data = data::Dict{String, Any}
        vr = VersionRange(v)
        d = Dict{String, UUID}(dep => UUID(uuid) for (dep, uuid::String) in data)
        deps[vr] = d
    end
    # All packages depend on julia
    deps[VersionRange()] = Dict("julia" => JULIA_UUID)

    # WeakCompat.toml
    weak_compat_data_toml = custom_isfile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "WeakCompat.toml")) ?
        parsefile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "WeakCompat.toml")) : Dict{String, Any}()
    weak_compat = Dict{VersionRange, Dict{String, VersionSpec}}()
    for (v, data) in weak_compat_data_toml
        data = data::Dict{String, Any}
        vr = VersionRange(v)
        d = Dict{String, VersionSpec}(dep => VersionSpec(vr_dep) for (dep, vr_dep::Union{String, Vector{String}}) in data)
        weak_compat[vr] = d
    end

    # WeakDeps.toml
    weak_deps_data_toml = custom_isfile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "WeakDeps.toml")) ?
        parsefile(pkg.in_memory_registry, pkg.registry_path, joinpath(pkg.path, "WeakDeps.toml")) : Dict{String, Any}()
    weak_deps = Dict{VersionRange, Dict{String, UUID}}()
    for (v, data) in weak_deps_data_toml
        data = data::Dict{String, Any}
        vr = VersionRange(v)
        d = Dict{String, UUID}(dep => UUID(uuid) for (dep, uuid::String) in data)
        weak_deps[vr] = d
    end

    @assert !isdefined(pkg, :info)
    pkg.info = PkgInfo(repo, subdir, version_info, compat, deps, weak_compat, weak_deps)

    return pkg.info
end

# Simplified tarball reader without path tracking overhead
function read_tarball_simple(
        callback::Function,
        predicate::Function,
        tar::IO;
        buf::Vector{UInt8} = Vector{UInt8}(undef, Tar.DEFAULT_BUFFER_SIZE),
    )
    globals = Dict{String, String}()
    while !eof(tar)
        hdr = Tar.read_header(tar, globals = globals, buf = buf)
        hdr === nothing && break
        predicate(hdr)::Bool || continue
        Tar.check_header(hdr)
        before = applicable(position, tar) ? position(tar) : 0
        callback(hdr)
        applicable(position, tar) || continue
        advanced = position(tar) - before
        expected = Tar.round_up(hdr.size)
        advanced == expected ||
            error("callback read $advanced bytes instead of $expected")
    end
    return
end

function uncompress_registry(tar_gz::AbstractString)
    if !isfile(tar_gz)
        error("$(repr(tar_gz)): No such file")
    end
    data = Dict{String, String}()
    buf = Vector{UInt8}(undef, Tar.DEFAULT_BUFFER_SIZE)
    io = IOBuffer()
    # PkgWasm (PLAN.md D2): decompressed through the Host seam, not a `zstd`/`7z` pipeline
    with_decompressed(tar_gz) do tar_path
        open(tar_path) do tar
            read_tarball_simple(x -> true, tar; buf = buf) do hdr
                Tar.read_data(tar, io; size = hdr.size, buf = buf)
                data[hdr.path] = String(take!(io))
            end
        end
    end
    return data
end

# PkgWasm registry unpack cache. Reading a compressed registry the stock way decompresses and
# walks the whole tarball (about 88 MB and 77k entries for General) on every load: ~0.3 s
# natively but ~3.4 s in Wasm, on every command. With the cache, the first load writes the
# decompressed tarball and an index (entry path => data offset and size) to
#     <DEPOT_PATH[1]>/scratchspaces/<Pkg UUID>/registry_cache/<git-tree-sha1>.idx
#     <DEPOT_PATH[1]>/scratchspaces/<Pkg UUID>/registry_cache/<git-tree-sha1>-<generation>.tar
# and later loads read only the index plus the entries they need (Registry.toml and the
# packages a command touches), with seek + read. The registry itself is untouched: it is still
# the stock compressed layout, reported as `:packed`, and `RegistryInstance` holds a
# `RegistryTarIndex` where stock holds the `Dict` of all files (same `haskey`/`getindex`/
# `delete!` use).
#
# Correctness when the registry changes: the index records the identity of the compressed
# tarball it was built from (absolute path, size, mtime and ctime at full precision, inode),
# taken before and checked again after the build, and it is used only while that identity
# is unchanged, so `Registry.update` (a new tarball and tree hash), `rm` + `add`, or any other
# rewrite or replacement of the tarball invalidates it. A tar generation is written once
# under a fresh name and never modified; the index names it and is published last, by one
# rename, so an index always describes the tar it names, including after a crash. A reader
# opens that tar when it reads the index, so pruning does not affect it. The previous
# generation for the same tree hash and entries built from earlier versions of the same
# tarball are removed when a new one is published. Any failure to build or read the cache,
# including a later read of an entry, falls back to the stock in-memory read.
# Single writer, as for all PkgWasm depot writes (mkpidlock is a no-op): two processes that
# build the cache for the same tarball at once each publish a complete, self-consistent
# generation (the last rename wins), but one may remove the other's tar while it is still
# needed, in which case that process falls back to the in-memory read.
# `Pkg.gc` removes the cache directory like any unused scratch space; it is rebuilt on the
# next load. On by default in Wasm, off natively; `JULIA_PKG_REGISTRY_CACHE=true|false`
# overrides.
# (`RegistryTarIndex`: at the top of this file)
const REGISTRY_CACHE_MAGIC = "pkgwasm-registry-cache-v2"

registry_cache_enabled() = Base.get_bool_env("JULIA_PKG_REGISTRY_CACHE", Pkg.WASM_TARGET) === true

registry_cache_dir() = joinpath(Pkg.depots1(), "scratchspaces", "44cfe95a-1eb2-52ea-b672-e2afdf69b78f", "registry_cache")

# The identity of the compressed tarball, as recorded in (and checked against) the index
# header; the path is the last field.
function registry_cache_source(compressed_tar::String)
    st = stat(compressed_tar)
    return string(REGISTRY_CACHE_MAGIC, '\t', st.size, '\t', st.mtime, '\t', st.ctime, '\t', st.inode, '\t', compressed_tar)
end

# The index header: source identity, tar generation file name, its size
function parse_registry_cache_header(text::String)
    lines = split(text, '\n'; limit = 4)
    length(lines) == 4 || return nothing
    return String(lines[1]), String(lines[2]), tryparse(Int64, lines[3]), lines[4]
end

# The cached index for `compressed_tar` (tree hash `tree_info`), or `nothing` if there is none
# that matches the tarball as it is now. The tar is opened here (see `RegistryTarIndex`).
function read_registry_cache(dir::String, tree_info::Base.SHA1, source::String, compressed_tar::String)
    idx = joinpath(dir, string(tree_info, ".idx"))
    isfile(idx) || return nothing
    h = parse_registry_cache_header(read(idx, String))
    h === nothing && return nothing
    src, tarname, tarsize, body = h
    (src == source && tarsize !== nothing && startswith(tarname, string(tree_info, '-'))) || return nothing
    tar = joinpath(dir, tarname)
    isfile(tar) || return nothing
    io = open_registry_cache_stream(tar)
    if filesize(io) != tarsize
        close(io)
        return nothing
    end
    entries = Dict{String, Tuple{Int64, Int64}}()
    for line in eachsplit(body, '\n'; keepempty = false)
        t1 = findfirst('\t', line)::Int
        t2 = findnext('\t', line, t1 + 1)::Int
        entries[String(SubString(line, t2 + 1))] =
            (parse(Int64, SubString(line, 1, t1 - 1)), parse(Int64, SubString(line, t1 + 1, t2 - 1)))
    end
    return RegistryTarIndex(compressed_tar, tar, entries, io, nothing)
end

# An IO that counts the bytes written to it (as `tee` of `Tar.read_header`: the bytes read)
mutable struct ByteCounter <: IO
    n::Int64
end
Base.write(c::ByteCounter, x::UInt8) = (c.n += 1; 1)
Base.unsafe_write(c::ByteCounter, ::Ptr{UInt8}, n::UInt) = (c.n += Int(n); Int(n))

# Whether `Tar.check_header` accepts `hdr`, decided by one scan of its path, without the
# regular expressions, for the usual header: a file or directory with an ASCII path without
# control characters. For any other header this is `false` and `Tar.check_header` decides
# (and throws its errors).
function tar_header_ok(hdr::Tar.Header)
    (hdr.type === :file || hdr.type === :directory) || return false
    (isempty(hdr.link) && hdr.size >= 0) || return false
    hdr.type === :directory && hdr.size != 0 && return false
    p = codeunits(hdr.path)
    n = length(p)
    (n > 0 && p[1] != UInt8('/')) || return false
    hdr.type !== :directory && p[n] == UInt8('/') && return false
    start = 1   # (the first byte of the component)
    for i in 1:(n + 1)
        if i > n || p[i] == UInt8('/')
            len = i - start
            # no `..` component; a non-directory's last component is not `.`
            len == 2 && p[start] == UInt8('.') && p[start + 1] == UInt8('.') && return false
            i > n && hdr.type !== :directory && len == 1 && p[start] == UInt8('.') && return false
            start = i + 1
        elseif p[i] < 0x20 || p[i] >= 0x7f
            return false
        end
    end
    return true
end

# Decompress `compressed_tar` into a new tar generation, index it and publish the index;
# returns the index, or `nothing` if the tarball changed during the build.
function write_registry_cache(dir::String, tree_info::Base.SHA1, source::String, compressed_tar::String)
    mkpath(dir)
    gen = basename(tempname(dir; cleanup = false))
    tarname = string(tree_info, '-', gen, ".tar")
    tar = joinpath(dir, tarname)
    tmp_idx = joinpath(dir, string(gen, ".idx.partial"))
    published = false
    try
        Pkg.Host.decompress(compressed_tar, tar)
        entries = Dict{String, Tuple{Int64, Int64}}()
        buf = Vector{UInt8}(undef, Tar.DEFAULT_BUFFER_SIZE)
        open(tar) do io
            globals = Dict{String, String}()
            # (the offset of the next header, from the bytes Tar reads: no `position` calls)
            counted = ByteCounter(0)
            off = Int64(0)
            while !eof(io)
                counted.n = 0
                hdr = Tar.read_header(io, globals = globals, buf = buf, tee = counted)
                hdr === nothing && break
                off += counted.n
                tar_header_ok(hdr) || Tar.check_header(hdr)
                ('\n' in hdr.path || '\t' in hdr.path) && error("unsupported entry path $(repr(hdr.path))")
                entries[hdr.path] = (off, Int64(hdr.size))
                off += Tar.round_up(hdr.size)
                skip(io, Tar.round_up(hdr.size))
            end
        end
        # the tarball must not have changed while it was read
        registry_cache_source(compressed_tar) == source || return nothing
        out = IOBuffer()
        print(out, source, '\n', tarname, '\n', filesize(tar), '\n')
        for (path, (off, size)) in entries
            print(out, off, '\t', size, '\t', path, '\n')
        end
        write(tmp_idx, take!(out))
        idx = joinpath(dir, string(tree_info, ".idx"))
        # what the index being replaced names, and entries of earlier versions of this tarball
        stale = String[]
        path_field = string('\t', compressed_tar)
        for f in readdir(dir)
            endswith(f, ".idx") || continue
            p = joinpath(dir, f)
            h = parse_registry_cache_header(read(p, String))
            h === nothing && continue
            if f == basename(idx)
                h[2] == tarname || push!(stale, joinpath(dir, h[2]))
            elseif endswith(h[1], path_field)
                push!(stale, p, joinpath(dir, h[2]))
            end
        end
        Base.mv(tmp_idx, idx; force = true)
        published = true
        for p in stale
            Base.rm(p; force = true)
        end
        io = open_registry_cache_stream(tar)
        return RegistryTarIndex(compressed_tar, tar, entries, io, nothing)
    finally
        Base.rm(tmp_idx; force = true)
        published || Base.rm(tar; force = true)
    end
end

# The files of a compressed registry: from the unpack cache when enabled (building it on the
# first load), otherwise (or if the cache fails) the stock in-memory `Dict`.
function load_compressed_registry(compressed_tar::String, tree_info::Union{Base.SHA1, Nothing})
    if tree_info !== nothing && registry_cache_enabled()
        try
            dir = registry_cache_dir()
            path = abspath(compressed_tar)
            source = registry_cache_source(path)
            cached = read_registry_cache(dir, tree_info, source, path)
            cached === nothing || return cached
            built = write_registry_cache(dir, tree_info, source, path)
            built === nothing || return built
        catch e
            @pkg_debug "registry cache unavailable, reading $(compressed_tar) in memory" exception = e
        end
    end
    return uncompress_registry(compressed_tar)
end

struct RegistryInstance
    path::String
    name::String
    uuid::UUID
    repo::Union{String, Nothing}
    description::Union{String, Nothing}
    pkgs::Dict{UUID, PkgEntry}
    tree_info::Union{Base.SHA1, Nothing}
    in_memory_registry::Union{Nothing, Dict{String, String}, RegistryTarIndex}
    # various caches
    name_to_uuids::Dict{String, Vector{UUID}}
end

const REGISTRY_CACHE = Dict{String, Tuple{Base.SHA1, Bool, RegistryInstance}}()

function get_cached_registry(path, tree_info::Base.SHA1, compressed::Bool)
    if !ispath(path)
        delete!(REGISTRY_CACHE, path)
        return nothing
    end
    v = get(REGISTRY_CACHE, path, nothing)
    if v !== nothing
        cached_tree_info, cached_compressed, reg = v
        if cached_tree_info == tree_info && cached_compressed == compressed
            return reg
        end
    end
    # Prevent hogging up memory indefinitely
    length(REGISTRY_CACHE) > 20 && empty!(REGISTRY_CACHE)
    return nothing
end

function RegistryInstance(path::AbstractString)
    compressed_file = nothing
    if isfile(path)
        @assert splitext(path)[2] == ".toml"
        d_reg_info = parsefile(nothing, dirname(path), basename(path))
        compressed_file = d_reg_info["path"]::String
        tree_info = Base.SHA1(d_reg_info["git-tree-sha1"]::String)
    else
        tree_info_file = joinpath(path, ".tree_info.toml")
        tree_info = if isfile(tree_info_file)
            Base.SHA1(parsefile(nothing, path, ".tree_info.toml")["git-tree-sha1"]::String)
        else
            nothing
        end
    end
    # Reuse an existing cached registry if it exists for this content
    if tree_info !== nothing
        reg = get_cached_registry(path, tree_info, compressed_file !== nothing)
        if reg isa RegistryInstance
            return reg
        end
    end

    # PkgWasm (registry-tar spike, approach (a)): a compressed registry (stock's layout) is
    # read in memory as stock does; `uncompress_registry` decompresses it through the Host
    # seam (`with_decompressed`), not a `7z` pipeline.
    in_memory_registry = if compressed_file !== nothing
        # (or from the unpack cache: `load_compressed_registry`)
        load_compressed_registry(joinpath(dirname(path), compressed_file), tree_info)
    else
        nothing
    end

    d = parsefile(in_memory_registry, path, "Registry.toml")
    pkgs = Dict{UUID, PkgEntry}()
    for (uuid, info) in d["packages"]::Dict{String, Any}
        uuid = UUID(uuid::String)
        info::Dict{String, Any}
        name = info["name"]::String
        pkgpath = info["path"]::String
        pkg = PkgEntry(pkgpath, path, name, uuid, in_memory_registry)
        pkgs[uuid] = pkg
    end
    reg = RegistryInstance(
        path,
        d["name"]::String,
        UUID(d["uuid"]::String),
        get(d, "repo", nothing)::Union{String, Nothing},
        get(d, "description", nothing)::Union{String, Nothing},
        pkgs,
        tree_info,
        in_memory_registry,
        Dict{String, UUID}(),
    )
    if tree_info !== nothing
        REGISTRY_CACHE[path] = (tree_info, compressed_file !== nothing, reg)
    end
    return reg
end

function Base.show(io::IO, ::MIME"text/plain", r::RegistryInstance)
    println(io, "Registry: $(repr(r.name)) at $(repr(r.path)):")
    println(io, "  uuid: ", r.uuid)
    println(io, "  repo: ", r.repo)
    if r.tree_info !== nothing
        println(io, "  git-tree-sha1: ", r.tree_info)
    end
    println(io, "  packages: ", length(r.pkgs))
    return
end

function uuids_from_name(r::RegistryInstance, name::String)
    create_name_uuid_mapping!(r)
    return get(Vector{UUID}, r.name_to_uuids, name)
end

function create_name_uuid_mapping!(r::RegistryInstance)
    isempty(r.name_to_uuids) || return
    for (uuid, pkg) in r.pkgs
        uuids = get!(Vector{UUID}, r.name_to_uuids, pkg.name)
        push!(uuids, pkg.uuid)
    end
    return
end

function verify_compressed_registry_toml(path::String)
    d = TOML.tryparsefile(path)
    if d isa TOML.ParserError
        @pkg_warn "Failed to parse registry TOML file at $(repr(path))" exception = d
        return false
    end
    for key in ("git-tree-sha1", "uuid", "path")
        if !haskey(d, key)
            @pkg_warn "Expected key $(repr(key)) to exist in registry TOML file at $(repr(path))"
            return false
        end
    end
    compressed_file = joinpath(dirname(path), d["path"]::String)
    if !isfile(compressed_file)
        @pkg_warn "Expected the compressed registry for $(repr(path)) to exist at $(repr(compressed_file))"
        return false
    end
    return true
end

function reachable_registries(; depots::Union{String, Vector{String}} = Base.DEPOT_PATH)
    # collect registries
    if depots isa String
        depots = [depots]
    end
    registries = RegistryInstance[]
    for d in depots
        isdir(d) || continue
        reg_dir = joinpath(d, "registries")
        isdir(reg_dir) || continue
        reg_paths = readdir(reg_dir; join = true)
        candidate_registries = String[]
        # All folders could be registries
        append!(candidate_registries, filter(isdir, reg_paths))
        if registry_read_from_tarball()
            compressed_registries = filter(endswith(".toml"), reg_paths)
            # if we are reading compressed registries, ignore compressed registries
            # with the same name
            compressed_registry_names = Set([splitext(basename(file))[1] for file in compressed_registries])
            filter!(x -> !(basename(x) in compressed_registry_names), candidate_registries)
            for compressed_registry in compressed_registries
                if verify_compressed_registry_toml(compressed_registry)
                    push!(candidate_registries, compressed_registry)
                end
            end
        end

        for candidate in candidate_registries
            # candidate can be either a folder or a TOML file
            if isfile(joinpath(candidate, "Registry.toml")) || isfile(candidate)
                push!(registries, RegistryInstance(candidate))
            end
        end
    end
    return registries
end

# Dict interface

function Base.haskey(r::RegistryInstance, uuid::UUID)
    return haskey(r.pkgs, uuid)
end

function Base.keys(r::RegistryInstance)
    return keys(r.pkgs)
end

Base.getindex(r::RegistryInstance, uuid::UUID) = r.pkgs[uuid]

Base.get(r::RegistryInstance, uuid::UUID, default) = get(r.pkgs, uuid, default)

Base.iterate(r::RegistryInstance) = iterate(r.pkgs)
Base.iterate(r::RegistryInstance, state) = iterate(r.pkgs, state)
