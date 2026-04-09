<img src="pics/banner-cut.jpg" alt="pg-chaos-test banner" width="100%" />

# pg-chaos-test

Chaos-mode regression testing for upstream PostgreSQL.

## What it does

Applies patches that randomize internal optimizer decisions and inject
timing noise into background worker lifecycle, then runs the full
`make check-world -k` test suite. The workflow **passes** only when both
conditions hold:

1. No `+ERROR` lines appear in any `*.diffs` regression output.
2. No core dumps, assertion failures (`TRAP:`), or crash signals
   (`SIGSEGV`, `SIGABRT`, etc.) are detected in any log file.

## Patches

Located in `patches/<branch>/`, applied in lexicographic order:

| Patch | Description |
|-------|-------------|
| `0001-...bgworker...` | Adds random 1–250 ms delays at background worker startup, normal exit, and error exit in `BackgroundWorkerMain()`. |
| `0002-...optimizer...` | Randomizes comparison inputs (`costcmp`, `keyscmp`, `outercmp`, rows) in `add_path` and `add_partial_path` via `pg_prng` while keeping the original dominance logic and `pfree` behavior intact. Replaces both precheck functions with unconditional `return true`. Interface-level fault injection: feed random values into the real decision machinery rather than randomizing each decision point. |

All chaos code is guarded by `#ifndef NO_CHAOS` — define `NO_CHAOS` to
restore original behavior.

## CI workflow

The GitHub Actions workflow (`.github/workflows/chaos-test.yml`) triggers on:

- **Every push** to `main`/`master`
- **Pull requests** against `main`/`master`
- **Manual dispatch** (with optional PostgreSQL ref override)
- **Weekly schedule** (Sunday 03:00 UTC)

### Workflow steps

1. Clone upstream `postgres/postgres` at the target ref (default: `master`)
2. Apply all patches from `patches/master/`
3. Configure with `--enable-tap-tests --enable-injection-points` and all optional libraries
4. Build with `-O3 -DWRITE_READ_PARSE_PLAN_TREES -DCOPY_PARSE_PLAN_TREES -DUSE_INJECTION_POINTS -DREALLOCATE_BITMAPSETS -DDISABLE_LEADER_PARTICIPATION`
5. Run `make check-world -k` with `PG_TEST_EXTRA` enabling all available test suites (continue past failures)
6. Run `check_diffs_errors.sh` — scan `*.diffs` for `+ERROR`
7. Run `check_crashes.sh` — scan for core files, `TRAP:`, segfault signals
8. Upload all diffs, logs, and core dumps as artifacts (retained 30 days)
9. **Fail** the run if either check finds issues

Steps 6–8 run even if the test suite is cancelled (e.g., by the 6-hour timeout),
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
git diff HEAD -- path/to/file.c > patches/master/0003-description.patch

# Or from commits:
git format-patch -1 <commit> -o patches/master/
```

Patches are applied in lexicographic order — use the `NNNN-` prefix convention.
