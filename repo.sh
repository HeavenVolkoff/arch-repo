#!/usr/bin/env bash

set -xeu
trap 'rm -f ${_pkgs:-} ${_makepkgconf:-}' EXIT

# makepkg needs a non root user
useradd builder -m
echo "builder ALL=(ALL) NOPASSWD: ALL" >>/etc/sudoers
chown -R builder:builder .

# Make output repository for pakcages
_repo="$(mktemp -d)"

# Change some makepkg options
_makepkgconf="$(mktemp)"
cp /etc/makepkg.conf "$_makepkgconf"
sed -Ei 's\^#?PKGEXT=.*$\PKGEXT=.pkg.tar.zst\' "$_makepkgconf"
sed -Ei "s\\^#?PKGDEST=.*$\\PKGDEST=${_repo}\\" "$_makepkgconf"

# Add zuepfe-original repo for pacman-hacks
cat <<EOF >/etc/pacman.conf
[zuepfe-repkg]
SigLevel = Required DatabaseRequired
Server = http://archlinux.zuepfe.net/\$repo/os/\$arch

[zuepfe-original]
SigLevel = Required DatabaseRequired
Server = http://archlinux.zuepfe.net/\$repo/os/\$arch

$(cat /etc/pacman.conf)
EOF
pacman-key --init
pacman-key --recv-keys FE8CF63AD2306FD41A5500E6DCD45EAF921A7822
pacman-key --recv-keys BFA8FEC40FE5207557484B35C8E50C5960ED8B9C
pacman-key --lsign-key FE8CF63AD2306FD41A5500E6DCD45EAF921A7822
pacman-key --lsign-key BFA8FEC40FE5207557484B35C8E50C5960ED8B9C

# Install build dependencies
pacman -Sy --noconfirm --noprogressbar git pacman base-devel pacman-hacks-build

# Retrieve current packages in repo
_pkgs="$(mktemp)"
if curl -L#Of \
    "https://$(echo "$GITHUB_REPOSITORY" | awk -F'/' '{ printf "%s.github.io/%s",$1,$2; }')/hvolkoff.db"; then
    tar -tvJ ./hvolkoff.db | grep -e "^d" | awk '{print $6}' | tr -d '/' >>_pkgs
fi

# Update submodules
git submodule update --init --remote --recursive

# Build packages
for _path in "$(pwd)"/*; do
    [ -d "$_path" ] || continue
    cd "$_path"
    if [ -f ./PKGBUILD ]; then
        _srcinfo="$(su -- builder makepkg --printsrcinfo | tr -d "[:blank:]")"
        _pkgver="$(echo "$_srcinfo" | awk -F'=' '{ if ($1 == "pkgver") print $2 }')"
        _pkgrel="$(echo "$_srcinfo" | awk -F'=' '{ if ($1 == "pkgrel") print $2 }')"
        _status=0
        for _pkgname in $(echo "$_srcinfo" | awk -F'=' '{ if ($1 == "pkgname") print $2 }'); do
            _return="$(grep "${_pkgname}-${_pkgver}-${_pkgrel}" "$_pkgs" && echo 0 || echo 1)"
            _status=$((_return + _status))
        done
        if [ "$_status" -ne 0 ]; then
            su -- builder makepkg -Cfs --config "$_makepkgconf" --needed --noconfirm --noprogressbar
        fi
    elif [ -f ./REPKGBUILD ]; then
        remakepkg -f
        for _pkg in ./pkg/*.pkg.*; do
            if ! grep "$_pkg" "$_pkgs"; then
                mv "$_pkg" "${_repo}"
            fi
        done
    fi

    cd ..
    rm -f "$_repo"/*.sig
done
