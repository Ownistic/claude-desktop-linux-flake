#!/bin/bash

# Build functions for Claude Desktop AppImage creation

# Claude Desktop version (official version from Anthropic)
CLAUDE_VERSION="0.11.6"

# AppImage version (independent of Claude version for multiple releases)
APPIMAGE_VERSION="1.0.5"

# Electron version to bundle
ELECTRON_VERSION="36.3.2"

download_claude_desktop() {
    local build_dir="$1"
    local installer_url="https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/Claude-Setup-x64.exe?v=$CLAUDE_VERSION"
    local installer_path="$build_dir/Claude-Setup-x64.exe"

    log_info "Downloading Claude Desktop Windows installer (v$CLAUDE_VERSION)..."
    download_with_retry "$installer_url" "$installer_path"
    verify_file "$installer_path"
}

download_electron() {
    local build_dir="$1"
    local arch="$2"

    # Map system architecture to Electron architecture
    case "$arch" in
        x86_64|amd64)
            local electron_arch="x64"
            ;;
        aarch64|arm64)
            local electron_arch="arm64"
            ;;
        armv7l|armhf)
            local electron_arch="armv7l"
            ;;
        i386|i686)
            local electron_arch="ia32"
            ;;
        *)
            log_warning "Unknown architecture: $arch, defaulting to x64"
            local electron_arch="x64"
            ;;
    esac

    local electron_url="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-linux-${electron_arch}.zip"
    local electron_zip="$build_dir/electron.zip"
    local electron_dir="$build_dir/electron"

    log_info "Downloading Electron v$ELECTRON_VERSION for $electron_arch..."
    download_with_retry "$electron_url" "$electron_zip"
    verify_file "$electron_zip"

    log_info "Extracting Electron..."
    mkdir -p "$electron_dir"
    cd "$electron_dir"
    unzip -q "$electron_zip"

    # Verify electron binary exists
    if [ ! -f "$electron_dir/electron" ]; then
        log_error "Electron binary not found after extraction"
        exit 1
    fi

    # Make electron executable
    chmod +x "$electron_dir/electron"

    log_success "Electron v$ELECTRON_VERSION extracted successfully"
    export ELECTRON_PATH="$electron_dir"
}

extract_installer() {
    local build_dir="$1"
    local installer_path="$build_dir/Claude-Setup-x64.exe"

    log_info "Extracting installer..."
    cd "$build_dir"

    # Extract the main installer
    7z x -y "$installer_path"
    verify_file "AnthropicClaude-$CLAUDE_VERSION-full.nupkg"

    # Extract the nupkg file
    7z x -y "AnthropicClaude-$CLAUDE_VERSION-full.nupkg"

    # Verify extraction
    if [ ! -d "lib/net45" ]; then
        log_error "Extraction failed: lib/net45 directory not found"
        exit 1
    fi

    log_success "Installer extracted successfully"
}

build_patchy_cnb() {
    local project_dir="$1"
    local patchy_dir="$project_dir/patchy-cnb"

    if [ ! -d "$patchy_dir" ]; then
        log_error "patchy-cnb directory not found at $patchy_dir"
        exit 1
    fi

    log_info "Building patchy-cnb..."
    cd "$patchy_dir"

    # Install dependencies
    npm install --no-package-lock

    # Build the module
    npm run build

    # Find the compiled module
    find_patchy_cnb_module "$patchy_dir"
}

find_patchy_cnb_module() {
    local patchy_dir="$1"

    # Look for the compiled module in various possible locations and names
    local possible_paths=(
        "$patchy_dir/patchy-cnb.linux-x64-gnu.node"
        "$patchy_dir/index.node"
        "$patchy_dir/patchy-cnb.node"
        "$patchy_dir/target/release/libpatchy_cnb.so"
    )

    # Also search for any .node files
    while IFS= read -r -d '' file; do
        possible_paths+=("$file")
    done < <(find "$patchy_dir" -name "*.node" -type f -print0 2>/dev/null)

    for path in "${possible_paths[@]}"; do
        if [ -f "$path" ]; then
            PATCHY_CNB_PATH="$path"
            log_success "Found patchy-cnb module at: $PATCHY_CNB_PATH"
            export PATCHY_CNB_PATH
            return 0
        fi
    done

    log_error "Could not find compiled patchy-cnb module"
    log_info "Contents of patchy-cnb directory:"
    ls -la "$patchy_dir/"
    exit 1
}

