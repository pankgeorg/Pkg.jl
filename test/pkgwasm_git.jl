# PkgWasm (PLAN.md D14): git through the git command line.
#  1. `PkgWasm.GitCLI` (LibGit2's API subset on git) compared with LibGit2 itself on the same
#     repositories: opening, HEAD and branches, revision resolution with LibGit2's error codes
#     (a corpus of specs), Pkg's DWIM lookup, peeling, subtrees, checkouts (files, modes,
#     symlinks, configured filter drivers), blob reads, dirtiness.
#  2. Pkg's git operations (registry add/update/status of a git registry, add by url/rev/path/
#     subdir, update of a tracked branch, develop by path and url, packages installed by git,
#     status --diff) run by stock Pkg with JULIA_PKG_USE_CLI_GIT=true and by PkgWasm, each in a
#     fresh process: output, manifests and depot files must be identical (test/git/ops.jl).

using Test, LibGit2, Pkg, Pkg
const GitCLI = Pkg.GitCLI
include(joinpath(@__DIR__, "git", "fixture.jl"))

class(e) = e isa GitCLI.GitError ? Symbol(e.code) : e isa LibGit2.GitError ? Symbol(e.code) : rethrow(e)
cli_or(f) = try f() catch e; (e isa GitCLI.GitError || e isa LibGit2.GitError) || rethrow(); class(e) end

const REV_CORPUS = ["v0.1.0", "main", "dev", "HEAD", "HEAD~1", "HEAD^", "HEAD^0", "HEAD~0", "no-such-rev",
    "HEAD@{0}", "@{0}", "HEAD@{1}", "HEAD@{yesterday}", "HEAD@{bad}", "main@{upstream}", "v0.1.0:sub",
    "v0.1.0:nope", "7", "aaaa", repeat("a", 40), "HEAD^{bogus}", "HEAD..HEAD", "HEAD...HEAD", "v0.1.0^{commit}",
    "v0.1.0^{tree}", "v0.1.0^{}", "v0.1.0^{object}", "HEAD:", ":/two", "", "refs/heads/main", "heads/main",
    "tags/v0.1.0", "origin/main", "pull/1/head", "HEAD^{/one}", "main^{tree}:src", "-v", "v0.1.0^^", "HEAD^2",
    "HEAD^{", "HEAD@{", "HEAD^{/..}", ":/..", "HEAD:src/Foo.jl", "dev:src/Foo.jl", "HEAD:link.jl",
    "cache/heads/main@{upstream}", "remotes/origin/main@{upstream}", "heads/main@{upstream}", "refs/heads/main@{u}",
    "origin/main@{u}", "nope@{u}", "x/y@{u}", "refs/tags/v0.1.0@{u}", "v0.1.0@{u}", "HEAD@{u}", "main@{push}", "a/b@{push}",
    "remotes/origin/HEAD@{yesterday}", "remotes/origin/main@{yesterday}", "main@{yesterday}", "main@{1}", "remotes/origin/HEAD@{0}"]

snapshot(root) = Dict(relpath(joinpath(d, f), root) =>
                      (islink(joinpath(d, f)) ? (:link, readlink(joinpath(d, f))) :
                       (filemode(joinpath(d, f)) & 0o777, read(joinpath(d, f), String)))
                      for (d, _, fs) in walkdir(root) for f in fs)

# hermetic: git sees no configuration or repository outside the test's own temp root
const ROOT = mktempdir()
ENV["HOME"] = ROOT
ENV["GIT_CEILING_DIRECTORIES"] = ROOT
ENV["GIT_CONFIG_NOSYSTEM"] = "1"

