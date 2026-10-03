#!/bin/sh
# Runs Scarpe from your clone without disturbing the person at this machine: dialogs, sounds and
# the clipboard go to Scarpe's stand-ins, and the app's HOME is a scratch folder of its own.
SCARPE="${SCARPE:-$HOME/scarpe}"                          # your clone of Scarpe
APP_DIR="$(cd "$(dirname "$0")" && pwd)"                  # the folder this script sits in
BOX="${SCARPE_HOME:-${TMPDIR:-/tmp}/scarpe-home-$(basename "$APP_DIR")}"  # this app's HOME
RUBY="$(cd "$SCARPE" && ruby -e 'print RbConfig.ruby')"   # the clone's Ruby, past any version-manager shim
mkdir -p "$BOX"
exec env PATH="$SCARPE/spec/support/fakebin:$PATH" HOME="$BOX" \
  SPEC_TRAP_FILE="$BOX/trapped.txt" SPEC_CLIPBOARD_FILE="$BOX/clipboard.txt" \
  RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}" \
  BUNDLE_GEMFILE="$SCARPE/Gemfile" "$RUBY" "$SCARPE/exe/scarpe" "$@" --dev
