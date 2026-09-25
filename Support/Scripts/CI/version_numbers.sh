#!/usr/bin/env bash
# shellcheck disable=SC1091

#  PactSwiftMockService
#
#  Created by Marko Justinek on 09/12/24.
#  Copyright © 2024 Marko Justinek. All rights reserved.
#  Permission to use, copy, modify, and/or distribute this software for any
#  purpose with or without fee is hereby granted, provided that the above
#  copyright notice and this permission notice appear in all copies.
#
#  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
#  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
#  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
#  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
#  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
#  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
#  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#

VERSION_NUMBER_SCRIPT_SOURCE_DIR="${BASH_SOURCE[0]%/*}"
source "$VERSION_NUMBER_SCRIPT_SOURCE_DIR/../Config/config.sh"

##############################################
# Versioning model
#
# A release of this project is named after the libpact_ffi it wraps: pinning
# 'libpact_ffi-v0.5.9' releases 'v0.5.9'. The version therefore comes from
# $LIBPACT_FFI_VERSION_FILE, not from incrementing whatever was released last.
#
# The one exception is a Swift-side-only fix against an already-released FFI
# version. There is no spare component for it — SwiftPM resolves these tags as
# semver, so the next release has to sort higher — so '-v patch' deliberately
# drifts the patch ahead of the FFI version (FFI 0.5.9 already out as v0.5.9 ->
# v0.5.10). The release notes still name the real FFI version, because they are
# generated from $LIBPACT_FFI_VERSION_FILE.
##############################################

# Every tag on the release repo, newest first. Empty output when it has none.
#
# 'jq -r .name' on a missing value prints the string "null", which is not empty
# and so defeats every '[ -z ... ]' fallback downstream — that is how an untagged
# release repo produced tags like 'vnull.1.0'. '// empty' prints nothing instead.
function release_repo_tags {
  local response
  if ! response=$(curl --silent --show-error --fail \
    "https://api.github.com/repos/$REPO_OWNER/$RELEASE_REPO_NAME/tags" 2>&1); then
    die "Could not read tags from $REPO_OWNER/$RELEASE_REPO_NAME:
  $response"
  fi

  echo "$response" | jq -r '.[].name // empty'
}

function latest_tag {
  release_repo_tags | head -1
}

# The libpact_ffi version this repository is pinned to, without the tag prefix:
# 'libpact_ffi-v0.5.9' -> '0.5.9'.
function libpact_ffi_version {
  local raw
  raw=$(awk 'NR==1 {print; exit}' "$LIBPACT_FFI_VERSION_FILE")
  raw=${raw#libpact_ffi-}
  echo "${raw#v}"
}

# Splits a dotted version into three components, defaulting missing ones to 0,
# so malformed input cannot leak an empty string into the arithmetic below.
function __version_components {
  local major minor patch
  IFS='.' read -r major minor patch <<< "${1#v}"
  echo "${major:-0} ${minor:-0} ${patch:-0}"
}

# True when $1 sorts strictly higher than $2.
function __version_greater {
  local a1 a2 a3 b1 b2 b3
  read -r a1 a2 a3 <<< "$(__version_components "$1")"
  read -r b1 b2 b3 <<< "$(__version_components "$2")"

  if [ "$a1" -ne "$b1" ]; then [ "$a1" -gt "$b1" ]; return; fi
  if [ "$a2" -ne "$b2" ]; then [ "$a2" -gt "$b2" ]; return; fi
  [ "$a3" -gt "$b3" ]
}

function __bump_patch {
  local major minor patch
  read -r major minor patch <<< "$(__version_components "$1")"
  echo "$major.$minor.$((patch + 1))"
}

# Works out the version to release.
#
# Modes:
#   ffi    (default) — release the pinned libpact_ffi version
#   patch            — Swift-side-only re-release; drifts ahead of the FFI version
function generate_version_number {
  local mode="${VERSION_PART:-${1:-ffi}}"
  local description="${DESCRIPTION:-${2:-}}"

  local ffi_version
  ffi_version=$(libpact_ffi_version)
  if [ -z "$ffi_version" ]; then
    die "Could not read a version from '$LIBPACT_FFI_VERSION_FILE'."
  fi

  local latest_version
  latest_version=$(latest_tag)
  latest_version=${latest_version#v}
  latest_version=${latest_version%% -*} # tolerate legacy 'v1.2.0 - description' tags

  local new_version
  case "$mode" in
    ffi)
      new_version=$ffi_version

      if [ -n "$latest_version" ] && ! __version_greater "$new_version" "$latest_version"; then
        die "v$new_version is not ahead of the latest release v$latest_version.
  '$LIBPACT_FFI_VERSION_FILE' pins libpact_ffi-v$ffi_version, which has been released already.
  Bump '$LIBPACT_FFI_VERSION_FILE' and rebuild, or use '-v patch' for a Swift-side-only re-release."
      fi
      ;;

    patch)
      # Ahead of both the last release and the FFI version, so the tag sorts
      # higher whichever of the two is further along.
      new_version=$ffi_version
      if [ -n "$latest_version" ]; then
        local bumped
        bumped=$(__bump_patch "$latest_version")
        if __version_greater "$bumped" "$new_version"; then
          new_version=$bumped
        fi
      fi

      if [ "$new_version" != "$ffi_version" ]; then
        echo "ℹ️ Swift-side-only release: v$new_version wraps libpact_ffi-v$ffi_version." >&2
      fi
      ;;

    major|minor)
      die "'-v $mode' is no longer supported.
  Versions track libpact_ffi: edit '$LIBPACT_FFI_VERSION_FILE' and release with '-v ffi' (the default).
  Use '-v patch' only for a Swift-side-only re-release against the same libpact_ffi."
      ;;

    *)
      die "Invalid version mode '$mode'. Expected 'ffi' or 'patch'."
      ;;
  esac

  local new_tag="v$new_version"

  if [ -n "$description" ]; then
    new_tag="$new_tag - $description"
  fi

  # Guard against re-using a tag. This has to be checked against the RELEASE repo:
  # the tags that matter live there, and a fresh clone of this repository has none
  # of them, so the old 'git tag --list' check could never fire.
  if release_repo_tags | grep -qx "$new_tag"; then
    die "Tag '$new_tag' already exists on $REPO_OWNER/$RELEASE_REPO_NAME."
  fi

  echo "$new_tag"
}

# A git revision range for the release notes.
#
# The version tags live on the release repo; this repository is tagged separately
# by the "Tag on PR merge" workflow, and a fresh clone may carry no tags at all.
# Falling back to the full history beats '..HEAD', which git reads as 'HEAD..HEAD'
# and which therefore yields silently empty release notes.
function release_notes_range {
  local tag="$1"

  if [ -n "$tag" ] && git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null 2>&1; then
    echo "$tag..HEAD"
  else
    echo "HEAD"
  fi
}
