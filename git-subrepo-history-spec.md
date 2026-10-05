# git-subrepo: shared history visibility

Draft specification · 4 October 2026

## Selected implementation contract

This fork selects **Option 3**. The comparisons and experiment reports below
describe the pre-implementation baseline; preserve them as evidence, not as
instructions to use the prototype commit-construction paths.

New subrepos default to prefixed history. Existing subrepos remain legacy until
`git subrepo migrate <path>`; new repositories can opt out with
`--history=legacy`. Migration moves all managed fields to `[subrepo-v2]`, with
metadata `format = 2` and `rewriteFormat = 1`. There is no parallel `[subrepo]`
section. The original upstream commit remains the synchronization identity;
`mappedCommit` identifies its prefixed browsing counterpart.

Imports use normal Git commits, including hooks and configured signing, with
the previous project HEAD first and the mapped upstream tip second. Rewriting
preserves raw message bytes and identities, removes invalidated signatures, and
uses versioned commit headers for provenance. Exports use original-layout history,
not browsing ancestry. Ordinary clones retain imported history without cache refs.

History repair is detected automatically but never silently approved. Each repair
requires confirmation or a proposal-bound `--accept-repair` token. It preserves
non-metadata content; irrecoverable local commit boundaries may be consolidated
into an explicitly identified contribution. `--all` requires separate repairs
first. Messages must explain the cause, retained state, and next safe action
without requiring users to choose hashes or edit tracking files.

`git subrepo log` combines local and imported changes offline. Optional
`--group-equivalent` uses provenance plus exact shared-delta checks; subjects
alone never prove equivalence. Incoming history uses explicitly fetched original
objects. Linked parent worktrees serialize operations, with ownership checks and
journaled recovery after interruption or remote-success/local-failure.

Initial scope excludes unborn parent repositories, nested prefixed subrepos,
directory moves, force pushes, and automatic divergent-upstream recovery.
Initialize the parent with a normal commit before importing. Use `retarget` for
supported upstream transitions.

The old-client section is an accidental-use guard, not universal compatibility
enforcement. Dedicated tests exercise upstream `5e0f401` and fork baseline
`91edb7044289294b9e47f646217461c47639c346`. In particular, upstream legacy
`status` can return success while reporting missing old metadata.

The public-CLI E2E in `test/history-e2e.t` uses real bare remotes, independent
parents, three alternating synchronization cycles, and an ordinary fresh clone.
Focused `test/history-*.t` suites cover migration, original-layout export,
repair, grouping, raw-byte/golden-object identity, hooks/signing, interruption,
worktree ownership, native SHA-256, file modes, symlinks, gitlinks, and installed
execution. Run `make test`; pinned-client checks use `make test-history-compat`.
The Bash/Git platform matrix is a separate `make CI_TEST` gate requiring Docker.
Local and platform validation are separate gates: run the configured oldest and
newest supported versions before claiming cross-version compatibility.

## Goal and scope

Developers in independent parent repositories should easily see individual changes imported through a shared subrepo. Identifying the originating parent project is not required. This spec compares three approaches, from improving the existing pull message to making imported commits part of the parent repository's reachable history. These historical proposals are superseded by the selected implementation contract above.

Upstream reviewed: https://github.com/ingydotnet/git-subrepo, commit `5e0f401`, reporting version 0.4.9.

## Verified baseline

Local fixtures contain parent repositories A and B, both using directory `shared/` and a common bare upstream. A → upstream → B and B → upstream → A were tested successfully. Parent-only files and `.gitrepo` were excluded from upstream; both parent working trees remained clean.

Normal `git log` shows one integration commit per pull. Individual upstream commits are currently accessible through `git log refs/subrepo/shared/fetch` after fetching or pulling. Exported commits retain messages but have different hashes from their parent-project counterparts because they contain only shared changes. Plain `git log` inside `shared/` still reads the parent repository's history.

## Comparison

| Aspect | 1. Pull-message summary | 2. Upstream as second parent | 3. Prefix-rewritten history |
| --- | --- | --- | --- |
| Plain `git log` | Individual summaries inside pull message | Individual upstream commit entries | Individual rewritten commit entries |
| `git log --oneline` | Integration title only | Individual upstream subjects | Individual rewritten subjects |
| `git log -- shared/` | Integration commits and local changes | Imported upstream paths do not match | Paths match; Git history simplification still matters |
| Individual imported diffs | Requires upstream objects/ref | Available, paths rooted in upstream | Available, paths under `shared/` |
| Fresh ordinary clone | Summary survives | Reachable upstream history survives | Reachable rewritten history survives |
| Parent history topology | Unchanged | Additional merge parent | Additional merge parent with rewritten history |
| Relative complexity | Low | Medium to high | High |

## Option 1: include imported commit summaries in pull messages

### User behavior

A pull creates a commit with a descriptive subject and an imported-change list in its body:

```text
Update shared: 2 incoming commits

Imported shared commits:
  abc1234 Alice — Fix reset handling
  def5678 Bob — Add timeout coverage

[existing git-subrepo metadata]
```

Default `git log` displays the body. `--oneline` displays only the subject. This is a summary, not separate reachable commit entries; a fresh clone need not contain the objects named in the summary.

### Implementation

1. Capture the old upstream commit from `.gitrepo` before updating metadata.
2. Fetch the new upstream tip. Enumerate commits reachable from the new tip but not the old tip, e.g. `git log --reverse OLD..NEW` with a deliberate format and ordering.
3. Extend `get-commit-message()` in `lib/git-subrepo` for pull operations. Preserve existing metadata and respect explicit `--message`, `--file`, and editing behavior.
4. Define behavior for initial clone, missing old objects, divergent/rewritten upstream, and large summaries. Do not silently call a divergent update a simple linear range; flag it and describe the selected reachable-commit set.
5. Show all imported summaries by default; if a configurable limit is added, include the total and an explicit omitted count.

### Acceptance

Two incoming upstream commits appear with distinct authors, subjects, and hashes in the pull body; repeated no-op pulls do not create duplicate summaries. Summaries survive an ordinary clone. Existing custom-message behavior and machine-readable metadata remain valid.

## Option 2: attach unmodified upstream history as a second parent

### User behavior

An integration commit has the previous parent-project HEAD as its first parent and the fetched upstream tip as its second parent. Its tree remains the intended parent-project tree, including the shared prefix and `.gitrepo`.

Ordinary unfiltered `git log` can traverse upstream commits as separate entries. `--first-parent` keeps the compact parent-project view. Normal clones retain reachable imported history, although shallow clones may truncate it.

### Implementation

Construct the integration commit from the prepared tree using a two-parent commit mechanism such as `git commit-tree TREE -p PARENT_HEAD -p UPSTREAM_TIP`, then safely update the branch and working tree. A production implementation must preserve signing, hooks, author identity, custom messages, editing, failure recovery, and metadata behavior; a raw `commit-tree` prototype does not automatically preserve these.

Do not perform an ordinary tree merge with the upstream root: that would place shared files at the wrong paths. Define whether clone/import also attaches upstream ancestry, and how repeated pulls, nested subrepos, multiple subrepos, and existing installations transition into this mode. Introduce it as an explicit opt-in history mode initially.

