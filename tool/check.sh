#!/usr/bin/env bash
# Auri's pre-merge gate. GitHub Actions is off for Brew repos (see AGENTS.md),
# so run this locally before merging and report its real output.
#
#   tool/check.sh            format, analyze, tests + coverage floor
#   tool/check.sh --build    also flutter build web and a debug APK
#
# MIN_COVERAGE (default below) fails the run if line coverage drops under it.
set -euo pipefail

cd "$(dirname "$0")/.."
MIN_COVERAGE="${MIN_COVERAGE:-72}"

step() { printf '\n== %s\n' "$*"; }

step 'flutter pub get'
flutter pub get >/dev/null

step 'dart format (check only)'
dart format --output=none --set-exit-if-changed lib test

step 'flutter analyze'
flutter analyze

step 'flutter test --coverage'
flutter test --coverage

step "line coverage (floor ${MIN_COVERAGE}%)"
awk -F: -v min="$MIN_COVERAGE" '
  /^LF:/ { total += $2 }
  /^LH:/ { hit += $2 }
  END {
    if (total == 0) { print "no coverage data"; exit 1 }
    pct = 100 * hit / total
    printf "%d/%d lines = %.1f%%\n", hit, total, pct
    if (pct < min) { printf "below the %s%% floor\n", min; exit 1 }
  }' coverage/lcov.info

if [[ "${1:-}" == "--build" ]]; then
  step 'flutter build web'
  flutter build web
  step 'flutter build apk --debug'
  flutter build apk --debug
fi

step 'all checks passed'
