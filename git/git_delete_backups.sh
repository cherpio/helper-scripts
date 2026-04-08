#!/bin/zsh

# Delete Backup Branches
# By default, deletes backup branches older than 1 week
# Use --all or -a to delete all backup branches regardless of age
#
# Usage:
#   git_delete_backups.sh           - Delete backups older than 1 week
#   git_delete_backups.sh --all     - Delete all backup branches
#   git_delete_backups.sh -a        - Delete all backup branches

# ====================================
# CONFIGURATION
# ====================================

DELETE_ALL=false
AGE_LIMIT_DAYS=7  # Default: delete backups older than 7 days

# Colors for output
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ====================================
# PARSE ARGUMENTS
# ====================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --all|-a)
            DELETE_ALL=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--all|-a]"
            exit 1
            ;;
    esac
done

# ====================================
# CONFIRM --all
# ====================================

if [ "$DELETE_ALL" = true ]; then
    echo "${YELLOW}Warning: This will delete ALL backup branches, regardless of age.${NC}"
    echo -n "Are you sure? [y/N] "
    read -r CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# ====================================
# MAIN LOGIC
# ====================================

BACKUP_BRANCHES=($(git for-each-ref --format='%(refname)' refs/heads | cut -d/ -f3- | grep "backup/"))
CURRENT_BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)

if [ ${#BACKUP_BRANCHES[@]} -eq 0 ]; then
    echo "${BLUE}No backup branches found.${NC}"
    exit 0
fi

# Calculate cutoff date (7 days ago)
CUTOFF_DATE=$(date -v-${AGE_LIMIT_DAYS}d +%s 2>/dev/null || date -d "${AGE_LIMIT_DAYS} days ago" +%s 2>/dev/null)

DELETED_COUNT=0
SKIPPED_COUNT=0

for BRANCH in ${BACKUP_BRANCHES[@]}; do
    # Skip if it's the current branch
    if [[ $CURRENT_BRANCH_NAME == $BRANCH ]]; then
        continue
    fi
    
    # Extract date from branch name pattern: backup/YYYY-MM-DD/HH-MM-SS/...
    # Example: backup/2026-01-05/14-30-45/feature-branch
    if [[ $BRANCH =~ ^backup/([0-9]{4}-[0-9]{2}-[0-9]{2})/([0-9]{2}-[0-9]{2}-[0-9]{2})/ ]]; then
        BRANCH_DATE_STR="${match[1]} ${match[2]//-/:}"  # Convert to "YYYY-MM-DD HH:MM:SS"
        BRANCH_DATE=$(date -j -f "%Y-%m-%d %H:%M:%S" "$BRANCH_DATE_STR" +%s 2>/dev/null)
        
        if [ -z "$BRANCH_DATE" ]; then
            echo "${YELLOW}Warning: Could not parse date for $BRANCH, skipping${NC}"
            continue
        fi
    else
        echo "${YELLOW}Warning: Branch $BRANCH doesn't match expected pattern, skipping${NC}"
        continue
    fi
    
    # Check if we should delete based on age
    SHOULD_DELETE=false
    
    if [ "$DELETE_ALL" = true ]; then
        SHOULD_DELETE=true
    elif [ "$BRANCH_DATE" -lt "$CUTOFF_DATE" ]; then
        SHOULD_DELETE=true
    fi
    
    if [ "$SHOULD_DELETE" = true ]; then
        echo "${YELLOW}Deleting backup branch $BRANCH...${NC}"
        git branch -D $BRANCH
        DELETED_COUNT=$((DELETED_COUNT + 1))
    else
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    fi
done

# Print summary
echo
echo "${GREEN}Summary:${NC}"
echo "  Deleted: $DELETED_COUNT backup branch(es)"
if [ "$DELETE_ALL" = false ]; then
    echo "  Skipped: $SKIPPED_COUNT newer backup branch(es) (< $AGE_LIMIT_DAYS days old)"
    echo
    echo "${BLUE}To delete all backups, run: $0 --all${NC}"
fi