### Limitations and risks

Upstream commits use paths such as `file.txt`, while the parent uses `shared/file.txt`. Consequently directory-filtered history and blame do not automatically follow upstream history. Root path names can also overlap with unrelated parent files and confuse path-history browsing. Merge commit comparisons against the second parent may produce noisy whole-project differences; first-parent comparisons should show only the intended integration changes.

Changing ancestry may affect git-subrepo's branch extraction and export logic. Repeated push/pull correctness must be demonstrated before adopting this mode. Full upstream ancestry increases parent repository history and object size.

### Acceptance

An integration has exactly the intended two parents and the same final tree as the baseline pull. Imported commits appear as separate entries in unfiltered logs and survive a fresh clone. First-parent diffs are correct. Subsequent exports contain only shared changes, with no duplicated parent history or `.gitrepo`. Path-filtering limitations are documented and demonstrated.

## Option 3: rewrite imported history under the shared prefix

### User behavior

Imported commits become reachable entries whose file paths are `shared/file.txt`. Authors, messages, and timestamps are preserved where possible; hashes change. Directory-filtered history can traverse the correctly prefixed imported changes, subject to Git's merge-history simplification. Blame must be tested, not assumed to work merely because paths match.

### Implementation

1. Deterministically map each upstream commit to a rewritten commit whose entire tree is nested under the configured subrepo path, and whose parents are the corresponding rewritten upstream parents.
2. Preserve upstream merge topology and maintain an upstream-to-rewritten mapping scoped by prefix and rewrite format. Reuse it on repeated pulls; support rebuilding it from durable data after a fresh clone.
3. Attach the rewritten upstream tip as the integration commit's second parent. The first parent remains the parent-project HEAD and the integration tree preserves unrelated parent files.
4. Keep original upstream IDs for fetch/push tracking and `.gitrepo`. Define extraction/export behavior so rewritten ancestry does not cause duplicate imports, accidental parent-file exports, or ambiguous mappings.
5. Specify metadata placement, subrepo moves, nested subrepos, force-updated upstreams, signing policy, and conversion from existing history modes. Rewriting invalidates original commit signatures; do not represent rewritten commits as retaining valid signatures.

### Limitations and risks

Rewriting every imported tree and its ancestry is more expensive and creates distinct objects for each prefix. Export remains a separate path transformation and must not assume rewritten commits equal upstream commits. Correct handling of merges, local shared changes, and repeated round trips is the main engineering challenge.

### Acceptance

Two individual imported commits appear in both unfiltered history and appropriate `shared/` path history. Their diffs contain only correctly prefixed files. Verify blame for unchanged imported lines and locally modified lines. Repeated pulls reuse existing mapped commits. A fresh clone can continue pulling and pushing. Upstream exports contain only unprefixed shared content and preserve intended changes without duplicates.

## Companion feature: `git subrepo log`

This is a proposed convenience command, separate from the three history formats:

```text
git subrepo log shared
git subrepo log shared --incoming
git subrepo log shared --oneline
```

Default behavior reads locally available fetched upstream history without modifying the working tree. An explicit fetch option may refresh it. Missing history should produce actionable guidance. `--incoming` compares the recorded upstream base with the fetched tip and warns if ancestry is divergent. Display authors, dates, subjects, and usable commit IDs. Pass-through Git log options need a documented argument boundary.

This can accompany any option, but does not make plain `git log` display separate imported entries by itself.

## End-to-end validation plan

Run each proposed mode in isolated copies of the existing two-parent fixture. For structural modes, also run the applicable existing git-subrepo tests.

1. Create multiple shared commits in A, including a commit that also changes a parent-only file; push shared changes, then pull into B.
2. Inspect default, one-line, graph, first-parent, and directory-filtered logs; inspect individual commit diffs and integration diffs.
3. Push changes from B back to A; repeat several cycles and verify file contents, export isolation, and no unexpected commit duplication.
4. Clone a parent repository afresh without copying local special refs; inspect visibility and continue synchronization.
5. Exercise independent edits, conflicting edits, upstream merge commits, no-op pulls, missing old objects, and a rewritten upstream.
6. Test multiple/nested subrepos, a non-default branch, custom commit messages, and failure recovery. Confirm original fixtures and upstream source remain untouched.

## Recommendation and estimated effort

Option 1 is the lowest-risk improvement for seeing what changed through ordinary Git tools. It does not satisfy a strict requirement for separate imported commit entries.

If separate entries are required, prototype Option 2 first and evaluate whether its path limitations are acceptable. Choose Option 3 only if history browsing by shared path and blame justify the additional complexity.

Rough planning estimates, not commitments: Option 1 is hours to a few days depending on edge-case coverage; Option 2 is hours for a local proof of concept and several days or more for reliable integration; Option 3 is plausibly weeks for a dependable implementation. Structural modes have now been tested as limited manual history prototypes, as recorded below. They are not implemented as git-subrepo features. Further testing should drive a revised estimate.


## Follow-up experiment: unmodified versus prefixed ancestry

Both modes were constructed manually in isolated copies of parent A and independent bare remotes. The existing pull commit was replaced by an experimental two-parent commit using exactly the same final tree; git-subrepo itself was not modified.

For the unmodified mode, the second parent was upstream tip `7357458`. For the prefixed mode, upstream commits were reconstructed in topological order using prefixed trees, mapped parents, preserved messages, authors, committers, and dates. The corresponding tip became `6c8d02e`.

| Check | Unmodified upstream | Prefix-rewritten upstream |
| --- | --- | --- |
| Integration tree identical to baseline | Passed | Passed |
| Individual B commit in ordinary log | `7357458` | `6c8d02e` |
| Log filtered to `shared/from-b.txt` | Integration commit only | Individual B commit |
| Imported individual diff path | `from-b.txt` | `shared/from-b.txt` |
| Blame on new one-line shared file | Traced B's original upstream commit through rename detection | Traced rewritten B commit at prefixed path |
| Fresh clone has attached history without special refs | Passed | Passed |
| Subsequent stock subrepo push, then pull | Passed | Passed |
| Upstream contains only intended shared files | Passed | Passed |
| Final working tree clean | Passed | Passed |

The blame result qualifies the earlier concern: mismatched paths do not necessarily prevent blame from following ancestry. Git detected the path change for this simple file. Ambiguous copies, renames, overlapping root paths, conflicts, and locally edited files remain untested.

The subsequent stock pull created a normal single-parent integration commit in both cases. Existing experimental ancestry remained reachable, but newly incoming commits were not attached as separate parent-history entries. Either mode therefore requires integration into every applicable import operation; changing one commit is insufficient as a continuing feature.

These results establish feasibility for a linear, conflict-free example only. They do not establish production compatibility, correct merge handling, robust blame, history mapping after moves, signature policy, hook behavior, or repeated long-running synchronization.

Refined recommendation: if unfiltered individual logs are the main requirement, unmodified upstream ancestry is the simpler structural option and preserves shared-upstream hashes. If developers routinely inspect history by `shared/` path, the prefixed mode already demonstrates a concrete usability benefit, at the cost of rewritten hashes and mapping complexity.


