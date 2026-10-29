# This file is a part of Julia. License is MIT: https://julialang.org/license

"""
    TOMLWriter

`TOML.print` for the tables PkgWasm writes, with static dispatch (PLAN.md M4.2): Base's
printer (TOML's `src/print.jl` in Julia 1.12) dispatches on `Any` values
and through `invokelatest`, and keeps its inline tables in an `IdSet`. Here each value is
told apart by `isa` over the types Pkg's tables hold, and printed exactly as Base prints
it; any other type is printed by Base's printer natively, and is an error built for Wasm
(`WASM_TARGET`, where that branch is not compiled). `inline_tables` is a vector, compared
by identity as an `IdSet` is.
"""
module TOMLWriter

import Dates
using UUIDs: UUID
using Base: SHA1
import TOML
using TOML.Internals.Printer: print_toml_escaped, printkey
import ..WASM_TARGET

const TOMLDates = Union{Base.TOML.DateTime, Base.TOML.Time, Base.TOML.Date, Dates.DateTime, Dates.Time, Dates.Date}

# `TOML.Internals.Printer.TOMLValue`
is_valid_toml_value(@nospecialize(value)) = value isa Union{
    AbstractVector, AbstractDict, Bool, Integer, AbstractFloat, AbstractString, TOMLDates,
}

# `to_toml_value`, for the conversion function `f` on a value of a concrete type
function to_toml_value(f::F, value::T) where {F, T}
    if f === nothing
        error("type `$(T)` is not a valid TOML type, pass a conversion function to `TOML.print`")
    end
    toml_value = f(value)
    if !is_valid_toml_value(toml_value)
        error("TOML syntax function for type `$(T)` did not return a valid TOML type but a `$(typeof(toml_value))`")
    end
    return toml_value
end

# the value, converted by `f` if it is not a TOML value (as `print_table` does); the types
# of the values Pkg converts are told apart, so that `f` is called on a concrete type
function toml_valid(f::F, @nospecialize(value)) where {F}
    is_valid_toml_value(value) && return value
    value isa UUID && return to_toml_value(f, value)
    value isa SHA1 && return to_toml_value(f, value)
    value isa VersionNumber && return to_toml_value(f, value)
    value isa Nothing && return to_toml_value(f, value)
    value isa Symbol && return to_toml_value(f, value)
    WASM_TARGET && error("PkgWasm TOML writer: unsupported value type")
    return Base.inferencebarrier(TOML.Internals.Printer.to_toml_value)(f, value)
end

# The table and array types Pkg's tables hold. The recursive printers below take their
# table or array unspecialized and read it through these accessors, so each has one
# signature: specializations of one method calling each other through `printvalue` are
# settled by inference with limited accuracy, which is not cached, and the trim verifier then
# finds no code for them (G3). Another type is natively printed as stock does (the
# `_generic` methods), and an error built for Wasm.
const TABLE_TYPES = (Dict{String, Any}, Dict{String, String}, Dict{String, Vector{String}}, Dict{String, UUID},
    Dict{String, Vector{Dict{String, Any}}}, Dict{String, Union{String, Vector{String}}},
    Dict{String, Dict{String, String}}, Dict{String, Dates.DateTime})
const VECTOR_TYPES = (Vector{Any}, Vector{String}, Vector{Int64}, Vector{Float64}, Vector{Bool},
    Vector{Dates.DateTime}, Vector{Dates.Date}, Vector{Dates.Time},
    Vector{Dict{String, Any}}, Vector{Dict{String, Dates.DateTime}})
# an `isa` chain over `types`: `body(T)` for the type of `x`, `otherwise` for none
isa_chain(x::Symbol, types, body, otherwise) =
    foldr((T, rest) -> :($x isa $T ? $(body(T)) : $rest), types; init = otherwise)
