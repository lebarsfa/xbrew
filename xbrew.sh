#!/usr/bin/env bash
set -euo pipefail

print_help() {
  cat <<'EOF'
xbrew - Install or reinstall a Homebrew formula or cask from a specific commit

Prerequisites:
  brew, git commands.

Installation:
  wget https://github.com/lebarsfa/xbrew/releases/latest/download/xbrew.sh
  sudo mv xbrew.sh /usr/local/bin/xbrew
  sudo chmod +x /usr/local/bin/xbrew

Usage:
  xbrew <install|reinstall> [--formula|--cask] [--dry-run] <formula or cask name> <version|commit-sha|raw-url> [tap]
  OR
  xbrew <install|reinstall> [--formula|--cask] [--dry-run] <raw-url> [tap]   # formula or cask name omitted, extracted from URL

Purpose:
  Create (if needed) a local Homebrew tap, fetch the exact <formula>.rb or
  <cask>.rb from the given version, commit SHA, or full raw.githubusercontent
  URL, then commit it into the tap, and run `brew install` or `brew reinstall`
  against the tap-qualified formula or cask.

Parameters:
  <install|reinstall>           Action to perform (install or reinstall).
  <formula or cask name>        Formula or cask name (e.g. doxygen).
  <version|commit-sha|raw-url>  Version or commit SHA in
                                homebrew-core/homebrew-cask or a full
                                raw.githubusercontent URL pointing to the 
                                formula/cask file.
  [tap]                         Optional tap name (default: "$USER/local").

Options:
  --formula    Treat target as a formula (default).
  --cask       Treat target as a cask.
  --dry-run    Useful to see what would be done, without performing any action.
  -h, --help   Show this help and exit.

How to find manually the raw URL or commit SHA on GitHub (web UI) for a given formula:
  1. Open the formula page in homebrew-core:
       https://github.com/Homebrew/homebrew-core/blob/master/Formula/<f>/<formula>.rb
     or
       https://github.com/Homebrew/homebrew-core/blob/master/Formula/<formula>.rb
     (replace <formula> with the formula name, e.g., doxygen, and <f> by its first letter, e.g. d, if the first letter is necessary; or check the output of brew info doxygen).
  2. Click the "History" button (top-right of the file view) to see commits that changed that file.
  3. Scan the commit list for the change that introduced the desired version
     (e.g. look for "1.9.6" or the version bump in the commit message or diff).
  4. Click "View code at this point" in the commit entry to view the file at that commit; then click "Raw".
     The browser address bar now shows the raw URL for that commit, for example:
       https://raw.githubusercontent.com/Homebrew/homebrew-core/<COMMIT_SHA>/Formula/doxygen.rb
  5. Copy that raw URL (or the commit SHA) and pass it to xbrew. Example:
       xbrew install https://raw.githubusercontent.com/Homebrew/homebrew-core/d2267b9f2ad247bc9c8273eb755b39566a474a70/Formula/doxygen.rb
Note: for casks, adapt to https://github.com/Homebrew/homebrew-cask/blob/master/Casks.

Examples:
  # Reinstall doxygen from a specific homebrew-core commit (default tap: $USER/local)
  xbrew reinstall doxygen d2267b9f2ad247bc9c8273eb755b39566a474a70
  brew pin doxygen
  
  # Reinstall cmake cask from a specific homebrew-cask commit
  xbrew reinstall --cask cmake 06eed90d6268ed8c26e23b0458a43f8d3317f66c

  # Reinstall a cask from a raw URL (type inferred from URL)
  xbrew reinstall https://raw.githubusercontent.com/Homebrew/homebrew-cask/06eed90d6268ed8c26e23b0458a43f8d3317f66c/Casks/c/cmake.rb

  # Reinstall from a version (may be slow and inaccurate, as it scans commit history for matches)
  xbrew reinstall doxygen 1.9.6

  # Install using a full raw URL treated as a formula, and a custom tap
  xbrew install --formula \
    https://raw.githubusercontent.com/Homebrew/homebrew-core/d2267b9f2ad247bc9c8273eb755b39566a474a70/Formula/doxygen.rb \
    myuser/old

Behavior and notes:
  - If you pass only a full raw URL, the script will try to extract the name
    and type from the URL path (/Formula/ or /Casks/, strip .rb). Prefer URLs
    containing those paths.
  - If you pass a name and version, the script will try to find the right 
    commit by scanning homebrew-core or homebrew-cask commit history for that
    formula/cask until it finds a match.
    For now, this can be slow and inaccurate.
    export GITHUB_TOKEN=ghp_XXX
    can be run before to possibly speed up GitHub API requests and increase 
    rate limits, see https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens.
  - The script commits the downloaded file into a local tap (Formula/ or 
    Casks/) and then runs brew install or brew reinstall (with --cask for 
    casks); it will not pin the formula or cask.
  - Use a trusted commit or URL only; the script does not sandbox or validate
    formula contents beyond a non-empty download check.
EOF
}