@testset "GitCLI vs LibGit2" begin
    mktempdir(ROOT) do dir
        make_fixture(dir)
        foo = joinpath(dir, "Foo")
        bare = joinpath(dir, "Foo.git")
        fgit(dir, "clone", "-q", "--bare", foo, bare)
        clone = joinpath(dir, "Foo-clone")                 # (a work tree with an upstream)
        fgit(dir, "clone", "-q", foo, clone)
        @testset "open, path, HEAD ($name)" for (name, p) in (("work tree", foo), ("bare", bare))
            r, lr = GitCLI.GitRepo(p), LibGit2.GitRepo(p)
            @test GitCLI.path(r) == rstrip(LibGit2.path(lr), '/')
            @test string(GitCLI.head_oid(r)) == string(LibGit2.head_oid(lr))
            @test GitCLI.isattached(r) == LibGit2.isattached(lr)
            @test GitCLI.branch(r) == LibGit2.branch(lr)
            @test GitCLI.headname(r) == LibGit2.headname(lr)
            @test GitCLI.remotes(r) == LibGit2.remotes(lr)
            @test GitCLI.isshallow(r) == LibGit2.isshallow(lr)
        end
        # no upward discovery, as git_repository_open
        @test cli_or(() -> GitCLI.GitRepo(joinpath(foo, "src"))) ==
              cli_or(() -> LibGit2.GitRepo(joinpath(foo, "src"))) == :ENOTFOUND
        @testset "revision $(repr(rev)) ($(basename(p)))" for p in (bare, clone), rev in REV_CORPUS
            r, lr = GitCLI.GitRepo(p), LibGit2.GitRepo(p)
            cli = cli_or(() -> string(GitCLI.GitHash(GitCLI.GitObject(r, rev))))
            lg = cli_or(() -> string(LibGit2.GitHash(LibGit2.GitObject(lr, rev))))
            @test cli == lg
            # Pkg's DWIM lookup (cache/heads/, remotes/origin/, heads/ first)
            pw = cli_or(() -> (x = Pkg.Types.get_object_or_branch(r, rev); x === nothing ? nothing : (string(GitCLI.GitHash(x[1])), x[2])))
            st = cli_or(() -> (x = Pkg.Types.get_object_or_branch(lr, rev); x === nothing ? nothing : (string(LibGit2.GitHash(x[1])), x[2])))
            @test pw == st
            cli isa String || continue
            @test cli_or(() -> string(GitCLI.GitHash(GitCLI.peel(GitCLI.GitTree, GitCLI.GitObject(r, rev))))) ==
                  cli_or(() -> string(LibGit2.GitHash(LibGit2.peel(LibGit2.GitTree, LibGit2.GitObject(lr, rev)))))
        end
        r, lr = GitCLI.GitRepo(bare), LibGit2.GitRepo(bare)
        @testset "objects by hash, typed lookups, subtrees, blobs" begin
            t = tree_of(foo, "v0.1.0")
            @test GitCLI.GitObject(r, GitCLI.GitHash(t)) isa GitCLI.GitTree
            @test LibGit2.GitObject(lr, LibGit2.GitHash(t)) isa LibGit2.GitTree
            @test cli_or(() -> GitCLI.GitObject(r, GitCLI.GitHash(repeat("0", 40)))) ==
                  cli_or(() -> LibGit2.GitObject(lr, LibGit2.GitHash(repeat("0", 40)))) == :ENOTFOUND
            @test cli_or(() -> GitCLI.GitBlob(r, "v0.1.0:sub")) == cli_or(() -> LibGit2.GitBlob(lr, "v0.1.0:sub")) == :ERROR
            tr, ltr = GitCLI.GitTree(r, t), LibGit2.GitTree(lr, t)
            for p in ("sub", "sub/Bar", "src/Foo.jl", "nope")
                a = try string(GitCLI.GitHash(tr[p])) catch e; e isa KeyError ? :key : rethrow() end
                b = try string(LibGit2.GitHash(ltr[p])) catch e; e isa KeyError ? :key : rethrow() end
                @test a == b
            end
            for spec in ("v0.1.0:Project.toml", "dev:src/Foo.jl", "v0.1.0:nope")
                @test read(Pkg.GitTools.git_file_stream(r, spec; fakeit = true), String) ==
                      read(Pkg.GitTools.git_file_stream(lr, spec; fakeit = true), String)
            end
        end
        @testset "checkout $rev (umask $(string(m; base = 8)), prefilled $pre)" for rev in ("v0.1.0", "dev"),
                m in (0o022, 0o002, 0o077), pre in (false, true)
            old = ccall(:umask, Base.Cmode_t, (Base.Cmode_t,), m)
            try
                a, b = mktempdir(ROOT), mktempdir(ROOT)
                if pre
                    for d in (a, b)
                        mkdir(joinpath(d, "src"); mode = 0o700)
                        write(joinpath(d, "keep.txt"), "x")
                    end
                end
                Pkg.GitTools.checkout_tree_to_path(r, GitCLI.GitObject(r, tree_of(foo, rev)), a)
                Pkg.GitTools.checkout_tree_to_path(lr, LibGit2.GitObject(lr, tree_of(foo, rev)), b)
                @test snapshot(a) == snapshot(b)
                @test filemode(joinpath(a, "src")) & 0o777 == filemode(joinpath(b, "src")) & 0o777
                pre || @test bytes2hex(Pkg.GitTools.tree_hash(a)) == tree_of(foo, rev)
            finally
                ccall(:umask, Base.Cmode_t, (Base.Cmode_t,), old)
            end
        end
        @testset "configured filter drivers are not run (as LibGit2)" begin
            fgit(foo, "config", "filter.up.smudge", "tr a-z A-Z")
            write(joinpath(foo, ".gitattributes"), "*.txt filter=up\n")
            write(joinpath(foo, "f.txt"), "lower\n")
            fgit(foo, "add", "-A"); fgit(foo, "commit", "-qm", "filters")
            r2, lr2 = GitCLI.GitRepo(foo), LibGit2.GitRepo(foo)
            a, b = mktempdir(ROOT), mktempdir(ROOT)
            Pkg.GitTools.checkout_tree_to_path(r2, GitCLI.GitObject(r2, tree_of(foo, "HEAD")), a)
            Pkg.GitTools.checkout_tree_to_path(lr2, LibGit2.GitObject(lr2, tree_of(foo, "HEAD")), b)
            @test read(joinpath(a, "f.txt"), String) == read(joinpath(b, "f.txt"), String) == "lower\n"
        end
        @testset "review-8: a tag named as the branch, short hex tag names, working-tree-encoding, registry filters" begin
            c2 = joinpath(dir, "Foo-tags")
            fgit(dir, "clone", "-q", foo, c2)
            fgit(c2, "tag", "main", "origin/dev"); fgit(c2, "tag", "abc", "origin/dev"); fgit(c2, "tag", "0", "origin/dev")
            r2, lr2 = GitCLI.GitRepo(c2), LibGit2.GitRepo(c2)
            @test GitCLI.branch(r2) == LibGit2.branch(lr2) == "main"
            @test GitCLI.headname(r2) == LibGit2.headname(lr2)
            for rev in ("abc", "0", "ab", "a0", "main")
                @test cli_or(() -> string(GitCLI.GitHash(GitCLI.GitObject(r2, rev)))) ==
                      cli_or(() -> string(LibGit2.GitHash(LibGit2.GitObject(lr2, rev))))
            end
            # working-tree-encoding: git converts, LibGit2 does not
            write(joinpath(c2, ".gitattributes"), "*.jl working-tree-encoding=UTF-16LE\n")
            fgit(c2, "add", ".gitattributes"); fgit(c2, "commit", "-qm", "enc")
            t = tree_of(c2, "HEAD")
            a, b = mktempdir(ROOT), mktempdir(ROOT)
            Pkg.GitTools.checkout_tree_to_path(r2, GitCLI.GitObject(r2, t), a)
            Pkg.GitTools.checkout_tree_to_path(lr2, LibGit2.GitObject(lr2, t), b)
            @test snapshot(a) == snapshot(b)
            # a fast-forward (registry update) does not run a configured smudge filter
            up = joinpath(dir, "Foo-up")
            fgit(dir, "clone", "-q", foo, up)
            fgit(up, "config", "filter.rw.smudge", "sed s/f/g/g")
            write(joinpath(foo, ".gitattributes"), "*.jl filter=rw\n")
            fgit(foo, "checkout", "-q", "main")
            write(joinpath(foo, "src", "New.jl"), "f\n")
            fgit(foo, "add", "-A"); fgit(foo, "commit", "-qm", "new")
            fgit(up, "fetch", "-q", "origin")
            @test GitCLI.merge!(GitCLI.GitRepo(up); branch = "refs/remotes/origin/main", fastforward = true)
            @test read(joinpath(up, "src", "New.jl"), String) == "f\n"
        end
        @testset "isdirty" begin
            r2, lr2 = GitCLI.GitRepo(foo), LibGit2.GitRepo(foo)
            @test GitCLI.isdirty(r2) == LibGit2.isdirty(lr2) == false
            write(joinpath(foo, "untracked.txt"), "u")             # untracked: not dirty
            @test GitCLI.isdirty(r2) == LibGit2.isdirty(lr2) == false
            touch(joinpath(foo, "Project.toml"))                   # a stat change only
            @test GitCLI.isdirty(r2) == LibGit2.isdirty(lr2) == false
            write(joinpath(foo, "Project.toml"), "changed")
            @test GitCLI.isdirty(r2) == LibGit2.isdirty(lr2) == true
        end
    end
end

@testset "Pkg's git operations: PkgWasm == stock Pkg (JULIA_PKG_USE_CLI_GIT)" begin
    mktempdir(ROOT) do dir
        work = joinpath(dir, "w")
        script = joinpath(@__DIR__, "git", "ops.jl")
        pkgwasm = dirname(@__DIR__)
        julia = Base.julia_cmd()
        run_ops(which, env...) = read(addenv(`$julia --startup-file=no $script $which $pkgwasm $work`, env...), String)
        stock = run_ops("stock", "JULIA_PKG_USE_CLI_GIT" => "true")
        ours = run_ops("pkgwasm")
        @test occursin("## develop url (file://: cloned into dev/): ok", stock)
        @test occursin("## registry Foo versions: [\"0.1.0\", \"0.1.1\"]", stock)
        if ours != stock
            for (i, (a, b)) in enumerate(zip(split(stock, '\n'), split(ours, '\n')))
                a == b || (@error "first difference at line $i" stock = a pkgwasm = b; break)
            end
        end
        @test ours == stock
    end
end