@eval Base.@nospecializeinfer is_typed_table(@nospecialize(t)) = $(isa_chain(:t, TABLE_TYPES, T -> true, false))
@eval Base.@nospecializeinfer is_typed_vector(@nospecialize(v)) = $(isa_chain(:v, VECTOR_TYPES, T -> true, false))
# the keys of a table (in `keys` order), the value at a key, an array's length and element
@eval Base.@nospecializeinfer table_keys(@nospecialize(t)) = $(isa_chain(:t, TABLE_TYPES, T -> :(collect(keys(t::$T))::Vector{String}),
    :(WASM_TARGET ? error("PkgWasm TOML writer: unsupported table type") : Base.inferencebarrier(collect)(keys(t)))))
@eval Base.@nospecializeinfer table_get(@nospecialize(t), k::String) = $(isa_chain(:t, TABLE_TYPES, T -> :((t::$T)[k]),
    :(error("PkgWasm TOML writer: unsupported table type"))))
@eval Base.@nospecializeinfer vector_length(@nospecialize(v)) = $(isa_chain(:v, VECTOR_TYPES, T -> :(length(v::$T)),
    :(error("PkgWasm TOML writer: unsupported array type"))))
@eval Base.@nospecializeinfer vector_get(@nospecialize(v), i::Int) = $(isa_chain(:v, VECTOR_TYPES, T -> :((v::$T)[i]),
    :(error("PkgWasm TOML writer: unsupported array type"))))
# (a table's value by key, whatever its keys: natively for a table of another type)
Base.@nospecializeinfer table_value(@nospecialize(t), @nospecialize(k)) =
    is_typed_table(t) ? table_get(t, k::String) : Base.inferencebarrier(getindex)(t, k)

##########
# Values #
##########

function printstring(io::IO, value::AbstractString)
    qmark = Base.contains(value, "\n") ? "\"\"\"" : "\""
    Base.print(io, qmark)
    print_toml_escaped(io, value)
    Base.print(io, qmark)
end

function printfloat(io::IO, value::Float64)
    if isnan(value)
        Base.print(io, "nan")
    elseif isinf(value)
        Base.print(io, value > 0 ? "+inf" : "-inf")
    else
        Base.print(io, value) # TOML specifies IEEE 754 binary64 for float
    end
end

Base.@nospecializeinfer function printvector(f::F, io::IO, @nospecialize(value::AbstractVector), sorted::Bool) where {F}
    if !is_typed_vector(value)
        WASM_TARGET && error("PkgWasm TOML writer: unsupported array type")
        return Base.inferencebarrier(printvector_generic)(f, io, value, sorted)
    end
    Base.print(io, "[")
    for i in 1:vector_length(value)
        i != 1 && Base.print(io, ", ")
        printvalue(f, io, vector_get(value, i), sorted)
    end
    Base.print(io, "]")
end
function printvector_generic(f::F, io::IO, value::AbstractVector, sorted::Bool) where {F}
    Base.print(io, "[")
    for (i, x) in enumerate(value)
        i != 1 && Base.print(io, ", ")
        printvalue(f, io, x, sorted)
    end
    Base.print(io, "]")
end

