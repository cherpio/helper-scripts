#!/usr/bin/env bash

# Prints a tree of all local branches showing which branch each was branched
# off from. Parent detection is purely merge-base based (branch names are
# ignored). When a branch's local merge-base collapses to the main branch but
# origin refs still show a non-main parent (typical after a parent-branch
# rebase), the node is annotated with "(probably branched off X, per origin)".
#
# Usage:
#   git_branch_tree.sh [MAIN_BRANCH] [--fetch] [--no-color] [--help]
#
# Options:
#   MAIN_BRANCH   Override detected default branch (e.g. master, develop).
#   --fetch       Run `git fetch origin` before analysing.
#   --no-color    Disable ANSI colour.
#   --help        Print this usage and exit.

set -uo pipefail

# ====================================
# COLORS
# ====================================

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
MAGENTA=$'\033[0;35m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'

USE_COLOR=true
[ -t 1 ] || USE_COLOR=false

# ====================================
# ARGUMENT PARSING
# ====================================

FETCH=false
MAIN_BRANCH=""

print_help() {
    cat <<'EOF'
Usage:
  git_branch_tree.sh [MAIN_BRANCH] [--fetch] [--no-color] [--help]

Prints a tree of local branches showing parent/child relationships derived
from git merge-base. Annotates nodes whose origin-side history suggests a
different (non-main) parent than local history does.

Options:
  MAIN_BRANCH   Override detected default branch (e.g. master, develop).
  --fetch       Run `git fetch origin` before analysing.
  --no-color    Disable ANSI colour.
  --help        Show this help and exit.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --fetch)    FETCH=true ;;
        --no-color) USE_COLOR=false ;;
        -h|--help)  print_help; exit 0 ;;
        --*)        echo "Unknown option: $arg" >&2; exit 1 ;;
        *)          MAIN_BRANCH="$arg" ;;
    esac
done

if [ "$USE_COLOR" = false ]; then
    RED=''; GREEN=''; YELLOW=''; MAGENTA=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

err() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1" >&2; }

# ====================================
# REPO / MAIN BRANCH DETECTION
# ====================================

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    err "Not in a git repository"
    exit 1
fi

detect_default_branch() {
    if command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        local b
        b=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)
        if [ -n "$b" ] && git show-ref --verify --quiet "refs/heads/$b"; then
            echo "$b"
            return 0
        fi
    fi
    local candidate
    for candidate in main master develop trunk; do
        if git show-ref --verify --quiet "refs/heads/$candidate"; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

if [ -z "$MAIN_BRANCH" ]; then
    if ! MAIN_BRANCH=$(detect_default_branch); then
        err "Could not detect default branch. Pass it as the first argument."
        exit 1
    fi
fi

if ! git show-ref --verify --quiet "refs/heads/$MAIN_BRANCH"; then
    err "Main branch '$MAIN_BRANCH' does not exist locally."
    exit 1
fi

if [ "$FETCH" = true ]; then
    if ! git fetch origin >/dev/null 2>&1; then
        warn "git fetch origin failed; continuing with existing refs."
    fi
fi

# ====================================
# COLLECT BRANCHES
# ====================================

LOCAL_BRANCHES=()
while IFS= read -r b; do
    [ -n "$b" ] && LOCAL_BRANCHES+=("$b")
done < <(git for-each-ref --format='%(refname:short)' refs/heads)

ORIGIN_BRANCHES=()
while IFS= read -r b; do
    [ -n "$b" ] || continue
    [ "$b" = "origin/HEAD" ] && continue
    ORIGIN_BRANCHES+=("$b")
done < <(git for-each-ref --format='%(refname:short)' refs/remotes/origin)

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")

# ====================================
# PARENT DETECTION
# ====================================

# find_parent_among <target-local-branch> <candidate-prefix> <candidates...>
#   candidate-prefix is "" for local candidates, "origin/" for origin candidates.
#   Prints the best parent candidate (in the candidate namespace), or empty.
find_parent_among() {
    local target="$1"
    local prefix="$2"
    shift 2
    local candidates=("$@")

    local target_sha
    target_sha=$(git rev-parse --verify "$target" 2>/dev/null) || return 0

    local fork_main
    fork_main=$(git merge-base "$MAIN_BRANCH" "$target" 2>/dev/null || true)

    local self_ns="${prefix}${target}"
    local main_ns="${prefix}${MAIN_BRANCH}"

    local best=""
    local best_mb=""
    local p p_sha mb

    for p in "${candidates[@]}"; do
        [ "$p" = "$self_ns" ] && continue
        [ "$p" = "$main_ns" ] && continue

        p_sha=$(git rev-parse --verify "$p" 2>/dev/null) || continue
        [ "$p_sha" = "$target_sha" ] && continue

        # If target is an ancestor of p, then p is a descendant of target
        # (p branched off target, not the other way around). Skip.
        if git merge-base --is-ancestor "$target" "$p" 2>/dev/null; then
            continue
        fi

        mb=$(git merge-base "$target" "$p" 2>/dev/null) || continue
        [ -z "$mb" ] && continue

        # Require shared history beyond what target shares with main:
        # mb must be strictly later than fork_main (i.e. fork_main is an
        # ancestor of mb, and mb != fork_main). This rules out cases where
        # target's merge-base with p is older than its divergence from main —
        # such a p was not target's parent (target hasn't seen p's commits).
        if [ -n "$fork_main" ]; then
            if [ "$mb" = "$fork_main" ]; then
                continue
            fi
            if ! git merge-base --is-ancestor "$fork_main" "$mb" 2>/dev/null; then
                continue
            fi
        fi

        # Topological ranking: a candidate whose merge-base is a (strict)
        # descendant of the current best's merge-base wins. If the two
        # merge-bases are identical, break ties alphabetically for stability.
        if [ -z "$best" ]; then
            best="$p"
            best_mb="$mb"
        elif [ "$mb" = "$best_mb" ]; then
            if [[ "$p" < "$best" ]]; then
                best="$p"
            fi
        elif git merge-base --is-ancestor "$best_mb" "$mb" 2>/dev/null; then
            best="$p"
            best_mb="$mb"
        fi
    done

    echo "$best"
}