process_app_asar() {
    local build_dir="$1"
    local patchy_cnb_path="$2"

    verify_file "$patchy_cnb_path"

    log_info "Processing app.asar files..."
    cd "$build_dir"

    # Create electron app directory
    ensure_dir "electron-app"

    # Copy app.asar files
    cp "lib/net45/resources/app.asar" "electron-app/"
    cp -r "lib/net45/resources/app.asar.unpacked" "electron-app/"

    cd "electron-app"

    # Extract app.asar
    asar extract app.asar app.asar.contents

    # Apply title bar fix
    log_info "Applying title bar fix..."
    SEARCH_BASE="app.asar.contents/.vite/renderer/main_window/assets"
    TARGET_PATTERN="MainWindowPage-*.js"

    log_info "Searching for '$TARGET_PATTERN' within '$SEARCH_BASE'..."
    # Find the target file recursively (ensure only one matches)
    TARGET_FILES=$(find "$SEARCH_BASE" -type f -name "$TARGET_PATTERN" 2>/dev/null)
    # Count non-empty lines to get the number of files found
    NUM_FILES=$(echo "$TARGET_FILES" | grep -c . || echo 0)
    log_info "Found $NUM_FILES matching files"

    if [ "$NUM_FILES" -eq 0 ]; then
        log_warning "No file matching '$TARGET_PATTERN' found within '$SEARCH_BASE'. Title bar fix not applied."
    elif [ "$NUM_FILES" -gt 1 ]; then
        log_warning "Expected exactly one file matching '$TARGET_PATTERN' within '$SEARCH_BASE', but found $NUM_FILES. Title bar fix not applied."
    else
        # Exactly one file found
        TARGET_FILE="$TARGET_FILES" # Assign the found file path
        log_info "Found target file: $TARGET_FILE"

        log_info "Removing '!' from 'if (!isWindows && isMainWindow) return null;' detection flag to enable title bar"
        log_info "Attempting to replace patterns like 'if(!VAR1 && VAR2)' with 'if(VAR1 && VAR2)' in $TARGET_FILE..."

        if command_exists perl; then
            perl -i -pe 's{if\(!(\w+)\s*&&\s*(\w+)\)}{if($1 && $2)}g' "$TARGET_FILE"

            # Verification: Check if the original pattern structure still exists
            if ! grep -q -E '!\w+&&\w+' "$TARGET_FILE"; then
                log_success "Successfully replaced patterns like '!VAR1&&VAR2' with 'VAR1&&VAR2' in $TARGET_FILE"
            else
                log_warning "Some instances of '!VAR1&&VAR2' might still exist in $TARGET_FILE."
            fi
        else
            log_error "Perl is required for title bar fix but not found. Please install perl."
        fi
    fi

    # Replace native bindings
    log_info "Replacing native bindings..."
    ensure_dir "app.asar.contents/node_modules/claude-native"
    ensure_dir "app.asar.unpacked/node_modules/claude-native"

    cp "$patchy_cnb_path" "app.asar.contents/node_modules/claude-native/claude-native-binding.node"
    cp "$patchy_cnb_path" "app.asar.unpacked/node_modules/claude-native/claude-native-binding.node"

    # Copy additional resources
    copy_additional_resources "$build_dir"

    # Repackage app.asar
    asar pack app.asar.contents app.asar

    log_success "app.asar processing completed"
}