Base.@nospecializeinfer function printvalue(f::F, io::IO, @nospecialize(value), sorted::Bool) where {F}
    if value isa String
        printstring(io, value)
    elseif value isa SubString{String}
        printstring(io, value)
    elseif value isa Bool
        Base.print(io, value ? "true" : "false")
    elseif value isa Int64
        Base.show(io, value)
    elseif value isa Float64
        printfloat(io, value)
    elseif value isa Vector{String}
        printvector(f, io, value, sorted)
    elseif value isa Vector{Any}
        printvector(f, io, value, sorted)
    elseif value isa Vector{Int64}
        printvector(f, io, value, sorted)
    elseif value isa Vector{Float64}
        printvector(f, io, value, sorted)
    elseif value isa Vector{Bool}
        printvector(f, io, value, sorted)
    elseif value isa Vector{Dates.DateTime}
        printvector(f, io, value, sorted)
    elseif value isa Vector{Dates.Date}
        printvector(f, io, value, sorted)
    elseif value isa Vector{Dates.Time}
        printvector(f, io, value, sorted)
    elseif value isa Vector{Dict{String, Any}}
        printvector(f, io, value, sorted)
    elseif value isa Dict{String, Any}
        print_inline_table(f, io, value, sorted)
    elseif value isa Dict{String, String}
        print_inline_table(f, io, value, sorted)
    elseif value isa Dict{String, UUID}
        print_inline_table(f, io, value, sorted)
    elseif value isa Dict{String, Vector{Dict{String, Any}}}
        print_inline_table(f, io, value, sorted)
    elseif value isa Dict{String, Union{String, Vector{String}}}
        print_inline_table(f, io, value, sorted)
    elseif value isa Dict{String, Dict{String, String}}
        print_inline_table(f, io, value, sorted)
    elseif value isa Dict{String, Dates.DateTime}
        print_inline_table(f, io, value, sorted)
    elseif value isa Vector{Dict{String, Dates.DateTime}}
        printvector(f, io, value, sorted)
    elseif value isa Base.TOML.DateTime # (Julia 1.12's printer formats it as a Dates.DateTime)
        Base.print(io, Dates.format(Dates.DateTime(value), Dates.dateformat"YYYY-mm-dd\THH:MM:SS.sss\Z"))
    elseif value isa Base.TOML.Time
        Base.print(io, Dates.format(Dates.Time(value), Dates.dateformat"HH:MM:SS.sss"))
    elseif value isa Base.TOML.Date
        Base.print(io, Dates.format(Dates.Date(value), Dates.dateformat"YYYY-mm-dd"))
    elseif value isa Dates.DateTime
        Base.print(io, Dates.format(value, Dates.dateformat"YYYY-mm-dd\THH:MM:SS.sss\Z"))
    elseif value isa Dates.Time
        Base.print(io, Dates.format(value, Dates.dateformat"HH:MM:SS.sss"))
    elseif value isa Dates.Date
        Base.print(io, Dates.format(value, Dates.dateformat"YYYY-mm-dd"))
    elseif !is_valid_toml_value(value)
        # (Base's fallback: convert, and print what `f` returns)
        printvalue(f, io, toml_valid(f, value), sorted)
    else
        WASM_TARGET && error("PkgWasm TOML writer: unsupported value type")
        Base.inferencebarrier(TOML.Internals.Printer.printvalue)(f, io, value, sorted)
    end
    return nothing
end

Base.@nospecializeinfer function print_inline_table(f::F, io::IO, @nospecialize(value::AbstractDict), sorted::Bool) where {F}
    vkeys = table_keys(value)::AbstractArray
    if sorted
        sort!(vkeys)
    end
    Base.print(io, "{")
    for (i, k) in enumerate(vkeys)
        v = table_value(value, k)
        i != 1 && Base.print(io, ", ")
        printkey(io, [String(k)])
        Base.print(io, " = ")
        printvalue(f, io, v, sorted)
    end
    Base.print(io, "}")
end

##########
# Tables #
##########

is_table(@nospecialize(value)) = isa(value, AbstractDict)
function is_array_of_tables(@nospecialize(value))
    value isa Vector{Dict{String, Any}} && return length(value) > 0
    value isa Vector{Dict{String, Dates.DateTime}} && return length(value) > 0
    value isa Vector{Any} && return length(value) > 0 && all(v -> isa(v, AbstractDict), value)
    # (the typed vectors of TOML's parser: no tables)
    (value isa Vector{String} || value isa Vector{Int64} || value isa Vector{Float64} || value isa Vector{Bool} ||
     value isa Vector{Dates.DateTime} || value isa Vector{Dates.Date} || value isa Vector{Dates.Time}) && return false
    value isa AbstractArray || return false
    WASM_TARGET && error("PkgWasm TOML writer: unsupported array type")
    return Base.inferencebarrier(TOML.Internals.Printer.is_array_of_tables)(value)::Bool
end
is_tabular(@nospecialize(value)) = is_table(value) || is_array_of_tables(value)

isinline(@nospecialize(value), inline_tables::Union{Nothing, Vector}) =
    inline_tables !== nothing && any(t -> t === value, inline_tables)

