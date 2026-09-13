#!/usr/bin/env zsh
# deploy.sh — install AutoCut plugin to SketchUp and provide a reload command
#
# On first run: detects or asks for the Plugins directory, saves it to ~/.zshenv
# as $SKETCHUP_PLUGINS_DIR for future runs.

set -euo pipefail

PLUGIN_ENTRY="AutoCut.rb"
PLUGIN_DIR="autocut"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_VAR="SKETCHUP_PLUGINS_DIR"
ZSHENV="$HOME/.zshenv"

# ── 1. Resolve Plugins directory ──────────────────────────────────────────────

if [[ -n "${SKETCHUP_PLUGINS_DIR:-}" ]]; then
  PLUGINS_DIR="$SKETCHUP_PLUGINS_DIR"
  echo "Using \$$ENV_VAR: $PLUGINS_DIR"
else
  echo "\$$ENV_VAR is not set."
  echo ""

  # Auto-detect: find the newest SketchUp version's Plugins folder
  DETECTED=""
  setopt nullglob 2>/dev/null || true
  for dir in "$HOME/Library/Application Support/SketchUp"*/SketchUp/Plugins; do
    [[ -d "$dir" ]] && DETECTED="$dir"
  done
  unsetopt nullglob 2>/dev/null || true

  if [[ -n "$DETECTED" ]]; then
    echo "Detected: $DETECTED"
    printf "Use this path? [Y/n] "
    read -r CONFIRM
    if [[ "$CONFIRM" =~ ^[Nn] ]]; then
      printf "Enter SketchUp Plugins path: "
      read -r PLUGINS_DIR
    else
      PLUGINS_DIR="$DETECTED"
    fi
  else
    echo "Could not auto-detect SketchUp Plugins directory."
    printf "Enter SketchUp Plugins path: "
    read -r PLUGINS_DIR
  fi

  # Expand ~ if the user typed it
  PLUGINS_DIR="${PLUGINS_DIR/#\~/$HOME}"

  if [[ ! -d "$PLUGINS_DIR" ]]; then
    echo "Error: directory not found: $PLUGINS_DIR"
    exit 1
  fi

  # Persist to ~/.zshenv so future shell sessions pick it up
  touch "$ZSHENV"
  if ! grep -qF "SKETCHUP_PLUGINS_DIR" "$ZSHENV" 2>/dev/null; then
    echo "" >> "$ZSHENV"
    echo "# SketchUp Plugins directory (set by AutoCut deploy.sh)" >> "$ZSHENV"
    echo "export SKETCHUP_PLUGINS_DIR=\"$PLUGINS_DIR\"" >> "$ZSHENV"
    echo "Saved to $ZSHENV — open a new terminal to pick it up automatically."
  fi
  export SKETCHUP_PLUGINS_DIR="$PLUGINS_DIR"
fi

# ── 2. Validate ───────────────────────────────────────────────────────────────

if [[ ! -d "$PLUGINS_DIR" ]]; then
  echo "Error: Plugins directory not found: $PLUGINS_DIR"
  exit 1
fi

# ── 3. Remove existing plugin ─────────────────────────────────────────────────

echo ""
echo "Removing old plugin..."
for target in "$PLUGINS_DIR/$PLUGIN_ENTRY" "$PLUGINS_DIR/$PLUGIN_DIR"; do
  if [[ -e "$target" ]]; then
    rm -rf "$target"
    echo "  removed: $target"
  fi
done

# ── 4. Copy new version ───────────────────────────────────────────────────────

echo "Copying new version from: $REPO_DIR"
for item in "$PLUGIN_ENTRY" "$PLUGIN_DIR"; do
  src="$REPO_DIR/$item"
  if [[ -e "$src" ]]; then
    cp -r "$src" "$PLUGINS_DIR/"
    echo "  copied:  $item"
  else
    echo "  warning: $src not found — skipping"
  fi
done

# ── 5. Reload ─────────────────────────────────────────────────────────────────

# Clears require cache for all autocut files, then reloads the entry point.
RELOAD_CMD='$LOADED_FEATURES.reject!{|f|f.include?("AutoCut")||f.include?("autocut")}; load(File.join(Sketchup.find_support_file("Plugins"),"AutoCut.rb"))'

echo ""
echo "Plugin installed to:"
echo "  $PLUGINS_DIR"
echo ""

if pgrep -xq "SketchUp" 2>/dev/null; then
  echo "SketchUp is running."
else
  echo "SketchUp is not running — start it to load the plugin automatically."
fi

echo ""
echo "To hot-reload without restarting SketchUp, paste into the Ruby Console"
echo "(Window → Ruby Console):"
echo ""
echo "  $RELOAD_CMD"
echo ""
printf '%s' "$RELOAD_CMD" | pbcopy
echo "↑ Copied to clipboard."