copy_additional_resources() {
    local build_dir="$1"

    # Copy Tray icons
    ensure_dir "app.asar.contents/resources"
    if ls "$build_dir/lib/net45/resources/Tray"* >/dev/null 2>&1; then
        cp "$build_dir/lib/net45/resources/Tray"* "app.asar.contents/resources/"
        log_info "Copied Tray icons"
    else
        log_warning "No Tray icons found"
    fi

    # Copy i18n json files
    ensure_dir "app.asar.contents/resources/i18n"
    if ls "$build_dir/lib/net45/resources/"*.json >/dev/null 2>&1; then
        cp "$build_dir/lib/net45/resources/"*.json "app.asar.contents/resources/i18n/"
        log_info "Copied i18n files"
    else
        log_warning "No i18n files found"
    fi
}

create_appimage() {
    local build_dir="$1"
    local output_dir="$2"

    log_info "Creating AppImage structure..."

    # Detect architecture
    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            arch="x86_64"
            ;;
        aarch64|arm64)
            arch="aarch64"
            ;;
        armv7l|armhf)
            arch="armhf"
            ;;
        i386|i686)
            arch="i386"
            ;;
        *)
            log_warning "Unknown architecture: $arch, defaulting to x86_64"
            arch="x86_64"
            ;;
    esac

    # Download Electron for the target architecture
    download_electron "$build_dir" "$arch"

    local appdir="$build_dir/Claude.AppDir"
    create_appdir_structure "$appdir"
    extract_icons "$build_dir" "$appdir"
    copy_app_files "$build_dir" "$appdir"
    copy_electron_files "$build_dir" "$appdir"
    create_desktop_files "$appdir"
    create_scripts "$appdir"

    # Use APPIMAGE_VERSION for filename instead of CLAUDE_VERSION
    local appimage_name="Claude-$APPIMAGE_VERSION-claude-$CLAUDE_VERSION-$arch.AppImage"
    local appimage_path="$output_dir/$appimage_name"

    # Remove existing AppImage if it exists
    if [ -f "$appimage_path" ]; then
        log_info "Removing existing AppImage: $appimage_path"
        rm -f "$appimage_path"
    fi

    # Ensure no processes are using files in the AppDir
    sync
    sleep 1

    # Debug: Check what architectures are detected
    log_info "Checking architectures in AppDir..."
    find "$appdir" -type f -executable -exec file {} \; | grep -E "(ELF|PE32|Mach-O)" | head -10 | while read line; do
        log_info "Binary found: $line"
    done

    # Set ARCH environment variable for AppImageTool
    export ARCH="$arch"
    log_info "Set ARCH environment variable to: $arch"

    # Build the AppImage
    log_info "Building AppImage for architecture: $arch"
    log_info "AppImage version: $APPIMAGE_VERSION (Claude Desktop: $CLAUDE_VERSION)"
    cd "$build_dir"

    # Set ARCH environment variable for AppImageTool
    export ARCH="$arch"
    
    # Try building with different methods
    if ! ARCH="$arch" appimagetool --no-appstream "$appdir" "$appimage_path" 2>/dev/null; then
        log_warning "AppImageTool failed with --no-appstream, trying without..."
        if ! ARCH="$arch" appimagetool "$appdir" "$appimage_path"; then
            log_error "AppImage creation failed"
            return 1
        fi
    fi

    # Verify the AppImage was created
    if [ -f "$appimage_path" ]; then
        log_success "AppImage created successfully: $appimage_path"
        # Make it executable
        chmod +x "$appimage_path"
    else
        log_error "AppImage was not created: $appimage_path"
        return 1
    fi
}

create_appdir_structure() {
    local appdir="$1"

    ensure_dir "$appdir/usr/bin"
    ensure_dir "$appdir/usr/lib/claude-desktop"
    ensure_dir "$appdir/usr/lib/electron"
    ensure_dir "$appdir/usr/share/applications"
    ensure_dir "$appdir/usr/share/icons/hicolor/256x256/apps"
}

