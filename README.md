<img src="pics/banner-cut.jpg" alt="pg-chaos-test banner" width="100%" />

# pg-chaos-test

Chaos-mode regression testing for upstream PostgreSQL.

## What it does

Applies patches that randomize internal optimizer decisions, inject
timing noise into background worker lifecycle, and upgrade
"unrecognized node type" errors to panics, then runs `make check`
(short) and `make check-world -k` (long). Each workflow **passes**
only when both conditions hold:

1. No `+ERROR` lines appear in any `*.diffs` regression output.
2. No core dumps, assertion failures (`TRAP:`), or crash signals
   (`SIGSEGV`, `SIGABRT`, etc.) are detected in any log file.

## Patches

Located in `patches/<branch>/`, applied in lexicographic order:

| Patch | Description |
|-------|-------------|
| `0001-...bgworker...` | Adds random 1–50 ms delays at background worker startup and normal exit in `BackgroundWorkerMain()`. Also defines `CHAOS_MODE` in `pg_prng.h` to enable all chaos code globally. |
| `0002-...optimizer...` | Randomizes the three core cost comparison functions (`compare_path_costs`, `compare_fractional_path_costs`, `compare_path_costs_fuzzily`) after the `disabled_nodes` check. Provides alternative `add_path` and `add_partial_path` implementations that randomize dominance inputs (`keyscmp`, rows, insertion order) while delegating cost comparison to the already-randomized `compare_path_costs_fuzzily` and keeping `outercmp` (parameterization) truthful. Randomizes two additional direct cost comparisons: the partial-vs-parallel-safe path choice in `add_paths_to_append_rel` (`allpaths.c`) and the seqscan+sort-vs-indexscan decision in `plan_cluster_use_sort` (`planner.c`). |
| `0003-...unrecognized...` | Upgrades `elog(ERROR, "unrecognized node type: %d", ...)` to `elog(PANIC, ...)` across executor, parser, planner, and node-handling code. Converts recoverable errors into crashes (core dumps) so that plan corruption caused by chaos randomization is reliably caught by the crash-detection scripts. |

All chaos code is guarded by `#ifdef CHAOS_MODE`, which is defined in
`pg_prng.h` by patch 0001. Remove or undefine `CHAOS_MODE` to restore
original behavior.

## CI workflows

There are two GitHub Actions workflows, both triggered on push, PR,
manual dispatch, and weekly schedule (Sunday 03:00 UTC):

| Workflow | File | Test target | Timeout |
|----------|------|-------------|---------|
| **Short** | `chaos-check.yml` | `make check` | 60 min |
| **Long**  | `chaos-test.yml`  | `make check-world -k` | 360 min |

### Common steps

1. Clone upstream `postgres/postgres` at the target ref (default: `master`)
2. Apply all patches from `patches/master/`
3. Configure with `--enable-tap-tests --enable-cassert --enable-debug --enable-injection-points` and all optional libraries
4. Build with `-O0 -DWRITE_READ_PARSE_PLAN_TREES -DCOPY_PARSE_PLAN_TREES -DUSE_INJECTION_POINTS -DREALLOCATE_BITMAPSETS -DDISABLE_LEADER_PARTICIPATION`
5. Run the test target (`make check` or `make check-world -k`)
6. Run `check_diffs_errors.sh` — scan `*.diffs` for `+ERROR`
7. Run `check_crashes.sh` — scan for core files, `TRAP:`, segfault signals
8. Upload all diffs, logs, and core dumps as artifacts (retained 30 days)
9. **Fail** the run if either check finds issues

Steps 6–8 run even if the test suite is cancelled (e.g., by the timeout),
so partial results are always collected.

## Scripts

- `check_diffs_errors.sh [dir]` — Recursively find `*.diffs` containing `+ERROR`
- `check_crashes.sh [dir]` — Detect core files, assertion failures, and crash signals

## Multi-version support

The `patches/` directory is organized by branch name. Currently only
`master` has patches. Future versions for `REL_18_STABLE` through
`REL_14_STABLE` can be added by placing adapted `.patch` files in the
corresponding directory.

## Adding new patches

```bash
# From a working tree with chaos changes:
git diff HEAD -- path/to/file.c > patches/master/0004-description.patch

# Or from commits:
git format-patch -1 <commit> -o patches/master/
```

Patches are applied in lexicographic order — use the `NNNN-` prefix convention.