## Further risk checks: stable identity and merges

Additional isolated experiments established:

- Rebuilding the prefixed history reproduced the previously generated `6c8d02e` tip exactly. Repeating a rewrite and extending upstream history kept previously mapped IDs unchanged, with prefix and reconstruction format fixed.
- A two-branch upstream merge retained both mapped parents, the correctly prefixed tree, and directory-filtered visibility. A later stock subrepo push exported only intended shared files and retained the original upstream merge as an ancestor.
- An upstream merge with an actual same-file conflict was resolved upstream and then rewritten. The rewritten result preserved the resolved content, both mapped parents, and their mapped common ancestor. This does not test a conflicting end-to-end pull into a locally modified parent project.
- Original upstream and rewritten upstream tips had no common ancestor in the isolated upstream graph. Import must use mapped ancestry consistently; export must use the original upstream ancestry. Mixing those graphs in an ordinary merge is not a substitute for mapping and extraction.
- Moving the prefix from `shared/` to `vendor/shared/` changed every mapped commit ID. Prefix moves require an explicit migration policy.
- The parent log can show the local full-project commit and its imported rewritten shared-only representation as separate commits with the same subject. Including special upstream refs with `--all` can show a third, original-upstream representation. Log duplication needs an explicit product decision; unchanged upstream ancestry also duplicates the local and exported versions.

### Requirements for a dependable prefix-history design

1. Keep original upstream IDs authoritative for synchronization. Give every rewritten commit an explicit durable association with its original upstream ID, and distinguish upstream IDs from rewritten IDs in interfaces.
2. Version the deterministic transformation: prefix, tree transformation, parent mapping, preserved metadata, message additions, and signature treatment all affect IDs. A reconstruction algorithm must preserve message bytes and metadata accurately; the experiment used simple messages, not arbitrary-byte fixtures.
3. Preserve the complete upstream parent graph, including merges, while keeping original and rewritten ancestry distinct during export.
4. Make mappings recoverable after cloning. Do not depend only on an unpushed local cache or special ref. Added provenance trailers may support recovery, but alter the mapped IDs and require a consistent format and export policy.
5. Preserve the parent-project first-parent chain and test subsequent imports, exports, conflicts, rebases, and reverts. A duplicate representation of a change is not a second independent change; reverts and cherry-picks must be tested explicitly.
6. Do not carry invalid upstream commit signatures into rewritten commits. Original signed objects can be retained separately for verification; any new signature authenticates the rewritten object, not the original upstream hash.
7. Document hash-sensitive links, CI references, external review annotations, and prefix moves. Do not silently rewrite existing published parent-project history when enabling the feature.

Recommendation remains conditional: prefix history is the stronger fit when both ordinary and directory-filtered logs are essential. Hash changes alone do not prove merges are unsafe; inconsistent ancestry mapping, export interactions, and duplicate change representations are the issues to validate. No production feature has yet been implemented.


## Open issue register and reproduction evidence

Status terminology: **Observed** means the described effect occurred in the fixture; **partly tested** means only a narrower case passed; **untested risk** is a requirement to investigate, not a demonstrated failure. All structural changes were manual prototypes. No upstream git-subrepo source was patched.

### H1 — Duplicate representations in normal history (observed)

**Trigger:** A commits shared changes and a parent-only change together; A exports the shared portion; B adds shared changes; A imports upstream history using a prefixed second parent. The parent commit and rewritten shared-only commit are distinct objects.

Exact diagnostic commands, run in `history-experiment/prefixed/parent`:

```bash
git log --format='%h %s' --grep='^A changes shared and parent files$'
git log --all --format='%h %s' --grep='^A changes shared and parent files$'
```

Normal log showed `c4febc9` and `2a14131`, both with the same subject. With `--all`, `eb05b7e` appeared too. This is duplicate representation in browsing, not evidence that file changes were applied twice. Do not infer equivalence from matching subjects; this fixture's creation sequence establishes the relationship.

**Decision/test needed:** Whether to accept duplicate entries, annotate their provenance, or change the graph construction. Plain Git has no project-specific duplicate-collapse policy. Verify cherry-picking and reverting each representation, especially parent commits that also touch unrelated files.

### H2 — Path-filtered history loses individual commits without prefixing (observed)

Exact commands, run separately in each `history-experiment/{unprefixed,prefixed}/parent`:

```bash
git log --format='%h %s' -- shared/from-b.txt
git log --full-history --format='%h %s' -- shared/from-b.txt
```

Unprefixed mode showed only the integration commit `1c947d3`; prefixed mode's default path log showed B's individual mapped commit `6c8d02e`. `--full-history` included the prefixed integration as well.

**Decision/test needed:** Prefixing is necessary for the tested directory-history expectation. Add rename, deletion, copy, overlapping-root-path, and nested-directory cases. Default Git history simplification can hide integration nodes even when individual commits are correctly available.

### H3 — Existing pull stops attaching new upstream ancestry (observed)

**Trigger:** Starting from an experimental two-parent integration, clone afresh; point `.gitrepo` at an isolated bare remote; add `shared/next.txt`, commit and push through git-subrepo; create `incoming.txt` upstream and push; run the stock pull.

The runner invoked:

```bash
git subrepo config shared remote <isolated-bare-remote> --force
git add shared/.gitrepo
git commit -m 'Use isolated test remote'
git add shared/next.txt
git commit -m 'Next shared change'
git subrepo push shared
# In the isolated upstream clone:
git add .
git commit -m 'Next upstream change'
git push
# Back in the fresh parent clone:
git subrepo pull shared
git show -s --format=%P HEAD
```

The last command returned exactly one parent in both modes. Old experimental history remained reachable; new upstream ancestry was not automatically attached.

**Implementation needed:** Integrate the chosen ancestry policy into every applicable import operation. Test initial clone, repeated pulls, force imports, custom messages, and existing installations.

### H4 — Original and rewritten graphs have different identities (observed)

The rewrite used a separate index to create prefixed trees and rebuilt each commit with mapped parents:

```bash
git read-tree --empty
git read-tree --prefix=shared/ <upstream-commit>
git write-tree
git commit-tree <prefixed-tree> -p <mapped-parent> # repeated -p for merges
```

The runner set `GIT_INDEX_FILE` to an isolated index and preserved author/committer identity and dates; commit messages were supplied on stdin. The complete runner below records those details.

After rewriting an upstream conflict-resolution merge, the test ran:

```bash
git merge-base <original-upstream-tip> <rewritten-upstream-tip>
```

It exited with status 1 and no common ancestor in the isolated upstream graph. This is expected for a full ancestry rewrite, not a failed pull.

**Implementation needed:** Preserve explicit original-to-rewritten associations. Use original ancestry for upstream synchronization and consistently mapped ancestry for imported browsing. Do not mix the two identities as if they were interchangeable merge bases.

### H5 — Prefix moves invalidate mapped IDs (observed)

The risk runner rebuilt the same upstream graph twice with `shared/` and once with `vendor/shared/`. It asserted that identical rewrites matched and that every mapped ID changed when the prefix moved.

