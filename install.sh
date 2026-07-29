#!/usr/bin/env bash
#
# install.sh — bootstrap a workstation.
#
# Usage:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/trusted/bootstrap/main/install.sh)"

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

REPO_HTTPS_URL="https://github.com/trusted/setup.git"
REPO_NWO="trusted/setup"
DEST_BASENAME="trusted-setup"

GH_APT_KEYRING="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
GH_APT_KEY_URL="https://cli.github.com/packages/githubcli-archive-keyring.gpg"
GH_APT_SOURCES="/etc/apt/sources.list.d/github-cli.sources"
GH_APT_SOURCES_LEGACY="/etc/apt/sources.list.d/github-cli.list"

# Wait this long for another process (unattended-upgrades, cloud-init, ...) to
# release the apt/dpkg locks instead of failing immediately.
APT_LOCK_TIMEOUT=600

# Never let git drop into an interactive username/password prompt; if the gh
# credential helper cannot answer we want a clear error instead of a hang.
export GIT_TERMINAL_PROMPT=0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

C_RESET=""; C_BOLD=""; C_BLUE=""; C_YELLOW=""; C_RED=""; C_GREEN=""
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_BLUE=$'\033[34m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
fi

log()  { printf '%s==>%s %s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$*" >&2; }
ok()   { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%swarn:%s %s\n' "$C_YELLOW$C_BOLD" "$C_RESET" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

TMPFILES=""
cleanup() {
    [ -n "$TMPFILES" ] || return 0
    # shellcheck disable=SC2086  # intentional word splitting over the file list
    rm -f $TMPFILES
}
trap cleanup EXIT

# Sets $TMPFILE (rather than printing it) so the bookkeeping below is not lost
# in a command-substitution subshell.
TMPFILE=""
mktempfile() {
    TMPFILE="$(mktemp "${TMPDIR:-/tmp}/install.sh.XXXXXX")"
    TMPFILES="$TMPFILES $TMPFILE"
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

PLATFORM=""     # macos | debian-family
OS_ID=""
OS_ID_LIKE=""
OS_VERSION_ID=""
OS_PRETTY=""

detect_platform() {
    case "$(uname -s)" in
        Darwin)
            PLATFORM="macos"
            OS_PRETTY="macOS $(sw_vers -productVersion 2>/dev/null || printf 'unknown') ($(uname -m))"
            ;;
        Linux)
            [ -r /etc/os-release ] || die "cannot read /etc/os-release; unsupported Linux distribution"
            # shellcheck disable=SC1091
            . /etc/os-release
            OS_ID="${ID:-}"
            OS_ID_LIKE="${ID_LIKE:-}"
            OS_VERSION_ID="${VERSION_ID:-}"
            OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VERSION_ID} ($(uname -m))"
            case " $OS_ID $OS_ID_LIKE " in
                *" debian "*|*" ubuntu "*)
                    PLATFORM="debian-family"
                    ;;
                *)
                    die "unsupported Linux distribution '$OS_ID'; this script supports Ubuntu and Debian"
                    ;;
            esac
            ;;
        *)
            die "unsupported operating system '$(uname -s)'"
            ;;
    esac
    log "Detected $OS_PRETTY"
}

# ---------------------------------------------------------------------------
# Ubuntu / Debian
# ---------------------------------------------------------------------------

SUDO=""

# sudo is assumed to be installed and passwordless on the Linux targets, so
# there is nothing to warm up here — just skip it entirely when already root.
setup_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        SUDO=""
    else
        SUDO="sudo"
    fi
}

# apt-get wrapper: runs as root, never prompts, and waits for the dpkg/apt
# locks rather than dying when cloud-init or unattended-upgrades holds them.
apt_get() {
    # shellcheck disable=SC2086  # $SUDO must expand to nothing when we are root
    $SUDO env \
        DEBIAN_FRONTEND=noninteractive \
        NEEDRESTART_MODE=a \
        NEEDRESTART_SUSPEND=1 \
        apt-get -o "DPkg::Lock::Timeout=$APT_LOCK_TIMEOUT" -y "$@"
}

as_root() {
    # shellcheck disable=SC2086
    $SUDO "$@"
}

