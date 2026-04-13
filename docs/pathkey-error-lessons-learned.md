# Lessons Learned: Discovery and Resolution of the "could not find pathkey item to sort" Error

**pg-chaos-test Project | GitHub Issue #9 | April 2026**

---

## 1. Executive Summary

During chaos-mode regression testing of PostgreSQL, the pg-chaos-test framework uncovered a flaky internal error in the query planner: "could not find pathkey item to sort" in `prepare_sort_from_pathkeys` (`createplan.c`). The error is unreachable in vanilla PostgreSQL but reveals a hidden architectural coupling between two planner subsystems — pathkey truncation and target-list construction — that is undocumented and fragile.

This report documents the root cause, the investigation process, the fix, and the broader lessons about PostgreSQL planner internals that emerged from a deep dive into the code.

## 2. Background

### 2.1 pg-chaos-test

The pg-chaos-test project applies patches that randomize internal optimizer decisions in PostgreSQL and then runs the standard regression suite. The goal is to surface latent bugs that are hidden by the deterministic plan choices the normal planner makes. The key chaos patches randomize cost comparisons in `add_path`, path-dominance checks, and the `truncate_useless_pathkeys` function.

### 2.2 Pathkeys and Target Lists

In PostgreSQL's planner, pathkeys represent sort orderings that a plan node promises to deliver. Each pathkey points to an EquivalenceClass (EC), and each EC has members — expressions like `t1.a` or `t2.x` that are known to be equal due to join conditions. The function `prepare_sort_from_pathkeys` translates pathkeys into concrete Sort columns by finding an EC member whose Vars are present in the plan node's target list (tlist).

The function `truncate_useless_pathkeys` removes pathkeys that no downstream operation needs: it checks ORDER BY, GROUP BY, DISTINCT, window functions, set operations, and pending merge joins. Crucially, the tlist is built to carry only the Vars needed by the query output and the surviving pathkeys. This creates a tight, undocumented coupling: truncation controls which pathkeys survive, and surviving pathkeys control which Vars appear in the tlist.

## 3. The Error

### 3.1 Symptoms

The error manifested as a flaky regression test failure under chaos mode. The `pg_regress` output showed:

    ERROR:  could not find pathkey item to sort

The error appeared in `prepare_sort_from_pathkeys` (`createplan.c`, line ~6259) when `find_computable_ec_member` returned NULL. It occurred only under chaos mode because patch 0006 bypasses `truncate_useless_pathkeys`, returning the full pathkey list unchanged. This preserves pathkeys that the normal planner would discard.

### 3.2 Why the Error Is Flaky

The error depends on two conditions aligning simultaneously. First, the chaos cost randomization must select a plan shape where a Gather Merge or Sort node iterates the full pathkey list. Second, the surviving pathkeys must reference Vars from join conditions that are absent from the SELECT clause — for example, a join column like `t1.a` in `SELECT t1.b, t2.y FROM t1 JOIN t2 ON t1.a = t2.x`. When the planner discards the pathkey for `t1.a` (as it normally does), the tlist doesn't need to carry `t1.a`. When chaos mode preserves that pathkey, the tlist still lacks `t1.a`, and `prepare_sort_from_pathkeys` cannot find a computable EC member.

## 4. Root Cause Analysis

### 4.1 The Invariant

The root cause is an undocumented architectural invariant: if a pathkey survives truncation, its EC must contain at least one member whose constituent Vars are all present in the tlist. Breaking one side of this coupling — keeping more pathkeys without enriching the tlist — triggers the error.

### 4.2 Misdiagnosis: Equivalence Member Relids