**Decision/test needed:** Version the transformation and define a migration policy for path moves and transformation changes. Check external links, CI references, and annotations that store mapped hashes.

### H6 — Merge/conflict correctness beyond the prototype (partly tested)

The risk runner created two upstream branches with independent files, then ran:

```bash
git merge --no-ff feature -m 'Merge shared feature'
```

It verified the rewritten merge had the corresponding two mapped parents and a subtree equal to the original upstream tree. After attaching that graph to a parent, `git subrepo push shared` succeeded; the original upstream merge remained an ancestor of the exported tip.

The conflict runner modified `shared.txt` differently on `main` and `conflicting-feature`, then ran:

```bash
git merge --no-ff conflicting-feature -m 'Resolve shared-line conflict'
# Expected status 1 and a conflict; replace file contents with the resolution:
git add shared.txt
git commit --no-edit
```

It rewrote the resolved graph and verified resolution contents, both mapped parents, their mapped merge base, and unchanged IDs for older mapped commits.

**Still needed:** Concurrent parent-project edits plus incoming upstream edits, actual conflict resolution during subrepo pull, multiple repeated round trips, parent branch merges, rebase, revert, cherry-pick, and upstream history replacement. Rewriting an already-resolved upstream merge does not establish those cases.

### H7 — Blame with mismatched paths (partly tested; no failure observed)

Exact commands in both prototype parents:

```bash
git blame --porcelain shared/from-b.txt
```

Unprefixed mode traced commit `7357458` with original filename `from-b.txt`; prefixed mode traced `6c8d02e` with filename `shared/from-b.txt`. Git's rename detection succeeded for the tested new one-line file.

**Still needed:** Ambiguous identical files, copies, renames, deletions/recreations, local edits, and conflicting merges. Do not claim unprefixed blame always fails, or that one passing file proves reliable blame.

### H8 — Signatures, durable mappings, and operational behavior (untested risks)

Changing trees or parents changes commit IDs and invalidates signatures over the original commit object. No signed-commit experiment was run. Hooks, signing configuration, custom message handling, shallow clones, mapping recovery, and arbitrary message-byte preservation also remain untested. The prototype's simple message normalization is not a production preservation algorithm.

**Still needed:** Signed upstream fixtures, deterministic byte-preserving reconstruction, mapping recovery in fresh clones, safe failure rollback, repository growth measurements, and a policy for preserving original signed objects without duplicating them unnecessarily in normal browsing.

## Exact experiment runners

Commands executed in this session:

```bash
python /workspace/scratch/f2424c82de5a/history-experiment.py
python /workspace/scratch/f2424c82de5a/history-risk-experiment.py
python /workspace/scratch/f2424c82de5a/conflict-risk-check.py
```

The following listings preserve the actual runner source. They depend on the earlier `subrepo-e2e` fixture and the checked-out `git-subrepo` source described above. They are experiment records, not production utilities. The first two create output directories and intentionally fail if those already exist; replay them in a fresh isolated workspace with an equivalent seed fixture. Existing directories were not deleted during this session. Diagnostic snippets above use placeholders where hashes or paths depend on that replay.

### history-experiment.py

```python
import os, subprocess, json
from pathlib import Path
base=Path('/workspace/scratch/f2424c82de5a'); root=base/'history-experiment'; root.mkdir()
env=os.environ.copy(); env['PATH']=str(base/'git-subrepo/lib')+':'+env['PATH']; env['GIT_SUBREPO_ROOT']=str(base/'git-subrepo')
for k,v in [('NAME','History Test'),('EMAIL','history-test@example.invalid')]:
 for role in ['AUTHOR','COMMITTER']: env['GIT_'+role+'_'+k]=v
def g(c,*a,input=None,extra=None,check=True):
 p=subprocess.run(['git',*a],cwd=c,env=env| (extra or {}),input=input,text=True,capture_output=True)
 if check and p.returncode: raise RuntimeError(f'{a}: {p.stdout} {p.stderr}')
 return p.stdout.strip() if check else {'code':p.returncode,'stdout':p.stdout.strip(),'stderr':p.stderr.strip()}
results={}
for mode in ['unprefixed','prefixed']:
 d=root/mode; d.mkdir(); remote=d/'shared.git'; repo=d/'parent'
 g(d,'clone','--bare',str(base/'subrepo-e2e/shared.git'),str(remote))
 g(d,'clone',str(base/'subrepo-e2e/repo-a'),str(repo))
 tip=g(repo,'rev-parse','HEAD'); upstream=g(repo,'config','--file=shared/.gitrepo','subrepo.commit')
 g(repo,'fetch',str(remote),'main'); oldfirst=g(repo,'rev-parse','HEAD^'); mapping={}
 second=upstream
 if mode=='prefixed':
  for sha in g(repo,'rev-list','--reverse','--topo-order',upstream).splitlines():
   index=d/'rewrite-index'
   if index.exists(): index.unlink()
   ix={'GIT_INDEX_FILE':str(index)}
   g(repo,'read-tree','--empty',extra=ix); g(repo,'read-tree','--prefix=shared/',sha,extra=ix)
   tree=g(repo,'write-tree',extra=ix)
   parents=g(repo,'show','-s','--format=%P',sha).split(); args=['commit-tree',tree]
   for p in parents: args+=['-p',mapping[p]]
   fields=g(repo,'show','-s','--format=%an%n%ae%n%aI%n%cn%n%ce%n%cI',sha).splitlines()
   ce=dict(zip(['GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_AUTHOR_DATE','GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL','GIT_COMMITTER_DATE'],fields))
   mapping[sha]=g(repo,*args,input=g(repo,'show','-s','--format=%B',sha)+'\n',extra=ce)
  second=mapping[upstream]
 new=g(repo,'commit-tree',g(repo,'rev-parse','HEAD^{tree}'),'-p',oldfirst,'-p',second,input=f'Experimental {mode} history integration\n')
 g(repo,'reset','--hard',new)
 assert g(repo,'rev-parse','HEAD^{tree}')==g(repo,'rev-parse',tip+'^{tree}')
 r={'same_tree':True,'normal_log':g(repo,'log','--format=%h %s','-10'), 'path_log':g(repo,'log','--format=%h %s','--','shared/from-b.txt'),'full_path_log':g(repo,'log','--full-history','--format=%h %s','--','shared/from-b.txt'),'blame':g(repo,'blame','--porcelain','shared/from-b.txt').splitlines()[:12],'upstream_commit_diff':g(repo,'show','--format=','--name-only',second)}
 fresh=d/'fresh'; g(d,'clone','--no-local',str(repo),str(fresh))
 r['fresh_clone_has_second_parent']=g(fresh,'cat-file','-t',second)=='commit'
 r['fresh_clone_special_refs']=g(fresh,'for-each-ref','--format=%(refname)','refs/subrepo')
 g(fresh,'subrepo','config','shared','remote',str(remote),'--force'); g(fresh,'add','shared/.gitrepo'); g(fresh,'commit','-m','Use isolated test remote')
 (fresh/'shared/next.txt').write_text('Next parent change\n'); g(fresh,'add','shared/next.txt');g(fresh,'commit','-m','Next shared change')
 r['push']=g(fresh,'subrepo','push','shared',check=False)
 seed=d/'seed'; g(d,'clone',str(remote),str(seed));(seed/'incoming.txt').write_text('Next upstream change\n');g(seed,'add','.');g(seed,'commit','-m','Next upstream change');g(seed,'push')
 r['pull']=g(fresh,'subrepo','pull','shared',check=False)
 r['final_files']=g(fresh,'ls-files','shared')
 r['upstream_files']=g(seed,'ls-tree','-r','--name-only','HEAD')
 r['next_pull_parents']=g(fresh,'show','-s','--format=%P','HEAD')
 results[mode]=r
print(json.dumps(results,indent=2))
(root/'results.json').write_text(json.dumps(results,indent=2))
```

