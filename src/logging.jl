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
log_lines(@nospecialize(msg)) = Tuple{Int, String}[(0, String(l)) for l in split(chomp(string(msg)), '\n')]

# `key = value` lines, as ConsoleLogger's `showvalue`
function log_kv!(lines::Vector{Tuple{Int, String}}, key::String, @nospecialize(val))
    buf = IOBuffer()
    if val isa Exception
        showerror_known(buf, val)
    elseif !WASM_TARGET
        val isa Tuple{Exception, Any} ? showerror_known(buf, val[1]) : show(buf, MIME"text/plain"(), val)
    # (built for Wasm: the values the supported paths log, shown typed)
    elseif val isa String
        show(buf, MIME"text/plain"(), val)
    elseif val isa Symbol
        show(buf, MIME"text/plain"(), val)
    elseif val isa Int64
        show(buf, MIME"text/plain"(), val)
    elseif val isa Bool
        show(buf, MIME"text/plain"(), val)
    elseif val isa Nothing
        show(buf, MIME"text/plain"(), val)
    elseif val isa VersionNumber
        show(buf, MIME"text/plain"(), val)
    elseif val isa Base.UUID
        show(buf, MIME"text/plain"(), val)
    else
        print(buf, "(a value this build of PkgWasm cannot show)")
    end
    vallines = split(String(take!(buf)), '\n')
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
        push!(body, :($(GlobalRef(@__MODULE__, :log_kv!))(lines, $(string(k)), $v)))
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
