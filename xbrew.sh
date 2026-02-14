#!/usr/bin/env bash
set -euo pipefail

print_help() {
  cat <<'EOF'
xbrew — Install or reinstall a Homebrew formula or cask from a specific commit

Prerequisites:
  brew, git commands.

Installation:
  wget https://github.com/lebarsfa/xbrew/releases/latest/download/xbrew.sh
  sudo mv xbrew.sh /usr/local/bin/xbrew
  sudo chmod +x /usr/local/bin/xbrew

Usage:
  xbrew <install|reinstall> [--formula|--cask] <formula or cask name> <commit-sha|raw-url> [tap]
  OR
  xbrew <install|reinstall> [--formula|--cask] <raw-url> [tap]   # formula or cask name omitted, extracted from URL

Purpose:
  Create (if needed) a local Homebrew tap, fetch the exact Formula/<formula>.rb
  from the given commit SHA (or a full raw.githubusercontent URL), commit it into
  the tap, and run `brew install` or `brew reinstall` against the tap-qualified
  formula.

Parameters:
  <install|reinstall>       Action to perform (install or reinstall).
  <formula or cask name>    Formula or cask name name (e.g. doxygen).
  <commit-sha|raw-url>      Commit SHA in homebrew-core or a full raw.githubusercontent URL
                            pointing to the formula file.
  [tap]                     Optional tap name (default: "$USER/local").

Options:
  --formula    Treat target as a formula (default).
  --cask       Treat target as a cask.
  -h, --help   Show this help and exit.

How to find the raw URL or commit SHA on GitHub (web UI)
  1. Open the formula page in homebrew-core:
       https://github.com/Homebrew/homebrew-core/blob/master/Formula/<f>/<formula>.rb
     or
       https://github.com/Homebrew/homebrew-core/blob/master/Formula/<formula>.rb
     (replace <formula> with the formula name, e.g., doxygen, and <f> by its first letter, e.g. d, if the first letter is necessary; or check the output of brew info doxygen).
  2. Click the "History" button (top-right of the file view) to see commits that changed that file.
  3. Scan the commit list for the change that introduced the desired version
     (look for "1.9.6" or the version bump in the commit message or diff).
  4. Click "View code at this point" in the commit entry to view the file at that commit; then click "Raw".
     The browser address bar now shows the raw URL for that commit, for example:
       https://raw.githubusercontent.com/Homebrew/homebrew-core/<COMMIT_SHA>/Formula/doxygen.rb
  5. Copy that raw URL (or the commit SHA) and pass it to xbrew. Example:
       xbrew install https://raw.githubusercontent.com/Homebrew/homebrew-core/d2267b9f2ad247bc9c8273eb755b39566a474a70/Formula/doxygen.rb

Examples:
  # Reinstall doxygen from a specific homebrew-core commit (default tap: $USER/local)
  xbrew reinstall doxygen d2267b9f2ad247bc9c8273eb755b39566a474a70
  brew pin doxygen
  
  # Reinstall cmake cask from a specific homebrew-cask commit
  xbrew reinstall --cask cmake 06eed90d6268ed8c26e23b0458a43f8d3317f66c

  # Reinstall a cask from a raw URL (type inferred from URL)
  xbrew reinstall https://raw.githubusercontent.com/Homebrew/homebrew-cask/06eed90d6268ed8c26e23b0458a43f8d3317f66c/Casks/c/cmake.rb

  # Install using a full raw URL treated as a formula, and a custom tap
  xbrew install --formula \
    https://raw.githubusercontent.com/Homebrew/homebrew-core/d2267b9f2ad247bc9c8273eb755b39566a474a70/Formula/doxygen.rb \
    myuser/old

Behavior and notes:
  - If you pass only a full raw URL, the script will try to extract the name and type
    from the URL path (/Formula/ or /Casks/, strip .rb). Prefer URLs containing those paths.
  - The script commits the downloaded file into a local tap (Formula/ or Casks/)
    and then runs brew install or brew reinstall (with --cask for casks).; it will not pin the formula or cask.
  - Inspect the file at $(brew --repo "<tap>")/Formula/<name>.rb or .../Casks/<name>.rb before installing
    if you want to review changes or verify provenance.
  - Use a trusted commit or URL only; the script does not sandbox or validate
    formula contents beyond a non-empty download check.
  - To reproduce on other machines, push the tap repo to a remote and `brew tap`
    that remote on the target machines.
EOF
}

