# Chaos-Mode Issue #6: Use-After-Free in `apply_scanjoin_target_to_paths`

## The Crash

With chaos mode enabled, the query

```sql
SELECT * FROM prt1_l t1 FULL JOIN prt2_l t2 ON t1.a = t2.b
```

crashes in `create_plan_recurse` with a use-after-free: an AppendPath at
the top-level join still references a child path that `add_path` (or
`add_partial_path`) has already `pfree`'d.  The tables `prt1_l` and `prt2_l`
use *multi-level* partitioning — some partitions are themselves
range-/list-partitioned — which is the essential ingredient.

The table structure:

```
    prt1_l  RANGE(a)                    prt2_l  RANGE(b)
    ├── p1  [0,250)     leaf            ├── p1  [0,250)     leaf
    ├── p2  [250,500)   LIST(c)         ├── p2  [250,500)   LIST(c)
    │   ├── p2_p1  IN('0000','0001')    │   ├── p2_p1  IN('0000','0001')
    │   └── p2_p2  IN('0002','0003')    │   └── p2_p2  IN('0002','0003')
    └── p3  [500,600)   RANGE(b)        └── p3  [500,600)   RANGE(a)
        ├── p3_p1  [0,13)                   ├── p3_p1  [0,13)
        └── p3_p2  [13,25)                  └── p3_p2  [13,25)
```

The FULL JOIN produces a three-level partitioned join tree:

```
          J = prt1_l ⟗ prt2_l          ← top-level join (partitioned)
         /       |        \
    J_p1      J_p2          J_p3        ← child joins (p2,p3 partitioned)
   (leaf)    / \           / \
         J_p2_p1 J_p2_p2  J_p3_p1 J_p3_p2   ← grandchild joins (leaves)
```


## Root Cause: Two-Phase Construction With a Top-Down/Bottom-Up Mismatch

The optimizer builds partitioned-join paths in two phases:

**Phase 1 — `generate_partitionwise_join_paths` (bottom-up).**
For each partitioned join rel, recurse into children *first*, call
`set_cheapest` on each child, then call `add_paths_to_append_rel` to
assemble parent Append/MergeAppend paths from the now-frozen children.
Because construction is bottom-up and `set_cheapest` freezes each child's
pathlist before the parent reads it, Phase 1 is safe: no path the parent
holds a pointer to can be freed later.

**Phase 2 — `apply_scanjoin_target_to_paths` (top-down).**
After the join tree is complete, the planner must inject the final
scan/join target (with `sortgroupref` annotations and, potentially,
projection expressions).  This function processes the *parent first* —
modifying or wrapping its paths in-place — then recurses into each child
partition.  Inside the child recursion, `add_paths_to_append_rel` is
called again to rebuild the child's Append/MergeAppend paths with the new
target.  That call invokes `add_path` / `add_partial_path`, which, in
chaos mode, `pfree` paths they deem dominated.

The problem: the parent's Append/MergeAppend was modified in-place
*before* the recursion.  Its `subpaths` list still points to children's
old paths.  When the child-level `add_path` frees one of those old paths,
the parent is left holding a dangling pointer.

The following sequence of pictures shows the pointer state at each step
of Phase 2 execution.  Solid arrows (`───>`) are live pointers; `╳╳╳>`
marks a dangling pointer to freed memory; `░░░` marks a freed struct.

**Step 1.  Modify top-level J's pathlist in-place.**

```
  J.pathlist
  ┌──────────┐
  │  A_J     │  (AppendPath for top-level join)
  └──┬───┬───┘
     │   │
     │   └──────────────────────┐
     ▼                          ▼
  ┌──────────┐           ┌──────────┐
  │ HashJoin │           │  A_p2    │  (AppendPath for child p2)
  │  J_p1    │           └──┬───┬──┘
  └──────────┘              │   │
                            ▼   ▼
                    ┌────────┐ ┌────────┐
                    │ HJ     │ │ HJ     │
                    │ J_p2_p1│ │ J_p2_p2│  (grandchild join paths)
                    └────────┘ └────────┘
```

All pointers valid.  `apply_scanjoin_target_to_paths` has stamped
`sortgrouprefs` (or wrapped with ProjectionPath) on `A_J`, but has
not yet touched children.

**Step 2a.  Recurse into p2; modify p2's pathlist in-place.**