### history-risk-experiment.py

```python
import subprocess, os, json
from pathlib import Path
base=Path('/workspace/scratch/f2424c82de5a'); root=base/'history-risk-experiment'; root.mkdir()
env=os.environ.copy()
for k,v in [('NAME','Risk Test'),('EMAIL','risk-test@example.invalid')]:
 for role in ['AUTHOR','COMMITTER']: env['GIT_'+role+'_'+k]=v
def g(c,*a,input=None,extra=None):
 p=subprocess.run(['git',*a],cwd=c,env=env|(extra or {}),input=input,text=True,capture_output=True)
 if p.returncode: raise RuntimeError(f'{a}: {p.stderr}')
 return p.stdout.strip()
def rewrite(repo,tip,prefix):
 mapping={}; idx=root/'index'
 for sha in g(repo,'rev-list','--reverse','--topo-order',tip).splitlines():
  if idx.exists(): idx.unlink()
  ix={'GIT_INDEX_FILE':str(idx)}
  g(repo,'read-tree','--empty',extra=ix);g(repo,'read-tree','--prefix='+prefix,sha,extra=ix)
  tree=g(repo,'write-tree',extra=ix);args=['commit-tree',tree]
  for p in g(repo,'show','-s','--format=%P',sha).split():args+=['-p',mapping[p]]
  fields=g(repo,'show','-s','--format=%an%n%ae%n%aI%n%cn%n%ce%n%cI',sha).splitlines()
  ce=dict(zip(['GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_AUTHOR_DATE','GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL','GIT_COMMITTER_DATE'],fields))
  mapping[sha]=g(repo,*args,input=g(repo,'show','-s','--format=%B',sha)+'\n',extra=ce)
 return mapping
up=root/'upstream';g(root,'clone',str(base/'subrepo-e2e/shared.git'),str(up))
old=g(up,'rev-parse','HEAD');initial=rewrite(up,old,'shared/')
assert initial[old]=='6c8d02efdda873d1ec2d78a399238e2675133986'
g(up,'switch','-c','feature');(up/'feature.txt').write_text('Feature change\n');g(up,'add','.');g(up,'commit','-m','Feature change');feature=g(up,'rev-parse','HEAD')
g(up,'switch','main');(up/'main.txt').write_text('Main change\n');g(up,'add','.');g(up,'commit','-m','Main change');main=g(up,'rev-parse','HEAD')
g(up,'merge','--no-ff','feature','-m','Merge shared feature'); tip=g(up,'rev-parse','HEAD')
m=rewrite(up,tip,'shared/');again=rewrite(up,tip,'shared/'); moved=rewrite(up,tip,'vendor/shared/')
assert m==again
assert all(m[x]==initial[x] for x in initial)
assert g(up,'show','-s','--format=%P',m[tip]).split()==[m[main],m[feature]]
assert g(up,'ls-tree',m[tip]+':shared')==g(up,'ls-tree',tip)
assert all(m[x]!=moved[x] for x in m)
source=base/'history-experiment/prefixed/parent'
print(json.dumps({'rewrite_reproduced_previous_tip':True,'repeated_rewrite_same_hashes':True,'extending_history_keeps_previous_hashes':True,'merge_topology_preserved':True,'prefixed_subtree_matches_upstream_tree':True,'moving_prefix_changes_all_mapped_hashes':True,'same_subject_multiple_entries':g(source,'log','--all','--format=%h %s','--grep=^A changes shared and parent files$'),'upstream_merge':tip,'rewritten_merge':m[tip]},indent=2))
# Attach rewritten merged history to isolated parent and exercise stock export again.
parent=root/'parent';g(root,'clone',str(source),str(parent));g(parent,'fetch',str(up),'main')
mp=rewrite(parent,tip,'shared/')
idx=root/'integration-index';ix={'GIT_INDEX_FILE':str(idx)}
g(parent,'read-tree','HEAD',extra=ix)
paths=g(parent,'ls-files','shared').splitlines()
g(parent,'update-index','--force-remove','--',*paths,extra=ix)
g(parent,'read-tree','--prefix=shared/',tip,extra=ix)
# Retain tracking metadata but update upstream commit and synchronization parent.
meta=g(parent,'show','HEAD:shared/.gitrepo');p=root/'gitrepo';p.write_text(meta+'\n')
g(root,'config','--file='+str(p),'subrepo.commit',tip);g(root,'config','--file='+str(p),'subrepo.parent',g(parent,'rev-parse','HEAD'));g(root,'config','--file='+str(p),'subrepo.remote',str(up))
blob=g(parent,'hash-object','-w',str(p));g(parent,'update-index','--add','--cacheinfo','100644,'+blob+',shared/.gitrepo',extra=ix)
tree=g(parent,'write-tree',extra=ix); commit=g(parent,'commit-tree',tree,'-p',g(parent,'rev-parse','HEAD'),'-p',mp[tip],input='Import upstream merge with prefixed history\n');g(parent,'reset','--hard',commit)
print('Merged path log:\n'+g(parent,'log','--format=%h %s','--','shared/feature.txt'))
# Bare remote avoids pushing to checked-out upstream branch.
remote=root/'remote.git';g(root,'clone','--bare',str(up),str(remote))
g(parent,'config','--file=shared/.gitrepo','subrepo.remote',str(remote));g(parent,'add','shared/.gitrepo');g(parent,'commit','-m','Use bare risk-test remote')
(parent/'shared/after-merge.txt').write_text('After merge change\n');g(parent,'add','shared/after-merge.txt');g(parent,'commit','-m','Change after importing upstream merge')
env['PATH']=str(base/'git-subrepo/lib')+':'+env['PATH'];env['GIT_SUBREPO_ROOT']=str(base/'git-subrepo')
print(g(parent,'subrepo','push','shared'))
print('Exported paths:\n'+g(root,'--git-dir='+str(remote),'ls-tree','-r','--name-only','main'))
print('Original upstream merge remains ancestor:',g(root,'--git-dir='+str(remote),'merge-base',tip,'main')==tip)
print('Clean:',not g(parent,'status','--porcelain'))
```

### conflict-risk-check.py

