#!/bin/bash
set -euo pipefail

# Build script for cross-compiling dbdev CLI
# Targets: darwin-x64, darwin-arm64, linux-x64, linux-arm64

DBDEV_VERSION="${DBDEV_VERSION:-0.1.7}"
DBDEV_REPO="https://github.com/supabase/dbdev"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
BIN_DIR="$SCRIPT_DIR/bin"
SRC_DIR="$BUILD_DIR/dbdev-$DBDEV_VERSION"

# Platform to Rust target mapping (Bash 3.x compatible)
# Using musl for Linux targets - more portable and easier to cross-compile
get_target() {
    case "$1" in
        darwin-x64)   echo "x86_64-apple-darwin" ;;
        darwin-arm64) echo "aarch64-apple-darwin" ;;
        linux-x64)    echo "x86_64-unknown-linux-musl" ;;
        linux-arm64)  echo "aarch64-unknown-linux-musl" ;;
        *)            echo "" ;;
    esac
}

ALL_PLATFORMS="darwin-x64 darwin-arm64 linux-x64 linux-arm64"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_dependencies() {
    log_info "Checking dependencies..."

    if ! command -v rustup &> /dev/null; then
        log_error "rustup is not installed. Install from https://rustup.rs/"
        exit 1
    fi

    if ! command -v cargo &> /dev/null; then
        log_error "cargo is not installed. Install Rust toolchain first."
        exit 1
    fi

    # Check for cross-compilation tool (optional but recommended for Linux targets)
    if ! command -v cross &> /dev/null; then
        log_warn "'cross' not found. Linux cross-compilation may require manual setup."
        log_warn "Install with: cargo install cross"
    fi
}

install_targets() {
    log_info "Installing Rust targets..."
    for platform in $ALL_PLATFORMS; do
        local target
        target="$(get_target "$platform")"
        log_info "Adding target: $target"
        rustup target add "$target" 2>/dev/null || true
    done
}

download_source() {
    log_info "Downloading dbdev source (v$DBDEV_VERSION)..."

    mkdir -p "$BUILD_DIR"

    if [[ -d "$SRC_DIR" ]]; then
        log_info "Source already exists at $SRC_DIR"
        return
    fi

    local archive_url="$DBDEV_REPO/archive/refs/tags/v$DBDEV_VERSION.tar.gz"
    local archive_path="$BUILD_DIR/dbdev-$DBDEV_VERSION.tar.gz"

    log_info "Downloading from $archive_url"
    curl -fsSL "$archive_url" -o "$archive_path"

    log_info "Extracting source..."
    tar -xzf "$archive_path" -C "$BUILD_DIR"
    rm "$archive_path"

    # Copy Cross.toml for cross-compilation config
    if [[ -f "$SCRIPT_DIR/Cross.toml" ]]; then
        cp "$SCRIPT_DIR/Cross.toml" "$SRC_DIR/cli/"
    fi

    # Add release profile optimizations to Cargo.toml
    if ! grep -q '\[profile.release\]' "$SRC_DIR/cli/Cargo.toml"; then
        cat >> "$SRC_DIR/cli/Cargo.toml" << 'CARGO_EOF'

[profile.release]
strip = true
lto = true
codegen-units = 1
opt-level = "z"
panic = "abort"
CARGO_EOF
        log_info "Added release profile optimizations"
    fi
}

build_target() {
    local platform="$1"
    local target
    target="$(get_target "$platform")"
    local output_name="dbdev-$platform"
    local output_path="$BIN_DIR/$output_name"

    log_info "Building for $platform ($target)..."

    cd "$SRC_DIR/cli"

    # Determine build method based on target
    case "$target" in
        *-apple-darwin)
            # Native macOS builds
            if [[ "$(uname -s)" == "Darwin" ]]; then
                cargo build --release --target "$target"
                cp "target/$target/release/dbdev" "$output_path"
            else
                log_warn "Skipping $platform - requires macOS host"
                return 1
            fi
            ;;
        *-linux-musl)
            # Linux musl targets - use cross if available
            if command -v cross &> /dev/null; then
                cross build --release --target "$target"
                cp "target/$target/release/dbdev" "$output_path"
            elif [[ "$(uname -s)" == "Linux" ]]; then
                # On Linux, try with musl toolchain
                cargo build --release --target "$target"
                cp "target/$target/release/dbdev" "$output_path"
            else
                log_warn "Skipping $platform - requires 'cross' tool on macOS"
                log_warn "Install with: cargo install cross"
                log_warn "Also ensure Docker is running"
                return 1
            fi
            ;;
    esac

    chmod +x "$output_path"
    log_info "Built: $output_path"
}

build_all() {
    mkdir -p "$BIN_DIR"

    local successful=""
    local failed=""

    for platform in $ALL_PLATFORMS; do
        if build_target "$platform"; then
            successful="$successful $platform"
        else
            failed="$failed $platform"
        fi
    done

    echo ""
    log_info "Build summary:"
    echo "  Successful:${successful:-" none"}"
    echo "  Failed/Skipped:${failed:-" none"}"
}

build_single() {
    local platform="$1"
    local target
    target="$(get_target "$platform")"

    if [[ -z "$target" ]]; then
        log_error "Unknown platform: $platform"
        log_error "Valid platforms: $ALL_PLATFORMS"
        exit 1
    fi

    mkdir -p "$BIN_DIR"
    build_target "$platform"
}

clean() {
    log_info "Cleaning build artifacts..."
    rm -rf "$BUILD_DIR"
    log_info "Build directory removed"
}

clean_all() {
    clean
    log_info "Removing binaries..."
    rm -f "$BIN_DIR"/dbdev-*
    log_info "All artifacts removed"
}

show_help() {
    cat << EOF
Usage: $0 [command] [options]

Commands:
    all             Build all targets (default)
    <platform>      Build specific platform (darwin-x64, darwin-arm64, linux-x64, linux-arm64)
    download        Download source only
    clean           Remove build directory
    clean-all       Remove build directory and binaries
    help            Show this help

Environment variables:
    DBDEV_VERSION   Version to build (default: $DBDEV_VERSION)

Examples:
    $0                      # Build all platforms
    $0 darwin-arm64         # Build only darwin-arm64
    $0 linux-x64            # Build only linux-x64
    DBDEV_VERSION=0.2.0 $0  # Build specific version

Cross-compilation notes:
    - macOS targets can be built on any macOS host (x64 or arm64)
    - Linux targets use musl for static linking (more portable)
    - Linux cross-compilation from macOS requires 'cross' tool and Docker:
        cargo install cross
        # Ensure Docker Desktop is running
EOF
}

main() {
    local command="${1:-all}"

    case "$command" in
        help|--help|-h)
            show_help
            ;;
        clean)
            clean
            ;;
        clean-all)
            clean_all
            ;;
        download)
            download_source
            ;;
        all)
            check_dependencies
            install_targets
            download_source
            build_all
            ;;
        darwin-x64|darwin-arm64|linux-x64|linux-arm64)
            check_dependencies
            install_targets
            download_source
            build_single "$command"
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
