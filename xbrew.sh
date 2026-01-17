#!/usr/bin/env bash
set -euo pipefail

print_help() {
  cat <<'EOF'
xbrew — Install or reinstall a Homebrew formula from a specific commit

Installation:
  wget https://github.com/lebarsfa/xbrew/releases/latest/download/xbrew.sh
  sudo mv xbrew.sh /usr/local/bin/xbrew
  sudo chmod +x /usr/local/bin/xbrew

Usage:
  xbrew <install|reinstall> <formula> <commit-sha|raw-url> [tap]
  OR
  xbrew <install|reinstall> <raw-url> [tap]   # formula omitted, extracted from URL

Purpose:
  Create (if needed) a local Homebrew tap, fetch the exact Formula/<formula>.rb
  from the given commit SHA (or a full raw.githubusercontent URL), commit it into
  the tap, and run `brew install` or `brew reinstall` against the tap-qualified
  formula.

Parameters:
  <install|reinstall>   Action to perform (install or reinstall).
  <formula>             Formula name (e.g., doxygen).
  <commit-sha|raw-url>  Commit SHA in homebrew-core or a full raw.githubusercontent URL
                        pointing to the formula file.
  [tap]                 Optional tap name (default: "$USER/local").

How to find the raw URL or commit SHA on GitHub (web UI)
  1. Open the formula page in homebrew-core:
       https://github.com/Homebrew/homebrew-core/blob/master/Formula/<f>/<formula>.rb
     or
       https://github.com/Homebrew/homebrew-core/blob/master/Formula/<formula>.rb
     (replace <formula> with the formula name, e.g., doxygen, and <f> by its first letter, e.g. d, if the first letter is necessary; or check the output of brew info doxygen).
  2. Click the "History" button (top-right of the file view) to see commits that
     changed that file.
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

  # Install using a full raw URL and a custom tap
  xbrew install \
    https://raw.githubusercontent.com/Homebrew/homebrew-core/d2267b9f2ad247bc9c8273eb755b39566a474a70/Formula/doxygen.rb \
    myuser/old

Behavior and notes:
  - If you pass a full raw URL as the second argument, the script will try to
    extract the formula name from the URL path (strip .rb).
  - The script commits the downloaded formula into the tap repository so Homebrew
    recognizes it; it will not pin the formula.
  - Inspect the file at $(brew --repo "$TAP")/Formula/<formula>.rb before installing
    if you want to review changes or verify provenance.
  - Use a trusted commit or URL only; the script does not sandbox or validate
    formula contents beyond a non-empty download check.
  - To reproduce on other machines, push the tap repo to a remote and `brew tap`
    that remote on the target machines.
  - Options:
      -h, --help    Show this help and exit
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

# show help early if requested
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  print_help
  exit 0
fi

command -v brew >/dev/null 2>&1 || { echo "Error: brew not found in PATH."; exit 4; }
command -v git >/dev/null 2>&1 || { echo "Error: git not found in PATH."; exit 4; }

ACTION="${1:-}"
ARG2="${2:-}"
ARG3="${3:-}"
ARG4="${4:-}"

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

# Determine whether the user passed a URL as the second argument (short form)
is_url() {
  [[ "$1" =~ ^https?:// ]]
}

if is_url "$ARG2"; then
  # Short form: ACTION <raw-url> [tap]
  RAW_URL="$ARG2"
  TAP="${ARG3:-${USER}/local}"
  if [[ "$RAW_URL" =~ /Formula/([^/]+)\.rb($|\?) ]]; then
    FORMULA="${BASH_REMATCH[1]}"
  else
    filename="$(basename "${RAW_URL%%\?*}")"
    if [[ "$filename" =~ \.rb$ ]]; then
      FORMULA="${filename%.rb}"
    else
      echo "Warning: could not reliably extract formula name from URL. Using '${filename}' as formula name."
      echo "Tip: prefer URLs containing /Formula/<name>.rb for reliable extraction."
      FORMULA="$filename"
    fi
  fi
else
  # Long form: ACTION <formula> <commit-sha|raw-url> [tap]
  FORMULA="$ARG2"
  COMMIT_OR_URL="$ARG3"
  TAP="${ARG4:-${USER}/local}"

  if [[ -z "$FORMULA" || -z "$COMMIT_OR_URL" ]]; then
    echo "Error: missing arguments."
    echo
    print_help
    exit 2
  fi

  if is_url "$COMMIT_OR_URL"; then
    RAW_URL="$COMMIT_OR_URL"
  else
    # Build two candidate raw URLs (new layout with first-letter subdir, then legacy layout)
    first_letter="$(echo "${FORMULA:0:1}" | tr '[:upper:]' '[:lower:]')"
    RAW_URL_CAND1="https://raw.githubusercontent.com/Homebrew/homebrew-core/${COMMIT_OR_URL}/Formula/${first_letter}/${FORMULA}.rb"
    RAW_URL_CAND2="https://raw.githubusercontent.com/Homebrew/homebrew-core/${COMMIT_OR_URL}/Formula/${FORMULA}.rb"
    # Prefer the new layout if it exists, otherwise fall back to the legacy layout
    if url_exists "$RAW_URL_CAND1"; then
      RAW_URL="$RAW_URL_CAND1"
    else
      RAW_URL="$RAW_URL_CAND2"
      echo "Warning: falling back to the legacy layout for the raw URL."
    fi
  fi
fi

# Final sanity: ensure RAW_URL and FORMULA are set
if [[ -z "${FORMULA:-}" || -z "${RAW_URL:-}" ]]; then
  echo "Error: could not determine formula name or source URL."
  echo
  print_help
  exit 2
fi

echo "Tap: $TAP"
echo "Action: $ACTION"
echo "Formula: $FORMULA"
echo "Source: $RAW_URL"
echo

# Create tap if missing
if ! brew tap | grep -q "^${TAP}\$"; then
  echo "Creating tap ${TAP}..."
  brew tap-new "${TAP}"
else
  echo "Tap ${TAP} already present."
fi

# Prepare tap repo and download formula
TAP_REPO="$(brew --repo "${TAP}")"
mkdir -p "${TAP_REPO}/Formula"

TMP_FILE=""
# portable mktemp
if TMP_FILE="$(mktemp 2>/dev/null)"; then
  :
elif TMP_FILE="$(mktemp -t xbrew.XXXXXX 2>/dev/null)"; then
  :
else
  echo "mktemp failed; cannot create temporary file."
  exit 5
fi
trap '[[ -f "$TMP_FILE" ]] && rm -f "$TMP_FILE"' EXIT INT TERM

echo "Downloading formula..."
if ! curl -fSL --retry 3 --retry-delay 2 "${RAW_URL}" -o "${TMP_FILE}"; then
  echo "Failed to download ${RAW_URL}"
  exit 3
fi

# quick non-invasive check: ensure file is non-empty
if [[ ! -s "${TMP_FILE}" ]]; then
  echo "Downloaded file is empty; aborting."
  exit 3
fi

# Move into tap repo and commit if changed, with git user fallback
DEST="${TAP_REPO}/Formula/${FORMULA}.rb"
mv "${TMP_FILE}" "${DEST}"
cd "${TAP_REPO}"

git add "Formula/${FORMULA}.rb"
if git diff --cached --quiet; then
  echo "No changes to commit (formula already present and identical)."
else
  if ! git commit -m "Add ${FORMULA} from ${RAW_URL}"; then
    echo "git commit failed; attempting non-interactive commit with temporary identity..."
    git -c user.name="xbrew" -c user.email="xbrew@local" commit -m "Add ${FORMULA} from ${RAW_URL}"
  fi
fi

# Install or reinstall from the tap
FULL_NAME="${TAP}/${FORMULA}"
echo
echo "Running: brew ${ACTION} ${FULL_NAME}"
if [[ "$ACTION" == "install" ]]; then
  brew install "${FULL_NAME}"
else
  # try reinstall, fall back to install if not present
  if ! brew reinstall "${FULL_NAME}"; then
    echo "Reinstall failed or formula not previously installed; attempting install..."
    brew install "${FULL_NAME}"
  fi
fi

echo
echo "Done: ${ACTION} completed for ${FORMULA} from ${RAW_URL} (tap: ${TAP})."
