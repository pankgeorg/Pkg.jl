# Stock Pkg's resolver tests (test/resolve.jl, with test/utils.jl and test/resolve_utils.jl)
# run against PkgWasm's Resolve module (G2 B23: the resolver was rewritten for typed dispatch
# and must give the same results). The files are loaded unchanged except that `Pkg` names
# PkgWasm: `import ..Pkg` binds the module below, and `using/import Pkg.X` become relative.

module PkgWasmResolveTests
import Pkg
const Pkg = Pkg
relative(src) = replace(src, r"\b(using|import) Pkg\b" => s"\1 ..Pkg")
load(name) = relative(read(joinpath(@__DIR__, name), String))
# test/resolve.jl includes these two by file name; provide them as modules first
Base.include_string(@__MODULE__, "module Utils\n" * replace(load("utils.jl"), r"^module Utils\n"m => "") , "utils.jl")
end

let src = PkgWasmResolveTests.load("resolve.jl")
    # resolve.jl's own `include("utils.jl")` / `include("resolve_utils.jl")` load the files by
    # path; route them through the relative-import loader instead
    src = replace(src,
        "include(\"utils.jl\")" => "Base.include_string(@__MODULE__, Main.PkgWasmResolveTests.load(\"utils.jl\"), \"utils.jl\")",
        "include(\"resolve_utils.jl\")" => "Base.include_string(@__MODULE__, Main.PkgWasmResolveTests.load(\"resolve_utils.jl\"), \"resolve_utils.jl\")",
        "include(\"NastyGenerator.jl\")" => "include(joinpath($(repr(@__DIR__)), \"NastyGenerator.jl\"))",
        "joinpath(@__DIR__, \"resolvedata.tar.gz\")" => "joinpath($(repr(@__DIR__)), \"resolvedata.tar.gz\")",
    )
    # resolve.jl's `module ResolveTest` does `import ..Pkg`: evaluate it inside a module that
    # binds Pkg = PkgWasm
    Base.include_string(PkgWasmResolveTests, src, joinpath(@__DIR__, "resolve.jl"))
end
