#!/usr/bin/env bash
set -euo pipefail

pubspec="pubspec.yaml"
changelog="CHANGELOG.md"
fastlane_dir="fastlane/metadata/android/en-US/changelogs"

version_line="$(grep -E '^version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+(\+[0-9]+)?[[:space:]]*$' "$pubspec" || true)"
if [[ -z "$version_line" ]]; then
  echo "Could not find a plain semver version line in $pubspec" >&2
  exit 1
fi

version="${version_line#version:}"
version="${version//[[:space:]]/}"
version_name="${version%%+*}"

IFS=. read -r major minor patch <<< "$version_name"
for part in "$major" "$minor" "$patch"; do
  if [[ ! "$part" =~ ^[0-9]+$ ]]; then
    echo "Version '$version_name' is not major.minor.patch" >&2
    exit 1
  fi
done

if (( minor > 99 || patch > 99 )); then
  echo "Version '$version_name' cannot be encoded as major * 10000 + minor * 100 + patch" >&2
  exit 1
fi

version_code=$((major * 10000 + minor * 100 + patch))
replacement="version: ${version_name}+${version_code}"

tmp_pubspec="$(mktemp)"
awk -v replacement="$replacement" '
  BEGIN { replaced = 0 }
  /^version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+(\+[0-9]+)?[[:space:]]*$/ && replaced == 0 {
    print replacement
    replaced = 1
    next
  }
  { print }
  END {
    if (replaced == 0) {
      exit 1
    }
  }
' "$pubspec" > "$tmp_pubspec"
mv "$tmp_pubspec" "$pubspec"

mkdir -p "$fastlane_dir"
tmp_notes="$(mktemp)"

awk -v version="$version_name" '
  BEGIN {
    in_section = 0
    found = 0
    version_pattern = version
    gsub(/\./, "\\.", version_pattern)
  }
  $0 ~ "^##[[:space:]]+(\\[v?" version_pattern "\\](\\([^)]*\\))?|v?" version_pattern ")([[:space:]-]|$)" {
    in_section = 1
    found = 1
    next
  }
  in_section && /^##[[:space:]]+/ {
    exit
  }
  in_section {
    print
  }
  END {
    if (found == 0) {
      exit 1
    }
  }
' "$changelog" |
  sed -e 's/[[:space:]]*$//' |
  awk '
    NF { seen = 1 }
    seen { lines[++count] = $0 }
    END {
      while (count > 0 && lines[count] == "") {
        count--
      }
      for (i = 1; i <= count; i++) {
        print lines[i]
      }
    }
  ' > "$tmp_notes"

if [[ ! -s "$tmp_notes" ]]; then
  echo "Changelog section for $version_name was empty" >&2
  exit 1
fi

# F-Droid caps changelogs at 500 characters and silently cuts the rest, so stop
# here and let the release PR be edited rather than ship a note for users that
# ends mid-sentence.
note_length="$(wc -m < "$tmp_notes" | tr -d '[:space:]')"
if (( note_length > 500 )); then
  echo "Changelog section for $version_name is $note_length characters; F-Droid allows 500." >&2
  echo "Shorten the $version_name section in $changelog on the release PR." >&2
  exit 1
fi

split_version_codes=(
  "$((version_code * 10 + 1))"
  "$((version_code * 10 + 2))"
  "$((version_code * 10 + 3))"
)

written_changelogs=()
for split_version_code in "${split_version_codes[@]}"; do
  fastlane_changelog="${fastlane_dir}/${split_version_code}.txt"
  cp "$tmp_notes" "$fastlane_changelog"
  written_changelogs+=("$fastlane_changelog")
done
rm "$tmp_notes"

echo "Set pubspec version to ${version_name}+${version_code}"
printf 'Wrote %s\n' "${written_changelogs[@]}"
