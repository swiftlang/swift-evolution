#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift.org open source project
##
## Copyright (c) 2026 Apple Inc. and the Swift project authors
## Licensed under Apache License v2.0 with Runtime Library Exception
##
## See https://swift.org/LICENSE.txt for license information
## See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
##
##===----------------------------------------------------------------------===##

set -Eeuo pipefail
shopt -s failglob
IFS=$'\n\t'

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

readonly check_mode="${1:?check-mode argument required (full|pull_request)}"
shift || true
readonly extractor_exec="${EXTRACTOR_EXEC:?EXTRACTOR_EXEC must point to the built swift-evolution-metadata-extractor binary}"
readonly summary_file="${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY must be available or set to an arbitrary file (e.g. in /tmp)}"

# Extract proposal metadata as JSON.
# Expects: extract_targets (array of proposal file paths), json_path (output file).
extract_json() {
  : "${json_path:?json_path must be set}"
  [[ "${#extract_targets[@]}" -gt 0 ]] || fatal "extract_targets must not be empty"

  local output
  if ! output="$("${extractor_exec}" extract "${extract_targets[@]}" --output-path "${json_path}" 2>&1)"; then
    printf '%s\n' "${output}" >&2
    fatal "extractor failed to run"
  fi
}

# Prints the number of errors (excludes warnings) across all extracted proposals.
# Expects: json_path.
error_count() {
  : "${json_path:?json_path must be set}"

  jq '[.proposals[].errors[]?] | length' "${json_path}"
}

# Appends a markdown section to the GitHub job summary.
# Expects: json_path, summary_heading.
append_summary() {
  : "${json_path:?json_path must be set}"
  : "${summary_heading:?summary_heading must be set}"

  {
    echo "### \`${summary_heading}\`"
    jq -r '
      # One markdown bullet per issue: "- <icon> [<code>] <message>".
      def bullet(icon): "- \(icon) [\(.code)] \(.message)";
      .proposals[]
      | (.errors[]?   | bullet("❌")),
        (.warnings[]? | bullet("⚠️"))
    ' "${json_path}"
  } >> "${summary_file}"

  local issues_count
  issues_count="$(jq '[.proposals[].errors[]?, .proposals[].warnings[]?] | length' "${json_path}")"
  [[ "$issues_count" -gt 0 ]] || echo "- ✅ no issues found" >> "${summary_file}"
}

# Percent-encode message data the way the Actions runner parses it: escape %
# first, then CR/LF. Mirrors escapeData() in actions/toolkit:
# https://github.com/actions/toolkit/blob/main/packages/core/src/command.ts
# Expects: data. Prints the escaped string.
escapeData() {
  : "${data:?data must be set}"

  local escaped="$data"
  escaped="${escaped//'%'/%25}"
  escaped="${escaped//$'\r'/%0D}"
  escaped="${escaped//$'\n'/%0A}"
  printf '%s' "$escaped"
}

# Emits a GitHub annotation per issue so both errors and warnings show up in the PR's Files tab.
# Expects: json_path, annotation_file.
emit_annotations() {
  : "${json_path:?json_path must be set}"
  : "${annotation_file:?annotation_file must be set}"

  # jq emits each issue as three NUL-terminated fields (kind, code, message); NUL
  # cannot appear in the text, so a tab or newline in a message never desyncs parsing.
  local -a fields
  mapfile -d '' -t fields < <(
    jq -j '
      .proposals[]
      | (.errors[]?, .warnings[]?)
      | "\(.kind)\u0000\(.code)\u0000\(.message)\u0000"
    ' "${json_path}"
  )

  # Each issue must contribute exactly three fields, so the total is a multiple of 3.
  (( ${#fields[@]} % 3 == 0 )) || fatal "expected NUL fields in groups of 3, got ${#fields[@]} (json_path=${json_path}, annotation_file=${annotation_file}, fields='${fields[*]}')"
  local i kind code message
  for ((i = 0; i < ${#fields[@]}; i += 3)); do
    kind="${fields[i]}"
    code="${fields[i + 1]}"
    message="${fields[i + 2]}"

    printf '::%s file=%s,line=1,title=Proposal validation failure (%s)::%s\n' \
      "${kind}" "${annotation_file}" "${code}" "$(data="$message" escapeData)"
  done
}

json_path="$(mktemp)"
readonly json_path
had_errors=false

case "$check_mode" in
  full)
    # Skip renamed-proposal redirect stubs (e.g. 0519-borrow-inout-types.md) like the extractor tool does.
    mapfile -t extract_targets < <(grep -LiE 'renamed as part of the evolution process' proposals/*.md)

    log "Validating ${#extract_targets[@]} proposal(s)..."

    extract_json
    summary_heading="All proposals" append_summary

    [[ "$(error_count)" == "0" ]] || had_errors=true
    ;;
  pull_request)
    base="${1:?base ref required for pull_request check-mode}"
    # `:(glob)` so subdirectories like `proposals/testing` are excluded.
    mapfile -t changed_files < <(git diff --name-only --diff-filter=ACMR "${base}...HEAD" -- ':(glob)proposals/*.md')

    if [[ "${#changed_files[@]}" -eq 0 ]]; then
      echo "No proposal files were changed; exiting..." | tee -a "${summary_file}" >&2
      exit 0
    fi

    log "Validating ${#changed_files[@]} changed proposal(s)..."

    for file in "${changed_files[@]}"; do
      echo "::group::Validating ${file}"

      extract_targets=("$file")
      extract_json

      summary_heading="$file" append_summary
      annotation_file="$file" emit_annotations

      echo "::endgroup::"

      [[ "$(error_count)" == "0" ]] || had_errors=true
    done
    ;;
  *)
    fatal "Unknown check-mode: ${check_mode} (expected full|pull_request)"
    ;;
esac

! "$had_errors" || fatal "❌ Found errors in target proposals."

log "✅ Found no errors in target proposals."
