# Pathlist Invariants for Extension Developers

When an extension adds custom paths to a relation's `pathlist` (for example,
a custom scan provider), it must respect a set of invariants that the core
optimizer relies on. Violating any of them can cause assertion failures,
wrong plans, or crashes in downstream code such as `set_cheapest()`,
`get_cheapest_parameterized_child_path()`, and `add_paths_to_append_rel()`.

The authoritative source is the `add_path()` comment in
`src/backend/optimizer/util/pathnode.c` and the "Parameterized Paths" and
"LATERAL subqueries" sections of `src/backend/optimizer/README`.
This document distils those into rules an extension author can check against.

## 1. Always use `add_path()` to insert paths

Never manipulate `rel->pathlist` directly. `add_path()` enforces the
dominance rules below and keeps the list sorted by `disabled_nodes` then
`total_cost` (cheapest first). Other planner code, notably
`add_path_precheck()`, depends on that ordering to prune candidates early.

## 2. The dominance rule: when one path may displace another

Path A **dominates** path B (and B can be removed) only when **all five**
of the following hold simultaneously:

| Dimension | Requirement for A to dominate B |
|---|---|
| Cost | A is no more expensive (startup *and* total), or costs are fuzzily equal |
| Pathkeys | A's sort order is at least as useful as B's |
| Parameterization | `PATH_REQ_OUTER(A)` ⊆ `PATH_REQ_OUTER(B)` |
| Row count | `A->rows` ≤ `B->rows` |
| Parallel safety | `A->parallel_safe` ≥ `B->parallel_safe` |

If *any* dimension favours B, both paths are kept.

### Dominance direction: more general evicts more specialized

The dominance rule has an inherent directionality.  For each structural
dimension, only the **more general** path (the one usable in more contexts)
can evict the **more specialized** one, never the reverse:

Parameterization describes what a path **demands** from its environment
(which relations must be on the outer side of a nestloop).  Pathkeys
describe what a path **provides** to its consumers (a guaranteed sort
order).  "More general" means demanding less or providing more — in either
case, the path is usable in a wider set of contexts.

> **Key insight.** "More specialized" means the exact opposite thing for the
> two dimensions.  For parameterization, more specialized = *larger*
> `required_outer` set (the path demands more from its environment).  For
> pathkeys, more specialized = *shorter* pathkeys list (the path provides
> less to its consumers).  In both cases, the more specialized path is the
> one that works in fewer contexts — and it is the one that can be evicted.

- **Parameterization:** a path with `required_outer = S₁` can dominate a
  path with `required_outer = S₂` only if `S₁ ⊆ S₂`.  The
  less-parameterized path demands less from its environment — it works in
  every join context where the more-parameterized one works, plus others
  where some of S₂'s relations are not yet available on the outer side.
  So keeping the less-parameterized path and discarding the
  more-parameterized one is safe — no reachable join order loses its
  candidate path.  The reverse removal would be unsafe: the
  more-parameterized path cannot serve join orders that don't provide all
  of its required outer relations.

- **Pathkeys:** a path with pathkeys K₁ can dominate a path with K₂ only
  if K₁ ⊇ K₂ (i.e., K₁ is an equal or longer prefix of the same
  ordering).  The better-sorted path provides more to its consumers — it
  satisfies every ORDER BY or merge-join requirement that the worse-sorted
  one satisfies, plus more.

The consequence: **paths with incompatible parameterizations
(`BMS_DIFFERENT`) can never dominate each other**.  Neither `S₁ ⊆ S₂` nor
`S₂ ⊆ S₁`, so the parameterization check fails in both directions and both
paths survive.  They serve fundamentally different join contexts and the
planner may need either one depending on which join order it explores at
higher levels.

Even when parameterizations *are* compatible, dominance is rare in practice.
A more-parameterized path applies extra join clauses, which typically gives
it a lower rowcount estimate and therefore lower cost.  So even though the
less-parameterized path wins on generality (S₁ ⊆ S₂), the
more-parameterized path wins on rows and cost — the dimensions push in
opposite directions, and neither path dominates the other.  As the
`add_path()` comment puts it: "a path of one parameterization can seldom
dominate a path of another."

