# PkgWasm host seam (PLAN.md D2, ABI.md v1 §5).
#
# These are the only operations whose implementation differs between native Julia and Wasm.
# The methods below are the native implementations. For the Wasm build, the project patch file
# `runner/patches/pkgwasm-host.jl` redefines `decompress`, `platform`, `std_stream` and
# `init_runtime`, so the signatures here are part of the contract and must not change.
# Downloads are no longer part of the seam: they are stock Pkg's `Downloads.request`, which a
# Wasm build gets from WasmFetch's overlay (the host's fetch).

module Host

import ..PkgWasm # PlatformEngines is included after Host; its helpers are looked up at call time

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

# Everything that leaves the seam is a `HostError`: a HostError passes through, anything else
# (Downloads.RequestError, filesystem errors while writing, publishing or cleaning up) becomes
# EIO with the original message.
# (`err` not specialized on, its message by showerror_known: static built for Wasm, M4.2 G3)
as_host_error(@nospecialize(err), what::String) =
    err isa HostError ? err : HostError(WASI_EIO, string(what, ": ", sprint(PkgWasm.showerror_known, err)))

# Remove a temporary file on an error path. A failure here is reported (as a HostError)
# rather than silently leaving the file behind.
function cleanup!(path::String, @nospecialize(err), what::String)
    try
        rm(path; force = true)
    catch rm_err
        throw(HostError(WASI_EIO, string(what, ": ", sprint(showerror, as_host_error(err, what)),
            "; additionally failed to remove ", path, ": ", sprint(PkgWasm.showerror_known, rm_err))))
    end
    throw(as_host_error(err, what))
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
    Host.std_stream(fd::Int32) -> IO

The process's stdout (`fd = 1`) or stderr (`fd = 2`) that `StdStream` writes to. Natively
`Base.stdout`/`Base.stderr` (bindings typed `IO`); the Wasm build's patch returns the
WasmCodegen runtime's concrete stream for `fd`, so the writes are statically dispatched.
"""
std_stream(fd::Int32)::IO = fd == Int32(1) ? stdout : stderr

"""
    Host.platform() -> Base.BinaryPlatforms.Platform

The platform of the machine PkgWasm runs on (PLAN.md D13): natively `HostPlatform()`; in the
Wasm build the patch answers it from `julia_io.host_platform` (ABI v3) plus `julia_version`.
Called once per session by `pkgwasm_init`/`__init__`; use `PkgWasm.host_platform()` elsewhere.
"""
platform()::Base.BinaryPlatforms.Platform = Base.BinaryPlatforms.HostPlatform()

"""
    Host.decompress(src, dst) -> nothing

Decompress the gzip or zstd file `src` (detected from its magic bytes) into `dst`.
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
            `$(PkgWasm.PlatformEngines.exe7z()) x -tgzip -so $src`
        elseif magic == UInt8[0x28, 0xb5, 0x2f, 0xfd]
            `$(PkgWasm.PlatformEngines.exezstd()) -d -c -q $src`
        else
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
