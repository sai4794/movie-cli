#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# Self-update
# ═══════════════════════════════════════════════════════════════
# movie-cli update — updates the project directly.
#
# Two install modes are detected automatically:
#   git mode     SCRIPT_DIR contains .git  → git fetch + pull (dev clone)
#   release mode otherwise                 → download GitHub main tarball,
#                                            swap lib/ plugins/ config/
#                                            under $SHARE_DIR (installed copy)
#
# User files are NEVER touched: ~/.config/movie-cli (CONF_DIR) holds user
# config + user plugins and is left intact. Installed-mode updates back up
# the previous lib/plugins/config before swapping.
#
# Versioning note: this repo has no GitHub releases (only commits), so
# "latest" = the main branch head SHA. Git mode compares local HEAD to
# origin/main; release mode reports the remote SHA and always updates.
# ═══════════════════════════════════════════════════════════════

REPO_URL="https://github.com/sai4794/movie-cli"
REPO_API="https://api.github.com/repos/sai4794/movie-cli"

# Resolve the share dir the same way install.sh does
_get_share_dir() {
    if [[ -n "${SHARE_DIR:-}" ]]; then
        printf '%s' "$SHARE_DIR"
    elif [[ "$SCRIPT_DIR" == *"/.local/share/movie-cli"* ]]; then
        printf '%s' "$SCRIPT_DIR"
    else
        printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/movie-cli"
    fi
}

# Fetch the latest main-branch commit SHA from the GitHub API
_get_remote_sha() {
    curl -s --connect-timeout 8 --max-time 15 \
        -H 'Accept: application/vnd.github+json' \
        "${REPO_API}/commits/main" 2>/dev/null \
        | grep -oE '"sha"[[:space:]]*:[[:space:]]*"[a-f0-9]{40}"' | head -1 \
        | grep -oE '[a-f0-9]{40}' 2>/dev/null || true
}

# Check for updates without applying. Prints status; returns 0 if update
# available, 1 if up to date / indeterminate.
update_check() {
    local mode remote local_sha
    if [[ -d "$SCRIPT_DIR/.git" ]]; then
        mode="git"
    else
        mode="release"
    fi
    printf 'Install mode: %s\n' "$mode" >&2
    printf 'Current version: %s\n' "$VERSION" >&2

    remote=$(_get_remote_sha)
    if [[ -z "$remote" ]]; then
        printf 'Could not reach GitHub (offline or rate-limited).\n' >&2
        return 1
    fi
    printf 'Remote main: %s\n' "${remote:0:7}" >&2

    case "$mode" in
        git)
            local_sha=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || true)
            if [[ -z "$local_sha" ]]; then
                printf 'Local HEAD unknown (not a git repo?)\n' >&2
                return 1
            fi
            printf 'Local HEAD:  %s\n' "${local_sha:0:7}" >&2
            if [[ "$local_sha" == "$remote" ]]; then
                ui_success "movie-cli is up to date."
                return 1
            fi
            printf 'Update available: %s -> %s\n' "${local_sha:0:7}" "${remote:0:7}" >&2
            return 0
            ;;
        release)
            # Installed copies: no local SHA; always allow update to main
            printf 'Update available (installed copy, main @ %s).\n' "${remote:0:7}" >&2
            return 0
            ;;
    esac
    return 1
}

