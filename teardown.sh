#!/bin/bash

# teardown.sh - Cleanup and project teardown script
# Purpose: Clean up temporary files, debug artifacts, and manage manifest lifecycle

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
STACK_NAME="ndjson-parquet-sqs"
DRY_RUN=false

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

# Function to show usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --full              Full teardown (delete stack + all temp files)"
    echo "  --temp-only         Clean only temporary/debug files (keep stack)"
    echo "  --stack-only        Delete CloudFormation stack only"
    echo "  --dry-run           Show what would be deleted without deleting"
    echo "  --keep-generated    Keep generated test data files"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --dry-run        # Preview what would be deleted"
    echo "  $0 --temp-only      # Clean debug files only"
    echo "  $0 --full           # Complete teardown"
}

# Parse command line arguments
MODE=""
KEEP_GENERATED=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --full)
            MODE="full"
            shift
            ;;
        --temp-only)
            MODE="temp"
            shift
            ;;
        --stack-only)
            MODE="stack"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --keep-generated)
            KEEP_GENERATED=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Require mode selection
if [ -z "$MODE" ]; then
    print_error "Please specify a teardown mode"
    usage
    exit 1
fi

# Function to delete CloudFormation stack
delete_stack() {
    print_status "Checking CloudFormation stack: $STACK_NAME"

    if aws cloudformation describe-stacks --stack-name "$STACK_NAME" &>/dev/null; then
        print_warning "CloudFormation stack exists: $STACK_NAME"

        if [ "$DRY_RUN" = true ]; then
            print_status "[DRY RUN] Would delete stack: $STACK_NAME"
        else
            read -p "Delete stack $STACK_NAME? (yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                print_status "Deleting stack: $STACK_NAME"
                aws cloudformation delete-stack --stack-name "$STACK_NAME"

                print_status "Waiting for stack deletion to complete..."
                aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
                print_success "Stack deleted successfully"
            else
                print_warning "Stack deletion cancelled"
            fi
        fi
    else
        print_status "Stack does not exist: $STACK_NAME"
    fi
}

# Function to clean temporary and debug files
clean_temp_files() {
    print_status "Cleaning temporary and debug files..."

    # List of temporary/debug files to delete
    TEMP_FILES=(
        "current-error.json"
        "latest-failure.json"
        "newest-failure.json"
        "stack-events.txt"
        "stack-resources.txt"
        "nul"
        "notes.txt"
    )

    # Debug scripts to delete
    DEBUG_SCRIPTS=(
        "check-latest-error.sh"
        "check-stack-status.sh"
        "cleanup-and-deploy.sh"
        "deploy-fresh.sh"
        "get-current-error.sh"
        "get-errors.sh"
        "quick-redeploy.sh"
        "update-lambdas.sh"
        "verify-deployment.sh"
        "view-logs.sh"
    )

    # Clean temporary files
    for file in "${TEMP_FILES[@]}"; do
        if [ -f "$file" ]; then
            if [ "$DRY_RUN" = true ]; then
                print_status "[DRY RUN] Would delete: $file"
            else
                rm -f "$file"
                print_success "Deleted: $file"
            fi
        fi
    done

    # Clean debug scripts
    for script in "${DEBUG_SCRIPTS[@]}"; do
        if [ -f "$script" ]; then
            if [ "$DRY_RUN" = true ]; then
                print_status "[DRY RUN] Would delete: $script"
            else
                rm -f "$script"
                print_success "Deleted: $script"
            fi
        fi
    done

    # Clean temp configuration directory
    if [ -d "configurations/temp" ]; then
        if [ "$DRY_RUN" = true ]; then
            print_status "[DRY RUN] Would delete: configurations/temp/"
            find configurations/temp -type f | while read file; do
                print_status "  - $file"
            done
        else
            rm -rf configurations/temp
            print_success "Deleted: configurations/temp/"
        fi
    fi

    # Clean build artifacts
    if [ -d "build" ]; then
        if [ "$DRY_RUN" = true ]; then
            print_status "[DRY RUN] Would delete: build/"
            find build -type f | while read file; do
                print_status "  - $file"
            done
        else
            rm -rf build
            print_success "Deleted: build/"
        fi
    fi

    # Clean generated test data files (optional)
    if [ "$KEEP_GENERATED" = false ]; then
        print_status "Cleaning generated test data files..."
        if [ "$DRY_RUN" = true ]; then
            print_status "[DRY RUN] Would delete test data files:"
            ls -1 2025-*.ndjson 2>/dev/null | while read file; do
                print_status "  - $file"
            done
        else
            rm -f 2025-*.ndjson
            print_success "Deleted test data files"
        fi
    else
        print_status "Keeping generated test data files (--keep-generated)"
    fi
}

# Main teardown logic
print_status "Starting teardown process..."
print_status "Mode: $MODE"
print_status "Dry run: $DRY_RUN"
echo ""

case $MODE in
    full)
        print_status "=== FULL TEARDOWN ==="
        delete_stack
        echo ""
        clean_temp_files
        ;;
    temp)
        print_status "=== TEMPORARY FILES CLEANUP ==="
        clean_temp_files
        ;;
    stack)
        print_status "=== STACK DELETION ONLY ==="
        delete_stack
        ;;
esac

echo ""
if [ "$DRY_RUN" = true ]; then
    print_warning "DRY RUN COMPLETE - No files were actually deleted"
    print_status "Run without --dry-run to perform actual deletion"
else
    print_success "Teardown complete!"
fi