```
  J.pathlist                       p2.pathlist
  ┌──────────┐                     ┌──────────┐
  │  A_J     │───────────────────> │  A_p2    │  (same pointer)
  └──────────┘                     └──┬───┬──┘
                                      │   │
                                      ▼   ▼
                              ┌────────┐ ┌────────┐
                              │HJ      │ │HJ      │
                              │J_p2_p1 │ │J_p2_p2 │
                              └────────┘ └────────┘
```

A_p2 is in *both* J's subpaths and p2's own pathlist.

**Step 2b.  Recurse into grandchildren; rebuild their pathlists.**

`add_path` in grandchild J_p2_p1 may pfree old grandchild paths.
A_p2.subpaths still points to the old grandchild addresses — but
this particular sub-step is not what triggers the top-level crash.

**Step 2c.  `add_paths_to_append_rel` rebuilds p2 from grandchildren.**

A brand-new `A_p2'` is created from the rebuilt grandchildren and
passed to `add_path(p2, A_p2')`.  In chaos mode, the coin flip
can go either way:

```
  Coin flip: pfree(A_p2)             ← THIS IS THE KILL SHOT

  J.pathlist                       p2.pathlist
  ┌──────────┐                     ┌──────────┐
  │  A_J     │╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳╳> │░░░░░░░░░░│  A_p2 FREED
  └──────────┘                     └──────────┘
                                   ┌──────────┐
                                   │  A_p2'   │  (new, valid)
                                   └──┬───┬──┘
                                      ▼   ▼
                              ┌────────┐ ┌────────┐
                              │HJ'     │ │HJ'     │  (rebuilt)
                              │J_p2_p1 │ │J_p2_p2 │
                              └────────┘ └────────┘
```

p2's pathlist now has the fresh `A_p2'`.  But A_J still holds a
pointer to the freed `A_p2` chunk — a dangling reference.

**Step 3.  Back at J: `create_plan_recurse` follows the dangling pointer.**

```
  create_plan_recurse(A_J)
       │
       ├── A_J->subpaths[0] ───> HashJoin J_p1  ✓ (leaf, untouched)
       │
       └── A_J->subpaths[1] ╳╳╳> ░░░░░░░░░░░░  A_p2 (FREED)
                                     ▲
                                     │
                              SEGFAULT / garbage data
