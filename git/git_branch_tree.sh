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

# Branch-name patterns to exclude. Matched as prefixes (via shell `case`),
# so `backup/` matches `backup/anything`. Add more via `--exclude PATTERN`.
EXCLUDED_BRANCHES=("backup/")

print_help() {
    cat <<'EOF'
Usage:
  git_branch_tree.sh [MAIN_BRANCH] [--fetch] [--exclude PATTERN]...
                     [--no-color] [--help]

Prints a tree of local branches showing parent/child relationships derived
from git merge-base. Annotates nodes whose origin-side history suggests a
different (non-main) parent than local history does.

Options:
  MAIN_BRANCH        Override detected default branch (e.g. master, develop).
  --fetch            Run `git fetch origin` before analysing.
  --exclude PATTERN  Skip branches whose name starts with PATTERN. Repeatable.
                     Default: backup/
  --no-color         Disable ANSI colour.
  --help             Show this help and exit.
EOF
}

args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
    arg="${args[$i]}"
    case "$arg" in
        --fetch)    FETCH=true ;;
        --no-color) USE_COLOR=false ;;
        --exclude)
            i=$((i + 1))
            if [ "$i" -ge "${#args[@]}" ]; then
                echo "--exclude requires an argument" >&2
                exit 1
            fi
            EXCLUDED_BRANCHES+=("${args[$i]}")
            ;;
        --exclude=*)
            EXCLUDED_BRANCHES+=("${arg#--exclude=}")
            ;;
        -h|--help)  print_help; exit 0 ;;
        --*)        echo "Unknown option: $arg" >&2; exit 1 ;;
        *)          MAIN_BRANCH="$arg" ;;
    esac
    i=$((i + 1))
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

# Single for-each-ref pass collects branch names AND their tip SHAs, so we
# don't need a separate `git rev-parse` call per branch later.
LOCAL_BRANCHES=()
LOCAL_SHA_MAP=""
while IFS=' ' read -r b sha; do
    [ -n "$b" ] || continue
    skip=false
    for pat in "${EXCLUDED_BRANCHES[@]}"; do
        case "$b" in
            $pat*) skip=true; break ;;
        esac
    done
    [ "$skip" = true ] && continue
    LOCAL_BRANCHES+=("$b")
    if [ -z "$LOCAL_SHA_MAP" ]; then
        LOCAL_SHA_MAP="${b}|${sha}"
    else
        LOCAL_SHA_MAP="${LOCAL_SHA_MAP}"$'\n'"${b}|${sha}"
    fi
done < <(git for-each-ref --format='%(refname:short) %(objectname)' refs/heads)

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")

# ====================================
# PARENT DETECTION
# ====================================
#
# Algorithm: walk target's unique commits (main..target) from newest to oldest.
# At each commit C, ask "which branches contain C?" via a single
# `git for-each-ref --contains`. The first commit where any eligible candidate
# appears is the fork-point, and that candidate is the parent. This is
# O(K) git invocations per target (K = commits since main) rather than the
# previous O(N+M) per target times ~5 git calls each.
#
# Eligibility rules:
#   - Skip target itself and main.
#   - Skip descendants of target (branches whose tip contains target's SHA):
#     those branches branched off target, not vice versa.
#   - For the origin side, restrict candidates to `origin/<X>` where X is a
#     local branch name — that's the only case where origin supplies useful
#     pre-rebase history for a branch the user actually cares about.

# Build a newline-wrapped "set" of local branch names for O(1)-ish membership
# tests via bash pattern matching.
LOCAL_NAMES_NL=$'\n'
for b in "${LOCAL_BRANCHES[@]}"; do
    LOCAL_NAMES_NL="${LOCAL_NAMES_NL}${b}"$'\n'
done

# Origin candidates: origin refs whose bare name matches a local branch.
# We build two parallel structures:
#   - ORIGIN_CANDIDATES_NL: newline-wrapped set for membership tests.
#   - ORIGIN_CANDIDATE_REFS: array of full refspecs, passed to
#     `for-each-ref` so it scans only our candidate refs (critical on repos
#     with thousands of unrelated origin refs).
ORIGIN_CANDIDATES_NL=$'\n'
ORIGIN_CANDIDATE_REFS=()
while IFS= read -r r; do
    [ -z "$r" ] && continue
    name="${r#origin/}"
    [ "$name" = "HEAD" ] && continue
    [ "$name" = "$MAIN_BRANCH" ] && continue
    case "$LOCAL_NAMES_NL" in
        *$'\n'"$name"$'\n'*)
            ORIGIN_CANDIDATES_NL="${ORIGIN_CANDIDATES_NL}${r}"$'\n'
            ORIGIN_CANDIDATE_REFS+=("refs/remotes/${r}")
            ;;
    esac
done < <(git for-each-ref --format='%(refname:short)' refs/remotes/origin)