An early hypothesis attributed the error to EC members with child relids (`em_relids` not a subset of the plan's relids). Core dump analysis of a failing session disproved this: both candidate EC members had relids that passed the `bms_is_subset` check. The real issue was that the Vars in the EC member's expression were absent from the tlist, not that the relids were wrong. This misdiagnosis led to an incorrect `bms_is_subset` filter in an earlier version of patch 0006 that was subsequently reverted.

### 4.3 The Code Path

The exact failure path is:

- **`prepare_sort_from_pathkeys`** iterates each pathkey in the plan's pathkey list.
- **`find_computable_ec_member`** (`equivclass.c`, line 991) extracts Vars from each EC member's expression via `pull_var_clause`, then checks each Var against the tlist using `list_member`. If any Var is missing, the member is skipped.
- If no EC member is computable, the function hits `elog(ERROR, "could not find pathkey item to sort")`.
- Only **`create_gather_merge_plan`** iterates the path's full pathkey list. Other callers (`create_sort_plan`, `create_mergejoin_plan`) use purpose-built sort-requirement lists that are always consistent with the tlist.

## 5. The Fix

### 5.1 Approach: Resjunk Target Entries

The fix (patch 0007) adds missing Vars as resjunk TargetEntries directly in `prepare_sort_from_pathkeys`. When `find_computable_ec_member` returns NULL under `CHAOS_MODE`, the patch finds a satisfiable EC member, extracts its Vars, checks each against the tlist, and appends any missing Vars as resjunk entries (`resjunk = true`). It then retries `find_computable_ec_member`. This is the standard PostgreSQL mechanism for carrying non-output sort keys through plan nodes — the same technique the planner uses for ORDER BY expressions not in SELECT.

### 5.2 Why Fix in prepare_sort_from_pathkeys

An earlier approach attempted to fix this in `create_gather_merge_plan`, but that would only protect one caller. By fixing it in `prepare_sort_from_pathkeys`, the safety net covers all callers: `create_gather_merge_plan`, `create_sort_plan`, `create_mergejoin_plan`, and any future callers. This makes the plan creation code robust against unexpected pathkeys regardless of how they arise.

### 5.3 Patch Summary

| Patch | File | Effect |
|-------|------|--------|
| 0006 | `pathkeys.c` | Bypass `truncate_useless_pathkeys`: return full pathkey list |
| 0007 | `createplan.c` | Add resjunk tlist entries for missing pathkey Vars in `prepare_sort_from_pathkeys` |
| 0008 | `indxpath.c` | Skip backward index scan generation (demonstrates `right_merge_direction` impact) |

## 6. Deeper Findings: Pathkey Truncation Analysis

### 6.1 truncate_useless_pathkeys Is Well-Designed

A thorough code-level analysis of `truncate_useless_pathkeys` revealed that it is remarkably well-designed and rarely produces suboptimal plans. The function checks six categories of pathkey consumers, all using a leading-prefix pattern: ORDER BY and window/setop pathkeys (ordered prefix match), GROUP BY and DISTINCT pathkeys (unordered prefix match), and merge-join usefulness. It has full visibility into the final query requirements via root's `sort_pathkeys`, `group_pathkeys`, `window_pathkeys`, `distinct_pathkeys`, and `setop_pathkeys`.

### 6.2 The Prefix Invariant

All six checks in `truncate_useless_pathkeys` return a count, and the function keeps the max-count prefix of pathkeys. This prefix-based design matches how consumers work: merge join (`find_mergeclauses_for_outer_pathkeys`), ORDER BY, and GroupAggregate all require leading-prefix matches. A pathkey at position N is only useful if positions 0 through N−1 are also useful for the same operation.

### 6.3 The right_merge_direction Heuristic

The `pathkeys_useful_for_merging` function includes a direction check: `right_merge_direction` prefers ASC by default (or matches ORDER BY direction). A backward index scan of a DESC index produces ASC pathkeys, and vice versa. This means the heuristic is lossless — btree's bidirectional scanning always provides the preferred direction. Patch 0008 demonstrates this by suppressing backward scan, making the heuristic lossy and forcing unnecessary Sort nodes when only DESC indexes exist.

### 6.4 The Real Bottom-Up Limitation

The genuine weakness of PostgreSQL's bottom-up planning is not in pathkey truncation but in cost-based path selection within `add_path`. A merge join that preserves useful sort order might lose to a hash join in local cost comparison, even when the merge join's sort order would save a sort at a higher level. A top-down planner (Cascades/Volcano style, used by SQL Server and CockroachDB) propagates required physical properties downward, making the merge join's benefit explicit. PostgreSQL's `total_cost` does account for this to some degree, but the local pruning in `add_path` can still discard valuable sorted paths.

## 7. Simple Reproducer

The error can be triggered with a minimal two-table join where the join column is not in SELECT:

```sql
CREATE TABLE t1 (a int, b int);
CREATE TABLE t2 (x int, y int);
SELECT t1.b, t2.y FROM t1 JOIN t2 ON t1.a = t2.x;
```

Here, `t1.a` is required by the join condition and appears in an EC, but is absent from the SELECT list. Normally, `truncate_useless_pathkeys` discards the pathkey for `t1.a` (no ORDER BY, no GROUP BY, no pending merge needs it after the join), so the tlist never carries `t1.a`. When chaos mode preserves the pathkey, `prepare_sort_from_pathkeys` looks for `t1.a` in the tlist and fails.

## 8. Lessons Learned

### 8.1 Chaos Testing Reveals Hidden Contracts

The pathkey-tlist coupling is an architectural invariant that exists only in the planner's implicit design — no comment or README documents it. The deterministic plan choices in vanilla PostgreSQL never violate it, so it remained hidden for decades. Chaos testing, by randomizing optimizer decisions, explores plan-space corners that deterministic planning never reaches, surfacing assumptions that are valid but undefended.

### 8.2 Core Dump Analysis Beats Hypothesis

The initial hypothesis (EC member relids mismatch) was plausible but wrong. Only analyzing a core dump from a failing session — inspecting the actual relids, EC members, and tlist contents — revealed the true root cause. The lesson: when debugging planner internals, examine the actual data structures rather than reasoning from code alone.

### 8.3 Fix at the Narrowest Bottleneck

The fix was placed in `prepare_sort_from_pathkeys` rather than in individual callers like `create_gather_merge_plan`. This single-point fix covers all current and future callers. The resjunk TargetEntry mechanism is well-established in PostgreSQL — the same technique is used for ORDER BY expressions not in SELECT — so the fix follows existing conventions rather than inventing new ones.

### 8.4 Truncation Is Conservative, Not Broken

Despite the error being triggered by bypassing truncation, the analysis showed that `truncate_useless_pathkeys` is not itself buggy. It correctly identifies pathkeys that no downstream operation needs. The value of the chaos-mode bypass is not in finding better plans but in stress-testing the plan creation machinery, verifying that code downstream of truncation handles unexpected inputs gracefully.

### 8.5 Document Architectural Invariants

The investigation produced a proposed comment for `build_join_pathkeys` explaining the tlist-pathkey coupling. This kind of documentation prevents future contributors from accidentally violating the invariant. Every cross-module coupling in the planner deserves an explicit comment at both ends.

## 9. Recommendations

- **Upstream consideration:** The resjunk TargetEntry approach in patch 0007 could be proposed as a defensive hardening measure for upstream PostgreSQL, guarded by an Assert rather than `CHAOS_MODE`, to catch future violations of the tlist-pathkey invariant.
- **Expand chaos surface:** Patch 0008 (backward scan suppression) demonstrates a new class of chaos perturbation: removing planner escape hatches rather than randomizing costs. Other candidates include suppressing Incremental Sort, disabling parameterized paths, or randomizing join order.
- **Invariant documentation:** Add comments to `truncate_useless_pathkeys`, `build_join_pathkeys`, and `prepare_sort_from_pathkeys` explicitly documenting the tlist-pathkey contract.
- **Regression test:** The simple reproducer (Section 7) should be added as a chaos-mode-specific regression test that verifies no ERROR is raised for join-column-not-in-SELECT queries.

## 10. References

- GitHub Issue: danolivo/pg-chaos-test#9
- PostgreSQL source: `src/backend/optimizer/plan/createplan.c` (`prepare_sort_from_pathkeys`, line ~6150)
- PostgreSQL source: `src/backend/optimizer/path/pathkeys.c` (`truncate_useless_pathkeys`, line ~2199)
- PostgreSQL source: `src/backend/optimizer/path/equivclass.c` (`find_computable_ec_member`, line ~991)
- PostgreSQL source: `src/backend/optimizer/path/indxpath.c` (`build_index_paths`, backward scan at line ~1013)
- Graefe, G. (1995). The Cascades Framework for Query Optimization. IEEE Data Engineering Bulletin, 18(3).
