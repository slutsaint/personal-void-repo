#!/usr/bin/env bash
# autoupdate.sh - check upstream tags and bump pkgs/*/template.
#
# Replaces autoupdate.fish. Differences that matter:
#   * tags come from `git ls-remote` (no API, no token, no rate limit, no 100-tag cap)
#   * a failure in one package never stops the others
#   * the template is only touched after the new distfile was downloaded and hashed
#   * ${version}/${pkgname}/${homepage} are ALL expanded, every occurrence
#   * seds/greps are anchored to line start (^version=), so other lines are never edited
#   * never "updates" to an older version (compared with sort -V)
#   * always exits 0: the workflow decides what is worth alerting about
#
# Env (all optional): PKGS_DIR, GIT_BASE (tests), GITHUB_OUTPUT, GITHUB_STEP_SUMMARY
set -u

PKGS_DIR=${PKGS_DIR:-./pkgs}
GIT_BASE=${GIT_BASE:-https://github.com}
OUT=${GITHUB_OUTPUT:-/dev/null}
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}

updates=()
failures=()

fail() { # pkg message
    printf '::warning::%s: %s\n' "$1" "$2"
    failures+=("$1: $2")
}

tpl() { printf '%s/%s/template' "$PKGS_DIR" "$1"; }

# value of a top-level VAR=... line, one pair of quotes stripped
tpl_get() { # pkg var
    sed -nE "s/^$2=[\"']?([^\"']*)[\"']?.*/\1/p" "$(tpl "$1")" | head -n1
}

# prints newest version matching pattern; returns 1 only if upstream was unreachable
latest_tag_version() { # repo pattern
    local repo=$1 pattern=$2 out i
    for i in 1 2 3; do
        if out=$(timeout 90 git ls-remote --tags --refs "$GIT_BASE/$repo.git" 2>/dev/null); then
            printf '%s\n' "$out" |
                sed -nE 's|.*refs/tags/(.*)$|\1|p' |
                sed -nE "s/$pattern/\1/p" |
                sort -V | tail -n1
            return 0
        fi
        sleep $((i * 5))
    done
    return 1
}

# is $2 strictly newer than $1 ?
is_newer() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$2" ]
}

expand_vars() { # pkg version string
    local s=$3
    s=${s//'${version}'/$2}
    s=${s//'${pkgname}'/$(tpl_get "$1" pkgname)}
    s=${s//'${homepage}'/$(tpl_get "$1" homepage)}
    printf '%s' "$s"
}

get_digest() { # url
    local tmp
    tmp=$(mktemp) || return 1
    if ! curl -fsSL --retry 4 --retry-delay 5 --retry-connrefused \
        --connect-timeout 15 --max-time 900 -o "$tmp" "$1" || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        return 1
    fi
    sha256sum "$tmp" | cut -d' ' -f1
    rm -f "$tmp"
}

check_github_tagged_updates() { # repo pkg pattern
    local repo=$1 pkg=$2 pattern=$3
    local t current latest raw url digest
    t=$(tpl "$pkg")
    echo "Checking for updates for $pkg ($repo)"

    [ -f "$t" ] || { fail "$pkg" "no template at $t"; return; }
    current=$(tpl_get "$pkg" version)
    [ -n "$current" ] || { fail "$pkg" "could not read version= from template"; return; }

    if ! latest=$(latest_tag_version "$repo" "$pattern"); then
        fail "$pkg" "could not reach upstream $repo (git ls-remote failed 3 times)"
        return
    fi
    [ -n "$latest" ] || { fail "$pkg" "no upstream tag matches $pattern"; return; }

    if [ "$latest" = "$current" ]; then echo "  up to date ($current)"; return; fi
    if ! is_newer "$current" "$latest"; then
        echo "  upstream newest ($latest) is older than template ($current), leaving it alone"
        return
    fi
    echo "  update found: $current -> $latest"

    raw=$(grep -m1 '^distfiles=' "$t" || true)
    if ! printf '%s' "$raw" | grep -qE '^distfiles=("[^"]*"|[^" ]+)$'; then
        fail "$pkg" "distfiles= is missing or multi-line; bump $pkg by hand (not supported)"
        return
    fi
    url=$(printf '%s' "$raw" | sed -E 's/^distfiles=//; s/^"//; s/"$//')
    url=${url%%>*}   # drop "url>renamed-file" suffix
    url=$(expand_vars "$pkg" "$latest" "$url")
    case "$url" in
        *'$'*) fail "$pkg" "unexpanded variable left in distfile URL: $url"; return ;;
    esac

    if ! digest=$(get_digest "$url") || [ -z "$digest" ]; then
        fail "$pkg" "could not download $url (template left unchanged)"
        return
    fi

    cp "$t" "$t.bak"
    sed -i -E "s/^version=.*/version=$latest/" "$t"
    sed -i -E "s/^checksum=.*/checksum=\"$digest\"/" "$t"
    sed -i -E "s/^revision=.*/revision=1/" "$t"
    if [ "$(tpl_get "$pkg" version)" != "$latest" ] || ! grep -q "$digest" "$t"; then
        mv "$t.bak" "$t"
        fail "$pkg" "template edit did not verify, restored original"
        return
    fi
    rm -f "$t.bak"
    updates+=("$pkg=$latest")
}

# ---- packages to track: repo  pkgname  tag-pattern ---------------------------------------
check_github_tagged_updates noctalia-dev/noctalia          noctalia          '^v([0-9]+\.[0-9]+\.[0-9]+)$'
check_github_tagged_updates noctalia-dev/noctalia-greeter  noctalia-greeter  '^v([0-9]+\.[0-9]+\.[0-9]+)$'
check_github_tagged_updates pankaspe/nordend-fm            nordend           '^v([0-9]+\.[0-9]+\.[0-9]+)$'
# ---------------------------------------------------------------------------------------------

{
    if [ "${#updates[@]}" -gt 0 ]; then
        echo "updates<<STRING"; printf '%s\n' "${updates[@]}"; echo "STRING"
    fi
    if [ "${#failures[@]}" -gt 0 ]; then
        echo "failures<<STRING"; printf '%s\n' "${failures[@]}"; echo "STRING"
    fi
} >> "$OUT"

{
    echo "### autoupdate"
    echo "updated: ${updates[*]:-none}"
    if [ "${#failures[@]}" -gt 0 ]; then
        echo; echo "problems:"; printf -- '- %s\n' "${failures[@]}"
    fi
} >> "$SUMMARY"

exit 0