```python
exec(open('/workspace/scratch/f2424c82de5a/history-risk-experiment.py').read().split("up=root/'upstream'")[0].replace("root.mkdir()","root.mkdir(exist_ok=True)"))
up=root/'upstream';oldtip=g(up,'rev-parse','HEAD');before=rewrite(up,oldtip,'shared/')
g(up,'switch','-c','conflicting-feature');(up/'shared.txt').write_text('Feature-side replacement\n');g(up,'add','.');g(up,'commit','-m','Feature edits shared line');feature=g(up,'rev-parse','HEAD')
g(up,'switch','main');(up/'shared.txt').write_text('Main-side replacement\n');g(up,'add','.');g(up,'commit','-m','Main edits shared line');main=g(up,'rev-parse','HEAD')
p=subprocess.run(['git','merge','--no-ff','conflicting-feature','-m','Resolve shared-line conflict'],cwd=up,env=env,text=True,capture_output=True)
assert p.returncode==1 and 'CONFLICT' in p.stdout
(up/'shared.txt').write_text('Resolved shared replacement\n');g(up,'add','shared.txt');g(up,'commit','--no-edit');tip=g(up,'rev-parse','HEAD')
m=rewrite(up,tip,'shared/');assert all(m[x]==before[x] for x in before)
assert g(up,'show',m[tip]+':shared/shared.txt')=='Resolved shared replacement'
assert g(up,'show','-s','--format=%P',m[tip]).split()==[m[main],m[feature]]
assert g(up,'merge-base',m[main],m[feature])==m[oldtip]
print('PASS: resolved conflicting merge preserved content, both parents, and common rewritten merge base; prior mapped hashes unchanged.')
# Original and rewritten upstream DAGs must not be confused during merge/export.
p=subprocess.run(['git','merge-base',tip,m[tip]],cwd=up,env=env,text=True,capture_output=True)
assert p.returncode==1
print('Confirmed: original and prefix-rewritten upstream tips have no common ancestor in their isolated upstream graph.')
```


## Worktree consideration: when rewriting happens

### Proposed import/export boundary

For Option 3, prefix rewriting is part of importing upstream history into the parent project, during `git subrepo clone` or `git subrepo pull`. Fetch original upstream objects first; create or reuse their prefix-rewritten counterparts; then attach the mapped tip as the parent integration commit's second parent. Original upstream objects and upstream tracking IDs remain unchanged.

Entering a worktree does not trigger prefix rewriting. `git subrepo branch shared` should continue to create an upstream-layout branch/worktree: files live at its root, without the parent project's `shared/` prefix. Its upstream ancestry uses original upstream hashes. If there are unpushed parent-project shared changes, extraction creates additional upstream-layout commits, whose hashes may differ from the parent commits. The worktree is therefore not necessarily an exact upstream checkout.

### Verified test against the manual prefixed prototype

Created an isolated clone of `history-experiment/prefixed/parent` at `branch-history-check`, configured test author/committer identity, and enabled the checked-out git-subrepo executable through PATH and GIT_SUBREPO_ROOT. Ran:

```bash
git subrepo branch shared -F
git worktree list --porcelain
git ls-tree -r --name-only subrepo/shared
git log --format='%h %s' subrepo/shared
git merge-base --is-ancestor 7357458 subrepo/shared
git merge-base --is-ancestor 6c8d02e subrepo/shared
```

The `-F` option fetched upstream history before constructing the branch. The command created branch `subrepo/shared` and worktree `.git/tmp/subrepo/shared`.

Observed worktree tip: original upstream commit `7357458`. Files were `from-b.txt` and `shared.txt` at the worktree root; there was no enclosing `shared/` directory and no `.gitrepo` in the extracted tree. Branch history showed original upstream commits `7357458`, `eb05b7e`, and `c6c8a52`.

The original-tip ancestry check exited 0 (true); the prefixed-tip ancestry check exited 1 (false). Thus the generated worktree used original upstream ancestry, rather than the rewritten browsing ancestry, in this synchronized, no-local-changes case.

### Design requirement and remaining checks

Keep the prefix-history mapping out of the upstream-layout worktree's export ancestry. Parent-project browsing and shared-repo development use different graph representations deliberately. Future Option 3 code must retain this behavior for branch creation, pull, push, and manual worktree editing.

The tested command was the existing git-subrepo implementation operating on a manually constructed prototype. Automatic rewrite-on-clone/pull is still a proposal. Explicitly test branch creation with unpushed shared changes, commit from the worktree back into the parent, subsequent export, conflicting updates, and synchronization after a fresh clone. This test alone does not establish those cases.


## Subcommand coverage for Option 3

The following requirements are derived from inspection of the current command handlers. They describe proposed integration behavior, not completed compatibility tests.

| Command | Required behavior or design decision | Validation needed |
| --- | --- | --- |
| `clone` | Import original upstream objects; create/reuse prefixed counterparts and attach their ancestry to the parent integration. | Initial import into existing and empty parent repositories; ordinary fresh clone retains browsing history. |
| `pull` | Extend the same deterministic mapping and attach newly imported ancestry on every integration. | Repeated pulls, upstream merges, conflicts, no-op updates, force imports, and merge/rebase methods. |
| `branch` | Keep upstream-layout worktrees and original upstream ancestry; extract local shared changes separately. | Existing synchronized case passed; test unpushed local changes and worktree edits. |
| `commit` | Apply the history policy when committing a manually merged subrepo branch into the parent. This must not bypass the behavior provided by pull. Determine how local extracted commits and fetched upstream commits contribute to the mapped integration ancestry. | Fetch → branch → manual merge/edit → commit → push → another parent's pull; test custom branch arguments and conflicts. |
| `push` | Export only shared content using original upstream ancestry. Do not export prefixed trees, browsing-only provenance, parent-only files, or `.gitrepo`. | Simple and upstream-merge examples passed; test repeated cycles, local parent merges, duplicate representations, and reverts. |
| `fetch` | Keep original upstream objects and refs authoritative. Fetch alone must not alter the parent branch/history. A mapping cache may be prepared only if its ownership and side effects are explicit. | Compare parent HEAD and working tree before/after fetch; verify original fetched IDs and offline behavior. |
| `init` | Define mapping and history-mode initialization when adopting an existing directory, including cases without a remote or established upstream base. Do not fabricate upstream history. | Existing directory with local history; empty/new upstream; later first push and pull. |
| `clean` | Removing worktrees/temporary branches must not destroy essential mapping state. Forced cleanup removes subrepo refs, so any cache must be reconstructible or retained under an explicitly documented policy. Attached history remains reachable through parent commits. | Clean and forced clean, then fresh fetch/branch/pull/push; validate mapping recovery without relying on old local refs. |
| `config` | Define when remote, branch, or merge-method changes preserve mappings, require new mappings, or invalidate synchronization state. Prefix moves need an explicit migration policy; they are not assumed to be handled by current config. | Switch upstream branch and remote, change merge/rebase method, and exercise a documented directory-move workflow. |
| `status` | Clearly label original upstream IDs, prefixed browsing IDs, and mapping availability when both representations exist. Existing labels must not imply those IDs are interchangeable. | Consistent status before/after import, cleanup, fresh clone, and local shared changes. |
| `help` | Document history mode, worktree boundary, hash distinctions, and limitations. | Examples agree with implemented behavior. |
| `version` | No direct history transformation; identify versions capable of handling the new mode. | Compatibility messaging is accurate. |
| `upgrade` | No direct history transformation; upgrading must not silently change an established rewrite format or invalidate stored mappings. | Define format/version compatibility across upgrades and downgrades. |

