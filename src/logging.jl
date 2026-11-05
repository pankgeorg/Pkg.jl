# This file is a part of Julia. License is MIT: https://julialang.org/license

## Error text without dynamic calls (M4.2)
#
# The logging macros are stock `@warn` & co.: in WasmCodegen builds, WasmCompat's Logging
# extension prints them as ConsoleLogger does. What stays here is Pkg's: the text of the errors
# the supported commands throw, for a caught error of a type not known at compile time.

"""
    showerror_known(io, e)

`showerror(io, e)`. Natively exactly that. Built for Wasm, Base's messages for the errors
the supported commands throw, printed with typed fields (Base's `showerror`s print
`AbstractString` and `Any` fields), and a fixed message for others.
"""
function showerror_known(io::IO, @nospecialize(e))
    WASM_TARGET || return showerror(io, e)
    if e isa Types.PkgError
        print(io, e.msg)
    elseif e isa ErrorException
        print(io, typed_msg(e.msg))
    elseif e isa ArgumentError
        print(io, "ArgumentError: ", typed_msg(e.msg))
    elseif e isa Base.IOError
        print(io, "IOError: ", e.msg)
        if e.code == Base.UV_ENOENT && '~' in e.msg
            print(io, "\nMany shells expand '~' to the home directory in unquoted strings. To replicate this behavior, call",
                      " `expanduser` to expand the '~' character to the user’s home directory.")
        end
    elseif e isa SystemError
        errstring = Libc.strerror(e.errnum)
        extrainfo = e.extrainfo  # (Any: told apart by the types Base gives it, G3)
        if extrainfo === nothing
            print(io, "SystemError: ", e.prefix, ": ", errstring)
        elseif extrainfo isa String
            print(io, "SystemError (with ", extrainfo, "): ", e.prefix, ": ", errstring)
        else
            print(io, "SystemError (with extra information this build of PkgWasm cannot print): ", e.prefix, ": ", errstring)
        end
    elseif e isa Host.HostError
        showerror(io, e)
    elseif e isa PlatformEngines.Downloads.RequestError # (a download's transport failure or final status: stock's text)
        showerror(io, e)
    elseif e isa Base.TOML.ParserError
        showerror(io, e)
    elseif e isa Resolve.ResolverError
        # stock `showerror(::IO, ::ResolverError)`: the message, then a nested exception
        print(io, typed_msg(e.msg))
        ex = e.ex
        if ex isa CompositeException
            for cex in ex
                print(io, "\n=> ")
                showerror_known(io, cex)
            end
        elseif ex !== nothing
            print(io, "\n")
            showerror_known(io, ex)
        end
    else
        print(io, "an error that this build of PkgWasm cannot print")
    end
    return nothing
end
"""
    error_text(err)

`sprint(showerror, err)` for a caught error (natively exactly that text), through the typed
`showerror_known` and an IOBuffer: `sprint` with an untyped argument packs a `Tuple{Any}`,
which the Wasm build does not support.
"""
function error_text(@nospecialize(err))
    io = IOBuffer()
    showerror_known(io, err)
    return String(take!(io))
end

# a message field (an AbstractString): a String as it is
typed_msg(@nospecialize(m)) = m isa String ? m : m isa SubString{String} ? String(m) :
    "(a message this build of PkgWasm cannot print)"

"""
    pkg_showerror_hook(io, e) -> Bool

`showerror(io, e)` for the exceptions of Pkg that `showerror_known` prints (true), else
nothing (false). The Wasm build makes it `WasmCompat.showerror_hook`, so a logged
`exception = err` of these types prints as natively.
"""
function pkg_showerror_hook(io::IO, @nospecialize(e))
    (e isa Types.PkgError || e isa Host.HostError ||
     e isa Base.TOML.ParserError || e isa Resolve.ResolverError) || return false
    showerror_known(io, e)
    return true
end
