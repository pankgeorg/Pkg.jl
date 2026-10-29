# This file is a part of Julia. License is MIT: https://julialang.org/license

# Lists, per testset of the stock Pkg test files, the Pkg API calls it makes and whether it
# uses git or launches `julia`:
#
#     julia test/stock/apicalls.jl [file.jl ...] > apicalls.toml

using TOML

const TESTDIR = dirname(@__DIR__)

testset_name(arg) = arg isa String ? arg : sprint(Base.show_unquoted, arg)

# `pkg"cmd ..."` and `pkgstr("cmd ...")` count as REPL-mode calls of `cmd`.
repl_cmd(s::AbstractString) = (w = split(strip(s)); isempty(w) ? "?" : w[1] == "registry" && length(w) > 1 ? "registry " * w[2] : w[1])

function api_name(ex)
    ex isa Expr && ex.head === :. || return nothing
    parts = String[]
    while ex isa Expr && ex.head === :.
        push!(parts, string(ex.args[2].value))
        ex = ex.args[1]
    end
    ex === :Pkg || return nothing
    return join(reverse(parts), ".")
end

function walk!(calls, flags, ex)
    ex isa Expr || return
    if ex.head === :call
        n = api_name(ex.args[1])
        n !== nothing && (calls[n] = get(calls, n, 0) + 1)
        f = ex.args[1]
        if f === :pkgstr || (f isa Expr && api_name(f) == "REPLMode.pkgstr")
            s = ex.args[end] isa String ? repl_cmd(ex.args[end]) : "?"
            calls["pkg\"$s\""] = get(calls, "pkg\"$s\"", 0) + 1
        end
        f in (:git_init_and_commit, :git_init_package) && push!(flags, "git")
        f === :julia_cmd || (f isa Expr && f.head === :. && f.args[end] == QuoteNode(:julia_cmd)) && push!(flags, "julia-subprocess")
    elseif ex.head === :macrocall && ex.args[1] === Symbol("@pkg_str")
        s = ex.args[end] isa String ? repl_cmd(ex.args[end]) : "?"
        calls["pkg\"$s\""] = get(calls, "pkg\"$s\"", 0) + 1
    elseif ex.head === :kw && ex.args[1] in (:url, :rev, :repo)
        push!(flags, "git?")
    elseif ex.head === :. && ex.args[1] === :LibGit2
        push!(flags, "git")
    end
    for a in ex.args
        # nested testsets are listed separately
        a isa Expr && a.head === :macrocall && a.args[1] === Symbol("@testset") && continue
        walk!(calls, flags, a)
    end
end

function testsets!(out, ex, file, path)
    ex isa Expr || return
    if ex.head === :macrocall && ex.args[1] === Symbol("@testset")
        line = ex.args[2] isa LineNumberNode ? ex.args[2].line : 0
        i = findfirst(a -> a isa String || (a isa Expr && a.head === :string), ex.args[3:end])
        name = i === nothing ? "?" : testset_name(ex.args[2 + i])
        calls, flags = Dict{String, Int}(), Set{String}()
        walk!(calls, flags, ex.args[end])
        p = [path; name]
        push!(out, Dict("file" => file, "line" => line, "path" => join(p, " > "),
            "calls" => calls, "flags" => sort!(collect(flags))))
        for a in ex.args[3:end]
            testsets!(out, a, file, p)
        end
    else
        for a in ex.args
            testsets!(out, a, file, path)
        end
    end
end

function list_testsets(files)
    out = Dict{String, Any}[]
    for f in files
        testsets!(out, Meta.parseall(read(joinpath(TESTDIR, f), String); filename = f), f, [f])
    end
    TOML.print(stdout, Dict("testset" => out))
end

include(joinpath(@__DIR__, "runtests.jl")) # STOCK_FILES
list_testsets(isempty(ARGS) ? STOCK_FILES : ARGS)
