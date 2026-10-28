# PkgWasm entry points (PLAN.md D5, ABI.md v1 §5-6).
#
# The Wasm module exports these three functions. Natively they are plain Julia functions, so
# the same command driver can be exercised (and compared against stock Pkg) without a compile.
#
#   pkgwasm_abi_version() -> Int32   must return ABI_VERSION (ABI.md v3 §6 step 5)
#   pkgwasm_init()        -> Int32   0 = ok, 1 = error (printed to stderr)
#   pkgwasm_main()        -> Int32   exit code: 0 = ok, 1 = reported error
#
# Command line (WASI args, argv[0] stripped into ARGS): `pkgwasm <cmd> [pkgs...]` with
# <cmd> one of add, rm, resolve, instantiate, status.

const ABI_VERSION = Int32(3) # ABI.md v3

pkgwasm_abi_version() = ABI_VERSION

"""
    sanitize_globals!()

PkgWasm globals (PLAN.md D8, `lanes/pkg-fork/globals.md`) back to their fresh-session state:
every session cache emptied, every flag at its default, no stream or native-tool object held.
The build calls this right before image emission (WasmCodegen `Config(pre_image_hooks)`);
`pkgwasm_init` calls it again, so a command never sees state from the build host.

Safe to call at any time and any number of times: it only resets PkgWasm-owned globals to
values that are valid fresh-session state, touches no file, no host import and no Base
global, and takes no lock. Afterwards `host_platform()` throws until `init_globals!()`
(or `pkgwasm_init()`) runs again, so native use in the same process must re-init first.
"""
function sanitize_globals!()
    DEFAULT_IO[] = nothing
    OFFLINE_MODE[] = false
    UPDATED_REGISTRY_THIS_SESSION[] = false
    RESPECT_SYSIMAGE_VERSIONS[] = true
    PREV_ENV_PATH[] = ""
    _auto_gc_enabled[] = true
    Types.STDLIB[] = nothing # rebuilt lazily from the embedded STDLIB_DATA (D10) ...
    empty!(Types.UPGRADABLE_STDLIBS_UUIDS) # ... which also refills this set
    for cache in (Types.TOML_CACHE, Registry.TOML_CACHE)
        empty!(cache.d)
        # the reusable parser keeps the last input text, its parse tree and file path
        Base.TOML.reinit!(cache.p, ""; filepath = nothing)
    end
    empty!(PlatformEngines.AUTH_ERROR_HANDLERS)
    empty!(Registry.REGISTRY_CACHE)
    empty!(API.undo_entries)
    API.saved_initial_snapshot[] = false
    empty!(GitTools.GIT_PROTOCOLS)
    empty!(GitTools.GIT_USERS)
    Host.NATIVE_DOWNLOADER[] = nothing
    PlatformEngines.EXE7Z[] = ""
    PlatformEngines.EXEZSTD[] = ""
    HOST_PLATFORM[] = HOST_PLATFORM_PLACEHOLDER # D13: set by init_globals! from Host.platform()
    return nothing
end

"""
    init_globals!()

Initialise the PkgWasm globals that depend on the environment (PLAN.md D8): what stock
`__init__` does. In the Wasm image `__init__` does not run, so `pkgwasm_init` calls this
after the Base-side globals (ENV, DEPOT_PATH, ...) have been set up.
"""
function init_globals!()
    sanitize_globals!()
    HOST_PLATFORM[] = Host.platform() # D13: answered once per session by the host runtime
    OFFLINE_MODE[] = Base.get_bool_env("JULIA_PKG_OFFLINE", false)
    _auto_gc_enabled[] = Base.get_bool_env("JULIA_PKG_GC_AUTO", true)
    return nothing
end

# ABI v3 §6 step 6: the Base-side init (RNG seed via `random_get`, ENV/ARGS/DEPOT_PATH/
# LOAD_PATH/cwd/homedir/tempdir from WASI) is the seam `Host.init_runtime()` (Wasm: L1's
# runtime via L2's patch; natively a no-op, Julia's startup has done it), called first; then
# the PkgWasm globals (D8). The start function must not call any import, so nothing here runs
# at image load.
function pkgwasm_init()::Int32
    return try
        Host.init_runtime() # Base globals first (G2 B1); PkgWasm's own globals read them
        init_globals!()
        Int32(0)
    catch e
        report_error(e)
        Int32(1)
    end
end

pkgwasm_main()::Int32 = pkgwasm_main(ARGS)

const SUPPORTED_COMMANDS = ("add", "rm", "resolve", "instantiate", "status")

function pkgwasm_main(args::Vector{String})::Int32
    return try
        run_command(args)
        Int32(0)
    catch e
        report_error(e)
        Int32(1)
    end
end

function run_command(args::Vector{String})
    isempty(args) && Types.pkgerror("usage: pkgwasm <command> [packages...]; commands: ", join(SUPPORTED_COMMANDS, ", "))
    cmd = args[1]
    pkgs = PackageSpec[PackageSpec(name) for name in args[2:end]]
    if cmd == "add"
        isempty(pkgs) && Types.pkgerror("pkgwasm add: no packages given")
        API.add(pkgs)
    elseif cmd == "rm"
        isempty(pkgs) && Types.pkgerror("pkgwasm rm: no packages given")
        API.rm(pkgs)
    elseif cmd == "resolve"
        length(args) == 1 || Types.pkgerror("pkgwasm resolve takes no arguments")
        API.resolve()
    elseif cmd == "instantiate"
        length(args) == 1 || Types.pkgerror("pkgwasm instantiate takes no arguments")
        API.instantiate()
    elseif cmd == "status"
        API.status(pkgs)
    else
        Types.pkgerror("unknown command `", cmd, "`; supported: ", join(SUPPORTED_COMMANDS, ", "))
    end
    return nothing
end

# Errors are reported like the Pkg REPL mode does: `ERROR: ` plus the message, no backtrace.
function report_error(e)
    io = stderr_f()
    printstyled(io, "ERROR: "; color = Base.error_color(), bold = true)
    showerror(io, e)
    println(io)
    return nothing
end