# On a freshly booted EC2 instance cloud-init is often still running its
# package phase, which holds the apt locks. Give it a bounded chance to finish.
wait_for_cloud_init() {
    have cloud-init || return 0
    have timeout || return 0
    local status
    status="$(cloud-init status 2>/dev/null | head -n 1 || true)"
    case "$status" in
        *done*|*disabled*|*error*|"") return 0 ;;
    esac
    log "Waiting for cloud-init to finish (up to 5 minutes)..."
    timeout 300 cloud-init status --wait >/dev/null 2>&1 || \
        warn "cloud-init did not report completion; continuing anyway"
}

APT_UPDATED="no"
apt_update_once() {
    if [ "$APT_UPDATED" = "no" ]; then
        log "Refreshing apt package lists"
        apt_get update
        APT_UPDATED="yes"
    fi
}

apt_install() {
    log "Installing: $*"
    apt_get install "$@"
}

# Package names are identical between Ubuntu 24.04 and Debian 13 for
# everything we need, but Debian's minimal/cloud images ship fewer of them
# preinstalled, so install only what is actually missing.
install_prereqs_apt() {
    local missing=""
    have curl || missing="$missing curl"
    [ -e /etc/ssl/certs/ca-certificates.crt ] || missing="$missing ca-certificates"
    if [ -n "$missing" ]; then
        apt_update_once
        # shellcheck disable=SC2086
        apt_install $missing
    fi
}

install_git_apt() {
    if have git; then
        ok "git already installed ($(git --version))"
        return 0
    fi
    apt_update_once
    apt_install git
}

# Add GitHub's official apt repository. The published key is already
# dearmored, so no gnupg dependency is needed. We write deb822 (.sources)
# format: supported by apt on Ubuntu 24.04 and preferred on Debian 13, where
# one-line .list entries are deprecated.
add_gh_apt_repo() {
    local key_tmp arch
    arch="$(dpkg --print-architecture)"

    log "Adding the GitHub CLI apt repository"
    mktempfile
    key_tmp="$TMPFILE"
    if ! curl -fsSL --retry 3 --retry-delay 2 "$GH_APT_KEY_URL" -o "$key_tmp"; then
        warn "could not download the GitHub CLI signing key"
        return 1
    fi
    [ -s "$key_tmp" ] || { warn "downloaded GitHub CLI signing key is empty"; return 1; }

    as_root install -d -m 0755 /etc/apt/keyrings
    as_root install -m 0644 "$key_tmp" "$GH_APT_KEYRING"

    # Drop the old one-line entry if a previous run (or the upstream docs)
    # created it, so apt does not warn about a duplicate source.
    [ -e "$GH_APT_SOURCES_LEGACY" ] && as_root rm -f "$GH_APT_SOURCES_LEGACY"

    printf 'Types: deb\nURIs: https://cli.github.com/packages\nSuites: stable\nComponents: main\nArchitectures: %s\nSigned-By: %s\n' \
        "$arch" "$GH_APT_KEYRING" \
        | as_root tee "$GH_APT_SOURCES" >/dev/null
    as_root chmod 0644 "$GH_APT_SOURCES"

    APT_UPDATED="no"   # the new source must be fetched
    return 0
}

install_gh_apt() {
    if have gh; then
        ok "gh already installed ($(gh --version | head -n 1))"
        return 0
    fi

    if add_gh_apt_repo; then
        if apt_update_once && apt_install gh; then
            return 0
        fi
        warn "installing gh from the GitHub repository failed; falling back to the distribution package"
        as_root rm -f "$GH_APT_SOURCES"
        APT_UPDATED="no"
    else
        warn "could not configure the GitHub CLI repository; falling back to the distribution package"
    fi

    # Ubuntu ships gh in universe (enabled by default on the official cloud
    # images); Debian 13 ships it in main.
    apt_update_once
    apt_install gh || die "failed to install gh from the distribution repositories"
}

install_debian_family() {
    case "$OS_ID" in
        ubuntu)
            case "$OS_VERSION_ID" in
                24.*|25.*|26.*) ;;
                *) warn "this script targets Ubuntu 24.04 LTS; found ${OS_VERSION_ID:-unknown}" ;;
            esac
            ;;
        debian)
            case "$OS_VERSION_ID" in
                13*|14*) ;;
                *) warn "this script targets Debian 13 (trixie); found ${OS_VERSION_ID:-unknown}" ;;
            esac
            ;;
    esac

    setup_sudo
    wait_for_cloud_init
    install_prereqs_apt
    install_git_apt
    install_gh_apt
}

