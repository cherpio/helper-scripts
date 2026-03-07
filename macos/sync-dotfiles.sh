#!/bin/bash

# iCloud Dotfiles Sync Script
# This script syncs .zshrc, .zsh_sessions, and .zsh_history with iCloud Drive

set -e  # Exit on any error

# Define paths
HOME_DIR="$HOME"
ICLOUD_DOCS="$HOME_DIR/Library/Mobile Documents/com~apple~CloudDocs"
ICLOUD_SYNC="$ICLOUD_DOCS/sync"
ICLOUD_DOTFILES="$ICLOUD_SYNC/dotfiles"
BACKUP_DIR="$HOME/.dotfiles_backup_$(date +%Y%m%d_%H%M%S)"

# Config dotfiles and dotfolders to sync
FILES=(".zshrc" ".gitconfig" ".gitignore_global" ".hgignore_global" ".zprofile" ".claude.json")
DIRECTORIES=(".config" ".gnupg" ".git-workspaces" ".claude" ".copilot")

# Other folder pairs to sync (format: "SOURCE_PATH,DESTINATION_PATH")
# SOURCE_PATH: absolute path to source folder
# DESTINATION_PATH: relative path within iCloud sync directory
FOLDER_PAIRS=()

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Function to check if iCloud Drive is available
check_icloud() {
    if [ ! -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" ]; then
        print_error "iCloud Drive not found. Please ensure iCloud Drive is enabled."
        exit 1
    fi
}

# Function to create backup directory
create_backup_dir() {
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
        print_success "Created backup directory: $BACKUP_DIR"
    fi
}

# Function to backup item (file or directory)
backup_item() {
    local item="$1"
    local item_path="$HOME_DIR/$item"
    
    if [ -e "$item_path" ] && [ ! -L "$item_path" ]; then
        create_backup_dir
        print_status "Backing up $item..."
        cp -R "$item_path" "$BACKUP_DIR/"
        print_success "Backed up $item to $BACKUP_DIR"
        return 0
    fi
    return 1
}
create_dotfiles_dir() {
    if [ ! -d "$ICLOUD_DOTFILES" ]; then
        print_status "Creating iCloud dotfiles directory..."
        mkdir -p "$ICLOUD_DOTFILES"
        print_success "Created directory: $ICLOUD_DOTFILES"
    else
        print_status "iCloud dotfiles directory already exists"
    fi
}

# Function to create iCloud dotfiles directory
create_dotfiles_dir() {
    if [ ! -d "$ICLOUD_DOTFILES" ]; then
        print_status "Creating iCloud dotfiles directory..."
        mkdir -p "$ICLOUD_DOTFILES"
        print_success "Created directory: $ICLOUD_DOTFILES"
    else
        print_status "iCloud dotfiles directory already exists"
    fi
}

# Function to create iCloud sync directory
create_sync_dir() {
    if [ ! -d "$ICLOUD_SYNC" ]; then
        print_status "Creating iCloud sync directory..."
        mkdir -p "$ICLOUD_SYNC"
        print_success "Created directory: $ICLOUD_SYNC"
    else
        print_status "iCloud sync directory already exists"
    fi
}

# Function to handle directory migration and symlinking
process_directory() {
    local dir="$1"
    local home_dir="$HOME_DIR/$dir"
    local icloud_dir="$ICLOUD_DOTFILES/$dir"
    
    print_status "Processing directory $dir..."
    
    # First, check if symlink exists but points to wrong location
    if [ -L "$home_dir" ]; then
        local link_target=$(readlink "$home_dir")
        if [ "$link_target" != "$icloud_dir" ]; then
            print_warning "$dir symlink points to wrong location ($link_target), fixing..."
            rm "$home_dir"
        fi
    fi
    
    # Check if directory exists in iCloud dotfiles
    if [ ! -d "$icloud_dir" ]; then
        # iCloud directory doesn't exist
        if [ -e "$home_dir" ]; then
            # Home item exists
            if [ -L "$home_dir" ]; then
                print_warning "$home_dir is already a symlink, removing it"
                rm "$home_dir"
            elif [ -d "$home_dir" ]; then
                # It's a directory, move it to iCloud
                print_status "Moving $home_dir to iCloud dotfiles..."
                mv "$home_dir" "$icloud_dir"
                print_success "Moved $dir to iCloud dotfiles"
            else
                # It's a file, backup and remove it
                backup_item "$dir"
                rm "$home_dir"
                print_warning "Removed file $home_dir (expected directory)"
            fi
        else
            # Neither exists, create empty directory in iCloud
            print_status "Creating new empty directory $dir in iCloud dotfiles..."
            mkdir -p "$icloud_dir"
            print_success "Created empty directory $dir in iCloud dotfiles"
        fi
    else
        # iCloud directory exists
        if [ -e "$home_dir" ]; then
            if [ -L "$home_dir" ]; then
                # Home item is already a symlink
                local link_target=$(readlink "$home_dir")
                if [ "$link_target" = "$icloud_dir" ]; then
                    print_status "$dir symlink already exists and points to correct location"
                    return
                else
                    print_warning "$dir symlink exists but points to wrong location, fixing..."
                    rm "$home_dir"
                fi
            else
                # Home item exists but is not a symlink, backup and remove it
                backup_item "$dir"
                print_warning "$dir exists in home directory, backing up and removing to prepare for symlink..."
                rm -rf "$home_dir"
                print_success "Backed up and removed $dir from home directory"
            fi
        fi
    fi
    
    # Create symlink if it doesn't exist
    if [ ! -L "$home_dir" ]; then
        print_status "Creating symlink for $dir..."
        ln -s "$icloud_dir" "$home_dir"
        print_success "Created symlink: $home_dir -> $icloud_dir"
    fi
}

# Function to handle custom folder pair migration and symlinking
process_folder_pair() {
    local pair="$1"
    local source_path="${pair%%,*}"  # Extract everything before the comma
    local dest_relative="${pair##*,}"  # Extract everything after the comma
    local icloud_path="$ICLOUD_SYNC/$dest_relative"
    
    print_status "Processing folder pair: $source_path -> $dest_relative..."
    
    # Expand variables in source path (properly quoted to handle spaces)
    eval "source_path=\"$source_path\""
    
    # First, check if symlink exists but points to wrong location
    if [ -L "$source_path" ]; then
        local link_target=$(readlink "$source_path")
        if [ "$link_target" != "$icloud_path" ]; then
            print_warning "Symlink points to wrong location ($link_target), fixing..."
            rm "$source_path"
        fi
    fi
    
    # Check if iCloud path exists
    if [ ! -d "$icloud_path" ]; then
        # iCloud directory doesn't exist
        if [ -e "$source_path" ]; then
            # Source exists
            if [ -L "$source_path" ]; then
                print_warning "$source_path is already a symlink, removing it"
                rm "$source_path"
            elif [ -d "$source_path" ]; then
                # It's a directory, move it to iCloud
                print_status "Moving $source_path to iCloud sync..."
                mkdir -p "$(dirname "$icloud_path")"
                mv "$source_path" "$icloud_path"
                print_success "Moved $source_path to $dest_relative"
            else
                # It's a file, backup and remove it
                local backup_name="$(basename "$source_path")"
                if [ -e "$source_path" ] && [ ! -L "$source_path" ]; then
                    create_backup_dir
                    print_status "Backing up $backup_name..."
                    cp -R "$source_path" "$BACKUP_DIR/"
                    print_success "Backed up $backup_name to $BACKUP_DIR"
                fi
                rm "$source_path"
                print_warning "Removed file $source_path (expected directory)"
            fi
        else
            # Neither exists, create empty directory in iCloud
            print_status "Creating new empty directory at $dest_relative in iCloud sync..."
            mkdir -p "$icloud_path"
            print_success "Created empty directory at $dest_relative"
        fi
    else
        # iCloud directory exists
        if [ -e "$source_path" ]; then
            if [ -L "$source_path" ]; then
                # Source is already a symlink
                local link_target=$(readlink "$source_path")
                if [ "$link_target" = "$icloud_path" ]; then
                    print_status "$dest_relative symlink already exists and points to correct location"
                    return
                else
                    print_warning "Symlink exists but points to wrong location, fixing..."
                    rm "$source_path"
                fi
            else
                # Source exists but is not a symlink, backup and remove it
                local backup_name="$(basename "$source_path")"
                if [ -e "$source_path" ] && [ ! -L "$source_path" ]; then
                    create_backup_dir
                    print_status "Backing up $backup_name..."
                    cp -R "$source_path" "$BACKUP_DIR/"
                    print_success "Backed up $backup_name to $BACKUP_DIR"
                fi
                print_warning "$source_path exists, backing up and removing to prepare for symlink..."
                rm -rf "$source_path"
                print_success "Backed up and removed $source_path"
            fi
        fi
    fi
    
    # Create symlink if it doesn't exist
    if [ ! -L "$source_path" ]; then
        print_status "Creating symlink for folder pair..."
        mkdir -p "$(dirname "$source_path")"
        ln -s "$icloud_path" "$source_path"
        print_success "Created symlink: $source_path -> $icloud_path"
    else
        # Symlink already exists, verify it points to the right place
        local link_target=$(readlink "$source_path")
        if [ "$link_target" = "$icloud_path" ]; then
            print_status "$dest_relative symlink already exists and points to correct location"
        fi
    fi
}

# Function to handle file migration and symlinking
process_file() {
    local file="$1"
    local home_file="$HOME_DIR/$file"
    local icloud_file="$ICLOUD_DOTFILES/$file"
    
    print_status "Processing file $file..."
    
    # First, check if symlink exists but points to wrong location
    if [ -L "$home_file" ]; then
        local link_target=$(readlink "$home_file")
        if [ "$link_target" != "$icloud_file" ]; then
            print_warning "$file symlink points to wrong location ($link_target), fixing..."
            rm "$home_file"
        fi
    fi
    
    # Check if file exists in iCloud dotfiles
    if [ ! -e "$icloud_file" ]; then
        # iCloud file doesn't exist
        if [ -e "$home_file" ]; then
            # Home file exists
            if [ -L "$home_file" ]; then
                print_warning "$home_file is already a symlink, removing it"
                rm "$home_file"
            elif [ -f "$home_file" ]; then
                # It's a file, move it to iCloud
                print_status "Moving $home_file to iCloud dotfiles..."
                mv "$home_file" "$icloud_file"
                print_success "Moved $file to iCloud dotfiles"
            else
                # It's a directory, backup and remove it
                backup_item "$file"
                rm -rf "$home_file"
                print_warning "Removed directory $home_file (expected file)"
            fi
        else
            # Neither file exists, create empty file in iCloud
            print_status "Creating new empty $file in iCloud dotfiles..."
            touch "$icloud_file"
            print_success "Created empty $file in iCloud dotfiles"
        fi
    else
        # iCloud file exists
        if [ -e "$home_file" ]; then
            if [ -L "$home_file" ]; then
                # Home file is already a symlink
                local link_target=$(readlink "$home_file")
                if [ "$link_target" = "$icloud_file" ]; then
                    print_status "$file symlink already exists and points to correct location"
                    return
                else
                    print_warning "$file symlink exists but points to wrong location, fixing..."
                    rm "$home_file"
                fi
            else
                # Home file exists but is not a symlink, backup and remove it
                backup_item "$file"
                print_warning "$file exists in home directory, backing up and removing to prepare for symlink..."
                rm -rf "$home_file"
                print_success "Backed up and removed $file from home directory"
            fi
        fi
    fi
    
    # Create symlink if it doesn't exist
    if [ ! -L "$home_file" ]; then
        print_status "Creating symlink for $file..."
        ln -s "$icloud_file" "$home_file"
        print_success "Created symlink: $home_file -> $icloud_file"
    fi
}

# Main execution
main() {
    echo "========================================"
    echo "   iCloud Dotfiles Sync Script"
    echo "========================================"
    echo
    
    print_status "Starting dotfiles sync process..."
    
    # Check if iCloud Drive is available
    check_icloud
    
    # Create dotfiles directory in iCloud Drive
    create_dotfiles_dir
    
    # Create sync directory in iCloud Drive for folder pairs
    create_sync_dir
    
    # Process each file
    for file in "${FILES[@]}"; do
        process_file "$file"
        echo
    done
    
    # Process each directory
    for dir in "${DIRECTORIES[@]}"; do
        process_directory "$dir"
        echo
    done
    
    # Process each folder pair
    for pair in "${FOLDER_PAIRS[@]}"; do
        process_folder_pair "$pair"
        echo
    done
    
    print_success "Dotfiles sync completed successfully!"
    echo
    print_status "Your dotfiles are now synced with iCloud Drive at:"
    print_status "$ICLOUD_DOTFILES"
    echo
    if [ ${#FOLDER_PAIRS[@]} -gt 0 ]; then
        print_status "Folder pairs are synced at:"
        print_status "$ICLOUD_SYNC"
        echo
    fi
    if [ -d "$BACKUP_DIR" ]; then
        print_status "Backups created at: $BACKUP_DIR"
        echo
    fi
    print_warning "Note: Changes may take a few minutes to sync between devices"
    print_warning "Run this script on each Mac where you want synced dotfiles"
}

# Run main function
main