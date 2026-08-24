#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
xcodegen_runner="$repo_root/scripts/xcodegen.sh"

generate_project() {
  sh "$xcodegen_runner" generate \
    --spec "$repo_root/project.yml" \
    --project "$repo_root" \
    --project-root "$repo_root" \
    --no-env
}

verify_project() {
  verify_root="$(mktemp -d /tmp/watchgpt-project-verify.XXXXXX)"
  trap 'rm -rf "$verify_root"' EXIT HUP INT TERM

  mkdir "$verify_root/repo"
  rsync -a \
    --exclude .git \
    --exclude .env \
    --exclude node_modules \
    --exclude DerivedData \
    --exclude LocalSecrets.xcconfig \
    "$repo_root/" "$verify_root/repo/"

  mv "$verify_root/repo/WatchGPT.xcodeproj" "$verify_root/expected.xcodeproj"

  (
    cd "$verify_root/repo"
    sh "$xcodegen_runner" generate \
      --spec "$verify_root/repo/project.yml" \
      --project "$verify_root/repo" \
      --project-root "$verify_root/repo" \
      --no-env \
      --quiet
  )

  mismatch=0
  for relative_path in \
    project.pbxproj \
    project.xcworkspace/contents.xcworkspacedata \
    xcshareddata/xcschemes/WatchGPTPhone.xcscheme
  do
    expected="$verify_root/expected.xcodeproj/$relative_path"
    generated="$verify_root/repo/WatchGPT.xcodeproj/$relative_path"

    if ! cmp -s "$expected" "$generated"; then
      echo "error: WatchGPT.xcodeproj/$relative_path is not in sync with project.yml or the source tree." >&2
      diff -u "$expected" "$generated" || true
      mismatch=1
    fi
  done

  if [ "$mismatch" -ne 0 ]; then
    echo "Run 'npm run project:generate' and commit the regenerated project." >&2
    exit 1
  fi

  echo "WatchGPT.xcodeproj is in sync with project.yml and the source tree."
}

case "${1:-}" in
  generate)
    generate_project
    ;;
  verify)
    verify_project
    ;;
  *)
    echo "usage: $0 {generate|verify}" >&2
    exit 64
    ;;
esac