```

Multi-level partitioning is required because the vulnerability needs at
least three levels (top join → child partition that is itself partitioned →
grandchild partitions) so that step 2c's `add_path` can free a path the
grandparent still references.


## Why It Never Reproduces Without Chaos Mode: The `tlist_same_exprs` Safety Net

Without chaos mode, `add_path` uses strict cost-based dominance: a new
path replaces (and frees) an old one only when it is *strictly cheaper*.
Two accidental properties of the cost model conspire to ensure the old
path is never freed, regardless of the `tlist_same_exprs` flag.

### Case A: `tlist_same_exprs = true` (Cost-Identity Protection)

When the scan/join target has the same expressions as the existing
reltarget (only `sortgrouprefs` differ), the in-place modification at the
parent level merely stamps `sortgrouprefs` onto the existing
`PathTarget`.  No `ProjectionPath` wrapper is created.  Since no wrapper
exists, the old and new Append paths — both assembled from the identical
set of child paths via `create_append_path` — have *bit-for-bit identical
costs*.  (`create_append_path` sums each child's startup/total cost with
pure addition, so the same inputs yield the same IEEE 754 result
regardless of evaluation order.)

When costs are identical, `add_path` keeps the old path and rejects the
new one.  No `pfree` of the old path occurs.  The dangling pointer never
forms.

```
  Step 1: stamp sortgrouprefs        Step 2c: add_path(p2, A_p2')
  (metadata-only, no cost change)

  p2.pathlist                         add_path compares:
  ┌─────────────────┐
  │  A_p2           │                   A_p2  cost = 120.50
  │  cost = 120.50  │                   A_p2' cost = 120.50  (identical!)
  │  target.sgr=[1] │ ← only change                  │
  └─────────────────┘                                 ▼
                                        Tie → keep old A_p2, reject A_p2'
                                        pfree(A_p2')  ← new one freed
                                        A_p2 survives ✓
```

**The `sortgrouprefs` array** is a per-column metadata annotation that
marks which output expressions serve as `ORDER BY` / `GROUP BY` keys.  It
has no effect on cost computation — only on downstream sort planning.
Updating it in-place is a metadata-only operation.

### Case B: `tlist_same_exprs = false` (Wrapper Protection)

When the target contains new expressions (e.g., computed columns that
Append itself cannot project), the in-place modification wraps each path
in a `ProjectionPath`.  At the parent level, the old `AppendPath A_p2` is
now wrapped: `ProjectionPath → A_p2`.

Even if `add_path` decides to free the loser, `pfree` operates on the
*outermost* pointer it receives — the `ProjectionPath` struct.  `pfree`
frees exactly one `palloc` chunk: the struct pointer given to it.  It does
*not* recursively free substructures.  Since `AppendPath` and
`ProjectionPath` are separate `palloc` allocations, freeing the
`ProjectionPath` wrapper leaves `A_p2` itself (and all of its `subpaths`
pointers) alive.  The parent's reference to `A_p2` remains valid.

```
  Step 1: wrap with ProjectionPath

  p2.pathlist
  ┌───────────────────────────┐
  │  ProjectionPath (Proj_p2) │  ← separate palloc chunk
  │  ┌──────────────────────┐ │
  │  │ subpath ─────────────────> A_p2   ← separate palloc chunk
  │  └──────────────────────┘ │   │
  └───────────────────────────┘   ├──> HJ J_p2_p1
                                  └──> HJ J_p2_p2

  Step 2c: add_path(p2, Proj_p2')

  Coin flip → pfree the old one:

  pfree(Proj_p2)                    What pfree sees:
  ┌───────────────────────────┐
  │░░░░░░░░░░░░░░░░░░░░░░░░░░│     pfree frees ONE palloc chunk:
  │░░░░FREED░░░░░░░░░░░░░░░░░│     the ProjectionPath struct only.
  └───────────────────────────┘
                                    A_p2 is a different palloc chunk.
       A_p2  SURVIVES ✓             It is NOT freed.
       │
       ├──> HJ J_p2_p1  ✓          J's A_J still reaches A_p2
       └──> HJ J_p2_p2  ✓          through A_J.subpaths → safe.
```

### The Dichotomy Covers All Cases

| Condition | Protection mechanism | Why safe |
|---|---|---|
| `tlist_same_exprs = true` | Cost identity: old path always wins tie | No pfree of old path |
| `tlist_same_exprs = false` | Wrapper absorption: pfree hits wrapper | Inner AppendPath survives |

There is no third case.  The `tlist_same_exprs` boolean is exhaustive, so
the two protections accidentally cover each other's blind spots.  This is
why, despite the structural vulnerability existing since commit `11cf92f`
introduced `apply_scanjoin_target_to_paths`, no one has observed a crash
in normal operation.


## MergeAppend and the Nonlinear Cost Model

One might wonder whether `MergeAppend` — whose cost model is more complex
than plain `Append` — could break the cost-identity protection in Case A.

`cost_merge_append` (in `costsize.c`) computes:

```
startup_cost += comparison_cost × N × log₂(N)
run_cost     += tuples × comparison_cost × log₂(N)
run_cost     += cpu_tuple_cost × APPEND_CPU_COST_MULTIPLIER × tuples
total_cost    = startup_cost + run_cost + input_startup_cost + input_total_cost
```

The `input_startup_cost` and `input_total_cost` are sums of child sort
costs.  `cost_sort`, called per child, depends on `pathtarget->width`
through `relation_byte_size(tuples, width)`, which determines the
sort-memory threshold for disk vs. in-memory sort — a step function.

However, this width dependency can only cause cost divergence between old
and new paths when the target *changes* (i.e., `tlist_same_exprs = false`).
But in the `tlist_same_exprs = false` case, the wrapper protection is
already active.  In the `tlist_same_exprs = true` case, width is
unchanged (only `sortgrouprefs` metadata changes), so `cost_sort` produces
identical results and the cost-identity protection holds.

MergeAppend therefore cannot break the safety net: the one case where it
*could* diverge is already guarded by the wrapper mechanism.

```
                         Can width change?
                              │
              ┌───────────────┴───────────────┐
              │                               │
    tlist_same_exprs=true           tlist_same_exprs=false
    width unchanged                 width may change
              │                               │
              ▼                               ▼
    cost_sort identical             cost_sort may differ
    cost_merge_append identical     costs may diverge
              │                               │
              ▼                               ▼
    Cost-identity protection        BUT: ProjectionPath wrapper
    keeps old path ✓                absorbs the pfree ✓
```


## Commit `11cf92f` and "Append Is Not Projection-Capable"

The `apply_scanjoin_target_to_paths` machinery was introduced by commit
`11cf92f` with this rationale:

> Since Append is not projection-capable, that might save a separate
> Result node.

The key insight is that Append nodes in the executor pass through tuples
without modifying them.  If the query's target list includes computed
expressions, a `Result` node must sit *above* the Append to evaluate them.
By instead pushing the target list *down* into each child scan/join, each
child (which *is* projection-capable) can produce the needed columns
directly, eliminating the Result node overhead.

This design motivation is what forces the top-down recursion pattern: the
parent's target must be determined first, then pushed down into children.
The irony is that the "Append is not projection-capable" property means
`tlist_same_exprs` is forced to `false` whenever there are computed
expressions, which activates the `ProjectionPath` wrapper — and thus
accidentally activates the wrapper protection that prevents the crash.
The very design feature that creates the vulnerability also creates its
own safety net in the most dangerous case.


## The Structural Fix

Rather than relying on the accidental safety net, the fix drops
Append/MergeAppend paths from partitioned *join* rels before the recursion
into children.  The key code, added to both the `pathlist` and
`partial_pathlist` loops in `apply_scanjoin_target_to_paths`:

```c
if (rel_is_partitioned && !IS_SIMPLE_REL(rel) &&
    (IsA(subpath, AppendPath) || IsA(subpath, MergeAppendPath)))
{
    rel->pathlist = foreach_delete_current(rel->pathlist, lc);
    continue;
}
```

**Why this is safe.** The comment block at line 7992 already explains the
design intent: for partitioned simple rels, old Append/MergeAppend paths
are dropped entirely (`rel->pathlist = NIL`) because `add_paths_to_append_rel`
will rebuild equivalent paths from the updated children — and the rebuilt
paths are always at least as cheap.  The fix extends this logic to
partitioned *join* rels, but more surgically: instead of wiping the entire
pathlist (which would discard valuable non-Append join paths like
HashJoin, NestLoop, MergeJoin that operate on the whole partitioned
relation), it removes only the Append/MergeAppend entries.

```
  BEFORE FIX                              AFTER FIX
  (partitioned join rel)                  (partitioned join rel)

  J.pathlist:                             J.pathlist:
  ┌──────────┐ ┌──────────┐ ┌────────┐   ┌──────────┐ ┌────────┐
  │  A_J     │ │ HashJoin │ │MJ_J    │   │ HashJoin │ │MJ_J    │
  │(Append)  │ │(whole-   │ │(Merge  │   │(whole-   │ │(Merge  │
  │  │  │    │ │ rel join)│ │ Join)  │   │ rel join)│ │ Join)  │
  └──┼──┼────┘ └──────────┘ └────────┘   └──────────┘ └────────┘
     │  │         kept ✓       kept ✓        kept ✓      kept ✓
     │  └──> child paths                  A_J dropped ──── no dangling
     └─────> (DANGEROUS)                  pointers possible!

  Recurse into children...                Recurse into children...
  add_path pfrees child paths             add_path pfrees child paths
  A_J holds dangling pointers ✗           nothing references old paths ✓

                                          add_paths_to_append_rel rebuilds
                                          fresh A_J' from updated children ✓
```

This is correct because:

1. Non-Append paths carry no per-partition subpath pointers, so they are
   not affected by the child-level reconstruction.
2. `add_paths_to_append_rel` (called after the child recursion at line 8212)
   rebuilds Append/MergeAppend paths from the freshly updated children,
   producing equivalent or better paths.
3. The fix eliminates the dangling-pointer window entirely: there are no
   stale Append/MergeAppend paths at the parent level when the child
   recursion runs, so nothing can be left pointing to freed memory.

For partitioned simple rels, the existing `rel->pathlist = NIL` at line
8017-8018 remains unchanged — it's correct and sufficient because simple
rels have *only* Append/MergeAppend paths.


## Summary

The use-after-free is a structural consequence of `apply_scanjoin_target_to_paths`'s
top-down recursion order combined with multi-level partitioning.  It has
been latent since commit `11cf92f` but never manifested in practice because
the `tlist_same_exprs` dichotomy provides two complementary protection
mechanisms — cost-identity for `true`, wrapper absorption for `false` —
that together prevent `add_path` from ever freeing an old path that a
parent still references.  Chaos mode's random tie-breaking defeats the
cost-identity mechanism, exposing the vulnerability.  The fix removes
Append/MergeAppend paths from partitioned join rels before recursing,
eliminating the dangling-pointer formation entirely without affecting
plan quality.
