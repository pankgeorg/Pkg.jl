# This file is a part of Julia. License is MIT: https://julialang.org/license

# Runs stock Pkg's test files (test/*.jl) against PkgWasm and/or the stdlib Pkg, one Julia
# process per file (see runfile.jl), and compares the two:
#
#     julia --project=test test/stock/runtests.jl [--target=pkgwasm|stock|both|compare] [--out=DIR]
#           [--timeout=SECONDS] [file.jl ...]
#
# Results: DIR/<target>/<file>.toml (non-passing results), .out (test output), .pkg.log (Pkg
# output); DIR/compare.md when both targets were run. Not part of test/runtests.jl.

using TOML

# The list of stock Pkg 1.13.2's test/runtests.jl, plus its two optional files.
const STOCK_FILES = [
    "new.jl", "pkg.jl", "repl.jl", "api.jl", "registry.jl", "subdir.jl", "extensions.jl",
    "artifacts.jl", "binaryplatforms.jl", "platformengines.jl", "sandbox.jl", "resolve.jl",
    "misc.jl", "force_latest_compatible_version.jl", "manifests.jl", "project_manifest.jl",
    "sources.jl", "workspaces.jl", "apps.jl", "stdlib_compat.jl",
    "historical_stdlib_version.jl", "aqua.jl",
]

function parse_args(args)
    opts = Dict("target" => "both", "out" => joinpath(@__DIR__, "out"), "timeout" => "5400")
    files = String[]
    for a in args
        m = match(r"^--(\w+)=(.*)$", a)
        m === nothing ? push!(files, a) : (opts[m[1]] = m[2])
    end
    isempty(files) && append!(files, STOCK_FILES)
    t = opts["target"]
    targets = t == "both" ? ["stock", "pkgwasm"] : t == "compare" ? String[] : [t]
    return targets, files, abspath(opts["out"]), parse(Int, opts["timeout"]), t != "pkgwasm" && t != "stock"
end

function run_file(target, file, out, timeout)
    dir = joinpath(out, target)
    mkpath(dir)
    res = joinpath(dir, file * ".toml")
    rm(res; force = true)
    cmd = `timeout --signal=KILL $timeout $(Base.julia_cmd()) --project=$(Base.active_project())
           $(joinpath(@__DIR__, "runfile.jl")) $target $file $res`
    # as `Pkg.test()`'s sandbox: the test environment stays loadable after `activate(temp = true)`
    cmd = addenv(cmd, "JULIA_LOAD_PATH" => join(["@", Base.active_project(), "@stdlib"], Sys.iswindows() ? ';' : ':'))
    t = @elapsed p = run(pipeline(ignorestatus(cmd); stdout = joinpath(dir, file * ".out"), stderr = joinpath(dir, file * ".out")))
    if !isfile(res) # the process died before writing its results
        why = p.exitcode == 137 ? "killed after $(timeout) s (timeout)" : "exit code $(p.exitcode) without results"
        open(io -> TOML.print(io, Dict("target" => target, "file" => file, "pass" => 0, "fail" => 0,
            "error" => 1, "broken" => 0, "crash" => why, "results" => Dict{String, Any}[])), res, "w")
    end
    r = TOML.parsefile(res)
    r["seconds"] = round(t; digits = 1)
    open(io -> TOML.print(io, r), res, "w")
    println(rpad("$target $file", 48), "pass ", r["pass"], ", fail ", r["fail"], ", error ", r["error"],
        ", broken ", r["broken"], get(r, "crash", ""), " (", r["seconds"], " s)")
    return r
end

const KEY = r -> (r["path"], r["source"], r["kind"])

function compare(out, files)
    io = IOBuffer()
    println(io, "# Stock Pkg test files: stock Pkg vs PkgWasm\n")
    println(io, "| file | stock pass/fail/error/broken | PkgWasm pass/fail/error/broken | only PkgWasm | only stock |")
    println(io, "|---|---|---|---|---|")
    details = IOBuffer()
    for f in files
        s, w = (TOML.parsefile(joinpath(out, t, f * ".toml")) for t in ("stock", "pkgwasm"))
        sk, wk = Set(map(KEY, s["results"])), Set(map(KEY, w["results"]))
        only_w = filter(r -> KEY(r) ∉ sk, w["results"])
        only_s = filter(r -> KEY(r) ∉ wk, s["results"])
        counts(r) = join((r["pass"], r["fail"], r["error"], r["broken"]), "/") * (haskey(r, "crash") ? " ($(r["crash"]))" : "")
        println(io, "| $f | $(counts(s)) | $(counts(w)) | $(length(only_w)) | $(length(only_s)) |")
        for (label, rs) in (("only PkgWasm", only_w), ("only stock", only_s))
            isempty(rs) && continue
            println(details, "\n## $f: $label\n")
            for r in rs
                println(details, "- `", r["kind"], "` ", r["path"], " ", replace(r["source"], r"#= (.*) =#" => s"\1"))
                msg = first(split(r["message"], "\n  Stacktrace:"))
                println(details, "\n  ```\n  ", replace(first(msg, 1200), "\n" => "\n  "), "\n  ```")
            end
        end
    end
    write(joinpath(out, "compare.md"), String(take!(io)) * String(take!(details)))
    return joinpath(out, "compare.md")
end

function main(args)
    targets, files, out, timeout, do_compare = parse_args(args)
    for target in targets, file in files
        run_file(target, file, out, timeout)
    end
    do_compare && println("comparison: ", compare(out, files))
    return
end

abspath(PROGRAM_FILE) == @__FILE__() && main(ARGS)
