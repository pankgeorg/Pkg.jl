# This file is a part of Julia. License is MIT: https://julialang.org/license

## Logging (M4.2: logging → direct prints)
#
# `@pkg_warn`, `@pkg_info`, `@pkg_debug`, `@pkg_error` are `@warn` & co. Natively they are
# exactly those (the same expansion, source location and keywords). Built for Wasm, where the
# logging machinery (the current logger is a scoped value, its dispatch is dynamic) is not
# compiled, they print what Base's default ConsoleLogger prints to `stderr` (`right_justify
# = 0`, no color; `@debug` below the default level prints nothing): the box, the level, the
# message's lines, `key = value` lines (values shown as `text/plain`, exceptions with
# `showerror`, without backtraces, so `catch_backtrace()` is not called), and for warnings and
# errors `@ Module file:line`. `maxlog`
# counts per id (`_id`, else the call site).

const LOG_MAXLOG_COUNTS = Dict{String, Int}()

# a message's lines: (indent, text)
# (G3 V19-V23: the message as a String without a dynamic `string`: messages are Strings; built
# for Wasm any other value prints a fixed text, natively `string(msg)` as before)
log_lines(@nospecialize(msg)) = Tuple{Int, String}[(0, String(l)) for l in split(chomp(log_message_string(msg)), '\n')]
log_message_string(@nospecialize(msg)) = msg isa String ? msg :
    msg isa SubString{String} ? String(msg) :
    WASM_TARGET ? "(a message this build of PkgWasm cannot print)" : string(msg)

# `key = value` lines, as ConsoleLogger's `showvalue`: a value shown as `text/plain` (the
# call specialized on the value's type at each call site: static where that type is known),
# an exception with `showerror` (`log_kv_exception!`)
function log_kv!(lines::Vector{Tuple{Int, String}}, key::String, val)
    val isa Exception && return log_kv_exception!(lines, key, val)
    buf = IOBuffer()
    show(buf, MIME"text/plain"(), val)
    return log_kv_lines!(lines, key, String(take!(buf)))
end
# (G3 row 2) a caught value logged as `key = value` (`err = log_value(err)`): natively the value
# itself, so the stock logging macros see exactly what they saw; built for Wasm a typed holder,
# so the untyped catch variable does not make the `log_kv!` call dynamic
struct LoggedValue
    val::Any
end
log_value(@nospecialize(x)) = WASM_TARGET ? LoggedValue(x) : x
function log_kv!(lines::Vector{Tuple{Int, String}}, key::String, v::LoggedValue)
    val = v.val
    val isa Exception && return log_kv_exception!(lines, key, val)
    buf = IOBuffer()
    WASM_TARGET ? print(buf, "(a value this build of PkgWasm cannot show)") : show(buf, MIME"text/plain"(), val)
    return log_kv_lines!(lines, key, String(take!(buf)))
end
# (G3 rows 40, 41, 50-52) a parsed TOML table logged as `key = value` (`auth = log_table(d)`):
# natively the table itself (stock output); built for Wasm its size and sorted keys, typed (the
# values, e.g. auth tokens, are `Any` and are not printed)
struct LoggedTable
    n::Int
    keys::Vector{String}
end
log_table(@nospecialize(d)) = !WASM_TARGET ? d :
    d isa Dict{String, Any} ? LoggedTable(length(d), sort!(collect(keys(d)))) : LoggedValue(d)
log_kv!(lines::Vector{Tuple{Int, String}}, key::String, v::LoggedTable) =
    log_kv_lines!(lines, key, string("Dict{String, Any} with ", v.n, v.n == 1 ? " entry" : " entries", isempty(v.keys) ? "" : string("; keys: ", join(v.keys, ", "))))

function log_kv_exception!(lines::Vector{Tuple{Int, String}}, key::String, @nospecialize(val))
    buf = IOBuffer()
    if val isa Exception
        showerror_known(buf, val)
    elseif !WASM_TARGET && val isa Tuple{Exception, Any}
        showerror_known(buf, val[1])
    elseif WASM_TARGET
        print(buf, "(a value this build of PkgWasm cannot show)")
    else
        show(buf, MIME"text/plain"(), val)
    end
    return log_kv_lines!(lines, key, String(take!(buf)))
