#!/usr/bin/env bash

# ====================================
# CONFIGURATION
# ====================================

# Get script directory for calling other scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect the default branch from the repository using GitHub CLI
detect_default_branch() {
    # Check if required tools are available
    if ! command -v gh >/dev/null 2>&1; then
        print_error "GitHub CLI (gh) is not installed. Cannot determine default branch."
        print_error "Please install gh or specify the branch name as the first argument."
        exit 1
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        print_error "jq is not installed. Cannot determine default branch."
        print_error "Please install jq or specify the branch name as the first argument."
        exit 1
    fi
    
    # Get default branch from GitHub
    local default_branch
    default_branch=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>&1)
    
    if [ $? -ne 0 ] || [ -z "$default_branch" ]; then
        print_error "Failed to determine default branch from GitHub."
        print_error "Error: $default_branch"
        print_error "Please specify the branch name as the first argument."
        exit 1
    fi
    
    echo "$default_branch"
}

EXCLUDED_BRANCHES=("backup/" "temp/" "archive/" "topic/")  # Add patterns to exclude
EXCLUDED_GH_LABELS=("mergequeue")  # Add GitHub labels to exclude branches with these labels

# Regex patterns for detecting stacked branches.
# Each entry is a regex matched against the full branch name.
# Remove an entry to disable that pattern; both are active by default.
STACKED_BRANCH_PATTERNS=(
    "^stacked/"                     # E.g. stacked/apy1234/APY-1234-my-feature
    "--stacked-[a-zA-Z0-9]+"        # E.g. APY-1235-my-feature--stacked-apy1234
)

# Parse CLI flags and optional positional MAIN_BRANCH argument
DRY_RUN=false
PUSH=false
VERBOSE=false
MAIN_BRANCH=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --push)    PUSH=true ;;
        --verbose) VERBOSE=true ;;
        --*)       echo "Unknown option: $arg"; exit 1 ;;
        *)         MAIN_BRANCH="$arg" ;;
    esac
done

if [ -z "$MAIN_BRANCH" ]; then
    MAIN_BRANCH=$(detect_default_branch)
fi

# Git hooks to temporarily deactivate during operations
HOOKS_TO_DEACTIVATE=("post-checkout" "post-merge" "pre-commit")

# Arrays to track results
IGNORED_BRANCHES=()
SUCCESSFUL_BRANCHES=()
FAILED_BRANCHES=()
MERGE_CONFLICT_BRANCHES=()
REBASE_CONFLICT_BRANCHES=()
REBASED_BRANCHES=()
UPTODATE_WITH_PARENT_BRANCHES=()

# Cache for branch lookups (using newline-separated format: ticket|branch)
TICKET_TO_BRANCH_MAP=""

# Cache for tool availability
GH_AVAILABLE=false
NPM_AVAILABLE=false

# Track deactivated hooks for cleanup
DEACTIVATED_HOOKS=()

# ====================================
# UTILITY FUNCTIONS
# ====================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_dry_run() {
    echo -e "${MAGENTA}[DRY-RUN]${NC} $1"
}

# Verify working directory is clean
verify_clean_working_directory() {
    if [[ -n $(git status --porcelain) ]]; then
        return 1
    fi
    return 0
}

# Deactivate git hooks by renaming them
deactivate_git_hooks() {
    local git_hooks_dir=".git/hooks"
    
    if [ ! -d "$git_hooks_dir" ]; then
        print_warning "Git hooks directory not found at $git_hooks_dir"
        return 0
    fi
    
    print_status "Deactivating git hooks..."
    
    for hook in "${HOOKS_TO_DEACTIVATE[@]}"; do
        local hook_path="$git_hooks_dir/$hook"
        local disabled_path="$git_hooks_dir/$hook.disabled"
        
        if [ -f "$hook_path" ] && [ ! -f "$disabled_path" ]; then
            if [ "$DRY_RUN" = true ]; then
                print_dry_run "Would deactivate hook: $hook"
            else
                if mv "$hook_path" "$disabled_path"; then
                    DEACTIVATED_HOOKS+=("$hook")
                    print_status "Deactivated hook: $hook"
                else
                    print_warning "Failed to deactivate hook: $hook"
                fi
            fi
        fi
    done
}

