# sweep-worktrees

Cleans up the git worktrees that coding agents leave behind. Point it at the folder where your agent creates worktrees (the Claude Code desktop app, `claude --worktree`, or your own scripts) and run it hourly: it removes checkouts whose pull request has merged, and anything else idle long enough to be finished, after saving whatever isn't committed.

It works with GitHub (through `gh`) and any GitLab host (through `glab`), and it fails closed: when in doubt, a checkout stays.

## How it decides

It looks at every checkout one or two levels under the root: `<root>/<project>/<name>` folders, legacy `<root>/<name>` checkouts, and checkouts nested one level inside those. Each one is matched to its PR/MR by commit, then:

| State | Action |
|---|---|
| Open PR/MR | keep |
| Merged, clean | remove, delete the branch |
| Detached review checkout of a merged or closed PR/MR, clean | remove |
| Merged, dirty inside a submodule | keep: a tarball can't hold submodule changes |
| Merged, dirty, idle for 7+ days | save leftovers to a tarball, remove, delete the branch |
| Closed or no PR/MR, clean, idle for 14+ days | remove the folder, keep the branch unless it's already in the default branch |
| Any other dirty checkout | keep; flagged in the summary once idle for 30+ days |
| PR/MR lookup failed | only: in the default branch, clean, idle for 14+ days → remove |

"Idle" is the newest change inside the checkout (dependency folders like `node_modules` and `target` excluded) or in its git HEAD log.

Open PRs/MRs are always fetched in full. Merged and closed ones are capped at the 500 most recent; a checkout idle for 7+ days that matches nothing in that window gets one extra lookup by its own commit, so older merged PRs are still recognized.

Standalone clones follow the same table with more care, since deleting a clone deletes its repository: nothing goes before 14 idle days, and a clone stays while it hosts worktrees, holds a stash, has a branch or tag with commits on no remote, or holds git-ignored files other than the usual build output, dependencies, caches, logs and editor or agent folders (a `.env`, say).

Before a repository's worktrees are judged, any that moved within the root are reconnected to their registration. Afterwards, `git worktree prune` drops the registrations of deleted ones, but no sooner than git's own gc would (`gc.worktreePruneExpire`, 3 months by default): a worktree moved elsewhere with a plain `mv` looks just like a deleted one. It also waits while any missing worktree of that repository lies outside the root. To move a worktree for good, use `git worktree move`.

## What it never touches

- Checkouts outside the root, such as the main checkouts your worktrees belong to (only their branches and worktree registrations change, as described above), and the checkout it is run from. A standalone clone under the root is judged like any other checkout.
- Anything a running process has as its working directory (checked with `lsof`).
- Worktrees the Claude Code desktop app has pooled for reuse or is still creating.
- A checkout with a `.worktree-keep` file in its root, or one locked with `git worktree lock`.
- A detached HEAD whose commit is on no ref and belongs to no PR/MR.
- A checkout that has other checkouts inside it (submodules aside).
- Anything whose state it could not read.

Every guard is checked again right before each deletion, and a checkout that changed in the meantime is left alone. If `lsof` fails or the desktop app's registry can't be parsed, the run deletes nothing at all.

Every external command has a deadline: 10 minutes, or an hour for hooks. One that runs over is killed and counts as failed, which keeps whatever depended on it.

Broken checkouts and folders that aren't checkouts are listed in the log and never deleted.

## Forges

A remote on `github.com` goes to `gh`, any other host to `glab`. List GitHub Enterprise hosts under `github_hosts` to send them to `gh` too:

```yaml
github_hosts:
  - github.example.com
```

An SSH remote may use a `Host` alias from `~/.ssh/config`, such as `git@github-work:org/app.git` for a second account. `ssh -G` resolves the alias to the host it points to, so `github-work` counts as `github.com`, and so does `ssh.github.com`, GitHub's SSH endpoint on port 443. A GitLab host is asked as written first and as resolved only if that fails, since the resolved host may be an SSH-only endpoint that `glab` can't query.

## Salvage

Before a dirty checkout is removed, its leftovers go into `<salvage_dir>/<repo>/<path>-<YYYYmmdd-HHMM>.tar.gz`, where `<path>` is the checkout's path under the root with `/` turned into `_`:

- `MANIFEST`: repo, remote, branch, HEAD, PR/MR, the reason, and the `git status` output
- `changes.patch`: `git diff --binary HEAD`, with your diff settings (external diff tools, textconv, custom prefixes, color) turned off
- `untracked/`: untracked, non-ignored files
- `plans/`: the checkout's `.plans/` folder, if any. Agents often keep design notes there, git-ignored; it is saved even when the checkout is otherwise clean.

