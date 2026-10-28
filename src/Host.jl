# PkgWasm host seam (PLAN.md D2, ABI.md v1 §5).
#
# These are the only operations whose implementation differs between native Julia and Wasm.
# The methods below are the native implementations. For the Wasm build, the project patch file
# `runner/patches/pkgwasm-host.jl` (owned by lane wcg-event) redefines `download` and
# `decompress` on top of the WasmCodegen runtime, so the signatures here are part of the
# contract and must not change.

module Host

import Downloads
import ..Pkg # PlatformEngines is included after Host; its helpers are looked up at call time

"""
    Host.Response(status, url, headers)

Final response of a [`Host.download`](@ref): HTTP status, the URL after redirects and the
response headers (names as sent by the server).
"""
struct Response
    status::Int
    url::String
    headers::Vector{Pair{String, String}}
end

"""
    Host.HostError(status, msg)

A transport, decompression or host failure in the seam. `status` is a WASI errno
(ABI.md §7; `29` = EIO when nothing more specific is known), `msg` a human-readable text.
"""
struct HostError <: Exception
    status::Int
    msg::String
end

const WASI_EIO = 29
const WASI_EILSEQ = 25

# ABI.md §4 `http_start` flags bit0: follow redirects, at most 10.
const MAX_REDIRECTS = 10

Base.showerror(io::IO, e::HostError) = print(io, "HostError: ", e.msg, " (errno ", e.status, ")")

partial_path(dest::String) = dest * ".partial"

# Everything that leaves the seam is a `HostError`: a HostError passes through, anything else
# (Downloads.RequestError, filesystem errors while writing, publishing or cleaning up) becomes
# EIO with the original message.
as_host_error(err, what::String) =
    err isa HostError ? err : HostError(WASI_EIO, string(what, ": ", sprint(showerror, err)))

# Remove a temporary file on an error path. A failure here is reported (as a HostError)
# rather than silently leaving the file behind.
function cleanup!(path::String, err, what::String)
    try
        rm(path; force = true)
    catch rm_err
        throw(HostError(WASI_EIO, string(what, ": ", sprint(showerror, as_host_error(err, what)),
            "; additionally failed to remove ", path, ": ", sprint(showerror, rm_err))))
    end
    throw(as_host_error(err, what))
end

const NATIVE_DOWNLOADER = Ref{Union{Nothing, Downloads.Downloader}}(nothing)

# A private Downloader whose requests follow at most MAX_REDIRECTS redirects, as the Wasm side
# does; created on first use so no Downloader exists at precompile/image time.
function native_downloader()
    d = NATIVE_DOWNLOADER[]
    if d === nothing
        d = Downloads.Downloader()
        d.easy_hook = (easy, info) -> Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_MAXREDIRS, MAX_REDIRECTS)
        NATIVE_DOWNLOADER[] = d
    end
    return d
end

"""
    Host.init_runtime() -> nothing

Initialise Base's runtime globals for this session (ARGS, DEPOT_PATH, LOAD_PATH, the active
project, cwd, homedir, tempdir, ENV, the RNG seed), as Julia's own startup does natively.
`pkgwasm_init` calls it first, before any PkgWasm global is initialised. Natively Julia has
already done this, so it does nothing; in the Wasm build the patch calls the WasmCodegen
runtime's `init_base_globals!()` (ABI v3 §6 step 6).
"""
init_runtime()::Nothing = nothing

"""
    Host.platform() -> Base.BinaryPlatforms.Platform

The platform of the machine PkgWasm runs on (PLAN.md D13): natively `HostPlatform()`; in the
Wasm build the patch answers it from `julia_io.host_platform` (ABI v3) plus `julia_version`.
Called once per session by `pkgwasm_init`/`__init__`; use `PkgWasm.host_platform()` elsewhere.
"""
platform()::Base.BinaryPlatforms.Platform = Base.BinaryPlatforms.HostPlatform()

"""
    Host.download(url, dest, headers) -> Host.Response

GET `url` into `dest`, following at most 10 redirects. The body is written to
`dest * ".partial"` and renamed to `dest` only after a complete response with status < 400.
On HTTP status ≥ 400, `dest` and the partial file are removed and the response is returned;
the caller maps the status to the error stock Pkg reports. Any other failure (transport,
too many redirects, filesystem) removes the partial file, leaves a previous complete `dest`
untouched, and throws [`HostError`](@ref). A partial `dest` is never left behind.
"""
function download(url::String, dest::String, headers::Vector{Pair{String, String}})::Response
    tmp = partial_path(dest)
    what = "download $url"
    try
        rm(tmp; force = true)
        resp = open(tmp, "w") do output
            Downloads.request(url; output, headers, downloader = native_downloader())
        end
        if resp.status >= 400
            rm(tmp; force = true)
            rm(dest; force = true)
        else
            # one rename: an atomic replace or an error with the previous `dest` kept (`mv` with
            # `force` deletes `dest` first and may fall back to copying)
            Base.rename(tmp, dest)
        end
        return Response(resp.status, resp.url, Pair{String, String}[String(k) => String(v) for (k, v) in resp.headers])
    catch err
        cleanup!(tmp, err, what)
    end
end

"""
    Host.decompress(src, dst) -> nothing

Decompress the gzip file `src` (detected from its magic bytes) into `dst`; natively zstd is
not available on this branch (Pkg 1.12 has no Zstd_jll).
The output is written to `dst * ".partial"` and renamed on success. On any failure the
partial output is removed and a [`HostError`](@ref) is thrown: EILSEQ (25) for an
unrecognised format, EIO (29) otherwise.
"""
function decompress(src::String, dst::String)::Nothing
    tmp = partial_path(dst)
    what = "decompress $src"
    try
        rm(tmp; force = true)
        magic = open(io -> read(io, 4), src)
        cmd = if length(magic) >= 2 && magic[1] == 0x1f && magic[2] == 0x8b
            `$(Pkg.PlatformEngines.exe7z()) x -tgzip -so $src`
        else
            # Pkg 1.12 has no zstd decompressor among its dependencies (no Zstd_jll), so
            # natively only gzip is accepted, as Pkg 1.12 itself does.
            throw(HostError(WASI_EILSEQ, "$what: unrecognized compression format"))
        end
        err = IOBuffer()
        if !success(pipeline(cmd; stdout = tmp, stderr = err))
            throw(HostError(WASI_EIO, "$what: " * strip(String(take!(err)))))
        end
        Base.rename(tmp, dst) # one rename, as in `download`
    catch err
        cleanup!(tmp, err, what)
    end
    return nothing
end

end # module Host
