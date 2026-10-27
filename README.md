# commit-notes

Writes GitHub release notes from the commit messages since the previous release tag.

GitHub's generated release notes list merged pull requests. Repositories that commit straight to `main` get nothing but a changelog link. commit-notes lists every commit in the release instead: one bullet per commit with its subject and short hash, its body indented beneath, and `Co-Authored-By:` and `Signed-off-by:` trailers removed. The changelog link follows.

```markdown
- Use commit messages as release notes (642861d)

  Commits go straight to main, so generated notes only held the changelog link.

**Full Changelog**: https://github.com/benomahony/zclig/compare/v0.1.0...v0.1.1
```

It is built on [zclig](https://github.com/benomahony/zclig) and runs `git` and `gh`, which must be on `PATH`.

## Install

Download a binary for your platform from the [latest release](https://github.com/benomahony/commit-notes/releases/latest), or build from source with Zig 0.17:

```sh
zig build -Doptimize=ReleaseSafe
```

## Usage

Run it in a clone with full history and tags. `gh` must be signed in, or `GH_TOKEN` set to a token that can write releases.

```sh
commit-notes write v1.2.0 --dry-run   # preview the notes
commit-notes write v1.2.0             # write them to the release
commit-notes backfill --dry-run       # preview every release in the repository
commit-notes backfill --yes           # rewrite every release
```

The previous release is the tag sorted before it among tags matching `--pattern` (default `v[0-9]*`). The first release lists every commit up to its tag. `--repo owner/name` sets the repository, defaulting to `GITHUB_REPOSITORY` and then the current clone. `--json` and `--plain` print the notes as records.

## GitHub Actions

Write the notes right after your workflow creates the release. The job needs `contents: write`, and the checkout needs `fetch-depth: 0` so the previous tag is there.

```yaml
- uses: actions/checkout@v5
  with:
    fetch-depth: 0
- name: Write the release notes
  env:
    GH_TOKEN: ${{ github.token }}
  run: |
    gh release download v0.1.0 --repo benomahony/commit-notes --pattern commit-notes-linux-x86_64 --output commit-notes
    chmod +x commit-notes
    git fetch --tags --quiet
    ./commit-notes write "$TAG"
```

A release created with `GITHUB_TOKEN` does not start other workflows, so run this in the workflow that creates the release rather than one triggered by `release` events.

## License

MIT