# Helper: test whether a URL exists (use HEAD; fall back to GET if HEAD unsupported)
url_exists() {
  local url="$1"
  # try HEAD first
  if curl -fsI --retry 2 --retry-delay 1 "$url" >/dev/null 2>&1; then
    return 0
  fi
  # fallback to a lightweight GET (some servers don't support HEAD)
  if curl -fsS --retry 2 --retry-delay 1 --max-time 10 -o /dev/null "$url"; then
    return 0
  fi
  return 1
}

# Helper: test whether a string looks like a URL
is_url() {
  [[ "$1" =~ ^https?:// ]]
}

# show help early if requested
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

# Next argument must be either a name or a raw URL
TARGET="${1:-}"
shift || true

if [[ -z "$TARGET" ]]; then
  echo "Error: missing target (name or raw URL)."
  echo
  print_help
  exit 2
fi

# Optional next arg may be commit-sha or raw-url (only for long form)
POSSIBLE_COMMIT_OR_URL="${1:-}"
if [[ -n "${POSSIBLE_COMMIT_OR_URL}" && ! "${POSSIBLE_COMMIT_OR_URL}" =~ ^https?:// ]]; then
  # it's probably a commit SHA; keep it and shift
  COMMIT_OR_URL="$POSSIBLE_COMMIT_OR_URL"
  shift
else
  COMMIT_OR_URL="${POSSIBLE_COMMIT_OR_URL:-}"
  # if it was a URL we will handle it below; if empty, leave empty
  if [[ -n "$COMMIT_OR_URL" && "$COMMIT_OR_URL" =~ ^https?:// ]]; then
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
  TAP="${COMMIT_OR_URL:-$TAP}"  # if user passed only two args, second may be tap

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
  # TARGET is a name; use it and build RAW_URL from COMMIT_OR_URL (if provided)
  NAME="$TARGET"
  if [[ -z "${COMMIT_OR_URL:-}" ]]; then
    echo "Error: missing commit-sha or raw URL for name '${NAME}'."
    echo
    print_help
    exit 2
  fi

  if is_url "$COMMIT_OR_URL"; then
    RAW_URL="$COMMIT_OR_URL"
  else
    # Build candidate raw URLs depending on TYPE (new layout with first-letter subdir, then legacy layout)
    FIRST_LETTER=$(printf '%s' "$NAME" | cut -c1 | tr '[:upper:]' '[:lower:]')  # Portable, POSIX-friendly first letter (always lower-case)
    if [[ "$TYPE" == "cask" ]]; then
      RAW_URL_CAND1="https://raw.githubusercontent.com/Homebrew/homebrew-cask/${COMMIT_OR_URL}/Casks/${FIRST_LETTER}/${NAME}.rb"
      RAW_URL_CAND2="https://raw.githubusercontent.com/Homebrew/homebrew-cask/${COMMIT_OR_URL}/Casks/${NAME}.rb"
      if url_exists "$RAW_URL_CAND1"; then
        RAW_URL="$RAW_URL_CAND1"
      else
        RAW_URL="$RAW_URL_CAND2"
        echo "Warning: falling back to the legacy layout for the raw URL."
      fi
    else
      RAW_URL_CAND1="https://raw.githubusercontent.com/Homebrew/homebrew-core/${COMMIT_OR_URL}/Formula/${FIRST_LETTER}/${NAME}.rb"
      RAW_URL_CAND2="https://raw.githubusercontent.com/Homebrew/homebrew-core/${COMMIT_OR_URL}/Formula/${NAME}.rb"
      if url_exists "$RAW_URL_CAND1"; then
        RAW_URL="$RAW_URL_CAND1"
      else
        RAW_URL="$RAW_URL_CAND2"
        echo "Warning: falling back to the legacy layout for the raw URL."
      fi
    fi
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
