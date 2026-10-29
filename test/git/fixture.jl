# Git fixtures of test/pkgwasm_git.jl: a package repository and a git registry, with fixed
# authors and dates, so both runs (and every run) see the same commit ids.

const GIT_ENV = ("GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@t", "GIT_COMMITTER_NAME" => "t",
                 "GIT_COMMITTER_EMAIL" => "t@t", "GIT_AUTHOR_DATE" => "2026-01-01T00:00:00Z",
                 "GIT_COMMITTER_DATE" => "2026-01-01T00:00:00Z", "GIT_CONFIG_NOSYSTEM" => "1")
fgit(dir, args...) = run(addenv(Cmd(["git", "-C", dir, args...]), GIT_ENV...))
fgit_read(dir, args...) = chomp(read(addenv(Cmd(["git", "-C", dir, args...]), GIT_ENV...), String))
commit_of(dir, rev) = fgit_read(dir, "rev-parse", rev * "^{commit}")
tree_of(dir, rev) = fgit_read(dir, "rev-parse", rev * "^{tree}")

const FOO_UUID = "7876af07-990d-54b4-ab0e-23690620f79a"
const BAR_UUID = "3fc5ad6e-8a5f-4ce1-9c6c-41c1c0d4a7b2"
const REG_UUID = "c0a2e2a8-7f4e-4a3d-9a59-0f5b2e3e6f11"

function new_commit!(dir, branch, file, content, msg)
    fgit(dir, "checkout", "-q", branch)
    mkpath(dirname(joinpath(dir, file)))
    write(joinpath(dir, file), content)
    fgit(dir, "add", "-A")
    fgit(dir, "commit", "-qm", msg)
    fgit(dir, "checkout", "-q", "main")
    return nothing
end

# Foo: main (v0.1.0: an executable script, a symlink, a subdirectory package Bar), dev (f() = 2)
function make_foo(dir)
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "Project.toml"), "name = \"Foo\"\nuuid = \"$FOO_UUID\"\nversion = \"0.1.0\"\n")
    write(joinpath(dir, "src", "Foo.jl"), "module Foo\nf() = 1\nend\n")
    mkpath(joinpath(dir, "bin"))
    write(joinpath(dir, "bin", "run.sh"), "#!/bin/sh\necho foo\n")
    chmod(joinpath(dir, "bin", "run.sh"), 0o755)
    symlink("src/Foo.jl", joinpath(dir, "link.jl"))
    mkpath(joinpath(dir, "sub", "Bar", "src"))
    write(joinpath(dir, "sub", "Bar", "Project.toml"), "name = \"Bar\"\nuuid = \"$BAR_UUID\"\nversion = \"0.2.0\"\n")
    write(joinpath(dir, "sub", "Bar", "src", "Bar.jl"), "module Bar\nend\n")
    fgit(dir, "init", "-q", "-b", "main")
    fgit(dir, "add", "-A")
    fgit(dir, "commit", "-qm", "one")
    fgit(dir, "tag", "v0.1.0")
    fgit(dir, "branch", "dev")
    new_commit!(dir, "dev", "src/Foo.jl", "module Foo\nf() = 2\nend\n", "two")
    return dir
end

function write_registry_versions(reg, foo, versions)
    open(joinpath(reg, "F", "Foo", "Versions.toml"), "w") do io
        for (v, tag) in versions
            println(io, "[\"$v\"]\ngit-tree-sha1 = \"$(tree_of(foo, tag))\"\n")
        end
    end
end

# Reg: a git registry with Foo 0.1.0 (repo: the Foo repository)
function make_registry(dir, foo)
    mkpath(joinpath(dir, "F", "Foo"))
    write(joinpath(dir, "Registry.toml"), """
        name = "Reg"
        uuid = "$REG_UUID"
        repo = "$dir"

        [packages]
        $FOO_UUID = { name = "Foo", path = "F/Foo" }
        """)
    write(joinpath(dir, "F", "Foo", "Package.toml"), "name = \"Foo\"\nuuid = \"$FOO_UUID\"\nrepo = \"$foo\"\n")
    write_registry_versions(dir, foo, [("0.1.0", "v0.1.0")])
    fgit(dir, "init", "-q", "-b", "main")
    fgit(dir, "add", "-A")
    fgit(dir, "commit", "-qm", "registry")
    return dir
end

# a new version of Foo (main, tagged) registered in Reg (a new registry commit)
function new_version!(reg, foo, v::VersionNumber)
    s = read(joinpath(foo, "Project.toml"), String)
    new_commit!(foo, "main", "Project.toml", replace(s, r"version = \".*\"" => "version = \"$v\""), "v$v")
    fgit(foo, "tag", "v$v", "main")
    write_registry_versions(reg, foo, [("0.1.0", "v0.1.0"), (string(v), "v$v")])
    fgit(reg, "add", "-A")
    fgit(reg, "commit", "-qm", "Foo v$v")
    return nothing
end

function git_init_commit!(dir)
    fgit(dir, "init", "-q", "-b", "main")
    fgit(dir, "add", "-A")
    fgit(dir, "commit", "-qm", "env")
    return nothing
end

function make_fixture(dir)
    mkpath(dir)
    foo = make_foo(joinpath(dir, "Foo"))
    make_registry(joinpath(dir, "Reg"), foo)
    return dir
end