Before anything is removed, the patch is checked to apply back to the checkout and the tarball to list back, and an existing tarball is never overwritten. If any of that fails, or the leftovers exceed the size cap, the checkout stays. Tarballs are deleted after 90 days; other files in `salvage_dir` are left alone.

To restore: extract the tarball, `git apply changes.patch` on a checkout of the recorded HEAD, and copy `untracked/` and `plans/` back.

## Requirements

- macOS or Linux, Ruby 3.3+ and git 2.31+. No gems at runtime, only the standard library.
- `gh` logged in for GitHub remotes, `glab` logged in for each GitLab host.
- `lsof` and `tar`.

## Install

```bash
git clone https://github.com/tycooon/sweep-worktrees ~/code/sweep-worktrees
ln -s ~/code/sweep-worktrees/bin/sweep-worktrees ~/.local/bin/sweep-worktrees
```

Create `~/.config/sweep-worktrees/config.yml`; only the root is required:

```yaml
worktrees_root: ~/worktrees
```

See what it would do:

```bash
sweep-worktrees --dry-run --verbose
```

### Configuration

| Key | Default | Meaning |
|---|---|---|
| `worktrees_root` | (required) | Folder the agent creates worktrees in |
| `salvage_dir` | `~/.local/share/sweep-worktrees/salvage` | Where tarballs go |
| `app_registry` | `~/Library/Application Support/Claude/git-worktrees.json` | Claude Code desktop app's worktree registry; a missing file is fine |
| `lock_file` | `~/.cache/sweep-worktrees.lock` | Keeps two runs from overlapping |
| `dirty_merged_idle_days` | `7` | Idle days before a dirty merged checkout is salvaged and removed |
| `unmerged_idle_days` | `14` | Idle days before a clean unmerged checkout is removed |
| `attention_idle_days` | `30` | Idle days after which a dirty checkout is flagged in the summary |
| `salvage_max_mb` | `200` | Leftovers larger than this keep the checkout |
| `salvage_retention_days` | `90` | Age at which tarballs are deleted |
| `forge_lookup_limit` | `500` | How many merged/closed PRs/MRs to fetch per repo |
| `hooks` | `{}` | Per-repo cleanup commands, see below |
| `github_hosts` | `[]` | GitHub Enterprise hosts, see [Forges](#forges) |

The config is checked before anything runs: an unknown key, a number that isn't a positive whole number, or broken YAML stops the run with exit code 2.

### Running it hourly on macOS

Save as `~/Library/LaunchAgents/local.sweep-worktrees.plist`, adjusting the paths, then load it with `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.sweep-worktrees.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.sweep-worktrees</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/you/.local/bin/sweep-worktrees</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/path/to/ruby/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>/Users/you/Library/Logs/sweep-worktrees.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/you/Library/Logs/sweep-worktrees.log</string>
</dict>
</plist>
```

`PATH` must reach Ruby, `git`, `gh`, `glab`, `lsof` and `tar`, plus whatever your hooks need.

## Hooks

Some repositories keep per-worktree state outside the checkout, such as build caches or test databases. A hook is that repo's own cleanup script, run once per pass from the repo's main checkout after its worktrees are handled:

```yaml
hooks:
  ~/code/app: bin/cleanup-caches
```

Hooks run only when listed in the config; the sweeper never runs scripts it finds in a repo. On a dry run the command gets `--dry-run` appended, so it must accept that flag. A non-zero exit is logged as a warning.

## The Claude Code desktop app

The desktop app keeps its own pool of worktrees and reuses idle ones for new sessions. `sweep-worktrees` reads the app's registry to leave pooled and still-creating worktrees alone. The registry format is undocumented and may change: a missing registry is treated as "no app", but one that exists and can't be parsed stops all deletions until it can be read again.

## Output

Each run prints one line per action, warnings prefixed with `warn:`, and a summary. `--verbose` also lists every kept checkout and why. The exit code is 0 for a clean run, 1 if anything warned or another run still holds the lock, and 2 for bad usage or config.

## Development

```bash
bundle install
bundle exec rake
```

Tests build throwaway repositories and use fake `gh`, `glab`, `ssh` and `lsof`, so they never touch real worktrees or the network.

## License

MIT, see [LICENSE.txt](LICENSE.txt).
