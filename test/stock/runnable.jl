# This file is a part of Julia. License is MIT: https://julialang.org/license

# Summarizes which testsets of the stock Pkg test files ran cleanly against PkgWasm natively
# and which S1 Pkg API calls they make (markdown on stdout):
#
#     julia test/stock/apicalls.jl > apicalls.toml
#     julia test/stock/runnable.jl <runtests.jl --out dir> apicalls.toml > runnable-table.md
#
# A top-level testset is clean when PkgWasm had no non-passing result inside it and it starts
# before the line where its file aborted (an error outside every testset). A file whose worker
# died before recording its results (`crash`, see runtests.jl) has no clean testsets.

using TOML
O, A = ARGS[1], ARGS[2]
S1 = r"^(add|rm|resolve|instantiate|status|Registry\.(add|rm|update|status)|pkg\"(add|rm|remove|resolve|instantiate|status|st|registry (add|rm|remove|update|up|status|st))\")$"
ts = TOML.parsefile(A)["testset"]
files = unique(t["file"] for t in ts)
println("| file | stock pass | PkgWasm pass | file status | top-level testsets clean natively / total | S1 API calls in clean testsets |")
println("|---|---|---|---|---|---|")
detail = IOBuffer()
for f in files
    s = TOML.parsefile(joinpath(O, "stock", f * ".toml")); w = TOML.parsefile(joinpath(O, "pkgwasm", f * ".toml"))
    bad = [r["path"] for r in w["results"] if r["kind"] != "broken"]
    load_abort = any(p -> p == f, bad)   # error outside every testset: the rest of the file did not run
    crash = get(w, "crash", nothing)
    abort_line = crash === nothing ? typemax(Int) : 0 # a crashed worker reached no testset we know of
    for r in w["results"]
        r["path"] == f || continue
        m = match(Regex("test/" * replace(f, "." => "\\.") * ":(\\d+)"), r["message"])
        abort_line = m === nothing ? 0 : parse(Int, m[1])
    end
    top = [t for t in ts if t["file"] == f && count(==('>'), t["path"]) == 1]
    clean = String[]; calls = Dict{String,Int}()
    for t in top
        p = t["path"]
        # an interpolated name ("... $(v)") is matched by its literal prefix
        stem = occursin('$', p) ? first(split(p, '$')) : nothing
        any(b -> b == p || startswith(b, p * " > ") || (stem !== nothing && startswith(b, stem)), bad) && continue
        t["line"] < abort_line || continue # not reached
        # nested testsets' calls count too
        subs = [u for u in ts if u["file"] == f && (u["path"] == p || startswith(u["path"], p * " > "))]
        c = Dict{String,Int}(); fl = Set{String}()
        for u in subs; mergewith!(+, c, u["calls"]); union!(fl, u["flags"]); end
        s1 = filter(kv -> occursin(S1, kv[1]), c)
        push!(clean, p)
        mergewith!(+, calls, s1)
        println(detail, "| $f | $(p[length(f)+4:end]) | $(t["line"]) | ", join(sort(["$k×$v" for (k, v) in s1]), ", "), " | ", join(sort(["$k×$v" for (k, v) in c if !occursin(S1, k)]), ", "), " | ", join(sort!(collect(fl)), ","), " |")
    end
    status = crash !== nothing ? "worker crashed: $crash" : isempty(bad) ? "all pass (as stock)" : load_abort ? "aborts at line $abort_line (error outside a testset)" : "partial"
    println("| $f | $(s["pass"]) | $(w["pass"]) | $status | $(length(clean))/$(length(top)) | ", join(sort(["$k×$v" for (k, v) in calls]), ", "), " |")
end
println("\n## Clean top-level testsets (no non-pass result in PkgWasm natively)\n")
println("| file | testset | line | S1 calls | other Pkg calls (run natively by the shim?) | flags |")
println("|---|---|---|---|---|---|")
print(String(take!(detail)))