# `print_table` on a table of a type Pkg's tables hold (the keywords explicit: no splat)
Base.@nospecializeinfer function print_subtable(f::F, io::IO, @nospecialize(value), ks::Vector{String};
                        indent::Int = 0, first_block::Bool = true, sorted::Bool = false,
                        by::B = identity, inline_tables::Union{Nothing, Vector} = nothing) where {F, B}
    if is_typed_table(value)
        print_table(f, io, value::AbstractDict, ks; indent, first_block, sorted, by, inline_tables)
    else
        WASM_TARGET && error("PkgWasm TOML writer: unsupported table type")
        Base.inferencebarrier(print_table)(f, io, value, ks; indent, first_block, sorted, by, inline_tables)
    end
    return nothing
end

Base.@nospecializeinfer function print_table(
        f::F, io::IO, @nospecialize(a::AbstractDict),
        ks::Vector{String} = String[];
        indent::Int = 0,
        first_block::Bool = true,
        sorted::Bool = false,
        inline_tables::Union{Nothing, Vector} = nothing,
        by::B = identity,
    ) where {F, B}

    if isinline(a, inline_tables)
        print_inline_table(f, io, a, sorted)
        return
    end

    akeys = table_keys(a)
    if sorted
        akeys = sort!(akeys; by)
    end

    # First print non-tabular entries
    for key in akeys
        value = toml_valid(f, table_value(a, key))
        if is_tabular(value) && !isinline(value, inline_tables)
            continue
        end

        Base.print(io, ' '^4max(0, indent - 1))
        printkey(io, [String(key)])
        Base.print(io, " = ") # print separator
        printvalue(f, io, value, sorted)
        Base.print(io, "\n")  # new line?
        first_block = false
    end

    for key in akeys
        value = toml_valid(f, table_value(a, key))
        if is_table(value) && !isinline(value, inline_tables)
            push!(ks, String(key))
            header = is_empty_table(value) || !all_values(is_tabular, value) || any_value(v -> isinline(v, inline_tables), value)
            if header
                # print table
                first_block || println(io)
                first_block = false
                Base.print(io, ' '^4indent)
                Base.print(io, "[")
                printkey(io, ks)
                Base.print(io, "]\n")
            end
            print_subtable(f, io, value, ks; indent = indent + header, first_block = header, sorted, by, inline_tables)
            pop!(ks)
        elseif is_array_of_tables(value)
            # print array of tables
            first_block || println(io)
            first_block = false
            push!(ks, String(key))
            if value isa Vector{Dict{String, Any}}
                print_tables(f, io, value, ks, indent, sorted, by, inline_tables)
            elseif value isa Vector{Dict{String, Dates.DateTime}}
                print_tables(f, io, value, ks, indent, sorted, by, inline_tables)
            elseif value isa Vector{Any}
                print_tables(f, io, value, ks, indent, sorted, by, inline_tables)
            else
                WASM_TARGET && error("PkgWasm TOML writer: unsupported array type")
                Base.inferencebarrier(print_tables)(f, io, value, ks, indent, sorted, by, inline_tables)
            end
            pop!(ks)
        end
    end
end

# the tables of an array of tables
Base.@nospecializeinfer function print_tables(f::F, io::IO, @nospecialize(value::AbstractVector), ks::Vector{String}, indent::Int, sorted::Bool, by::B, inline_tables) where {F, B}
    if !is_typed_vector(value)
        WASM_TARGET && error("PkgWasm TOML writer: unsupported array type")
        return Base.inferencebarrier(print_tables_generic)(f, io, value, ks, indent, sorted, by, inline_tables)
    end
    for i in 1:vector_length(value)
        v = vector_get(value, i)
        Base.print(io, ' '^4indent)
        Base.print(io, "[[")
        printkey(io, ks)
        Base.print(io, "]]\n")
        # TODO, nicer error here
        !isa(v, AbstractDict) && error("array should contain only tables")
        print_subtable(f, io, v, ks; indent = indent + 1, sorted, by, inline_tables)
    end