This natural counterbalance does **not** exist for pathkeys.  A path sorted
by `(a, b, c)` is not inherently cheaper or more expensive than one sorted
by `(a, b)` — the cost depends on how the ordering was produced (e.g., a
matching index vs an explicit Sort node), not on the number of sort columns.
Consequently, dominance along the pathkeys axis is more common: if a
longer-sorted path happens to also be cheaper, it will legitimately evict a
shorter-sorted one.  The structural safety net is the same as for
parameterization — `compare_pathkeys` returns `PATHKEYS_DIFFERENT` for
unrelated orderings (e.g. `(a, b)` vs `(x, y)`), and in that case neither
path can dominate the other regardless of cost.

### Why incompatible parameterizations must coexist — an example

Two parameterizations are **compatible** when one is a subset of the other
(e.g. `{t1}` and `{t1, t4}`).  They are **incompatible** when neither is a
subset (`{t1, t4}` vs `{t1, t5}`  ⟹  `BMS_DIFFERENT`).

Consider a child partition with three paths:

    P1   required_outer = {t1}        cost = 100
    P2   required_outer = {t1, t4}    cost = 50
    P3   required_outer = {t1, t5}    cost = 60

P1 and P2 are compatible: `{t1} ⊆ {t1, t4}`.  In principle P1 could
dominate P2 if it also won on cost, rows, pathkeys, and parallel-safety.
(Here it does not, because P2 is cheaper — it applies extra join clauses
from t4, producing fewer rows.)

P2 and P3 are **incompatible**: `{t1, t4} ⊄ {t1, t5}` and vice versa.
P2 is useful when the chosen join order places t4 on the outer side of a
nestloop, P3 when t5 is on the outer side.  Because `bms_subset_compare`
returns `BMS_DIFFERENT`, the dominance rule's parameterization check fails
in both directions and both paths survive.

Now, if something incorrectly declares P2 a "subset" of P3, the dominance
logic can delete P3.  In this three-path example P1 still acts as a
fallback: `get_cheapest_path_for_pathkeys()` searches for paths whose outer
is a subset of the requested set, and P1 with outer = `{t1}` qualifies for
any request because `{t1} ⊆ {t1, t5}`.

The scenario that truly breaks is when **all paths are parameterized and
there is no less-parameterized fallback** — which is exactly what happens
with LATERAL subqueries.  In a lateral context every child path is
parameterized by at least the lateral reference (say, t1).  If the children
only have paths like:

    P2   required_outer = {t1, t4}    cost = 50
    P3   required_outer = {t1, t5}    cost = 60

and the bogus dominance check deletes P3, then when the planner asks for a
path satisfying `required_outer = {t1, t5}`, no path qualifies:
`{t1, t4} ⊄ {t1, t5}`, so P2 does not match.
`get_cheapest_path_for_pathkeys()` returns NULL, and the
`Assert(cheapest != NULL)` in `get_cheapest_parameterized_child_path()`
fires.

The general rule: **never fake the `bms_subset_compare` result for
`required_outer`**.  Unlike cost and row estimates, parameterization
compatibility is a structural property — it determines which join orders
are *reachable*, not merely which are *cheap*.

## 3. Parameterization constraints

### 3a. Same parameterization ⟹ same rowcount

All paths for a given relation that share the same `required_outer` set
**must produce the same rowcount estimate**. This is enforced by requiring
every such path to apply *all* available join clauses from those outer
relations (some as index conditions, the rest as filters). The pre-filter
mechanism in `add_path_precheck()` relies on this.

### 3b. Parameterized paths are treated as having no pathkeys

`add_path()` compares parameterized paths as if their `pathkeys` are NIL.
This means a parameterized path cannot win purely because of its sort order.
The rationale: parameterized paths end up on the inner side of a nestloop,
where the sort order is discarded anyway.

### 3c. LATERAL relations may have no unparameterized paths

When a relation contains LATERAL references, *all* of its paths will be
parameterized by at least the set of laterally-referenced relations. Code
that walks the pathlist must not assume an unparameterized path exists.

## 4. What `set_cheapest()` expects

After path generation is complete, `set_cheapest()` scans `rel->pathlist`
and populates:

- `cheapest_startup_path` — cheapest unparameterized path by startup cost
- `cheapest_total_path` — cheapest unparameterized path by total cost
  (falls back to the least-parameterized path if no unparameterized path
  exists)
