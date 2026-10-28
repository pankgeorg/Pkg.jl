# PkgWasm host seam (PLAN.md D2, ABI.md v1 §5).
#
# These are the only operations whose implementation differs between native Julia and Wasm.
# The methods below are the native implementations. For the Wasm build, the project patch file
# `runner/patches/pkgwasm-host.jl` (owned by lane wcg-event) redefines `download` and
# `decompress` on top of the WasmCodegen runtime, so the signatures here are part of the
# contract and must not change.

module Host

import Downloads
import ..Pkg.PlatformEngines: exe7z, exezstd

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

Base.showerror(io::IO, e::HostError) = print(io, "HostError: ", e.msg, " (errno ", e.status, ")")

partial_path(dest::String) = dest * ".partial"

function rm_quiet(path::String)
    try
        rm(path; force = true)
    catch
    end
    return nothing
end

"""
    Host.download(url, dest, headers) -> Host.Response

GET `url` into `dest`, following redirects. Throws [`HostError`](@ref) on transport failure.
On HTTP status ≥ 400 it removes `dest` and returns the response; the caller maps the status
to the error stock Pkg reports. A partial `dest` is never left behind.
"""
function download(url::String, dest::String, headers::Vector{Pair{String, String}})::Response
    tmp = partial_path(dest)
    rm_quiet(tmp)
    resp = try
        open(tmp, "w") do output
            Downloads.request(url; output, headers)
        end
    catch err
        rm_quiet(tmp)
        err isa Downloads.RequestError || rethrow()
        throw(HostError(WASI_EIO, sprint(showerror, err)))
    end
    if resp.status >= 400
        rm_quiet(tmp)
        rm_quiet(dest)
    else
        mv(tmp, dest; force = true)
    end
    return Response(resp.status, resp.url, Pair{String, String}[String(k) => String(v) for (k, v) in resp.headers])
end

"""
    Host.decompress(src, dst) -> nothing

Decompress the gzip or zstd file `src` (detected from its magic bytes) into `dst`.
The output is written to `dst * ".partial"` and renamed on success; on failure it is
removed and a [`HostError`](@ref) is thrown.
"""
function decompress(src::String, dst::String)::Nothing
    magic = open(io -> read(io, 4), src)
    cmd = if length(magic) >= 2 && magic[1] == 0x1f && magic[2] == 0x8b
        `$(exe7z()) x -tgzip -so $src`
    elseif magic == UInt8[0x28, 0xb5, 0x2f, 0xfd]
        `$(exezstd()) -d -c -q $src`
    else
        throw(HostError(WASI_EILSEQ, "decompress: unrecognized compression format in $src"))
    end
    tmp = partial_path(dst)
    err = IOBuffer()
    ok = try
        success(pipeline(cmd; stdout = tmp, stderr = err))
    catch e
        rm_quiet(tmp)
        throw(HostError(WASI_EIO, "decompress: " * sprint(showerror, e)))
    end
    if !ok
        rm_quiet(tmp)
        throw(HostError(WASI_EIO, "decompress: failed to decompress $src: " * String(take!(err))))
    end
    mv(tmp, dst; force = true)
    return nothing
end

end # module Host
