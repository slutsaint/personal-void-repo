#!/bin/sh -e
#
# SPDX-License-Identifier: LicenseRef-LICENSE
# Copyright (C) 2026 Wladimir Bec
#
# NOTE: adapted from HeavenDivided/void-builder 'builder'. Signing moved to ./sign so the
# private key never exists while upstream code is being built. Check that repo's LICENSE.
#

: "${VOID_PACKAGES:=./void-packages}"
: "${PKGS_DIR:=./pkgs}"
: "${REPO_DIR:=./repo}"
: "${COMMON_DIR:=./common}"
: "${ETC_DIR:=./etc}"

error() {
    printf "\033[0;31merror\033[0m: %s\n" "$*" >&2
}

warn() {
    printf "\033[0;33mwarn\033[0m: %s\n" "$*"
}

info() {
    printf "\033[0;32minfo\033[0m: %s\n" "$*"
}

if [ "$#" -lt 1 ]; then
    cat <<EOF
$0 pkg...

    Helper for building Void Linux packages from custom directories.

Environment Variables:
    VOID_PACKAGES       Path to the void-packages repo ($VOID_PACKAGES)
    PKGS_DIR            Path to the custom packages repo ($PKGS_DIR)
    REPO_DIR            Where to place the resulting binaries ($REPO_DIR)
    COMMON_DIR          Path to the custom common overlay ($COMMON_DIR)
    ETC_DIR             Path to the custom etc overlay ($ETC_DIR)
    EXTRA_ARGS          Extra arguments to pass to xbps-src ($EXTRA_ARGS)

EOF
    exit 0
fi

info "Checking if $VOID_PACKAGES exists..."
[ -d "$VOID_PACKAGES" ] || {
    warn "$VOID_PACKAGES not found, cloning it..."
    git clone https://github.com/void-linux/void-packages "$VOID_PACKAGES" --depth 1
} && {
    info "$VOID_PACKAGES found, resetting it..."
    (
        cd "$VOID_PACKAGES"
        git reset --hard
        git clean -fdx
        git pull
    )
}

if [ -d "$COMMON_DIR" ]; then
    info "Copying custom common/ overlay from $COMMON_DIR to $VOID_PACKAGES/common..."
    for entry in "$COMMON_DIR"/*; do
        [ -e "$entry" ] || continue

        name="${entry##"$COMMON_DIR/"}"

        [ "$name" = "shlibs" ] && {
            info "Merging $entry into $VOID_PACKAGES/common/shlibs..."
            shlibs="$VOID_PACKAGES/common/shlibs"
            while IFS= read -r line; do
                case "$line" in
                    ""|"#"*) continue ;;
                esac

                soname="${line%% *}"
                libname="${soname%%.so*}"
                esc_libname="$(printf '%s' "$libname" | sed -e 's/[][\\.^$*+?(){}|]/\\&/g')"

                grep -v -E "^${esc_libname}\.so" "$shlibs" > "$shlibs.tmp"
                mv "$shlibs.tmp" "$shlibs"

                info "  replacing any $libname.so* entries with: $line"
                echo "$line" >> "$shlibs"
            done < "$entry"
            continue
        }

        dest="$VOID_PACKAGES/common/$name"
        [ -e "$dest" ] && {
            warn "$VOID_PACKAGES/common/$name already exists, removing it..."
        }
        rm -fr "$dest"

        info "Copying $entry to $VOID_PACKAGES/common..."
        cp -r "$entry" "$dest"
    done
fi

if [ -d "$ETC_DIR" ]; then
    info "Copying custom etc/ overlay from $ETC_DIR to $VOID_PACKAGES/etc..."
    for entry in "$ETC_DIR"/*; do
        [ -e "$entry" ] || continue

        name="${entry##"$ETC_DIR/"}"
        dest="$VOID_PACKAGES/etc/$name"
        [ -e "$dest" ] && {
            warn "$VOID_PACKAGES/etc/$name already exists, removing it..."
        }
        rm -fr "$dest"

        info "Copying $entry to $VOID_PACKAGES/etc..."
        cp -r "$entry" "$dest"
    done
fi

info "Copying custom packages from $PKGS_DIR to $VOID_PACKAGES."
for pkg in "$PKGS_DIR"/*; do
    [ -d "$pkg" ] || continue

    pkg="${pkg##"$PKGS_DIR/"}"
    dest="$VOID_PACKAGES/srcpkgs/$pkg"
    [ -d "$dest" ] && {
        warn "$VOID_PACKAGES/srcpkgs/$pkg already exists, removing it..."
        warn "Consider submitting a PR to merge your changes into the"
        warn "official void-packages repo"
        rm -fr "$dest"
    }

    src="$PKGS_DIR/$pkg"
    info "Copying $src to $VOID_PACKAGES..."
    cp -r "$src" "$dest"
done

for pkg; do
    [ -d "$PKGS_DIR/$pkg" ] || {
        error "$pkg not found in $PKGS_DIR, skipping..."
        continue
    }

    info "Building $pkg..."
    # shellcheck disable=2086
    # we need words splitting
    "$VOID_PACKAGES/xbps-src" -H "$REPO_DIR" $EXTRA_ARGS pkg "$pkg"
    info "Finished building $pkg"
done