# ---------------------------------------------------------------------------
# macOS
# ---------------------------------------------------------------------------

brew_prefix_for_arch() {
    case "$(uname -m)" in
        arm64) printf '/opt/homebrew' ;;
        *)     printf '/usr/local' ;;
    esac
}

# Append `brew shellenv` to the login shell's profile so brew-installed git
# and gh stay on PATH in future shells.
persist_brew_shellenv() {
    local brew_bin="$1" profile line
    line="eval \"\$($brew_bin shellenv)\""
    case "${SHELL:-}" in
        */bash) profile="$HOME/.bash_profile" ;;
        *)      profile="$HOME/.zprofile" ;;
    esac
    if grep -qsF "$brew_bin shellenv" "$profile"; then
        return 0
    fi
    printf '\n# Added by trusted-setup install.sh\n%s\n' "$line" >>"$profile"
    ok "Added Homebrew to PATH in $profile"
}

ensure_homebrew() {
    local brew_bin
    if have brew; then
        ok "Homebrew already installed ($(brew --version | head -n 1))"
        return 0
    fi

    brew_bin="$(brew_prefix_for_arch)/bin/brew"
    if [ -x "$brew_bin" ]; then
        eval "$("$brew_bin" shellenv)"
        ok "Found Homebrew at $brew_bin"
        return 0
    fi

    log "Installing Homebrew (this also installs the Xcode Command Line Tools)"
    log "sudo will ask for your password"
    if [ ! -t 0 ] && [ ! -e /dev/tty ]; then
        warn "no terminal available; the Homebrew installer cannot prompt for your password"
    fi
    NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || die "Homebrew installation failed"

    [ -x "$brew_bin" ] || die "Homebrew was installed but $brew_bin is missing"
    eval "$("$brew_bin" shellenv)"
    persist_brew_shellenv "$brew_bin"
}

brew_install() {
    local formula="$1"
    if brew list --versions "$formula" >/dev/null 2>&1; then
        ok "$formula already installed via Homebrew"
        return 0
    fi
    log "Installing $formula with Homebrew"
    brew install "$formula"
}

install_macos() {
    [ "$(id -u)" -ne 0 ] || die "do not run this script as root on macOS; Homebrew refuses to run as root"
    ensure_homebrew
    brew_install git
    brew_install gh
}

# ---------------------------------------------------------------------------
# git + gh credential wiring
# ---------------------------------------------------------------------------

check_gh_auth() {
    log "Checking GitHub authentication"
    if gh auth status --hostname github.com >/dev/null 2>&1; then
        ok "Authenticated to github.com"
        return 0
    fi
    printf '\n' >&2
    gh auth status --hostname github.com >&2 || true
    printf '\n' >&2
    die "not authenticated to github.com. Run 'gh auth login' (or export GH_TOKEN) and re-run this script."
}

configure_git_credentials() {
    log "Configuring git to use gh for github.com credentials"
    gh auth setup-git --hostname github.com \
        || die "'gh auth setup-git' failed"

    local helper
    helper="$(git config --global --get-all 'credential.https://github.com.helper' 2>/dev/null | tr '\n' ' ' || true)"
    ok "credential.https://github.com.helper = ${helper:-<unset>}"

    # A global insteadOf rule that rewrites HTTPS GitHub URLs to SSH would
    # silently defeat the gh credential helper. Warn rather than edit the
    # user's config for them.
    local rewrites
    rewrites="$(git config --global --get-regexp '^url\..*\.insteadof$' 2>/dev/null || true)"
    case "$rewrites" in
        *git@github.com*)
            warn "a global url.*.insteadOf rule rewrites GitHub URLs to SSH:"
            printf '%s\n' "$rewrites" >&2
            warn "the clone below forces HTTPS, but you may want to remove that rule"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Clone the repository
# ---------------------------------------------------------------------------

