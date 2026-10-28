# PkgWasm entry points (PLAN.md D5, ABI.md v1 §5-6).
#
# The Wasm module exports these three functions. Natively they are plain Julia functions, so
# the same command driver can be exercised (and compared against stock Pkg) without a compile.
#
#   pkgwasm_abi_version() -> Int32   must return ABI_VERSION (ABI.md §6 step 3)
#   pkgwasm_init()        -> Int32   0 = ok, 1 = error (printed to stderr)
#   pkgwasm_main()        -> Int32   exit code: 0 = ok, 1 = reported error
#
# Command line (WASI args, argv[0] stripped into ARGS): `pkgwasm <cmd> [pkgs...]` with
# <cmd> one of add, rm, resolve, instantiate, status.

const ABI_VERSION = Int32(1)

pkgwasm_abi_version() = ABI_VERSION

"""
    init_globals!()

Initialise the PkgWasm globals that depend on the environment (PLAN.md D8). Natively this is
what `__init__` does; in the Wasm image `__init__` does not run, so `pkgwasm_init` calls it.
"""
function init_globals!()
    OFFLINE_MODE[] = Base.get_bool_env("JULIA_PKG_OFFLINE", false)
    _auto_gc_enabled[] = Base.get_bool_env("JULIA_PKG_GC_AUTO", true)
    return nothing
end

function pkgwasm_init()::Int32
    return try
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