# Helper: test whether a URL exists (use HEAD; fall back to GET if HEAD unsupported)
url_exists() {
  local url="$1"
  shift
  local extra_args=("$@")

  local normalized=()
  local arg
  for arg in "${extra_args[@]}"; do
    [ -z "$arg" ] && continue   # skip empty args
    if [[ $arg == -H* && $arg == *' '* ]]; then
      normalized+=("${arg%% *}" "${arg#* }")
    else
      normalized+=("$arg")
    fi
  done

  # try HEAD first (silence stderr)
  if curl -fsI --retry 2 --retry-delay 1 "${normalized[@]}" "$url" >/dev/null 2>/dev/null; then
    return 0
  fi

  # fallback to lightweight GET (also silence stderr)
  if curl -fsS --retry 2 --retry-delay 1 --max-time 10 -o /dev/null "${normalized[@]}" "$url" >/dev/null 2>/dev/null; then
    return 0
  fi

  return 1
}

# Helper: test whether a string looks like a URL
is_url() {
  [[ "$1" =~ ^https?:// ]]
}

# Helper: find the raw URL for a given formula/cask name and version or commit by scanning homebrew-core or homebrew-cask commit history
homebrew_find_rb() {
  NAME="$1"
  SECOND="$2"            # either VERSION or COMMIT SHA
  TYPE="${3:-formula}"    # "formula" or "cask"
  UA="hb-finder/1.0"
  #SLEEP_SHORT=0.05
  #SLEEP_PAGE=0.2  
  SLEEP_SHORT=0
  SLEEP_PAGE=0
  MAX_PAGES=1000000
  PAGE=1
  AUTH_HEADER=""
  [ -n "${GITHUB_TOKEN:-}" ] && AUTH_HEADER="-H Authorization: token ${GITHUB_TOKEN}"
  : ${DEBUG:=0}

  if [ -z "$NAME" ]; then
    printf '%s\n' "Usage: homebrew_find_rb <NAME> [VERSION|COMMIT] [TYPE]" >&2
    return 2
  fi

  FIRST_LETTER=$(printf '%s' "$NAME" | cut -c1 | tr '[:upper:]' '[:lower:]')

  if [ "$TYPE" = "cask" ]; then
    COMMITS_BASE="https://github.com/Homebrew/homebrew-cask/commits/HEAD"
    RAW_BASE="https://raw.githubusercontent.com/Homebrew/homebrew-cask"
    PATHS="Casks/${FIRST_LETTER}/${NAME}.rb Casks/${NAME}.rb"
  else
    COMMITS_BASE="https://github.com/Homebrew/homebrew-core/commits/HEAD"
    RAW_BASE="https://raw.githubusercontent.com/Homebrew/homebrew-core"
    PATHS="Formula/${FIRST_LETTER}/${NAME}.rb Formula/${NAME}.rb"
  fi

  # Determine whether SECOND looks like a commit SHA (7-40 hex chars)
  is_sha() {
    case "$1" in
      '' ) return 1 ;;
      * ) printf '%s' "$1" | grep -Eiq '^[0-9a-f]{7,40}$' && return 0 || return 1 ;;
    esac
  }

  # If SECOND is a SHA, check the explicit raw URLs and return the first that exists
  if is_sha "$SECOND"; then
    sha="$SECOND"
    for path_try in $PATHS; do
      url="${RAW_BASE}/${sha}/${path_try}"
      if url_exists "$url" -A "$UA" "$AUTH_HEADER"; then
        printf '%s\n' "$url"
        return 0
      fi
      sleep "$SLEEP_SHORT"
    done
    printf '%s\n' "No file found at commit ${sha} for ${NAME}" >&2
    return 3
  fi

  # Otherwise treat SECOND as a version (or empty)
  WANT_VER="$SECOND"

  # helper: convert name to CamelCase (optional class detection)
  to_camel() {
    printf '%s' "$1" \
      | sed -E 's/[-_]+/ /g' \
      | awk '{ for(i=1;i<=NF;i++){ $i = toupper(substr($i,1,1)) substr($i,2) } print }' \
      | tr -d ' '
  }
  CLASS_NAME=$(to_camel "$NAME")

  # Escape a string for use in a grep -E literal match
  escape_for_grepE() {
    printf '%s' "$1" | sed -E 's/[][^$.*/\\+?(){}|]/\\&/g'
  }

  build_ver_regex() {
    v="$1"
    ver_regex=""
    [ -z "$v" ] && return 0
    raw=$(printf '%s' "$v" | sed -E 's/^[vV]//; s/[^0-9.].*$//')
    IFS='.' read -r -a comps <<< "$raw"
    if [ "${#comps[@]}" -eq 0 ]; then
      return 0
    fi
    pattern=""
    for i in "${!comps[@]}"; do
      num="${comps[$i]}"
      num=$(printf '%s' "$num" | sed -E 's/[^0-9]//g')
      if [ -z "$num" ]; then
        num="${comps[$i]}"
      fi
      if [ "$i" -eq 0 ]; then
        pattern="${num}"
      else
        pattern="${pattern}([._-])${num}"
      fi
    done
    ver_regex="(^|[^0-9A-Za-z])[vV]?(${pattern}|Release[_-]?${pattern})([^0-9A-Za-z]|$)"
  }
  build_ver_regex "$WANT_VER"

  WANT_VER_ESC=$(escape_for_grepE "$WANT_VER")

  fetch_shas_from_page() {
    page_url="$1"
    curl -s $AUTH_HEADER -A "$UA" "$page_url" \
      | grep -oE '/Homebrew/(homebrew-core|homebrew-cask)/commit/[0-9a-f]{7,40}' \
      | sed -E 's#.*/commit/([0-9a-f]{7,40}).*#\1#' \
      | awk '!seen[$0]++'
  }

  sanitize_content() {
    awk '
      BEGIN { skip=0 }
      /^\s*(fails_with|resource|bottle|patch|on_macos|on_linux)\b/ { skip=1; next }
      /^\s*end\s*$/ && skip==1 { skip=0; next }
      skip==1 { next }
      { print }
    '
  }

  check_content_for_match() {
    sha="$1"
    path="$2"
    raw_url="${RAW_BASE}/${sha}/${path}"
    content=$(curl -s --max-time 10 -A "$UA" $AUTH_HEADER "$raw_url") || return 1
    [ -n "$content" ] || return 1
    no_comments=$(printf '%s' "$content" | sed -E 's/#.*$//')
    sanitized=$(printf '%s' "$no_comments" | sanitize_content)

    if [ -z "$WANT_VER" ]; then
      printf '%s\n' "$raw_url"
      return 0
    fi

    # Debug output to stderr so it is visible even when stdout is captured
    if [ "$DEBUG" -eq 1 ]; then
      printf '%s\n' "DEBUG: checking ${raw_url}" >&2
      printf '%s\n' "DEBUG: ver_regex=${ver_regex}" >&2
      printf '%s\n' "DEBUG: WANT_VER_ESC=${WANT_VER_ESC}" >&2
      # show a short preview of sanitized content for context
      printf '%s\n' "DEBUG: sanitized preview:" >&2
      printf '%s\n' "%s" "$(printf '%s' "$sanitized" | sed -n '1,40p')" >&2
    fi

    if [ -n "$ver_regex" ] && printf '%s' "$sanitized" | grep -Eiq "version[[:space:]]+['\"][^'\"]*"; then
      if printf '%s' "$sanitized" | grep -Eiq "version[[:space:]]+['\"][^'\"]*${ver_regex}[^'\"]*['\"]"; then
        printf '%s\n' "$raw_url"; return 0
      fi
    fi

    if [ -n "$ver_regex" ] && printf '%s' "$sanitized" | grep -Eiq "url[[:space:]]+.*${ver_regex}"; then
      printf '%s\n' "$raw_url"; return 0
    fi

    if [ -n "$ver_regex" ] && printf '%s' "$sanitized" | awk -v re="$ver_regex" '
      BEGIN{IGNORECASE=1; in_stable=0; found=0}
      /stable[[:space:]]+do/ { in_stable=1; next }
      /^\s*end\s*$/ && in_stable { in_stable=0; next }
      in_stable && $0 ~ re { found=1; exit }
      END{ exit !found }' ; then
      printf '%s\n' "$raw_url"; return 0
    fi

    return 1
  }

  check_commit_message_for_match() {
    sha="$1"
    path_try="$2"
    repo_base=$(printf '%s' "$COMMITS_BASE" | sed -E 's#/commits/HEAD##')
    commit_url="${repo_base}/commit/${sha}"
    title=$(curl -s $AUTH_HEADER -A "$UA" "$commit_url" \
      | sed -n 's/.*<title>\(.*\)<\/title>.*/\1/p' \
      | sed -E 's/ · .*//; s/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$title" ] || return 1

    if [ "$DEBUG" -eq 1 ]; then
      printf '%s\n' "DEBUG: commit ${sha} title: ${title}" >&2
    fi

    if [ -n "$WANT_VER" ] && [ -n "$ver_regex" ]; then
      if printf '%s' "$title" | grep -Eiq "$ver_regex"; then
        printf '%s\n' "${RAW_BASE}/${sha}/${path_try}"; return 0
      fi
      return 1
    fi

    if printf '%s' "$title" | grep -Eiq "${NAME}"; then
      printf '%s\n' "${RAW_BASE}/${sha}/${path_try}"; return 0
    fi

    return 1
  }

  # main loop: page through commits for each candidate path
  while [ "$PAGE" -le "$MAX_PAGES" ]; do
    for path_try in $PATHS; do
      page_url="${COMMITS_BASE}/${path_try}?page=${PAGE}"
      shas=$(fetch_shas_from_page "$page_url")
      if [ -z "$shas" ]; then
        continue
      fi

      # Use process substitution so the while loop runs in the current shell (not a subshell)
      while IFS= read -r sha; do
        [ -z "$sha" ] && continue

        if url=$(check_content_for_match "$sha" "$path_try"); then
          printf '%s\n' "$url"
          return 0
        fi

        if cm_url=$(check_commit_message_for_match "$sha" "$path_try"); then
          printf '%s\n' "$cm_url"
          return 0
        fi

        sleep "$SLEEP_SHORT"
      done < <(printf '%s\n' "$shas")

    done

    PAGE=$((PAGE + 1))
    sleep "$SLEEP_PAGE"
  done

  # last resort: return HEAD raw URL for the most likely path
  for path_try in $PATHS; do
    printf '%s\n' "${RAW_BASE}/HEAD/${path_try}"
    return 0
  done

  printf '%s\n' "No match found for ${NAME} ${WANT_VER}" >&2
  return 3
}

# Main script starts here

# Show help early if requested
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  print_help
  exit 0
fi

command -v brew >/dev/null 2>&1 || { echo "Error: brew not found in PATH."; exit 4; }
command -v git >/dev/null 2>&1 || { echo "Error: git not found in PATH."; exit 4; }

# Basic args parsing
ACTION="${1:-}"
shift || true

# Basic validation of action
if [[ -z "$ACTION" ]]; then
  print_help
  exit 2
fi

if [[ "$ACTION" != "install" && "$ACTION" != "reinstall" ]]; then
  echo "Error: action must be 'install' or 'reinstall'."
  echo
  print_help
  exit 2
fi

# Default type
TYPE="formula"

# Optional explicit type flag
if [[ "${1:-}" == "--formula" || "${1:-}" == "--cask" ]]; then
  TYPE="${1#--}"
  shift
fi

# Optional dry-run flag (allowed after optional --formula/--cask)
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  shift
fi

# Next argument must be either a name or a raw URL
TARGET="${1:-}"
shift || true

if [[ -z "$TARGET" ]]; then
  echo "Error: missing target (name or raw URL)."
  echo
  print_help
  exit 2
fi

# Optional next arg may be version or commit-sha or raw-url (only for long form)
POSSIBLE_VER_OR_COMMIT_OR_URL="${1:-}"
if [[ -n "$POSSIBLE_VER_OR_COMMIT_OR_URL" ]] && ! is_url "$POSSIBLE_VER_OR_COMMIT_OR_URL"; then
  # it's probably a version or commit SHA; keep it and shift
  VER_OR_COMMIT_OR_URL="$POSSIBLE_VER_OR_COMMIT_OR_URL"
  shift
else
  VER_OR_COMMIT_OR_URL="${POSSIBLE_VER_OR_COMMIT_OR_URL:-}"
  # if it was a URL we will handle it below; if empty, leave empty
  if [[ -n "$VER_OR_COMMIT_OR_URL" ]] && is_url "$VER_OR_COMMIT_OR_URL"; then
    # leave it as-is and shift
    shift
  fi
fi

# Optional tap argument (last positional)
TAP="${1:-${USER}/local}"

# Determine whether TARGET is a URL

RAW_URL=""
NAME=""

if is_url "$TARGET"; then
  RAW_URL="$TARGET"
  # Short form: TARGET is a raw URL; try to infer type and name from URL
  RAW_URL="$TARGET"
  TAP="${VER_OR_COMMIT_OR_URL:-$TAP}"  # if user passed only two args, second may be tap

  # Strip query string for matching
  url_path="${RAW_URL%%\?*}"

  # Try patterns that include optional first-letter subdir, prefer explicit Casks/Formula
  if [[ "$url_path" =~ /Formula/([^/]+)\.rb$ ]]; then
    NAME="${BASH_REMATCH[1]}"
    TYPE="formula"
  elif [[ "$url_path" =~ /Formula/[^/]+/([^/]+)\.rb$ ]]; then
    NAME="${BASH_REMATCH[1]}"
    TYPE="formula"
  elif [[ "$url_path" =~ /Casks/([^/]+)\.rb$ ]]; then
    NAME="${BASH_REMATCH[1]}"
    TYPE="cask"
  elif [[ "$url_path" =~ /Casks/[^/]+/([^/]+)\.rb$ ]]; then
    NAME="${BASH_REMATCH[1]}"
    TYPE="cask"
  else
    # Fallback: use basename and try to infer type from the path
    filename="$(basename "$url_path")"
    if [[ "$filename" =~ \.rb$ ]]; then
      NAME="${filename%.rb}"
    else
      NAME="$filename"
    fi

    if [[ "$url_path" =~ /Casks/ ]]; then
      TYPE="cask"
    elif [[ "$url_path" =~ /Formula/ ]]; then
      TYPE="formula"
    else
      echo "Warning: could not reliably extract name/type from URL. Using '${NAME}' as name and type '${TYPE}'."
      echo "Tip: prefer URLs containing /Formula/<name>.rb or /Casks/<name>.rb for reliable extraction."
    fi
  fi

else
  # TARGET is a name; use it and build RAW_URL from VER_OR_COMMIT_OR_URL (if provided)
  NAME="$TARGET"
  if [[ -z "${VER_OR_COMMIT_OR_URL:-}" ]]; then
    echo "Error: missing version or commit-sha or raw URL for name '${NAME}'."
    echo
    print_help
    exit 2
  fi

  if is_url "$VER_OR_COMMIT_OR_URL"; then
    RAW_URL="$VER_OR_COMMIT_OR_URL"
  else
    echo "Finding raw URL for ${TYPE} '${NAME}' with version/commit '${VER_OR_COMMIT_OR_URL}'... This might take a long time and be inaccurate."
    RAW_URL="$(homebrew_find_rb "$NAME" "$VER_OR_COMMIT_OR_URL" "$TYPE")"
  fi
fi

# Final sanity: ensure RAW_URL and NAME are set
if [[ -z "${NAME:-}" || -z "${RAW_URL:-}" ]]; then
  echo "Error: could not determine formula/cask name or source URL."
  echo
  print_help
  exit 2
fi

echo "Tap: $TAP"
echo "Action: $ACTION"
echo "Type: $TYPE"
echo "Name: $NAME"
echo "Source: $RAW_URL"
echo

if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run enabled, stopping before performing actions."
  exit 0
fi

# Create tap if missing
if ! brew tap | grep -Fxq "${TAP}"; then
  echo "Creating tap ${TAP}..."
  brew tap-new "${TAP}"
else
  echo "Tap ${TAP} already present."
fi

# Prepare tap repo and download file
TAP_REPO="$(brew --repo "${TAP}")"
if [[ "$TYPE" == "cask" ]]; then
  mkdir -p "${TAP_REPO}/Casks"
  DEST_DIR="Casks"
else
  mkdir -p "${TAP_REPO}/Formula"
  DEST_DIR="Formula"
fi

# portable mktemp
TMP_FILE=""
if TMP_FILE="$(mktemp 2>/dev/null)"; then
  :
elif TMP_FILE="$(mktemp -t xbrew.XXXXXX 2>/dev/null)"; then
  :
else
  echo "mktemp failed; cannot create temporary file."
  exit 5
fi
trap '[[ -f "$TMP_FILE" ]] && rm -f "$TMP_FILE"' EXIT INT TERM

echo "Downloading ${TYPE}..."
if ! curl -fSL --retry 3 --retry-delay 2 "${RAW_URL}" -o "${TMP_FILE}"; then
  echo "Failed to download ${RAW_URL}"
  exit 3
fi

# quick non-invasive check: ensure file is non-empty
if [[ ! -s "${TMP_FILE}" ]]; then
  echo "Downloaded file is empty; aborting."
  exit 3
fi

# Remove unsupported 'conflicts_with' lines (Homebrew removed support)
if grep -q "conflicts_with" "$TMP_FILE"; then
  echo "Removing unsupported 'conflicts_with' lines from formula/cask..."
  sed -i '' '/conflicts_with/d' "$TMP_FILE"
fi

# Move into tap repo and commit if changed, with git user fallback
DEST="${TAP_REPO}/${DEST_DIR}/${NAME}.rb"
if ! mv "$TMP_FILE" "$DEST"; then
  echo "Error: failed to move downloaded file to ${DEST}." >&2
  echo "Possible causes: insufficient permissions, read-only filesystem, or no disk space." >&2
  exit 6
fi
cd "${TAP_REPO}"

git add "${DEST_DIR}/${NAME}.rb"
if git diff --cached --quiet; then
  echo "No changes to commit (file already present and identical)."
else
  if ! git commit -m "Add ${NAME} (${TYPE}) from ${RAW_URL}"; then
    echo "git commit failed; attempting non-interactive commit with temporary identity..."
    git -c user.name="xbrew" -c user.email="xbrew@local" commit -m "Add ${NAME} (${TYPE}) from ${RAW_URL}"
  fi
fi

# Install or reinstall from the tap
BREW_TYPE_FLAG=""
if [[ "$TYPE" == "cask" ]]; then
  BREW_TYPE_FLAG="--cask"
fi

FULL_NAME="${TAP}/${NAME}"
echo
echo "Running: brew ${ACTION} ${BREW_TYPE_FLAG} ${FULL_NAME}"
if [[ "$ACTION" == "install" ]]; then
  brew install ${BREW_TYPE_FLAG} "${FULL_NAME}"
else
  if ! brew reinstall ${BREW_TYPE_FLAG} "${FULL_NAME}"; then
    echo "Reinstall failed or not previously installed; attempting install..."
    brew install ${BREW_TYPE_FLAG} "${FULL_NAME}"
  fi
fi

echo
echo "Done: ${ACTION} completed for ${NAME} (${TYPE}) from ${RAW_URL} (tap: ${TAP})."