# ── git mode: dev clone ─────────────────────────────────────────────────────
_update_git() {
    local repo="$SCRIPT_DIR"
    # Refuse if working tree is dirty — never clobber uncommitted work
    if ! git -C "$repo" diff --quiet 2>/dev/null; then
        die_user "Working tree has uncommitted changes. Commit or stash first, then re-run update."
    fi
    printf 'Pulling latest from origin/main...\n' >&2
    git -C "$repo" fetch origin 2>&1 | tail -2 || die_network "git fetch failed"
    local ahead
    ahead=$(git -C "$repo" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
    if [[ "$ahead" == "0" ]]; then
        ui_success "Already up to date."
        return 0
    fi
    git -C "$repo" pull --ff-only origin main 2>&1 | tail -5 || die_user "git pull failed (conflict?). Resolve and re-run."
    ui_success "Updated: $ahead commit(s) pulled."
    # Re-run dependency check since new code may need new deps
    check_deps
    ui_success "Done. New version active on next run."
}

# ── release mode: installed copy ────────────────────────────────────────────
_update_release() {
    local share_dir
    share_dir=$(_get_share_dir)
    [[ -d "$share_dir" ]] || die_user "Not an installed copy: $share_dir missing. Run install.sh first."

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local tarball="${tmp_dir}/movie-cli.tar.gz"
    local extract_dir="${tmp_dir}/extract"

    printf 'Downloading latest main branch...\n' >&2
    curl -fsSL --connect-timeout 10 --max-time 120 \
        -o "$tarball" "${REPO_URL}/archive/refs/heads/main.tar.gz" \
        || { rm -rf "$tmp_dir"; die_network "Download failed. Check network / GitHub access."; }

    # Verify it's a real gzip tarball before touching anything
    if ! tar -tzf "$tarball" >/dev/null 2>&1; then
        rm -rf "$tmp_dir"
        die_user "Downloaded archive is corrupt (not a tarball). Aborting — nothing changed."
    fi

    mkdir -p "$extract_dir"
    tar -xzf "$tarball" -C "$extract_dir" 2>/dev/null || { rm -rf "$tmp_dir"; die_user "Extract failed. Aborting."; }
    local src_dir
    src_dir=$(find "$extract_dir" -maxdepth 1 -type d -name 'movie-cli-*' | head -1)
    [[ -n "$src_dir" && -d "$src_dir" ]] || { rm -rf "$tmp_dir"; die_user "Archive layout unexpected. Aborting."; }

    # Backup current share dir (lib/plugins/config only — never CONF_DIR)
    local backup_dir="${XDG_DATA_HOME:-$HOME/.local/share}/movie-cli-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    cp -r "$share_dir/lib" "$backup_dir/lib" 2>/dev/null || true
    cp -r "$share_dir/plugins" "$backup_dir/plugins" 2>/dev/null || true
    cp -r "$share_dir/config" "$backup_dir/config" 2>/dev/null || true

    # Resolve the entrypoint dir (INSTALL_DIR is only set by install.sh, not
    # lib/init.sh). BASH_SOURCE[0] is the sourced lib file, so locate the
    # entrypoint: $0 when invoked by path, PATH lookup when invoked by name.
    local install_dir="${INSTALL_DIR:-}"
    if [[ -z "$install_dir" ]]; then
        local entry="${0#-}"
        if [[ "$entry" != */* ]]; then
            entry=$(command -v "movie-cli" 2>/dev/null || printf '%s' "$entry")
        fi
        install_dir="$(cd "$(dirname "$entry")" && pwd 2>/dev/null || true)"
    fi

    # Swap (rm first — cp -r nests instead of overwriting, same bug as install.sh)
    rm -rf "$share_dir/lib" "$share_dir/plugins" "$share_dir/config"
    cp -r "$src_dir/lib" "$share_dir/lib"
    cp -r "$src_dir/plugins" "$share_dir/plugins"
    cp -r "$src_dir/config" "$share_dir/config"

    # Keep the entrypoint in sync with the new lib (VERSION etc. live in lib/init.sh)
    if [[ -x "$install_dir/movie-cli" ]] && [[ -f "$src_dir/movie-cli" ]]; then
        cp "$src_dir/movie-cli" "$install_dir/movie-cli"
        chmod +x "$install_dir/movie-cli"
        # Re-point SCRIPT_DIR to the share dir (same sed as install.sh)
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i "" "s|SCRIPT_DIR=.*|SCRIPT_DIR=\"$share_dir\"|" "$install_dir/movie-cli" 2>/dev/null || true
        else
            sed -i "s|SCRIPT_DIR=.*|SCRIPT_DIR=\"$share_dir\"|" "$install_dir/movie-cli" 2>/dev/null || true
        fi
    fi

    rm -rf "$tmp_dir"
    ui_success "Updated. Previous lib/plugins/config backed up to: $backup_dir"
    printf 'User config in %s was NOT touched.\n' "$CONF_DIR" >&2
    check_deps
    ui_success "Done. Run: movie-cli --version to confirm."
}

# Main entry
update_self() {
    local mode
    if [[ -d "$SCRIPT_DIR/.git" ]]; then
        mode="git"
    else
        mode="release"
    fi
    debug "update mode=$mode script_dir=$SCRIPT_DIR"

    if [[ "${UPDATE_CHECK_ONLY:-0}" == "1" ]]; then
        update_check
        return $?
    fi

    case "$mode" in
        git)     _update_git ;;
        release) _update_release ;;
    esac
}