# Reactivate git hooks by renaming them back
reactivate_git_hooks() {
    local git_hooks_dir=".git/hooks"
    
    if [ ${#DEACTIVATED_HOOKS[@]} -eq 0 ]; then
        return 0
    fi
    
    print_status "Reactivating git hooks..."
    
    for hook in "${DEACTIVATED_HOOKS[@]}"; do
        local hook_path="$git_hooks_dir/$hook"
        local disabled_path="$git_hooks_dir/$hook.disabled"
        
        if [ -f "$disabled_path" ]; then
            if [ "$DRY_RUN" = true ]; then
                print_dry_run "Would reactivate hook: $hook"
            else
                if mv "$disabled_path" "$hook_path"; then
                    print_status "Reactivated hook: $hook"
                else
                    print_error "Failed to reactivate hook: $hook"
                fi
            fi
        fi
    done
    
    DEACTIVATED_HOOKS=()
}

# Cleanup function to ensure hooks are reactivated on exit
cleanup_on_exit() {
    reactivate_git_hooks
}

# ====================================
# BRANCH IDENTIFICATION FUNCTIONS
# ====================================

# Build a map of ticket numbers to branch names for efficient lookup
build_ticket_branch_map() {
    local all_branches
    all_branches=$(git branch --format='%(refname:short)')
    
    TICKET_TO_BRANCH_MAP=""
    local count=0
    
    while IFS= read -r branch; do
        # Skip stacked branches for parent matching
        if is_stacked_branch "$branch"; then
            continue
        fi
        
        local ticket
        ticket=$(extract_ticket_from_branch "$branch")
        
        if [ -n "$ticket" ]; then
            # Check if ticket already exists in map
            local existing
            existing=$(echo "$TICKET_TO_BRANCH_MAP" | grep -m1 "^${ticket}|" | cut -d'|' -f2)
            
            if [ -z "$existing" ]; then
                # Add to map: ticket|branch
                if [ -z "$TICKET_TO_BRANCH_MAP" ]; then
                    TICKET_TO_BRANCH_MAP="${ticket}|${branch}"
                else
                    TICKET_TO_BRANCH_MAP="${TICKET_TO_BRANCH_MAP}"$'\n'"${ticket}|${branch}"
                fi
                count=$((count + 1))
            fi
        fi
    done <<< "$all_branches"
}

# Check if a branch is a stacked branch
# Matches any pattern defined in STACKED_BRANCH_PATTERNS
is_stacked_branch() {
    local branch="$1"
    for pattern in "${STACKED_BRANCH_PATTERNS[@]}"; do
        if [[ "$branch" =~ $pattern ]]; then
            return 0
        fi
    done
    return 1
}

# Extract the parent ticket number from a stacked branch name
# Pattern 1: stacked/br1234/BR-2345-my-feature -> br1234
# Pattern 2: APY-1235-my-feature--stacked-apy1234 -> apy1234
# Returns empty string if branch doesn't match any known pattern
extract_parent_ticket() {
    local branch="$1"
    if [[ "$branch" =~ ^stacked/([^/]+)/(.+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$branch" =~ --stacked-([a-zA-Z0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# Normalize a ticket identifier by removing special characters and converting to lowercase
# Example: BR-1234 -> br1234
normalize_ticket() {
    local ticket="$1"
    echo "$ticket" | tr -d '\-_' | tr '[:upper:]' '[:lower:]'
}

# Extract ticket number from a branch name (assumes ticket is at the start)
# Example: BR-1234-my-feature -> br1234
extract_ticket_from_branch() {
    local branch="$1"
    # Try to extract ticket pattern (letters followed by optional dash/underscore and numbers)
    if [[ "$branch" =~ ^([A-Za-z]+[-_]?[0-9]+) ]]; then
        normalize_ticket "${BASH_REMATCH[1]}"
    fi
}

# Find the parent branch for a stacked branch
# Returns the full branch name if found, empty string otherwise
# Uses the pre-built TICKET_TO_BRANCH_MAP for efficient lookup
find_parent_branch() {
    local stacked_branch="$1"
    local parent_ticket
    parent_ticket=$(extract_parent_ticket "$stacked_branch")
    
    if [ -z "$parent_ticket" ]; then
        return 1
    fi
    
    # Normalize the parent ticket
    local normalized_parent
    normalized_parent=$(normalize_ticket "$parent_ticket")
    
    # Look up in the map (format: ticket|branch)
    local found_branch
    found_branch=$(echo "$TICKET_TO_BRANCH_MAP" | grep -m1 "^${normalized_parent}|" | cut -d'|' -f2)
    
    if [ -n "$found_branch" ]; then
        # Verify the branch actually exists
        if git rev-parse --verify "$found_branch" >/dev/null 2>&1; then
            echo "$found_branch"
            return 0
        else
            return 1
        fi
    fi
    
    return 1
}

# Check if a branch has been merged into main
is_merged_to_main() {
    local branch="$1"
    # Get the merge base. If branch is merged, its tip will be an ancestor of main.
    local merge_base
    merge_base=$(git merge-base "$branch" "$MAIN_BRANCH")
    local branch_commit
    branch_commit=$(git rev-parse "$branch")

    [ "$merge_base" = "$branch_commit" ]
}

# Check if remote branch exists
remote_branch_exists() {
    local branch="$1"
    git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1
}

# ====================================
# BRANCH EXCLUSION FUNCTIONS
# ====================================

# Function to check if branch should be excluded
should_exclude_branch() {
    local branch="$1"
    
    # Skip the main branch
    if [ "$branch" = "$MAIN_BRANCH" ]; then
        return 0  # exclude
    fi
    
    # Check against excluded patterns
    for pattern in "${EXCLUDED_BRANCHES[@]}"; do
        if [[ "$branch" == *"$pattern"* ]]; then
            return 0  # exclude
        fi
    done
    
    # Check for excluded GitHub labels (only if GH is available)
    if [ "$GH_AVAILABLE" = true ]; then
        local pr_info
        if [ "$VERBOSE" = true ]; then
            pr_info=$(gh pr list --head "$branch" --json number,labels,reviewDecision --jq '.[0]')
        else
            pr_info=$(gh pr list --head "$branch" --json number,labels,reviewDecision --jq '.[0]' 2>/dev/null)
        fi
        
        if [ -n "$pr_info" ] && [ "$pr_info" != "null" ]; then
            local labels
            labels=$(echo "$pr_info" | jq -r '.labels[].name' 2>/dev/null)
            local has_mergequeue=false
            local has_blocked=false
            
            for label in $labels; do
                if [ "$label" = "blocked" ]; then
                    has_blocked=true
                fi
                for excluded_label in "${EXCLUDED_GH_LABELS[@]}"; do
                    if [ "$label" = "$excluded_label" ]; then
                        has_mergequeue=true
                    fi
                done
            done
            
            # Only exclude mergequeue PRs if they're approved and not blocked
            if [ "$has_mergequeue" = true ]; then
                local review_decision
                review_decision=$(echo "$pr_info" | jq -r '.reviewDecision' 2>/dev/null)
                
                if [ "$review_decision" = "APPROVED" ] && [ "$has_blocked" = false ]; then
                    return 0  # exclude (approved mergequeue without blocked tag)
                fi
                # If mergequeue but not approved or has blocked tag, don't exclude
                return 1
            fi
        fi
    fi
    
    return 1  # don't exclude
}

# ====================================
# TOPOLOGICAL SORT FOR STACKED BRANCHES
# ====================================

# Build dependency map for stacked branches
# Returns array of branches in correct processing order
topological_sort_stacked_branches() {
    # Read branches from arguments
    local branches=("$@")
    local sorted=()
    local visited=()
    local in_progress=()
    
    # Helper function for depth-first search
    visit_branch() {
        local branch="$1"
        
        # Check if already visited
        for v in "${visited[@]}"; do
            if [ "$v" = "$branch" ]; then
                return 0
            fi
        done
        
        # Check for circular dependency
        for ip in "${in_progress[@]}"; do
            if [ "$ip" = "$branch" ]; then
                print_warning "Circular dependency detected involving $branch"
                return 1
            fi
        done
        
        in_progress+=("$branch")
        
        # If this is a stacked branch, visit its parent first
        if is_stacked_branch "$branch"; then
            local parent
            parent=$(find_parent_branch "$branch" 2>/dev/null) || true
            
            if [ -n "$parent" ]; then
                # Check if parent is in our list of stacked branches
                for sb in "${branches[@]}"; do
                    if [ "$sb" = "$parent" ]; then
                        visit_branch "$parent"
                        break
                    fi
                done
            fi
        fi
        
        # Remove from in_progress
        local temp=()
        for ip in "${in_progress[@]}"; do
            if [ "$ip" != "$branch" ]; then
                temp+=("$ip")
            fi
        done
        in_progress=("${temp[@]}")
        
        # Add to visited and sorted
        visited+=("$branch")
        sorted+=("$branch")
    }
    
    # Visit all branches
    for branch in "${branches[@]}"; do
        visit_branch "$branch"
    done
    
    # Return sorted array
    echo "${sorted[@]}"
}

# ====================================
# BRANCH PROCESSING FUNCTIONS
# ====================================

# Merge main into a branch (helper function for both regular and stacked branches)
merge_main_into_branch() {
    local branch="$1"
    
    # Check for uncommitted changes before switching branches
    if ! verify_clean_working_directory; then
        print_error "Uncommitted changes detected. Skipping $branch. Please commit or stash changes first."
        FAILED_BRANCHES+=("$branch")
        return 1
    fi

    # Checkout the branch
    if [ "$VERBOSE" = true ]; then
        git checkout "$branch"
    else
        git checkout "$branch" >/dev/null 2>&1
    fi || {
        print_error "Failed to checkout $branch"
        FAILED_BRANCHES+=("$branch")
        return 1
    }

    # Verify we're on the correct branch
    actual_branch=$(git branch --show-current)
    if [ "$actual_branch" != "$branch" ]; then
        print_error "CRITICAL: Checked out wrong branch!"
        print_error "Expected: $branch"
        print_error "Actual:   $actual_branch"
        print_error "This is a serious error. Aborting."
        FAILED_BRANCHES+=("$branch")
        exit 1
    fi

    # Pull latest changes for this branch
    if remote_branch_exists "$branch"; then
        print_status "Pulling latest changes for $branch..."
        if [ "$DRY_RUN" = true ]; then
            print_dry_run "Would pull origin/$branch"
        else
            if [ "$VERBOSE" = true ]; then
                git pull origin "$branch"
            else
                git pull origin "$branch" >/dev/null 2>&1
            fi || {
                print_error "Failed to pull $branch. There may be conflicts or connectivity issues."
                FAILED_BRANCHES+=("$branch")
                return 1
            }
        fi
    else
        print_warning "Remote branch origin/$branch not found. Skipping pull."
    fi

    # Check if the branch is already up-to-date with MAIN_BRANCH
    if git merge-base --is-ancestor "$MAIN_BRANCH" "$branch" 2>/dev/null; then
        print_success "Branch $branch is already up-to-date with $MAIN_BRANCH"
        SUCCESSFUL_BRANCHES+=("$branch")
        return 0
    fi

    # Create backup before making any changes
    print_status "Creating backup of $branch..."
    if [ "$DRY_RUN" = true ]; then
        print_dry_run "Would create backup of $branch"
    else
        if [ -f "$SCRIPT_DIR/git_backup.sh" ]; then
            "$SCRIPT_DIR/git_backup.sh" >/dev/null 2>&1 || print_warning "Failed to create backup of $branch"
        else
            print_warning "git_backup.sh not found at $SCRIPT_DIR, skipping backup"
        fi
    fi

    # Attempt to merge main
    print_status "Merging $MAIN_BRANCH into $branch..."

    if [ "$DRY_RUN" = true ]; then
        print_dry_run "Would merge $MAIN_BRANCH into $branch"
        # Check if merge would conflict
        if git merge-tree "$(git merge-base "$MAIN_BRANCH" "$branch")" "$MAIN_BRANCH" "$branch" | grep -q "^changed in both"; then
            print_warning "Merge would have conflicts"
            MERGE_CONFLICT_BRANCHES+=("$branch")
            return 1
        else
            print_success "Merge would succeed for $branch"
            SUCCESSFUL_BRANCHES+=("$branch")
            return 0
        fi
    fi

    local merge_succeeded=false
    if [ "$VERBOSE" = true ]; then
        if git merge "$MAIN_BRANCH" --no-edit; then
            merge_succeeded=true
        fi
    else
        # The 2>&1 redirects stderr to stdout, so both are captured by >/dev/null
        if git merge "$MAIN_BRANCH" --no-edit >/dev/null 2>&1; then
            merge_succeeded=true
        fi
    fi

    if [ "$merge_succeeded" = true ]; then
        print_success "Merge successful for $branch"

        # Safety check: prevent pushing main branch
        if [ "$branch" = "$MAIN_BRANCH" ]; then
            print_error "CRITICAL: Attempted to push $MAIN_BRANCH branch!"
            print_error "This should never happen. The script has a logic error."
            FAILED_BRANCHES+=("$branch")
            return 1
        fi

        # Push the changes
        print_status "Pushing $branch..."
        if [ "$PUSH" = false ]; then
            print_warning "Skipping push (use --push to enable)"
            SUCCESSFUL_BRANCHES+=("$branch")
            return 0
        else
            if [ "$VERBOSE" = true ]; then
                git push origin "$branch"
            else
                git push origin "$branch" >/dev/null 2>&1
            fi || {
                print_error "Failed to push $branch"
                FAILED_BRANCHES+=("$branch")
                return 1
            }
            print_success "Successfully pushed $branch"
            SUCCESSFUL_BRANCHES+=("$branch")
            return 0
        fi
    else
        print_warning "Merge conflict detected in $branch"

        # Abort the merge
        git merge --abort >/dev/null 2>&1
        
        # Verify abort was successful
        if ! verify_clean_working_directory; then
            print_error "Working directory not clean after merge abort in $branch"
            FAILED_BRANCHES+=("$branch")
            return 1
        fi
        
        print_status "Merge aborted for $branch"
        MERGE_CONFLICT_BRANCHES+=("$branch")
        return 1
    fi
}

# Process a regular (non-stacked) branch by merging main into it
process_regular_branch() {
    local branch="$1"
    
    print_status "Processing regular branch: $branch"
    merge_main_into_branch "$branch"
}

# Process a stacked branch by rebasing on parent or merging main
process_stacked_branch() {
    local branch="$1"
    
    print_status "Processing stacked branch: $branch"
    
    # Validate branch name format
    local parent_ticket
    parent_ticket=$(extract_parent_ticket "$branch" 2>/dev/null) || true
    
    if [ -z "$parent_ticket" ]; then
        print_error "Invalid stacked branch format: $branch"
        print_error "Expected formats:"
        print_error "  stacked/parent-ticket/branch-name"
        print_error "  branch-name--stacked-<ticket> (e.g. APY-1235-my-feature--stacked-apy1234)"
        FAILED_BRANCHES+=("$branch")
        return 0  # Return 0 to not trigger set -e
    fi
    
    # Find the parent branch
    local parent_branch
    parent_branch=$(find_parent_branch "$branch" 2>/dev/null) || true
    
    if [ -z "$parent_branch" ]; then
        print_warning "Could not find parent branch for $branch (looking for ticket: $parent_ticket)"
        print_warning "Parent branch may have been merged or deleted. Will merge from $MAIN_BRANCH instead."
        merge_main_into_branch "$branch"
        return 0
    fi
    
    print_status "Parent branch for $branch: $parent_branch"
    
    # Check if parent branch was successfully updated (only if it's a local branch that was processed)
    local parent_in_branches=false
    for b in "${REGULAR_BRANCHES[@]}" "${STACKED_BRANCHES[@]}"; do
        if [ "$b" = "$parent_branch" ]; then
            parent_in_branches=true
            break
        fi
    done
    
    if [ "$parent_in_branches" = true ]; then
        # Parent was in our list to process, check if it succeeded
        local parent_has_conflicts=false
        local parent_failed=false
        
        for failed in "${FAILED_BRANCHES[@]}" "${MERGE_CONFLICT_BRANCHES[@]}" "${REBASE_CONFLICT_BRANCHES[@]}"; do
            if [ "$failed" = "$parent_branch" ]; then
                parent_has_conflicts=true
                break
            fi
        done
        
        if [ "$parent_has_conflicts" = true ]; then
            print_error "Parent branch $parent_branch has conflicts or failed to update"
            print_error "Cannot safely rebase $branch. Please resolve parent branch first."
            FAILED_BRANCHES+=("$branch")
            return 0
        fi
    fi
    
    # Check for uncommitted changes before switching branches
    if ! verify_clean_working_directory; then
        print_error "Uncommitted changes detected. Skipping $branch. Please commit or stash changes first."
        FAILED_BRANCHES+=("$branch")
        return 1
    fi

    # Checkout the stacked branch
    if [ "$VERBOSE" = true ]; then
        git checkout "$branch"
    else
        git checkout "$branch" >/dev/null 2>&1
    fi || {
        print_error "Failed to checkout $branch"
        FAILED_BRANCHES+=("$branch")
        return 1
    }

    # Verify we're on the correct branch
    actual_branch=$(git branch --show-current)
    if [ "$actual_branch" != "$branch" ]; then
        print_error "CRITICAL: Checked out wrong branch!"
        print_error "Expected: $branch"
        print_error "Actual:   $actual_branch"
        print_error "This is a serious error. Aborting."
        FAILED_BRANCHES+=("$branch")
        exit 1
    fi

    # Pull latest changes for this branch
    if remote_branch_exists "$branch"; then
        print_status "Pulling latest changes for $branch..."
        if [ "$DRY_RUN" = true ]; then
            print_dry_run "Would pull origin/$branch"
        else
            if [ "$VERBOSE" = true ]; then
                git pull origin "$branch"
            else
                git pull origin "$branch" >/dev/null 2>&1
            fi || {
                print_error "Failed to pull $branch. There may be conflicts or connectivity issues."
                FAILED_BRANCHES+=("$branch")
                return 1
            }
        fi
    else
        print_warning "Remote branch origin/$branch not found. Skipping pull."
    fi
    
    # Check if parent branch has been merged to main
    if is_merged_to_main "$parent_branch"; then
        print_status "Parent branch $parent_branch has been merged to $MAIN_BRANCH"
        print_status "Merging $MAIN_BRANCH into $branch instead of rebasing..."
        merge_main_into_branch "$branch"
        return 0
    fi
    
    # Check if the branch is already up-to-date with parent
    if git merge-base --is-ancestor "$parent_branch" "$branch" 2>/dev/null; then
        print_success "Branch $branch is already up-to-date with parent $parent_branch"
        UPTODATE_WITH_PARENT_BRANCHES+=("$branch")
        return 0
    fi
    
    # Create backup before rebasing
    print_status "Creating backup of $branch..."
    if [ "$DRY_RUN" = true ]; then
        print_dry_run "Would create backup of $branch"
    else
        if [ -f "$SCRIPT_DIR/git_backup.sh" ]; then
            "$SCRIPT_DIR/git_backup.sh" >/dev/null 2>&1 || print_warning "Failed to create backup of $branch"
        else
            print_warning "git_backup.sh not found at $SCRIPT_DIR, skipping backup"
        fi
    fi
    
    print_status "Rebasing $branch onto $parent_branch..."
    
    if [ "$DRY_RUN" = true ]; then
        print_dry_run "Would rebase $branch onto $parent_branch"
        print_warning "Branch would need manual force-push after rebase"
        REBASED_BRANCHES+=("$branch")
        return 0
    fi
    
    if git rebase "$parent_branch"; then
        print_success "Rebase successful for $branch"
        
        print_warning "Branch $branch has been rebased locally but NOT pushed."
        print_warning "To push: git push --force-with-lease origin $branch"
        REBASED_BRANCHES+=("$branch")
        return 0
    else
        print_warning "Rebase conflict detected in $branch"
        git rebase --abort >/dev/null 2>&1
        
        # Verify abort was successful
        if ! verify_clean_working_directory; then
            print_error "Working directory not clean after rebase abort in $branch"
            FAILED_BRANCHES+=("$branch")
            return 1
        fi
        
        print_status "Rebase aborted for $branch"
        REBASE_CONFLICT_BRANCHES+=("$branch")
        return 1
    fi
}

# ====================================
# INITIALIZATION AND CHECKS
# ====================================

# Set up trap to ensure hooks are reactivated on exit
trap cleanup_on_exit EXIT

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    print_error "Not in a git repository!"
    exit 1
fi

# Check for uncommitted changes before starting
if ! verify_clean_working_directory; then
    print_error "You have uncommitted changes in your working directory."
    print_error "Please commit or stash your changes before running this script."
    exit 1
fi

# Check and cache GitHub CLI availability
if command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    if [ "$VERBOSE" = true ]; then
        gh auth status
    else
        gh auth status >/dev/null 2>&1
    fi && GH_AVAILABLE=true && print_status "GitHub CLI is available and authenticated" || \
    print_warning "GitHub CLI (gh) is not authenticated. GitHub label checks will be skipped."
else
    if ! command -v gh >/dev/null 2>&1; then
        print_warning "GitHub CLI (gh) is not installed. GitHub label checks will be skipped."
    fi
    if ! command -v jq >/dev/null 2>&1; then
        print_warning "jq is not installed. GitHub label checks will be skipped."
    fi
fi

# Check npm availability
if command -v npm >/dev/null 2>&1; then
    NPM_AVAILABLE=true
else
    print_warning "npm is not installed. npm install will be skipped."
fi

# Store the current branch and directory
ORIGINAL_BRANCH=$(git branch --show-current)
ORIGINAL_DIR=$(pwd)

# Navigate to git root
GIT_ROOT=$(git rev-parse --show-toplevel)
if [ $? -ne 0 ]; then
    print_error "Not in a git repository"
    exit 1
fi

if [ "$ORIGINAL_DIR" != "$GIT_ROOT" ]; then
    print_status "Navigating to git root: $GIT_ROOT"
    cd "$GIT_ROOT" || {
        print_error "Failed to navigate to git root"
        exit 1
    }
fi

if [ "$DRY_RUN" = true ]; then
    print_dry_run "DRY-RUN MODE: No changes will be made"
fi

if [ "$PUSH" = false ]; then
    print_warning "Changes will be made locally but NOT pushed to remote. Use --push to enable pushing."
fi

print_status "Main branch: ${YELLOW}${MAIN_BRANCH}${NC}"
print_status "Currently on branch: $ORIGINAL_BRANCH"
print_status "Excluded patterns: ${EXCLUDED_BRANCHES[*]}"
print_status "Excluded GitHub labels: ${EXCLUDED_GH_LABELS[*]}"

# Deactivate git hooks before operations
deactivate_git_hooks

# Fetch latest changes
print_status "Fetching latest changes..."
if [ "$DRY_RUN" = true ]; then
    print_dry_run "Would fetch from origin"
else
    if [ "$VERBOSE" = true ]; then
        git fetch origin
    else
        git fetch origin >/dev/null 2>&1
    fi
fi

# Update main branch with safety checks
print_status "Updating $MAIN_BRANCH branch..."

# Checkout main branch
if [ "$DRY_RUN" = true ]; then
    print_dry_run "Would checkout and reset $MAIN_BRANCH"
else
    # Checkout main
    if [ "$VERBOSE" = true ]; then
        git checkout "$MAIN_BRANCH"
    else
        git checkout "$MAIN_BRANCH" >/dev/null 2>&1
    fi || {
        print_error "Failed to checkout $MAIN_BRANCH"
        exit 1
    }
    
    # Verify main branch is clean before updating
    if ! verify_clean_working_directory; then
        print_error "$MAIN_BRANCH branch has uncommitted changes!"
        print_error "This should never happen. Please investigate and clean up $MAIN_BRANCH manually."
        exit 1
    fi
    
    # Get the SHA of local main before update
    main_sha_before=$(git rev-parse HEAD)
    
    # Check if local main has commits not on remote
    commits_ahead=$(git rev-list origin/$MAIN_BRANCH..$MAIN_BRANCH --count 2>/dev/null || echo "0")
    
    if [ "$commits_ahead" != "0" ]; then
        print_error "$MAIN_BRANCH is $commits_ahead commits ahead of origin/$MAIN_BRANCH!"
        print_error "This indicates $MAIN_BRANCH has local commits that were never pushed."
        print_error "This script will NOT modify $MAIN_BRANCH to prevent data loss."
        print_error "Please investigate and fix $MAIN_BRANCH manually before running this script."
        print_error "You may need to reset $MAIN_BRANCH to origin/$MAIN_BRANCH if the local commits are invalid."
        exit 1
    fi
    
    # Reset main to match remote exactly (safer than pull/merge)
    print_status "Resetting $MAIN_BRANCH to origin/$MAIN_BRANCH..."
    if [ "$VERBOSE" = true ]; then
        git reset --hard "origin/$MAIN_BRANCH"
    else
        git reset --hard "origin/$MAIN_BRANCH" >/dev/null 2>&1
    fi || {
        print_error "Failed to reset $MAIN_BRANCH to origin/$MAIN_BRANCH"
        exit 1
    }
    
    # Verify main was actually updated or already up to date
    main_sha_after=$(git rev-parse HEAD)
    
    if [ "$main_sha_before" != "$main_sha_after" ]; then
        print_success "$MAIN_BRANCH updated from $main_sha_before to $main_sha_after"
    else
        print_success "$MAIN_BRANCH already up-to-date"
    fi
    
    # Final safety check: verify main matches remote exactly
    main_remote_sha=$(git rev-parse "origin/$MAIN_BRANCH")
    main_local_sha=$(git rev-parse HEAD)
    
    if [ "$main_local_sha" != "$main_remote_sha" ]; then
        print_error "CRITICAL ERROR: $MAIN_BRANCH does not match origin/$MAIN_BRANCH after update!"
        print_error "Local:  $main_local_sha"
        print_error "Remote: $main_remote_sha"
        print_error "Aborting to prevent corruption."
        exit 1
    fi
fi

# Build ticket-to-branch map for efficient parent lookups
print_status "Building branch lookup cache..."
build_ticket_branch_map

# ====================================
# BRANCH COLLECTION AND CATEGORIZATION
# ====================================

# Get all local branches and categorize them
ALL_BRANCHES=$(git branch --format='%(refname:short)')
REGULAR_BRANCHES=()
STACKED_BRANCHES=()

while IFS= read -r branch; do
    if should_exclude_branch "$branch"; then
        IGNORED_BRANCHES+=("$branch")
        continue
    fi
    
    if is_stacked_branch "$branch"; then
        STACKED_BRANCHES+=("$branch")
    else
        REGULAR_BRANCHES+=("$branch")
    fi
done <<< "$ALL_BRANCHES"

if [ ${#REGULAR_BRANCHES[@]} -eq 0 ] && [ ${#STACKED_BRANCHES[@]} -eq 0 ]; then
    print_warning "No branches found to update (after applying exclusions)"
    if [ "$DRY_RUN" = false ]; then
        git checkout "$ORIGINAL_BRANCH"
    fi
    exit 0
fi

print_status "Found regular branches to update (${#REGULAR_BRANCHES[@]}):"
if [ ${#REGULAR_BRANCHES[@]} -gt 0 ]; then
    printf '%s\n' "${REGULAR_BRANCHES[@]}" | sed 's/^/  - /'
else
    echo "  (none)"
fi

print_status "Found stacked branches to update (${#STACKED_BRANCHES[@]}):"
if [ ${#STACKED_BRANCHES[@]} -gt 0 ]; then
    printf '%s\n' "${STACKED_BRANCHES[@]}" | sed 's/^/  - /'
else
    echo "  (none)"
fi

echo

# ====================================
# PHASE 1: PROCESS REGULAR BRANCHES
# ====================================

print_status "=== PHASE 1: Processing regular branches ==="
echo

for branch in "${REGULAR_BRANCHES[@]}"; do
    process_regular_branch "$branch"
    echo  # Empty line for readability
done

# ====================================
# PHASE 2: PROCESS STACKED BRANCHES
# ====================================

if [ ${#STACKED_BRANCHES[@]} -gt 0 ]; then
    print_status "=== PHASE 2: Processing stacked branches ==="
    echo
    
    # Sort stacked branches topologically
    print_status "Sorting stacked branches by dependencies..."
    SORTED_STACKED_BRANCHES=($(topological_sort_stacked_branches "${STACKED_BRANCHES[@]}"))
    
    print_status "Processing order:"
    printf '%s\n' "${SORTED_STACKED_BRANCHES[@]}" | sed 's/^/  - /'
    echo
    
    for branch in "${SORTED_STACKED_BRANCHES[@]}"; do
        process_stacked_branch "$branch"
        echo  # Empty line for readability
    done
fi

# ====================================
# CLEANUP AND SUMMARY
# ====================================

# Return to original branch
print_status "Returning to original branch: $ORIGINAL_BRANCH"
if [ "$DRY_RUN" = false ]; then
    if [ "$VERBOSE" = true ]; then
        git checkout "$ORIGINAL_BRANCH"
    else
        git checkout "$ORIGINAL_BRANCH" >/dev/null 2>&1
    fi || {
        print_error "Failed to checkout $ORIGINAL_BRANCH"
        exit 1
    }
    
    # Verify we're on the correct branch
    actual_branch=$(git branch --show-current)
    if [ "$actual_branch" != "$ORIGINAL_BRANCH" ]; then
        print_error "CRITICAL: Checked out wrong branch when returning!"
        print_error "Expected: $ORIGINAL_BRANCH"
        print_error "Actual:   $actual_branch"
        print_error "This is a serious error. Aborting."
        exit 1
    fi
fi

# Reactivate git hooks
reactivate_git_hooks

# Final verification: ensure main branch wasn't modified
if [ "$DRY_RUN" = false ]; then
    final_main_sha=$(git rev-parse "$MAIN_BRANCH" 2>/dev/null)
    final_remote_sha=$(git rev-parse "origin/$MAIN_BRANCH" 2>/dev/null)
    
    if [ "$final_main_sha" != "$final_remote_sha" ]; then
        print_error "CRITICAL ERROR: $MAIN_BRANCH has diverged from origin/$MAIN_BRANCH!"
        print_error "Local:  $final_main_sha"
        print_error "Remote: $final_remote_sha"
        print_error "This script has a bug that modified $MAIN_BRANCH."
        print_error "DO NOT push $MAIN_BRANCH to remote!"
        print_error "You may need to reset: git checkout $MAIN_BRANCH && git reset --hard origin/$MAIN_BRANCH"
        exit 1
    fi
fi

# Navigate back to original directory
if [ "$ORIGINAL_DIR" != "$GIT_ROOT" ]; then
    print_status "Returning to original directory: $ORIGINAL_DIR"
    cd "$ORIGINAL_DIR" || {
        print_warning "Failed to return to original directory"
    }
fi

# Run npm install if npm is available and package.json exists
if [ "$NPM_AVAILABLE" = true ] && [ -f "package.json" ] && [ "$DRY_RUN" = false ]; then
    # Check if package-lock.json or node_modules changed
    if git diff --name-only "$ORIGINAL_BRANCH@{1}" "$ORIGINAL_BRANCH" | grep -qE 'package-lock.json|package.json'; then
        print_status "Dependencies may have changed. Running npm install..."
        if npm install; then
            print_success "npm install successful"
        else
            print_error "npm install failed"
            exit 1
        fi
    else
        print_status "No dependency changes detected. Skipping npm install."
    fi
fi

# Print summary
echo
print_status "=== SUMMARY ==="

if [ ${#IGNORED_BRANCHES[@]} -gt 0 ]; then
    print_warning "Ignored branches (${#IGNORED_BRANCHES[@]}):"
    printf '%s\n' "${IGNORED_BRANCHES[@]}" | sed 's/^/  ⊝ /'
fi

if [ ${#SUCCESSFUL_BRANCHES[@]} -gt 0 ]; then
    print_success "Updated branches (${#SUCCESSFUL_BRANCHES[@]}):"
    printf '%s\n' "${SUCCESSFUL_BRANCHES[@]}" | sed 's/^/  ✓ /'
fi

if [ ${#UPTODATE_WITH_PARENT_BRANCHES[@]} -gt 0 ]; then
    print_success "Stacked branches already up-to-date with parent (${#UPTODATE_WITH_PARENT_BRANCHES[@]}):"
    printf '%s\n' "${UPTODATE_WITH_PARENT_BRANCHES[@]}" | sed 's/^/  ✓ /'
fi

if [ ${#REBASED_BRANCHES[@]} -gt 0 ]; then
    print_success "Rebased stacked branches (requires manual force-push) (${#REBASED_BRANCHES[@]}):"
    printf '%s\n' "${REBASED_BRANCHES[@]}" | sed 's/^/  ↻ /'
    echo -e "${YELLOW}⚠ These branches need to be force-pushed manually:${NC}"
    for branch in "${REBASED_BRANCHES[@]}"; do
        echo -e "  ${YELLOW}git push --force-with-lease origin $branch${NC}"
    done
fi

if [ ${#MERGE_CONFLICT_BRANCHES[@]} -gt 0 ]; then
    print_warning "Branches with merge conflicts (${#MERGE_CONFLICT_BRANCHES[@]}):"
    printf '%s\n' "${MERGE_CONFLICT_BRANCHES[@]}" | sed 's/^/  ⚠ /'
    echo -e "${YELLOW}These branches need manual conflict resolution${NC}"
fi

if [ ${#REBASE_CONFLICT_BRANCHES[@]} -gt 0 ]; then
    print_warning "Branches with rebase conflicts (${#REBASE_CONFLICT_BRANCHES[@]}):"
    printf '%s\n' "${REBASE_CONFLICT_BRANCHES[@]}" | sed 's/^/  ⚠ /'
    echo -e "${YELLOW}These branches need manual conflict resolution${NC}"
fi

if [ ${#FAILED_BRANCHES[@]} -gt 0 ]; then
    print_error "Branches that failed (${#FAILED_BRANCHES[@]}):"
    printf '%s\n' "${FAILED_BRANCHES[@]}" | sed 's/^/  ✗ /'
fi

echo
if [ "$DRY_RUN" = true ]; then
    print_dry_run "Dry-run completed! No actual changes were made."
elif [ "$PUSH" = false ]; then
    print_warning "Operation completed! Changes made locally but not pushed to remote. Use --push to push."
else
    print_status "Operation completed!"
fi

# Clean up old backup branches
if [ "$DRY_RUN" = false ]; then
    echo
    print_status "Cleaning up old backup branches..."
    if [ -f "$SCRIPT_DIR/git_delete_backups.sh" ]; then
        "$SCRIPT_DIR/git_delete_backups.sh" 2>/dev/null || print_warning "Failed to clean up old backups"
    else
        print_warning "git_delete_backups.sh not found at $SCRIPT_DIR, skipping cleanup"
    fi
fi

# Exit with appropriate code
if [ ${#FAILED_BRANCHES[@]} -gt 0 ]; then
    exit 1
elif [ ${#MERGE_CONFLICT_BRANCHES[@]} -gt 0 ] || [ ${#REBASE_CONFLICT_BRANCHES[@]} -gt 0 ]; then
    exit 10  # More distinctive exit code for conflicts
else
    exit 0
fi