### Priority

1. **`commit` and `push`:** close the manual-import bypass and prove that export ancestry and content remain correct.
2. **`clean` and `config`:** prove mapping durability and define transitions when synchronization settings change.
3. **`init`, `fetch`, and `status`:** define first-use behavior, preserve the original upstream view, and make the two identities understandable.

Apply relevant `--all`, force, fetch, merge/rebase, custom-message, and nested-subrepo cases to each supported command rather than assuming single-subdirectory tests cover them. Existing command-handler inspection identifies the integration points; the validation work above remains open except where explicitly recorded as passed.


## Migration and mixed-client compatibility

### Preferred approach: explicit migration with a metadata-layout gate

Use an opt-in migration command and a new metadata layout that compatible clients understand, while the tested legacy client fails to read a required legacy field. This is the preferred approach agreed in discussion. Local hooks and CI may provide additional diagnostics or enforcement, but are not prerequisites for this proposed gate.

A version number alone is insufficient: the inspected client records `subrepo.cmdver = 0.4.9` but does not enforce it when reading `.gitrepo`. Its config handler accepts a `version` key, but inspection found no enforced metadata-format version check.

The tested gate moves the upstream tracking commit from `subrepo.commit` to a proposed `subrepo-v2.commit` field and removes the old field. New clients must explicitly understand the new layout; legacy clients encounter the missing mandatory `subrepo.commit` and stop. Keep the new file valid Git-config syntax. This is a deliberate format change, not an invalid SHA or deliberately broken remote.

Field names below are illustrative and not an implemented schema:

```ini
[subrepo]
    remote = <upstream remote>
    branch = main
    parent = <parent-project synchronization point>
    method = merge
    cmdver = <last writer version>
[subrepo-v2]
    format = 2
    history = prefixed
    rewriteFormat = 1
    commit = <original upstream commit ID>
```

Do not retain the legacy `subrepo.commit` alongside the new one in gated mode: the tested refusal depends on its absence. Metadata-format version, rewrite-format version, and software-writer version serve different purposes. New clients must reject unsupported metadata or rewrite formats before mutation and provide a clear upgrade diagnostic. Preserve original upstream IDs for synchronization; do not put mapped browsing IDs in their place.

### Proposed interface

```text
# New subrepo, explicit opt-in:
git subrepo clone <remote> shared --history=prefixed

# Existing subrepo, preview then migrate:
git subrepo migrate shared --history=prefixed --dry-run
git subrepo migrate shared --history=prefixed
```

These commands/options do not exist in the inspected checkout. Migration is more than setting a flag: it must attach historical ancestry, initialize/recover mappings, and record the gated metadata layout atomically.

### Existing-repository migration sequence

1. Installing new software preserves existing legacy-mode behavior until explicitly enabled. New clients support both known legacy and new formats.
2. For the initial implementation, require a clean working tree, no unresolved subrepo operation, and shared content synchronized to its recorded upstream base. Explain blockers and how to resolve them; do not silently push unrelated work as part of migration.
3. Fetch or locate the upstream commit recorded by the existing `.gitrepo`. Verify its required reachable history is available. If the remote has advanced, do not silently substitute its current tip: keep migration separate from importing new file content.
4. Reconstruct the chosen tip's prefix-rewritten ancestry deterministically, preserving the mapping and complete parent graph.
5. Create one migration commit with the current parent HEAD as first parent and the mapped upstream tip as second parent. Preserve the current parent tree except for the deliberate metadata changes. Keep all existing published parent commit IDs unchanged.
6. Record history mode, metadata format, rewrite format, original upstream tracking ID, and recoverable mapping/provenance. Validate synchronization-parent handling against subsequent extraction and export; do not assume the old `parent` field can be changed arbitrarily.
7. Publish the migration commit through the ordinary parent-project workflow. Each collaborator receives the metadata layout when they update that parent repository. Migrating one independent parent repository does not migrate other parents sharing the same upstream; each opts in separately, while the shared upstream remains in its original layout.
8. Compatible clients maintain mapped ancestry on applicable clone/pull/commit operations; branch worktrees and push retain upstream-layout semantics.

Dry run must leave parent refs, index, working tree, and tracking metadata unchanged. Explicitly document any fetch/cache side effects, or avoid them. Repeating migration to the same format must be a no-op; unsupported format transitions need a dedicated plan. Failure must not leave the branch pointing to an incomplete migration or metadata promising ancestry that was not attached.

Bulk migration uses `git subrepo migrate --all` (`-a`). With `--dry-run`, check
every subrepo and report every blocker without making changes. Without
`--dry-run`, run the same preflight checks before migrating any subrepo; a blocked
subrepo prevents all migrations. Already migrated subrepos are unchanged.
Integration failures after successful preflight may leave earlier migrations
completed; retries must safely resume or skip those completed migrations.
Content differing from the recorded upstream commit requires explicit push/pull
synchronization, not just fetching objects.

### Historical visibility and boundaries

The migration attaches history reachable from the recorded original upstream tip. It does not rewrite earlier parent-project integration commits or automatically restore upstream histories lost after force pushes. Old integration entries remain alongside attached individual history; duplicate representations are still an open issue. A repair/recovery procedure is needed for missing objects, old-client history gaps created before migration, or partial/manual conversions.

Changing prefix or rewrite format changes mapped identities and requires an explicit migration policy. Disabling history mode cannot remove already published attached ancestry without rewriting parent history; a rollback plan should distinguish reverting metadata/behavior from deleting historical commits.

### Confirmed legacy-client gate experiment

Tested client: checkout `5e0f401`, reporting git-subrepo 0.4.9. Isolated parent clone: `old-format-gate-test`, seeded from `history-experiment/prefixed/parent`.

The experiment moved the current upstream ID, added an illustrative format field, and committed the metadata change:

```bash
tracking_commit=$(git config --file=shared/.gitrepo subrepo.commit)
git config --file=shared/.gitrepo --unset subrepo.commit
git config --file=shared/.gitrepo subrepo-v2.commit "$tracking_commit"
git config --file=shared/.gitrepo subrepo-v2.format 2
git add shared/.gitrepo
git commit -m 'Experimental incompatible metadata layout'
```

It then invoked the following legacy commands in that clone:

```bash
git subrepo fetch shared
git subrepo pull shared
git subrepo push shared
git subrepo branch shared -F
git subrepo pull shared -r /workspace/scratch/f2424c82de5a/subrepo-e2e/shared.git -b main
```

All five returned exit status 1 with:

```text
git-subrepo: Command failed: 'git config --file=shared/.gitrepo subrepo.commit'.
```

Afterward parent HEAD was unchanged from the metadata-test commit, and `git status --porcelain` was empty. The explicit remote/branch override did not bypass the missing-commit check. This demonstrates refusal for those commands in this version; no compatible new-format client was implemented or tested.

### Remaining migration acceptance tests