extract_icons() {
    local build_dir="$1"
    local appdir="$2"

    cd "$build_dir"

    if command_exists wrestool && command_exists icotool && [ -f "lib/net45/claude.exe" ]; then
        log_info "Extracting icons from claude.exe..."

        if wrestool -x -t 14 lib/net45/claude.exe -o claude.ico 2>/dev/null; then
            if icotool -x claude.ico 2>/dev/null; then
                # Extract icons of various sizes
                for size in 16 24 32 48 64 128 256; do
                    ensure_dir "$appdir/usr/share/icons/hicolor/${size}x${size}/apps"
                    local icon_file=$(find . -name "*${size}x${size}x32.png" 2>/dev/null | head -n 1)
                    if [ -n "$icon_file" ]; then
                        cp "$icon_file" "$appdir/usr/share/icons/hicolor/${size}x${size}/apps/claude-desktop.png"
                    fi
                done

                # Use the largest available icon for the AppImage
                for size in 256 128 64 48 32; do
                    local icon_file=$(find . -name "*${size}x${size}x32.png" 2>/dev/null | head -n 1)
                    if [ -n "$icon_file" ]; then
                        cp "$icon_file" "$appdir/claude-desktop.png"
                        log_success "Extracted ${size}x${size} icon for AppImage"
                        return
                    fi
                done
            fi
        fi
    fi

    # Fallback: create a placeholder icon
    log_warning "Could not extract icons, creating placeholder..."
    create_placeholder_icon "$appdir"
}

create_placeholder_icon() {
    local appdir="$1"

    if command_exists convert; then
        # Create a nice gradient icon with ImageMagick
        convert -size 256x256 \
            -background "linear-gradient(135deg,#667eea 0%,#764ba2 100%)" \
            -fill white -gravity center -pointsize 40 \
            -annotate 0 "Claude" \
            "$appdir/claude-desktop.png"
    else
        # Create a simple SVG icon
        cat > "$appdir/claude-desktop.svg" << 'EOF'
<svg width="256" height="256" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="grad" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:#667eea;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#764ba2;stop-opacity:1" />
    </linearGradient>
  </defs>
  <rect width="256" height="256" fill="url(#grad)" rx="20"/>
  <text x="128" y="140" font-family="Arial, sans-serif" font-size="36"
        fill="white" text-anchor="middle" font-weight="bold">Claude</text>
</svg>
EOF
        # Convert SVG to PNG if possible, otherwise use SVG
        if command_exists rsvg-convert; then
            rsvg-convert -w 256 -h 256 "$appdir/claude-desktop.svg" > "$appdir/claude-desktop.png"
            rm "$appdir/claude-desktop.svg"
        else
            mv "$appdir/claude-desktop.svg" "$appdir/claude-desktop.png"
        fi
    fi

    # Copy to standard icon location
    cp "$appdir/claude-desktop.png" "$appdir/usr/share/icons/hicolor/256x256/apps/claude-desktop.png"
}

copy_app_files() {
    local build_dir="$1"
    local appdir="$2"

    log_info "Copying application files..."
    cp -r "$build_dir/electron-app/app.asar" "$appdir/usr/lib/claude-desktop/"
    cp -r "$build_dir/electron-app/app.asar.unpacked" "$appdir/usr/lib/claude-desktop/"
}

