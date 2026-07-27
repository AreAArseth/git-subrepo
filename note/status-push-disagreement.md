# git-subrepo status and push disagreement

## Summary

`git subrepo status` could report hundreds of commits to push even when the
subrepo content already matched upstream, and normal `git subrepo push` then
refused to push its own reconstructed branch. In the same state:

- `git subrepo status <subdir>` reported several hundred commits to push.
- `git subrepo push <subdir>` failed because its reconstructed branch did not
  contain the upstream HEAD.
- `git subrepo push <subdir> --squash` reported that there were no new commits.
- A direct tree comparison confirmed that the only difference was the local
  `.gitrepo` metadata file, which must not be pushed upstream.

These were three independent defects:

1. A false positive in the status implementation, because its content
   comparison included `.gitrepo`. **Fixed**, see "Issue 1" below.
2. An ancestry-reconstruction problem in normal, non-squashed push. **Fixed**,
   see "Issue 2" below.
3. A push with nothing to contribute still reconstructed the whole range and
   recorded no sync point, so the cost recurred on every invocation. **Fixed**,
   see "Issue 3" below.

## Conditions

Both defects need a parent repository that has lived for a while:

- The subrepo was cloned long ago and pulled since. A merge-method
  `git subrepo pull` that merges anything local does not update the `parent`
  field in `.gitrepo`, so `parent` stays at the original clone point while
  `commit` tracks the latest pull. Every such repository has a very wide
  `$subrepo_parent..HEAD` range. See "Issue 3" for the exact rule.
- Many parent-repository commits touch the subdirectory after that recorded
  parent.
- The history between the recorded parent and `HEAD` contains merges.
- For Issue 2, at least one commit in that range has no readable
  `<subdir>/.gitrepo`. A commit that removes and later restores the
  subdirectory is enough.

The `.gitrepo` state that triggers it looks like this, with `parent` much older
than `commit`:

```ini
[subrepo]
	remote = <subrepo remote>
	branch = <tracking branch>
	commit = 1111111111111111111111111111111111111111
	parent = 2222222222222222222222222222222222222222
	method = merge
	cmdver = 0.4.9
```

Investigated against `git-subrepo 0.4.9` at `e65e2e2` with git `2.43.7`. The
status implementation involved in Issue 1 was introduced by `f23bb2d4`.

## Symptoms

Status reported the whole parent-repository history as pending, with `.gitrepo`
as the only content difference:

```text
Git subrepo 'bar':
  Remote URL:      <subrepo remote>
  Upstream Ref:    1111111
  Tracking Branch: <tracking branch>
  Pulled Commit:   1111111
  Pull Parent:     2222222
  Pull:           up to date
  Push:           323 commits
    Local commits:
      3333333 <parent repo commit subject>
      4444444 <parent repo commit subject>
      ...and 321 more commits
    Local diff:
       .gitrepo | 12 ++++++++++++
       1 file changed, 12 insertions(+)
```

Normal push failed:

```text
git-subrepo: Can't commit: 'subrepo/bar' doesn't contain upstream HEAD:
1111111111111111111111111111111111111111
```

Squashed push reported no work:

```text
Subrepo 'bar' has no new commits to push.
```

## Content-parity verification

Comparing the fetched upstream root tree with the current subtree showed that
`.gitrepo` was the only difference:

```bash
git diff --name-status refs/subrepo/bar/fetch HEAD:bar
```

```text
A	.gitrepo
```

Excluding `.gitrepo` makes the comparison succeed:

```bash
subrepo_commit=$(git config --file=bar/.gitrepo subrepo.commit)
subdir_tree=$(git rev-parse HEAD:bar)
git diff --quiet \
  "$subrepo_commit" "$subdir_tree" \
  -- . ':(exclude).gitrepo'
```

Exit status: `0`. So `--squash` was right that there was no content to push.

## Issue 1: status counts metadata-only history as pending (fixed)

The status implementation collects every parent-repository commit that touches
the subdirectory after `.gitrepo`'s recorded `parent`:

```bash
git rev-list "$subrepo_parent..HEAD" -- "$subdir"
```

It then tries to suppress that history count when the current subtree matches
the recorded upstream commit:

```bash
git diff --quiet "$subrepo_commit" "$subdir_tree"
```