end
function log_kv_lines!(lines::Vector{Tuple{Int, String}}, key::String, s::String)
    vallines = split(s, '\n')
    if length(vallines) == 1
        push!(lines, (2, string(key, " = ", vallines[1])))
    else
        push!(lines, (2, string(key, " =")))
        append!(lines, ((3, String(l)) for l in vallines))
    end
    return lines
end

# whether a message with `maxlog = n` and id `id` is still printed (and count it)
function log_maxlog!(id::String, n::Integer)
    remaining = get!(LOG_MAXLOG_COUNTS, id, Int(n))
    remaining == 0 && return false
    LOG_MAXLOG_COUNTS[id] = remaining - 1
    return true
end

function log_print(io::IO, prefix::String, lines::Vector{Tuple{Int, String}}, suffix::String)
    # (right_justify = 0: the suffix on a line of its own)
    isempty(suffix) || push!(lines, (0, ""))
    buf = IOBuffer()
    for (i, (indent, msg)) in enumerate(lines)
        boxstr = length(lines) == 1 ? "[ " : i == 1 ? "┌ " : i < length(lines) ? "│ " : "└ "
        print(buf, boxstr)
        i == 1 && print(buf, prefix, " ")
        print(buf, " "^indent, msg)
        i == length(lines) && !isempty(suffix) && print(buf, suffix)
        println(buf)
    end
    write(io, take!(buf))
    return nothing
end

log_suffix(mod::String, file::String, line::Int) = string("@ ", mod, " ", Base.contractuser(file), ":", line)

# the direct print of a log call (built for Wasm)
function log_direct_expr(level::Symbol, mod::Module, src::LineNumberNode, args)
    level === :Debug && return :(nothing)
    isempty(args) && return :(nothing)
    msg, kvs = args[1], args[2:end]
    prefix = level === :Warn ? "Warning:" : string(level, ":")
    suffix = level === :Info ? :("") :
        :($(GlobalRef(@__MODULE__, :log_suffix))($(string(mod)), $(string(src.file)), $(src.line)))
    body = Any[:(lines = $(GlobalRef(@__MODULE__, :log_lines))($msg))]
    maxlog, id = nothing, string(mod, ":", src.file, ":", src.line)
    for kv in kvs
        # (as Base: `k = v`, a variable, or any expression under its own text)
        k, v = if kv isa Expr && kv.head === :(=)
            kv.args[1], kv.args[2]
        elseif kv isa Symbol
            kv, kv
        else
            Symbol(kv), kv
        end
        k === :maxlog && (maxlog = v; continue)
        # (`exception = (e, backtrace)`: no backtraces built for Wasm, the exception only)
        k === :exception && v isa Expr && v.head === :tuple && length(v.args) == 2 && (v = v.args[1])
        k === :_id && (id = v; continue)
        k in (:_module, :_file, :_line, :_group) && continue
        f = k === :exception ? :log_kv_exception! : :log_kv!
        push!(body, :($(GlobalRef(@__MODULE__, f))(lines, $(string(k)), $v)))
    end
    push!(body, :($(GlobalRef(@__MODULE__, :log_print))($(GlobalRef(@__MODULE__, :stderr_f))(), $prefix, lines, $suffix)))
    ex = Expr(:let, Expr(:block), Expr(:block, body...))
    if maxlog !== nothing
        idex = id isa String ? id : :(string($id))
        ex = :($(GlobalRef(@__MODULE__, :log_maxlog!))($idex, $maxlog) ? $ex : nothing)
    end
    return ex
end

for (name, level) in ((:pkg_debug, :Debug), (:pkg_info, :Info), (:pkg_warn, :Warn), (:pkg_error, :Error))
    stock = Symbol("@", lowercase(string(level)))
    @eval macro $name(args...)
        stock = Expr(:macrocall, GlobalRef(Base, $(QuoteNode(stock))), __source__, args...)
        direct = log_direct_expr($(QuoteNode(level)), __module__, __source__, args)
        return esc(:($(GlobalRef(@__MODULE__, :WASM_TARGET)) ? $direct : $stock))
    end
end

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
    elseif e isa Base.TOML.ParserError
        showerror(io, e)
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