end
function print_tables_generic(f::F, io::IO, value::AbstractVector, ks::Vector{String}, indent::Int, sorted::Bool, by::B, inline_tables) where {F, B}
    for v in value
        Base.print(io, ' '^4indent)
        Base.print(io, "[[")
        printkey(io, ks)
        Base.print(io, "]]\n")
        # TODO, nicer error here
        !isa(v, AbstractDict) && error("array should contain only tables")
        print_subtable(f, io, v, ks; indent = indent + 1, sorted, by, inline_tables)
    end
end

# `isempty(t)`, `all(p(v) for v in values(t))` and `any(...)` for a table `t` of a type Pkg's tables hold
function is_empty_table(@nospecialize(t))
    t isa Dict{String, Any} && return isempty(t)
    t isa Dict{String, String} && return isempty(t)
    t isa Dict{String, Vector{String}} && return isempty(t)
    t isa Dict{String, UUID} && return isempty(t)
    t isa Dict{String, Vector{Dict{String, Any}}} && return isempty(t)
    t isa Dict{String, Union{String, Vector{String}}} && return isempty(t)
    t isa Dict{String, Dict{String, String}} && return isempty(t)
    t isa Dict{String, Dates.DateTime} && return isempty(t)
    WASM_TARGET && error("PkgWasm TOML writer: unsupported table type")
    return Base.inferencebarrier(isempty)(t)::Bool
end
function all_values(p::P, @nospecialize(t)) where {P}
    t isa Dict{String, Any} && return all(p, values(t))
    t isa Dict{String, String} && return all(p, values(t))
    t isa Dict{String, Vector{String}} && return all(p, values(t))
    t isa Dict{String, UUID} && return all(p, values(t))
    t isa Dict{String, Vector{Dict{String, Any}}} && return all(p, values(t))
    t isa Dict{String, Union{String, Vector{String}}} && return all(p, values(t))
    t isa Dict{String, Dict{String, String}} && return all(p, values(t))
    t isa Dict{String, Dates.DateTime} && return all(p, values(t))
    WASM_TARGET && error("PkgWasm TOML writer: unsupported table type")
    return Base.inferencebarrier(all)(p, values(t))::Bool
end
function any_value(p::P, @nospecialize(t)) where {P}
    t isa Dict{String, Any} && return any(p, values(t))
    t isa Dict{String, String} && return any(p, values(t))
    t isa Dict{String, Vector{String}} && return any(p, values(t))
    t isa Dict{String, UUID} && return any(p, values(t))
    t isa Dict{String, Vector{Dict{String, Any}}} && return any(p, values(t))
    t isa Dict{String, Union{String, Vector{String}}} && return any(p, values(t))
    t isa Dict{String, Dict{String, String}} && return any(p, values(t))
    t isa Dict{String, Dates.DateTime} && return any(p, values(t))
    WASM_TARGET && error("PkgWasm TOML writer: unsupported table type")
    return Base.inferencebarrier(any)(p, values(t))::Bool
end

#######
# API #
#######

"""
    TOMLWriter.print([f], io, table; sorted = false, by = identity, inline_tables = nothing)

`TOML.print(f, io, table; sorted, by, inline_tables)`; `inline_tables` an `IdSet` (as
stock), a vector of tables or `nothing`.
"""
print(f::F, io::IO, a::AbstractDict; sorted::Bool = false, by::B = identity,
      inline_tables = nothing) where {F, B} =
    print_table(f, io, a; sorted, by, inline_tables = inline_vector(inline_tables))
print(io::IO, a::AbstractDict; sorted::Bool = false, by::B = identity,
      inline_tables = nothing) where {B} =
    print_table(nothing, io, a; sorted, by, inline_tables = inline_vector(inline_tables))

# the inline tables as a vector (compared by identity): as given, or the elements of the
# `IdSet` stock `TOML.print` takes
inline_vector(::Nothing) = nothing
inline_vector(v::Vector) = v
inline_vector(s::Base.IdSet) = Any[x for x in s]

end # module