# Maps stored as newline-separated "key|value" strings (bash 3.2 compatible).
LOCAL_PARENT_MAP=""
ORIGIN_NOTE_MAP=""
CHILDREN_MAP=""

map_get() {
    # map_get <map-var-value> <key> -> first matching value, or empty
    local map="$1"
    local key="$2"
    [ -z "$map" ] && return 0
    printf '%s\n' "$map" | awk -F'|' -v k="$key" '$1 == k { print substr($0, length(k) + 2); exit }'
}

map_get_all() {
    # map_get_all <map-var-value> <key> -> all matching values, newline-separated
    local map="$1"
    local key="$2"
    [ -z "$map" ] && return 0
    printf '%s\n' "$map" | awk -F'|' -v k="$key" '$1 == k { print substr($0, length(k) + 2) }'
}

map_append() {
    # map_append <map-var-value> <key> <value> -> prints new map value
    local map="$1"
    local key="$2"
    local val="$3"
    if [ -z "$map" ]; then
        printf '%s|%s' "$key" "$val"
    else
        printf '%s\n%s|%s' "$map" "$key" "$val"
    fi
}

for b in "${LOCAL_BRANCHES[@]}"; do
    [ "$b" = "$MAIN_BRANCH" ] && continue

    lp=$(find_parent_among "$b" "" "${LOCAL_BRANCHES[@]}")
    [ -z "$lp" ] && lp="$MAIN_BRANCH"
    LOCAL_PARENT_MAP=$(map_append "$LOCAL_PARENT_MAP" "$b" "$lp")

    if [ ${#ORIGIN_BRANCHES[@]} -gt 0 ]; then
        op=$(find_parent_among "$b" "origin/" "${ORIGIN_BRANCHES[@]}")
        if [ -n "$op" ]; then
            op_name="${op#origin/}"
            if [ "$op_name" != "$MAIN_BRANCH" ] && [ "$op_name" != "$lp" ]; then
                ORIGIN_NOTE_MAP=$(map_append "$ORIGIN_NOTE_MAP" "$b" "$op_name")
            fi
        fi
    fi
done

# ====================================
# BUILD CHILDREN MAP
# ====================================

for b in "${LOCAL_BRANCHES[@]}"; do
    [ "$b" = "$MAIN_BRANCH" ] && continue
    parent=$(map_get "$LOCAL_PARENT_MAP" "$b")
    CHILDREN_MAP=$(map_append "$CHILDREN_MAP" "$parent" "$b")
done

# ====================================
# STATUS MARKER
# ====================================

status_marker() {
    local branch="$1"
    local parent="$2"
    local ab behind ahead
    ab=$(git rev-list --left-right --count "$parent...$branch" 2>/dev/null) || return 0
    behind=$(echo "$ab" | awk '{print $1}')
    ahead=$(echo "$ab" | awk '{print $2}')
    [ -z "$behind" ] && behind=0
    [ -z "$ahead" ] && ahead=0
    if [ "$behind" = 0 ] && [ "$ahead" = 0 ]; then
        echo ""
    else
        echo "[+${ahead} -${behind}]"
    fi
}

# ====================================
# RENDER TREE
# ====================================

render_node() {
    local branch="$1"
    local prefix="$2"
    local is_last="$3"
    local is_root="${4:-false}"

    local connector="" child_prefix="$prefix"
    if [ "$is_root" != true ]; then
        if [ "$is_last" = true ]; then
            connector="└── "
            child_prefix="${prefix}    "
        else
            connector="├── "
            child_prefix="${prefix}│   "
        fi
    fi

    local label
    if [ "$branch" = "$CURRENT_BRANCH" ]; then
        label="${BOLD}${GREEN}* ${branch}${NC}"
    elif [ "$is_root" = true ]; then
        label="${BOLD}${CYAN}${branch}${NC}"
    else
        label="$branch"
    fi

    local status=""
    if [ "$is_root" != true ]; then
        local parent s
        parent=$(map_get "$LOCAL_PARENT_MAP" "$branch")
        s=$(status_marker "$branch" "$parent")
        [ -n "$s" ] && status=" ${DIM}${s}${NC}"
    fi

    local note=""
    local origin_note
    origin_note=$(map_get "$ORIGIN_NOTE_MAP" "$branch")
    if [ -n "$origin_note" ]; then
        note=" ${MAGENTA}(probably branched off ${origin_note}, per origin)${NC}"
    fi

    echo -e "${prefix}${connector}${label}${status}${note}"

    local children_raw
    children_raw=$(map_get_all "$CHILDREN_MAP" "$branch")
    [ -z "$children_raw" ] && return 0

    local children=()
    while IFS= read -r line; do
        [ -n "$line" ] && children+=("$line")
    done < <(printf '%s\n' "$children_raw" | sort)

    local count=${#children[@]}
    local i=0
    for child in "${children[@]}"; do
        i=$((i + 1))
        if [ "$i" -eq "$count" ]; then
            render_node "$child" "$child_prefix" true
        else
            render_node "$child" "$child_prefix" false
        fi
    done
}

render_node "$MAIN_BRANCH" "" false true