copy_electron_files() {
    local build_dir="$1"
    local appdir="$2"

    log_info "Copying Electron runtime..."
    
    # Clean any existing electron files to avoid architecture conflicts
    if [ -d "$appdir/usr/lib/electron" ]; then
        rm -rf "$appdir/usr/lib/electron"
        ensure_dir "$appdir/usr/lib/electron"
    fi
    
    cp -r "$ELECTRON_PATH"/* "$appdir/usr/lib/electron/"

    # Ensure electron binary is executable
    chmod +x "$appdir/usr/lib/electron/electron"
    
    # Verify architecture consistency
    local electron_arch=$(file "$appdir/usr/lib/electron/electron" | grep -o 'x86-64\|x86_64\|i386\|aarch64\|ARM' | head -1)
    log_info "Electron binary architecture: $electron_arch"

    log_success "Electron runtime copied successfully"
}

create_desktop_files() {
    local appdir="$1"

    log_info "Creating desktop entry..."
    cat > "$appdir/usr/share/applications/claude-desktop.desktop" << EOF
[Desktop Entry]
Name=Claude Desktop
GenericName=AI Assistant
Comment=Claude Desktop - AI-powered assistant by Anthropic (v$CLAUDE_VERSION)
Exec=claude-desktop
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;Development;
MimeType=x-scheme-handler/claude;
Keywords=AI;Assistant;Claude;Anthropic;Chat;
StartupWMClass=Claude Desktop
EOF

    # Create AppStream metadata to avoid warnings
    ensure_dir "$appdir/usr/share/metainfo"
    cat > "$appdir/usr/share/metainfo/claude-desktop.appdata.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>claude-desktop</id>
  <name>Claude Desktop</name>
  <summary>AI-powered assistant by Anthropic</summary>
  <description>
    <p>
      Claude Desktop is an AI-powered assistant that can help you with various tasks
      including writing, analysis, coding, and creative projects.
    </p>
    <p>
      This AppImage packages Claude Desktop v$CLAUDE_VERSION with AppImage version $APPIMAGE_VERSION.
    </p>
  </description>
  <launchable type="desktop-id">claude-desktop.desktop</launchable>
  <url type="homepage">https://claude.ai</url>
  <categories>
    <category>Office</category>
    <category>Utility</category>
    <category>Development</category>
  </categories>
  <keywords>
    <keyword>AI</keyword>
    <keyword>Assistant</keyword>
    <keyword>Claude</keyword>
    <keyword>Anthropic</keyword>
    <keyword>Chat</keyword>
  </keywords>
  <releases>
    <release version="$APPIMAGE_VERSION" date="$(date +%Y-%m-%d)">
      <description>
        <p>AppImage version $APPIMAGE_VERSION with Claude Desktop $CLAUDE_VERSION</p>
      </description>
    </release>
  </releases>
</component>
EOF

    # Create symlink for AppImage
    ln -sf usr/share/applications/claude-desktop.desktop "$appdir/claude-desktop.desktop"
}

create_scripts() {
    local appdir="$1"

    # Create AppRun script
    log_info "Creating AppRun script..."
    cat > "$appdir/AppRun" << 'EOF'
#!/bin/bash
SELF=$(readlink -f "$0")
HERE=${SELF%/*}

# Set up environment
export PATH="${HERE}/usr/bin:${PATH}"
export LD_LIBRARY_PATH="${HERE}/usr/lib:${LD_LIBRARY_PATH}"

# Handle URL protocol
if [ "$1" = "claude://" ] || [[ "$1" == claude://* ]]; then
    exec "${HERE}/usr/lib/electron/electron" "${HERE}/usr/lib/claude-desktop/app.asar" --gtk-version=3 --enable-features=WaylandWindowDecorations --ozone-platform-hint=auto "$@"
else
    exec "${HERE}/usr/lib/electron/electron" "${HERE}/usr/lib/claude-desktop/app.asar" --gtk-version=3 --enable-features=WaylandWindowDecorations --ozone-platform-hint=auto "$@"
fi
EOF
    chmod +x "$appdir/AppRun"

    # Create launcher script
    log_info "Creating launcher script..."
    cat > "$appdir/usr/bin/claude-desktop" << 'EOF'
#!/bin/bash
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
export LD_LIBRARY_PATH="${SCRIPT_DIR}/../lib:${LD_LIBRARY_PATH}"
exec "${SCRIPT_DIR}/../lib/electron/electron" "${SCRIPT_DIR}/../lib/claude-desktop/app.asar" --gtk-version=3 --enable-features=WaylandWindowDecorations --ozone-platform-hint=auto "$@"
EOF
    chmod +x "$appdir/usr/bin/claude-desktop"
}
