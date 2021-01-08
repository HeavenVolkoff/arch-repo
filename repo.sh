#!/usr/bin/env bash

set -xeu

trap 'git clean -dfX' EXIT

# makepkg needs a non root user
groupadd builder -g "${PGID:-1000}"
useradd builder -m -u "${PUID:-1000}" -g "${PGID:-1000}"
echo "builder ALL=(ALL) NOPASSWD: ALL" >>/etc/sudoers
chown -R builder:builder .

# Make output repository for pakcages
mkdir -p /tmp/repo
chown builder:builder /tmp/repo

# Change some makepkg options
cp /etc/makepkg.conf /tmp/makepkg.conf
chown builder:builder /tmp/makepkg.conf
sed -Ei 's\^#?PKGEXT=.*$\PKGEXT=.pkg.tar.zst\' /tmp/makepkg.conf
sed -Ei "s\\^#?PKGDEST=.*$\\PKGDEST=/tmp/repo\\" /tmp/makepkg.conf
sed -Ei "s\\^#?MAKEFLAGS=.*$\\MAKEFLAGS=$(nproc)\\" /tmp/makepkg.conf
eval "$(grep 'CARCH' /etc/makepkg.conf)"

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
pacman -Syq --noconfirm --noprogressbar git pacman base-devel pacman-hacks-build

# Retrieve current packages in repo
_repo_path="${REPO}/${CARCH}"
git fetch origin repo:repo
git show "repo:${_repo_path}/${REPO}.db.tar.zst" | tar -tvf - --zst |
    grep -e "^d" | awk '{print $6}' | tr -d '/' >/tmp/packages.txt
chown builder:builder /tmp/packages.txt

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
            if echo "$_pkgname" | grep -qE -- '-git$'; then
                _status=1
                break
            fi
            _return="$(grep -q "${_pkgname}-${_pkgver}-${_pkgrel}" /tmp/packages.txt && echo 0 || echo 1)"
            _status=$((_return + _status))
        done
        if [ "$_status" -ne 0 ]; then
            su -- builder makepkg -Ccfs --config /tmp/makepkg.conf --needed --noconfirm --noprogressbar
        fi
    elif [ -f ./REPKGBUILD ]; then
        remakepkg -f --repkgrel "$(cat ./REPKGREL 2>/dev/null || echo '1')"
        for _pkg in ./*.pkg.*; do
            mv "$_pkg" /tmp/repo/
        done
        rm -fr ./pkg
    fi
done

cd ..
rm -f /tmp/repo/*.sig
if [ -z "$(find /tmp/repo -maxdepth 0 -type d -empty)" ]; then
    git clean -dfX

    restore_stash="true"
    if ! git diff-index --quiet HEAD --; then
        git stash -uaq
        restore_stash="git stash apply"
    fi

    git checkout repo
    trap 'git stash -uaq && git checkout main && $restore_stash && chown -R "${PUID:-1000}:${PGID:-1000}" .' EXIT

    git clean -xfd
    mkdir -p "$_repo_path"
    mv /tmp/repo/* "${_repo_path}/"
    repo-add "${_repo_path}/${REPO}.db.tar.zst" "${_repo_path}"/*.pkg.*
    git add -A
    git commit --amend -m "Update repository packages"
    git push --force-with-lease origin repo
    chown -R "${PUID:-1000}:${PGID:-1000}" .
fi