- `cheapest_parameterized_paths` — one representative per distinct
  parameterization, plus the cheapest unparameterized path

The pathlist must be non-empty; an empty list triggers:
```
ERROR: could not devise a query plan for the given query
```

## 5. What downstream consumers assume

`get_cheapest_parameterized_child_path()` (used by
`add_paths_to_append_rel()` for partitioned tables) searches a child's
pathlist for a path whose `required_outer` is a subset of a target
parameterization. It asserts that at least one such path exists. If a
previous incorrect path removal deleted that path, this assertion fails.

## 6. Checklist for extension authors

When your extension creates a custom `Path` and calls `add_path()`:

1. Set `PATH_REQ_OUTER` (via `param_info`) accurately. It must reflect
   exactly which outer relations supply parameters to this path.

2. If parameterized, apply all available join clauses from those outer
   relations — some as access-method conditions, the rest as filters —
   so that the rowcount matches other paths of the same parameterization.

3. Set `rows` to the same estimate that other paths of the same
   parameterization use (call `get_parameterized_baserel_size()` or
   `get_parameterized_joinrel_size()` as appropriate).

4. Set `pathkeys` to reflect the actual output order. But note that if the
   path is parameterized, `add_path()` will ignore those pathkeys during
   dominance comparison.

5. Set `parallel_safe` correctly. An incorrect `true` can cause a
   parallel-unsafe path to be chosen inside a parallel worker, leading to
   crashes. An incorrect `false` merely costs optimality.

6. Do not remove paths from `rel->pathlist` yourself. Let `add_path()`
   handle dominance pruning. Manual removal risks breaking the invariant
   that all needed parameterizations are represented.

7. Call `add_path()` *before* `set_cheapest()` runs. After `set_cheapest()`,
   the pathlist is considered frozen for the purposes of that planning level.

## 7. Planning implications of the dominance rules

The interplay between cost comparison and the specialization rules described
above has observable consequences for query plans.  Understanding these
helps extension authors predict which of their custom paths will survive
and which will be pruned.

### Parameterized paths accumulate; sorted paths do not

Because a more-parameterized path applies extra join clauses, it typically
produces fewer rows and therefore lower cost.  This means it wins on cost
while losing on generality — the two dimensions push in opposite
directions, preventing dominance.  The practical result is that the pathlist
**grows roughly in proportion to the number of distinct parameterizations**.
Each new parameterization almost always finds its place.

Pathkeys have no such built-in counterbalance.  A longer-sorted path can be
both more general (provides a longer useful prefix) *and* cheaper (if the
ordering came for free from a matching index).  So it can legitimately evict
a shorter-sorted path, and the pathlist stays **compact along the sort-order
dimension**.  In practice this means the planner gravitates toward "the best
sort order that came for free from an index" rather than accumulating many
alternative orderings.

### Parameterized paths lose their sort order in dominance comparison

`add_path()` treats parameterized paths as having NIL pathkeys (see §3b).
They compete only on cost and rows.  A parameterized index scan that
produces a useful `(a, b, c)` ordering gets **zero credit** for it during
dominance comparison.

The consequence is a systematic bias: if an unsorted parameterized path is
marginally cheaper than a sorted one with the same `required_outer`, the
sorted one is evicted.  An upstream merge join that could have exploited
that ordering will never see it.  In practice, this means nestloop + hash
join combinations dominate below other nestloops, even in cases where
nestloop + merge join would have been better.  The `optimizer/README`
acknowledges this as a deliberate tradeoff — planning time savings justify
the bias.

### Partitioned tables multiply the effect

`add_paths_to_append_rel()` iterates over the union of all
parameterizations seen across **any** child partition.  Each child must
supply a path for every parameterization in that union.  If there are N
partitions and M distinct parameterizations, this produces N × M lookups in
`get_cheapest_parameterized_child_path()`.

Because the cost counterbalance prevents parameterization pruning, M can be
large.  LATERAL references make it worse: every child path is parameterized
(no unparameterized fallback exists), and the number of distinct
parameterizations multiplies with the number of outer relations that can
feed the lateral reference.  This is the scenario where violating the
parameterization invariant is most likely to surface as a crash — there is
no less-parameterized path to act as a fallback when the needed one has been
incorrectly evicted.
