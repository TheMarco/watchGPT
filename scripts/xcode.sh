#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
project="$repo_root/WatchGPT.xcodeproj"
scheme="WatchGPTPhone"
configuration="Debug"
derived_root="/tmp/watchgpt-derived-data"

unsigned_build() {
  action="$1"
  derived_path="$2"

  xcodebuild \
    -quiet \
    -project "$project" \
    -scheme "$scheme" \
    -configuration "$configuration" \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$derived_path" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    ENABLE_PREVIEWS=NO \
    "$action"
}

simulator_build() {
  action="$1"
  derived_path="$2"
  destination="${WATCHGPT_TEST_DESTINATION:-generic/platform=iOS Simulator}"

  xcodebuild \
    -quiet \
    -project "$project" \
    -scheme "$scheme" \
    -configuration "$configuration" \
    -destination "$destination" \
    -derivedDataPath "$derived_path" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    ENABLE_PREVIEWS=NO \
    "$action"
}

case "${1:-}" in
  build)
    unsigned_build build "$derived_root/build"
    ;;
  analyze)
    unsigned_build analyze "$derived_root/analyze"
    ;;
  test-build)
    # Compile the hosted XCTest bundle against device SDKs so this check does
    # not depend on locally installed simulator runtimes. `test` below remains
    # the command that actually launches XCTest in a selected simulator.
    unsigned_build build-for-testing "$derived_root/test-build"
    ;;
  test)
    if [ -z "${WATCHGPT_TEST_DESTINATION:-}" ]; then
      echo "error: WATCHGPT_TEST_DESTINATION must name an available simulator." >&2
      echo "Example: WATCHGPT_TEST_DESTINATION='platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' npm run test:simulator" >&2
      exit 64
    fi
    simulator_build test "$derived_root/test"
    ;;
  *)
    echo "usage: $0 {build|analyze|test-build|test}" >&2
    exit 64
    ;;
esac
