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
| `0001-...optimizer...` | Randomizes path selection in `add_path`, `add_path_precheck`, `add_partial_path`, and `add_partial_path_precheck` via `pg_prng`. Cost comparisons, pathkeys comparisons, and list insertion order are all randomized. |
| `0002-...bgworker...` | Adds random 1–250 ms delays at background worker startup, normal exit, and error exit in `BackgroundWorkerMain()`. |

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
3. Configure with `--enable-cassert --enable-debug --enable-tap-tests`
4. Build and run `make check-world -k` (continue past failures)
5. Run `check_diffs_errors.sh` — scan `*.diffs` for `+ERROR`
6. Run `check_crashes.sh` — scan for core files, `TRAP:`, segfault signals
7. Upload all diffs, logs, and core dumps as artifacts (retained 30 days)
8. **Fail** the run if either check finds issues

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