The comparison included `.gitrepo` in the local subtree. The upstream subrepo
root does not contain `.gitrepo`, so the comparison was non-empty even when all
real content matched, and the code retained and reported the entire pending
list.

The same omission affected the `--diff` output, which is why `Local diff`
listed `.gitrepo` as the only changed file. Both call sites are in
`subrepo:status` in `lib/git-subrepo`.

### Fix

The parity check and the local diffstat both pass a pathspec that excludes
`.gitrepo`:

```bash
git diff --quiet "$subrepo_commit" "$subdir_tree" -- . ':(exclude).gitrepo'
```

The `Remote` diffstat is unchanged: it compares two upstream commits, and
neither side contains `.gitrepo`.

Because `assert-repo-is-ready` rejects running from anywhere but the top of the
repository, the leading `.` in the pathspec is always the whole tree.

### Regression test

`test/status.t` asserts that a subrepo whose content matches upstream reports
`Push: up to date` even with parent-repository commits touching the subdir, and
that a local content change produces a `Local diff` naming the changed file and
never `.gitrepo`.

## Issue 2: normal push reconstructs history without current upstream (fixed)

Normal push rebuilds `subrepo/<subdir>` from the parent-repository commits
between the recorded pull parent and `HEAD`. The branch builder in
`subrepo:branch`:

1. Runs:

   ```bash
   git rev-list --reverse --ancestry-path --topo-order \
     "$subrepo_parent..HEAD"
   ```

2. Selects a single chain by accepting a commit only when it is a direct child
   of the previously accepted commit.
3. Recreates subrepo commits with recorded `.gitrepo` commits as additional
   parents.
4. Removes `.gitrepo` with `filter-branch`.

During the failed push, the reconstructed branch did not contain the upstream
HEAD. Its merge base with the fetched upstream was an older commit, so the
safety check correctly refused to push it. The failure was therefore not in the
containment check; the branch handed to that check was incomplete.

### Root cause

The first theory was that the direct-child selection follows one side of a
merged history and never reaches the later synchronization commit on the
mainline. That theory is wrong, and ruling it out matters because it changes
what the fix has to do.

`--topo-order --reverse` is a topological order, so a commit always appears
after every in-range ancestor of itself. Every in-range commit except `HEAD`
has at least one in-range direct child, and that child appears later in the
list. So on graph shape alone the greedy chain can never dead-end: whichever
fork it takes, the merge commit that rejoins the forks has the current chain
tip as one of its parents and is accepted.

What actually severed the chain was the `.gitrepo` presence check, which ran
*before* the direct-child check and skipped the commit without advancing the
recorded ancestor:

```bash
FAIL=false OUT=true RUN git config --blob \
  "$commit:$subdir/.gitrepo" "subrepo.commit"
if [[ -z $output ]]; then
  o "Ignore commit, no .gitrepo file"
  continue
fi
```

Once a commit in the range had no `.gitrepo` file, or a `.gitrepo` from which
`subrepo.commit` could not be read, the chain tip stayed behind that commit.
Every later commit was then a child of the skipped commit rather than of the
tip, so all of them, `HEAD` included, were rejected as "not in the selected
path". The branch stopped at whatever commit happened to be the tip, which is
why it carried an old `.gitrepo` commit as its merge parent and failed
containment.

Verbose output from the reproduction, with the chain dying one commit before
the removal:

```text
* Working on <commit that removed the subdir>
* Ignore commit, no .gitrepo file
* Working on <next commit>
* is child:
* Ignore <next commit>, it's not in the selected path
```

### Fix

The reconstructed branch has to satisfy both invariants before push:

1. It contains the fetched upstream HEAD.
2. Its root tree, excluding `.gitrepo`, equals the current subdirectory tree.

Both follow once the chain is guaranteed to end at `HEAD`, because `HEAD`'s
`.gitrepo` records the upstream commit that push has already verified against
the fetched upstream, and `HEAD`'s subdir tree is the tree being pushed.

Path selection and content recreation are now separate concerns. The
direct-child check and the `ancestor=$commit` assignment both run *before* the
`.gitrepo` lookup, so a commit that cannot be recreated still advances the
selected path:

```bash
if [[ $ancestor ]]; then
  # reject commits that are not a direct child of the current tip
fi

ancestor=$commit

FAIL=false OUT=true RUN git config --blob \
  "$commit:$subdir/.gitrepo" "subrepo.commit"
if [[ -z $output ]]; then
  o "Ignore commit, no .gitrepo file"
  continue
fi
```

That is enough to guarantee the chain reaches `HEAD`. Let `T` be the final tip
and suppose `T` is not `HEAD`. `T` is in range, so it is an ancestor of `HEAD`,
so it has a direct child `D` that is also in range. Topological ordering puts
`D` after `T` in the list, and nothing after `T` was accepted, so the tip was
still `T` when `D` was processed. `D` is a direct child of `T`, so `D` would
have been accepted, contradicting that `T` is final.

Note that a commit which removes the subdir is still not recreated, so the
reconstructed history jumps straight from the content before the removal to the
content after it is restored. The final tree is `HEAD`'s subdir either way.

### Rejected alternative

A first-parent traversal was considered:

```bash
git rev-list --reverse --first-parent "$subrepo_parent..HEAD"
```

This does not survive contact with the existing tests. `test/branch-rev-list.t`
pushes in the middle of its fixture specifically so that `subrepo_parent` ends
up on a *second* parent, commented "We push here to force subrepo to handle
histories where it's not first parent". A strict first-parent range excludes
that commit. Rewriting the walk to run backwards from `HEAD` would also work,
but it is unnecessary: the forward walk already reaches `HEAD` once the path
stops being severed.

### Regression test

`test/branch-merge-upstream.t` covers the three original symptoms, that a real
local change still pushes afterwards, and that `--squash` still works. Against
the unfixed `subrepo:branch`, 10 of its 14 assertions fail. The two `--squash`
assertions pass either way, which is consistent with squash bypassing the
reconstruction entirely.

## Issue 3: a push with nothing to contribute paid for the whole range (fixed)

Fixing Issue 2 made the reconstruction reach `HEAD`, so normal push stopped
failing. It did not make it cheap. Push reconstructed every commit in
`$subrepo_parent..HEAD` before it could compare the result against upstream, and
that is where the roughly 90 seconds went.

Worse, the outcome was not recorded. When push concluded there was nothing to
send it returned at `CODE=-2` *before* `update-gitrepo-file`, so `.gitrepo` was
left untouched and the next invocation reconstructed exactly the same range
again. This is also why `--squash` reporting "no new commits" never helped: it
took the same early return.

### Why the range grows without bound

`update-gitrepo-file` advances `parent` only when the reconstructed branch
resolves exactly to the upstream HEAD:

```bash
# Only write new parent when we are at the head of upstream
if [[ $upstream_head_commit && $subrepo_commit_ref ]]; then
  OUT=true RUN git rev-parse "$subrepo_commit_ref"
  if [[ $upstream_head_commit == "$output" ]]; then
    RUN git config --file="$gitrepo" subrepo.parent "$original_head_commit"
  fi
fi
```

Push satisfies that trivially, because it sets `subrepo_commit_ref` to the
upstream commit it just pushed. A merge-method pull does not: it merges upstream
into the reconstructed branch, so `subrepo_commit_ref` is a merge commit
whenever anything local was merged. That is coherent as a definition of a sync
point, since local commits that are not upstream do still need pushing. The
consequence is that a repository which pulls often and pushes rarely keeps
`parent` at the last push, and the range that both `status` and `push` have to
consider only grows.

### Fix

Push now checks content parity before reconstructing anything, using the same
comparison `status` uses:

```bash
if ! $force_wanted && ! $new_upstream &&
   [[ $subrepo_commit == "$upstream_head_commit" ]] &&
   subrepo-content-matches-upstream; then
```

If the subdir content already matches the recorded upstream commit there is
nothing to contribute, so the reconstruction is skipped entirely. When the range
did contain local commits, push also records the sync point: it sets
`subrepo_commit_ref` to the upstream commit so the guard above passes, calls
`update-gitrepo-file`, and commits the result with a `git subrepo push (sync)`
subject. Later `push` and `status` commands then start from that point instead
of walking the same history again.

The sync commit is only made when there was actually pending history. Straight
after a clone the only commit touching the subdir is the sync commit itself, so
a push there stays a plain no-op that changes nothing, which is what
`test/push-no-changes.t` and `test/push-after-push-no-changes.t` expect.

