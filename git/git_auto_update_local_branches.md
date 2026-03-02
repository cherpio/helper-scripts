# Git Auto Update Local Branches

A bash script that automatically updates all your local Git branches by merging changes from the main branch. It includes special support for "stacked" branches (branches built on top of other feature branches).

## Features

- ✅ Automatically updates all local branches with latest changes from main
- ✅ Handles stacked branches with intelligent rebasing
- ✅ Excludes specified branch patterns and GitHub PR labels
- ✅ **Dry-run mode** to preview changes before applying
- ✅ **Push mode** to push changes to remote (opt-in)
- ✅ **Verbose mode** for detailed debugging output
- ✅ Comprehensive error handling and conflict detection
- ✅ Clean separation of merge vs rebase conflicts
- ✅ Automatic npm install when dependencies change

## Usage

### Basic Usage

```bash
# Update all branches locally (auto-detects default branch from GitHub)
./git_auto_update_local_branches.sh

# Override with a different main branch
./git_auto_update_local_branches.sh develop
```

**Note**: The script automatically detects the default branch using GitHub CLI (`gh`). If you don't have `gh` installed or authenticated, you must specify the branch name as an argument.

**Note**: By default the script does **not** push changes to remote. Use `--push` to enable pushing.

### Dry-Run Mode

Preview what would happen without making any changes. No local or remote changes will be made.

```bash
./git_auto_update_local_branches.sh --dry-run
```

### Push Mode

Update all branches and push changes to the remote repository.

```bash
./git_auto_update_local_branches.sh --push
```

### Verbose Mode

By default, the script silences the output of `git` and `gh` commands to keep the summary clean. Use `--verbose` to see the detailed output for debugging.

```bash
./git_auto_update_local_branches.sh --verbose
```

### Combining Flags

Flags can be combined freely and used alongside a branch name argument:

```bash
./git_auto_update_local_branches.sh --dry-run --verbose
./git_auto_update_local_branches.sh --push --verbose main
./git_auto_update_local_branches.sh develop --dry-run
```

## How It Works

### Phase 1: Regular Branches

The script processes all non-stacked branches first:

1. Auto-detects the default branch from GitHub (or uses the provided argument).
2. Fetches latest changes from remote.
3. Updates the default branch by resetting it to match the remote.
4. For each regular branch:
   - Checks out the branch.
   - Pulls latest changes for the branch.
   - Merges the default branch into the branch.
   - Pushes changes to the remote (only if `--push` is specified).

### Phase 2: Stacked Branches

Stacked branches reference a parent branch via a ticket number embedded in the branch name. Two naming conventions are supported:

**Legacy format:** `stacked/parent-ticket/branch-name`

Example: `stacked/br4565/BR-4596-my-feature`

**New suffix format:** `branch-name--stacked-<ticket>`

Example: `APY-1235-my-feature--stacked-apy1234`

The suffix format is preferred when CI extracts ticket numbers from branch names, as the branch itself starts with its own ticket number.

The script handles stacked branches intelligently:

1. **Sorts by dependencies**: Processes parent branches before their children.
2. **Checks parent status**:
   - If parent branch **exists**: Rebases the stacked branch onto the parent.
   - If parent **merged to main**: Merges `main` into the stacked branch.
   - If parent **not found**: Falls back to merging `main`.

### Stacked Branch Examples

```bash
# Parent branch
BR-1234-authentication

# Legacy stacked branch
stacked/br1234/BR-5678-user-profile

# New suffix-style stacked branch
BR-5678-user-profile--stacked-br1234
```

**Important**: The parent ticket reference is case-insensitive and ignores hyphens/underscores. In the suffix format it must be pre-normalized (lowercase, no hyphens) since `--` is used as the separator.

Valid matches:

- `BR-1234-feature` matches `stacked/br1234/...` or `...--stacked-br1234`
- `br_1234_feature` matches `stacked/BR1234/...` or `...--stacked-br1234`
- `Br1234Feature` matches `stacked/br-1234/...` or `...--stacked-br1234`

## Configuration

Edit the variables at the top of the script to configure defaults:

```bash
# Branch patterns to exclude from processing
EXCLUDED_BRANCHES=("backup/" "temp/" "archive/" "topic/")

# GitHub PR labels that exclude a branch from processing
EXCLUDED_GH_LABELS=("mergequeue")

# Regex patterns that identify a branch as stacked.
# Remove an entry to disable that pattern.
STACKED_BRANCH_PATTERNS=(
    "^stacked/"                   # Legacy: stacked/parent-ticket/branch-name
    "--stacked-[a-zA-Z0-9]+"     # New:    branch-name--stacked-<ticket>
)
```

### CLI Flags

| Flag | Description |
| --- | --- |
| `--dry-run` | Preview changes without modifying anything |
| `--push` | Push changes to remote after updating (default: off) |
| `--verbose` | Show full git/gh command output |

### Excluding Branches

Branches are excluded if they:

- Match any pattern in `EXCLUDED_BRANCHES`.
- Are the `main` branch itself.
- Have a GitHub PR with any label in `EXCLUDED_GH_LABELS` (requires `gh` CLI).

## Output Summary

After processing, the script displays:

1. **Ignored branches**: Excluded based on patterns or labels.
2. **Updated branches**: Successfully merged and pushed.
3. **Rebased stacked branches**: Successfully rebased (require manual force-push).
4. **Branches with merge conflicts**: Need manual conflict resolution.
5. **Branches with rebase conflicts**: Need manual conflict resolution.
6. **Branches that failed**: Other errors occurred.

### Rebased Branches

Rebased branches are **not automatically force-pushed** for safety. You must manually push them:

```bash
git push --force-with-lease origin branch-name
```

The script will show you the exact commands to run.

## Exit Codes

- `0`: Success (all branches processed without conflicts).
- `1`: One or more branches failed to process due to an error.
- `10`: One or more branches have merge or rebase conflicts that require manual resolution.

## Requirements

### Required

- **Git**: Version control system
- **Bash 3.2+**: Compatible with macOS default Bash version
- **GitHub CLI (`gh`)**: For auto-detecting the default branch from GitHub
- **jq**: For parsing GitHub CLI JSON output

### Optional

- **npm**: For automatic dependency updates if `package.json` changes are detected.

**Note**: Unlike previous versions, `gh` and `jq` are now required for default branch detection. If you don't have them installed, you must specify the branch name as an argument:

```bash
# Install GitHub CLI and jq (macOS)
brew install gh jq

# Or specify branch manually
./git_auto_update_local_branches.sh main
```

## Error Handling

The script includes comprehensive error handling:

- ✅ Detects uncommitted changes before processing.
- ✅ Aborts merges/rebases on conflict and cleans up.
- ✅ Validates stacked branch naming format.
- ✅ Handles missing remote branches.
- ✅ Returns to your original branch on completion.
- ✅ Verifies the working directory is clean after operations.

## Stacked Branch Workflow

### Creating a Stacked Branch

1. Create your parent feature branch normally:

   ```bash
   git checkout -b BR-1234-parent-feature
   ```

2. Create a stacked branch on top, referencing the parent's ticket number:

   ```bash
   # Legacy format
   git checkout -b stacked/br1234/BR-5678-child-feature

   # New suffix format (preferred when CI reads ticket from branch name)
   git checkout -b BR-5678-child-feature--stacked-br1234
   ```

### What Happens During Update

**Scenario 1**: Parent branch still exists.

```text
BR-5678-child-feature--stacked-br1234 rebased onto BR-1234-parent-feature
(Manual force-push required)
```

**Scenario 2**: Parent has been merged to main.

```text
BR-5678-child-feature--stacked-br1234 merged with main
(Push if --push flag was used)
```

**Scenario 3**: Parent was deleted/not found.

```text
BR-5678-child-feature--stacked-br1234 merged with main
(Push if --push flag was used)
```

## Common Issues

### Invalid Stacked Branch Format

**Error**: `Invalid stacked branch format: stacked/BR-1234-feature`

**Solution**: Stacked branches must have three parts: `stacked/parent-ticket/branch-name`.

```bash
# Wrong
stacked/BR-1234-feature

# Correct (legacy format)
stacked/br1234/BR-5678-feature

# Correct (suffix format)
BR-5678-feature--stacked-br1234
```

### Suffix Format: Ticket Must Be Normalized

In the suffix format (`--stacked-<ticket>`), the ticket must be **pre-normalized**: lowercase with no hyphens or underscores, because `--` is the separator.

```bash
# Wrong (hyphens in suffix are ambiguous)
BR-5678-feature--stacked-BR-1234

# Correct
BR-5678-feature--stacked-br1234
```

### Parent Branch Not Found

If the parent branch can't be found, the script will automatically fall back to merging from `main`. This is normal when the parent has been merged and deleted.

### Merge/Rebase Conflicts

The script detects and aborts conflicting operations. You'll need to:

1. Manually check out the branch.
2. Resolve the conflicts.
3. Run the script again (it will skip already-updated branches).

## Tips

- Run with **--dry-run** first to preview changes.
- Ensure your working directory is clean before running.
- Stacked branches are processed in dependency order automatically.
- The script is safe to re-run—it skips branches that are already up-to-date.
- Force-push rebased branches carefully after reviewing changes.

## Examples

### Update locally (no push)

```bash
./git_auto_update_local_branches.sh
```

### Update and push to remote

```bash
./git_auto_update_local_branches.sh --push
```

### Preview with dry-run

```bash
./git_auto_update_local_branches.sh --dry-run
```

### Debug with verbose output

```bash
./git_auto_update_local_branches.sh --verbose
```

### Update using 'develop' as main branch

```bash
./git_auto_update_local_branches.sh develop
```

### Dry-run with verbose output

```bash
./git_auto_update_local_branches.sh --dry-run --verbose
```

### Push with verbose output on a specific branch

```bash
./git_auto_update_local_branches.sh --push --verbose main
```

### Exclude additional patterns

Edit the script to add more exclusions:

```bash
EXCLUDED_BRANCHES=("backup/" "temp/" "archive/" "experimental/")
```

### After running the script

```bash
# Force-push a rebased stacked branch
git push --force-with-lease origin BR-5678-feature--stacked-br1234

# Resolve conflicts manually for failed branches
git checkout BR-1234-feature
git merge main
# ... resolve conflicts ...
git push
```
