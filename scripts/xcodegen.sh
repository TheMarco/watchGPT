#!/bin/sh

set -eu

expected_version="2.44.1"

if command -v mint >/dev/null 2>&1; then
  exec mint run xcodegen "$@"
fi

if command -v xcodegen >/dev/null 2>&1; then
  installed_version="$(xcodegen version | sed -n 's/^Version: //p')"

  if [ "$installed_version" = "$expected_version" ]; then
    exec xcodegen "$@"
  fi

  echo "error: XcodeGen $expected_version is required; found $installed_version." >&2
  echo "Install Mint with 'brew install mint', then run 'npm run tools:bootstrap'." >&2
  exit 1
fi

echo "error: XcodeGen $expected_version is required." >&2
echo "Install Mint with 'brew install mint', then run 'npm run tools:bootstrap'." >&2
exit 1