The parity comparison and the pending-commit walk are now shared helpers,
`subrepo-content-matches-upstream` and `subrepo-pending-push-commits`, used by
both `subrepo:status` and `subrepo:push`. The two commands cannot disagree about
what is pending, which was the original complaint.

### Behaviour change

Content parity now means there is nothing to push, so local subrepo commits
whose net content change is nothing new to upstream are no longer sent. Before
this change they were: individually they are not empty, so
`filter-branch --prune-empty` kept them and push duplicated content-redundant
history upstream. Nothing is lost in terms of content. To send such history
deliberately, reconstruct it and push that branch explicitly:

```bash
git subrepo branch <subdir>
git subrepo push <subdir> subrepo/<subdir>
```

`test/push-content-parity.t` covers both directions, including that the explicit
branch still carries net-zero commits upstream.

### Reconstruction cost

Two hot spots made the reconstruction itself slow, independently of how often it
ran.

`.gitrepo` was stripped with `filter-branch --tree-filter "rm -f .gitrepo"`,
which checks out every tree in the range to the filesystem just to delete one
file. An index filter does the same work without touching the worktree:

```bash
git filter-branch -f --prune-empty --index-filter \
  "git rm --cached -q --ignore-unmatch .gitrepo" -- "$filter" --first-parent
```

The rebase check in `subrepo:branch` ran once per commit, and
`git:commit-in-rev-list` implemented reachability as a full walk piped through
`grep`:

```bash
git rev-list "$list_head" | grep -q "^$commit"
```

That is now `git merge-base --is-ancestor`, which is also stricter, since the
old prefix match could accept an unrelated commit sharing a SHA prefix. The
reference commit being checked repeats across most of the range, so the check
now only runs when it changes, and the `git:rev-exists` guard was hoisted out of
the loop.

One call site relied on the old behaviour by accident: with an explicit branch
argument push does not fetch, so `upstream_head_commit` is empty and the old
empty-pattern `grep` matched anything. That containment check is now explicitly
skipped when there is no upstream head to check against.

### Measured

A fixture with 401 parent-repo commits touching the subdir since the recorded
parent, upstream history around 200 commits:

| scenario                          | before  | after  |
| --------------------------------- | ------- | ------ |
| content already matches upstream  | 36.2s   | 0.4s   |
| one real new file in the subdir   | 35.8s   | 26.8s  |

The first row is not a like-for-like comparison of outcomes: the old code did
not spend 36 seconds concluding there was nothing to do, it reconstructed the
range and pushed that content-redundant history upstream. That is the behaviour
change described above, and the timing is what an operator waited for either
way.

The second row is the reconstruction cost, which both versions pay. Attributing
it, with each change applied on its own: the index filter accounts for nearly
all of it (36.8s to 29.8s), and skipping the repeated rebase check for the rest.
The `merge-base` swap on its own was neutral at this scale, where process startup
dominates a 200-commit walk; it matters for long upstream histories, and it is
kept for the stricter comparison regardless.

## Why `--squash` behaved differently

For squash mode, `subrepo:push` sets:

```bash
subrepo_parent=HEAD^
```

The branch builder therefore creates a single cumulative subtree snapshot whose
additional parent is the recorded upstream commit. After `.gitrepo` is removed,
that snapshot is empty relative to the upstream commit and is pruned back to
it, so the command reports no new commits. This bypasses the reconstruction of
hundreds of individual parent-repo commits, and with it the Issue 2 defect. It
did not avoid the Issue 3 cost, because it still reconstructed a snapshot of the
whole range and still recorded nothing.

## Original impact

- Operators saw large false-positive push counts.
- A no-op normal push took roughly 90 seconds before failing, every time.
- The failure suggested missing upstream reconciliation even though content was
  already equal.
- Users were tempted to use `--force`, which bypasses the correct ancestry
  safety check and is unsafe on protected branches.
- Automation could not reliably distinguish real subrepo content from
  parent-repository history using the status output alone.

## Diagnosis

To check by hand whether a subrepo has real content to push:

```bash
git diff --name-status refs/subrepo/<subdir>/fetch HEAD:<subdir>
```

If `.gitrepo` is the only result, there is no subrepo content to push.

Do not use `--force` to bypass the ancestry check. It disables the containment
guarantee that both fixes above exist to preserve.