# find_parents <target> <target_sha> -> prints "local_parent|origin_parent".
# Walks target's unique commits once, asking `for-each-ref --contains` about
# BOTH local heads and candidate origin refs in a single call per commit.
# This halves git invocations for branches that would otherwise trigger both
# a local and an origin walk. Short-circuits on the first non-main local
# parent (annotation only matters when local = main).
find_parents() {
    local target="$1"
    local target_sha="$2"

    # Scope passed to `git for-each-ref --contains`: all local heads plus
    # the curated origin candidate refs.
    local scope=("refs/heads")
    if [ "${#ORIGIN_CANDIDATE_REFS[@]}" -gt 0 ]; then
        scope+=("${ORIGIN_CANDIDATE_REFS[@]}")
    fi

    # Refs whose tip contains target_sha → descendants of target → never parents.
    local desc_nl=$'\n'
    local r
    while IFS= read -r r; do
        [ -n "$r" ] && desc_nl="${desc_nl}${r}"$'\n'
    done < <(git for-each-ref --format='%(refname:short)' --contains "$target_sha" "${scope[@]}")

    local local_parent="" origin_parent=""
    local c cand local_best origin_best
    while IFS= read -r c; do
        [ -z "$c" ] && continue
        local_best=""
        origin_best=""
        while IFS= read -r cand; do
            [ -z "$cand" ] && continue
            case "$desc_nl" in
                *$'\n'"$cand"$'\n'*) continue ;;
            esac
            case "$cand" in
                origin/*)
                    [ -n "$origin_parent" ] && continue
                    [ "$cand" = "origin/$target" ] && continue
                    if [ -z "$origin_best" ] || [[ "$cand" < "$origin_best" ]]; then
                        origin_best="$cand"
                    fi
                    ;;
                *)
                    [ -n "$local_parent" ] && continue
                    [ "$cand" = "$target" ] && continue
                    [ "$cand" = "$MAIN_BRANCH" ] && continue
                    if [ -z "$local_best" ] || [[ "$cand" < "$local_best" ]]; then
                        local_best="$cand"
                    fi
                    ;;
            esac
        done < <(git for-each-ref --format='%(refname:short)' --contains "$c" "${scope[@]}")

        [ -z "$local_parent" ] && [ -n "$local_best" ] && local_parent="$local_best"
        [ -z "$origin_parent" ] && [ -n "$origin_best" ] && origin_parent="${origin_best#origin/}"

        # If local found a non-main parent, we're done — annotation only
        # applies when local collapses to main, so origin no longer matters.
        if [ -n "$local_parent" ] && [ "$local_parent" != "$MAIN_BRANCH" ]; then
            origin_parent=""
            break
        fi
        # Both found (local will be main by construction below if still empty).
        if [ -n "$local_parent" ] && [ -n "$origin_parent" ]; then
            break
        fi
    done < <(git rev-list "$MAIN_BRANCH..$target" 2>/dev/null)

    [ -z "$local_parent" ] && local_parent="$MAIN_BRANCH"
    printf '%s|%s' "$local_parent" "$origin_parent"
}

# Maps stored as newline-separated "key|value" strings (bash 3.2 compatible).
# Lookups and appends are pure-bash to avoid the per-call fork overhead that
# an awk or printf-subshell pipeline would add.
LOCAL_PARENT_MAP=""
ORIGIN_NOTE_MAP=""
CHILDREN_MAP=""

# Pure-bash map_get: prints first value for key, empty on miss.
map_get() {
    local map="$1"
    local key="$2"
    local line
    [ -z "$map" ] && return 0
    while IFS= read -r line; do
        if [ "${line%%|*}" = "$key" ]; then
            printf '%s' "${line#*|}"
            return 0
        fi
    done <<< "$map"
}

# Pure-bash map_get_all: prints all values for key, newline-separated.
map_get_all() {
    local map="$1"
    local key="$2"
    local line
    [ -z "$map" ] && return 0
    while IFS= read -r line; do
        if [ "${line%%|*}" = "$key" ]; then
            printf '%s\n' "${line#*|}"
        fi
    done <<< "$map"
}

total=${#LOCAL_BRANCHES[@]}
idx=0
progress_enabled=false
[ -t 2 ] && [ "$total" -gt 20 ] && progress_enabled=true

for b in "${LOCAL_BRANCHES[@]}"; do
    idx=$((idx + 1))
    [ "$b" = "$MAIN_BRANCH" ] && continue

    if [ "$progress_enabled" = true ]; then
        printf '\r\033[2Kanalysing %d/%d: %s' "$idx" "$total" "$b" >&2
    fi

    target_sha=$(map_get "$LOCAL_SHA_MAP" "$b")
    [ -z "$target_sha" ] && continue

    parents=$(find_parents "$b" "$target_sha")
    lp="${parents%%|*}"
    op_name="${parents#*|}"

    if [ -z "$LOCAL_PARENT_MAP" ]; then
        LOCAL_PARENT_MAP="${b}|${lp}"
    else
        LOCAL_PARENT_MAP="${LOCAL_PARENT_MAP}"$'\n'"${b}|${lp}"
    fi

    # find_parents only returns a non-empty origin result when local = main
    # and origin found a non-main parent — exactly the annotation condition.
    if [ -n "$op_name" ]; then
        if [ -z "$ORIGIN_NOTE_MAP" ]; then
            ORIGIN_NOTE_MAP="${b}|${op_name}"
        else
            ORIGIN_NOTE_MAP="${ORIGIN_NOTE_MAP}"$'\n'"${b}|${op_name}"
        fi
    fi
done

if [ "$progress_enabled" = true ]; then
    printf '\r\033[2K' >&2
fi

# ====================================
# BUILD CHILDREN MAP
# ====================================

for b in "${LOCAL_BRANCHES[@]}"; do
    [ "$b" = "$MAIN_BRANCH" ] && continue
    parent=$(map_get "$LOCAL_PARENT_MAP" "$b")
    if [ -z "$CHILDREN_MAP" ]; then
        CHILDREN_MAP="${parent}|${b}"
    else
        CHILDREN_MAP="${CHILDREN_MAP}"$'\n'"${parent}|${b}"
    fi
done

# ====================================
# STATUS MARKER
# ====================================

status_marker() {
    local branch="$1"
    local parent="$2"
    local ab behind ahead
    ab=$(git rev-list --left-right --count "$parent...$branch" 2>/dev/null) || return 0
    # Output is "<behind>\t<ahead>". Split with bash parameter expansion
    # instead of piping to awk twice.
    behind="${ab%%[[:space:]]*}"
    ahead="${ab##*[[:space:]]}"
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