- Test the gate across the intended supported legacy-version range, rather than extrapolating from 0.4.9.
- Exercise force options and all command paths, particularly forced clone/init/replacement behavior, manual commit, clean/config/status, `--all`, and nested subrepos. Clone/init do not use the same metadata-reader path, so the demonstrated gate must not be described as universal.
- Implement and test new-client reads/writes of both formats, unsupported-format refusal, migration idempotence, dry-run behavior, safe failure recovery, and downgrade diagnostics.
- Run a mixed-client sequence before and after migration, including branches created before the migration commit, metadata conflicts, and later parent merges. A legacy branch not yet updated with the migrated metadata is not locally protected by the new layout.
- Verify fresh clones can recover mappings and execute branch → worktree edits → commit → push → pull without exporting browsing-only metadata.
- Define whether additional hooks/server checks are useful for detecting merges from pre-migration branches. They remain optional supplements; the metadata gate is the chosen baseline.

### User guidance

Explain the format transition in migration output, `.gitrepo` comments, and documentation. The legacy client itself will emit a generic missing-field error; the new client and troubleshooting guide should identify it as an upgrade requirement. This gate prevents the tested accidental legacy operations, not deliberate metadata edits or every possible force replacement.


## Review decisions confirmed by the user

- Focus implementation on **Option 3: prefix-rewritten imported history**. Options 1 and 2 remain comparison material, not parallel implementation requirements. This supersedes earlier conditional recommendations.
- Accept duplicate representations in raw Git history. The proposed `git subrepo log` should annotate and optionally group confirmed equivalents using recorded provenance; matching messages alone are insufficient. Duplicates can involve any change already represented in parent history, not only the current user's own commits.
- Nested subrepos are not used in the user's current workflow and may be explicitly refused initially.
- Upstream force-pushed history is outside the intended workflow; detect divergence and refuse automatic recovery initially. This does not exclude ordinary branch merges in the parent project.
- Parent-project worktrees and subsequent branch integration are a real user workflow and require dedicated coverage. Directory-move requirements have not yet been confirmed.

## H9 — Synchronization point lost after squash-merging a parent worktree branch

**Status:** Reproduced in the legacy client. The user's described symptom is a possible match, not a confirmed diagnosis of their actual incident. The user's `retarget` command was not found in checkout `5e0f401`; its source and exact behavior are unknown.

### Distinguish this workflow

This uses a linked worktree of the **parent project** on another branch. Git subrepo commands run inside that parent worktree, then the branch is integrated back into another parent branch. It is not a nested subrepo and not the extracted upstream-layout worktree created by `git subrepo branch`.

### Trigger and reproduction

Disposable fixture: `parent-worktree-check`. It contains an isolated parent clone, a bare shared remote, a shared-upstream clone, and linked parent worktrees. The test used the existing legacy git-subrepo implementation without prefix-history changes.

1. Clone baseline parent A and copy the baseline shared upstream into an isolated bare remote. Change the cloned `.gitrepo` remote to that test remote and commit the change.
2. Record the parent starting commit and create a linked parent worktree on branch `feature`.
3. In the feature worktree, add and commit a parent-only file. This creates a branch-specific commit before the subrepo synchronization.
4. In the independent shared-upstream clone, add `incoming.txt`, commit it, and push to the isolated upstream.
5. In the feature parent worktree, run `git subrepo pull shared`. It records the branch-specific pre-pull commit in `subrepo.parent`.
6. Squash-merge `feature` into the original parent branch and commit the squashed result. The shared files and tracking metadata are present, but the branch-specific synchronization commit is not an ancestor of the receiving branch.
7. Run `git subrepo branch shared -F` in the receiving branch.

Equivalent replay commands after preparing the isolated remote and parent fixture:

```bash
# In the parent project:
start_commit=$(git rev-parse HEAD)
git worktree add -b feature ../feature

# In ../feature (a parent-project worktree):
printf 'Parent branch change\n' > feature-only.txt
git add feature-only.txt
git commit -m 'Parent feature change'

# In the independent shared-upstream clone:
printf 'Upstream change\n' > incoming.txt
git add incoming.txt
git commit -m 'Upstream change'
git push

# Back in ../feature:
git subrepo pull shared
git config --file=shared/.gitrepo subrepo.parent

# In the original parent branch, still at the recorded start:
git merge --squash feature
git commit -m 'Squashed feature integration'
git subrepo branch shared -F

# Diagnostic: evaluate the recorded tracking point against receiving HEAD.
sync_commit=$(git config --file=shared/.gitrepo subrepo.parent)
git merge-base --is-ancestor "$sync_commit" HEAD
```

The displayed shell sequence is an equivalent replay of the subprocess calls, not a claim that this exact shell block was executed. All mutations and branch resets in the experiment were confined to disposable fixtures.

### Observed result

The recorded synchronization point was `f2c1681b4e4e4c4cc3e09accd51b9da7b621a821`. After squash integration, `git merge-base --is-ancestor` returned false. The branch command refused with:

```text
git-subrepo: The last sync point (where upstream and the subrepo were equal) is not an ancestor.
This is usually caused by a rebase affecting that commit.
To recover set the subrepo parent in 'shared/.gitrepo'
to '5c32def25c8819c77b4d864aed08e51f4d1feaa0'
and validate the subrepo by comparing with 'git subrepo branch shared'
```

This is a failure of **ancestry**, not necessarily absence of the object: the feature branch still retains the original commit in this fixture. It concerns the parent-project synchronization point, distinct from the original-upstream-to-prefixed mapping.

### Passing control and experiment caveat

A separate linked parent worktree was created from the same pre-feature starting commit and integrated `feature` using an ordinary `git merge --no-ff`. The synchronization point remained an ancestor, and `git subrepo branch shared -F` successfully created the upstream-layout branch/worktree.

An earlier control attempt encountered an existing temporary `subrepo/shared` branch and refused with a branch-already-exists error. That was a distinct lifecycle issue, not an ancestry failure. The clean control was rerun after removing the temporary subrepo branch/worktree. Tests must distinguish temporary-branch collisions from tracking-point failures.

### Interpretation and remaining work

- Squash integration preserves the resulting files but not the original branch ancestry. The `.gitrepo` synchronization point can therefore be copied into a history where it is no longer a valid ancestor.
- A rebase or cherry-pick can plausibly create the same class of stale tracking point, but those variants were not reproduced in this experiment.
- Linked parent worktrees share refs and git-subrepo temporary branch/worktree names in the inspected implementation. Independently of the reproduced ancestry problem, test sequential and simultaneous operations from different parent worktrees for stale or colliding state.
- Inspect the user's actual `retarget` implementation and error before claiming that it repairs this exact condition. Do not automatically replace `subrepo.parent` with an arbitrary commit; validate that any chosen baseline matches shared contents and intended export history.
- Option 3 must test ordinary parent merges, squash integrations, and recovery separately. Attaching prefixed upstream ancestry alone does not repair an invalid original parent synchronization point.
- Initial behavior for unsupported squash/rebase recovery should fail with clear diagnostics and preserve data. Whether to provide an explicit validated repair/retarget command is an open design decision, not an implemented feature.