resolve_data_home() {
    : "${HOME:?HOME is not set}"
    local data_home="${XDG_DATA_HOME:-}"
    # Per the XDG basedir spec, a relative XDG_DATA_HOME is invalid and must
    # be treated as unset.
    case "$data_home" in
        /*) ;;
        "") data_home="$HOME/.local/share" ;;
        *)
            warn "XDG_DATA_HOME ('$data_home') is not an absolute path; using \$HOME/.local/share"
            data_home="$HOME/.local/share"
            ;;
    esac
    printf '%s' "$data_home"
}

update_existing_clone() {
    local dest="$1" origin
    origin="$(git -C "$dest" remote get-url origin 2>/dev/null || printf '')"

    case "$(printf '%s' "$origin" | tr '[:upper:]' '[:lower:]')" in
        *github.com[:/]trusted/setup*) ;;
        *)
            die "$dest is already a git repository with origin '${origin:-<none>}', not $REPO_NWO. Move it aside and re-run."
            ;;
    esac

    log "$DEST_BASENAME is already cloned; updating"
    # Make sure an existing clone that was made over SSH starts using HTTPS.
    case "$origin" in
        https://github.com/*) ;;
        *)
            log "Switching origin from '$origin' to HTTPS"
            git -C "$dest" remote set-url origin "$REPO_HTTPS_URL"
            ;;
    esac

    if ! git -C "$dest" diff --quiet || ! git -C "$dest" diff --cached --quiet; then
        warn "local uncommitted changes in $dest; fetching but not merging"
        git -C "$dest" fetch --prune origin || warn "fetch failed"
        return 0
    fi

    if ! git -C "$dest" pull --ff-only; then
        warn "could not fast-forward $dest; leaving it as is"
    fi
}

clone_repo() {
    local data_home dest parent
    data_home="$(resolve_data_home)"
    dest="$data_home/$DEST_BASENAME"
    parent="$(dirname "$dest")"

    CLONE_DEST="$dest"

    if [ -e "$dest" ] && git -C "$dest" rev-parse --git-dir >/dev/null 2>&1; then
        update_existing_clone "$dest"
        return 0
    fi

    if [ -e "$dest" ]; then
        if [ -d "$dest" ] && [ -z "$(ls -A "$dest" 2>/dev/null)" ]; then
            rmdir "$dest"
        else
            die "$dest already exists and is not a $REPO_NWO checkout. Move it aside and re-run."
        fi
    fi

    mkdir -p "$parent"
    log "Cloning $REPO_NWO into $dest"
    if ! git clone "$REPO_HTTPS_URL" "$dest"; then
        die "clone failed. Confirm your GitHub account has access to $REPO_NWO (try: gh repo view $REPO_NWO)."
    fi
}

# ---------------------------------------------------------------------------
# Handoff
# ---------------------------------------------------------------------------

# Replace this process with the repository's own setup.sh, which drives the
# rest of the machine setup. exec keeps the controlling terminal, so setup.sh
# can still prompt the user even though we were started from a curl pipeline.
handoff_to_setup() {
    local dest="$1"
    local setup="$dest/setup.sh"

    [ -f "$setup" ] || die "expected $setup in the checkout, but it is not there"

    log "Handing off to $setup"
    printf '\n' >&2

    # Let setup.sh find its own checkout without re-deriving the XDG paths.
    TRUSTED_SETUP_DIR="$dest"
    export TRUSTED_SETUP_DIR

    # exec bypasses the EXIT trap, so drop the temp files now.
    cleanup
    trap - EXIT

    cd "$dest"
    if [ -x "$setup" ]; then
        exec "$setup"
    fi
    # Not executable in the checkout — run it through bash explicitly.
    exec bash "$setup"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

CLONE_DEST=""

usage() {
    cat <<EOF
install.sh — install git and the GitHub CLI, point git's credential helper at
gh, clone $REPO_NWO into \${XDG_DATA_HOME:-\$HOME/.local/share}/$DEST_BASENAME,
then exec the setup.sh from that checkout to continue the setup.

Usage:
  /bin/bash -c "\$(curl -fsSL https://some-host/install.sh)"
  ./install.sh [-h|--help]

Supported: Ubuntu 24.04 LTS, Debian 13 (trixie), macOS.
Requires GitHub credentials to already be available to gh, and sudo access
(passwordless on Linux).
EOF
}

main() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
        "") ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac

    detect_platform

    case "$PLATFORM" in
        macos)         install_macos ;;
        debian-family) install_debian_family ;;
    esac

    have git || die "git is not on PATH after installation"
    have gh  || die "gh is not on PATH after installation"

    check_gh_auth
    configure_git_credentials
    clone_repo

    printf '\n' >&2
    ok "$(git --version)"
    ok "$(gh --version | head -n 1)"
    ok "$REPO_NWO checked out at $CLONE_DEST"

    handoff_to_setup "$CLONE_DEST"
}

main "$@"
