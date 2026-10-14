#!/bin/bash
# Builds DuoScribe.app into ./build and (with "run") opens it.
#   ./build.sh        build only
#   ./build.sh run    build, then launch
# Everything printed here is also saved to build.log.
cd "$(dirname "$0")" || exit 1

build() {
    echo "== DuoScribe build, $(date) =="
    sw_vers 2>/dev/null | tr '\n' ' '; echo
    swift --version 2>&1 | head -2
    echo

    swift build -c release || return 1

    local bin_dir app
    bin_dir="$(swift build -c release --show-bin-path)" || return 1
    app="build/DuoScribe.app"

    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$bin_dir/DuoScribe" "$app/Contents/MacOS/DuoScribe" || return 1
    cp Resources/Info.plist "$app/Contents/Info.plist" || return 1
    for bundle in "$bin_dir"/*.bundle; do
        [ -e "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
    done

    # Ad-hoc signature: enough for macOS to show the microphone and
    # system-audio permission prompts for this app.
    codesign --force --deep --sign - "$app" || return 1

    echo
    echo "BUILD OK: $(pwd)/$app"
}

build 2>&1 | tee build.log
status=${PIPESTATUS[0]}

if [ "$status" -ne 0 ]; then
    echo "BUILD FAILED (details in build.log)" | tee -a build.log
    exit "$status"
fi

if [ "${1:-}" = "run" ]; then
    open build/DuoScribe.app
fi
