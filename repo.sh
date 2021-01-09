#!/usr/bin/env bash

set -xeu

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
pacman -Syq --noconfirm --noprogressbar git git-lfs pacman openssh base-devel pacman-hacks-build

trap 'git clean -dfX' EXIT

set +x

# Configure gitlab SSH key and access
mkdir ~/.ssh
printf -- '%s' "$GITLAB_DEPLOY_KEY" >~/.ssh/id_ed25519
ssh-keyscan -H gitlab.com >~/.ssh/known_hosts
cat <<EOF >~/.ssh/config
Host gitlab
    HostName gitlab.com
    IdentityFile ~/.ssh/id_ed25519
    User git
EOF
chmod -R 600 ~/.ssh
ssh-agent -a /tmp/ssh-auth.sock
export SSH_AUTH_SOCK=/tmp/ssh-auth.sock
ssh-add ~/.ssh/id_ed25519

set -x

# Retrieve current packages in repo
_repo_path="${REPO}/${CARCH}"
git remote add gitlab "$GITLAB_REPO"
git fetch gitlab repo:repo
git show "repo:${_repo_path}/${REPO}.db.tar.zst" | tar -tvf - --zst |
    grep -e "^d" | awk '{print $6}' | tr -d '/' >/tmp/packages.txt
chown builder:builder /tmp/packages.txt

# Update submodules
git lfs install
git submodule update --init --remote --recursive

# Build packages
_failures=()
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
            if ! su -- builder makepkg -Ccfs --config /tmp/makepkg.conf --needed --noconfirm --noprogressbar; then
                _failures+=("$_path")
            fi
        fi
    elif [ -f ./REPKGBUILD ]; then
        if ! remakepkg -d -f -R "$(cat ./REPKGREL 2>/dev/null || echo '1')"; then
            _failures+=("$_path")
            continue
        fi
        for _pkg in ./*.pkg.*; do
            mv "$_pkg" /tmp/repo/
        done
        rm -fr ./pkg
    fi
done

# Change branch to repo
cd ..

git clean -dfX

restore_stash="true"
if ! git diff-index --quiet HEAD --; then
    git stash -uaq
    restore_stash="git stash apply"
fi

git checkout repo
trap 'git stash -uaq && git checkout main && $restore_stash && chown -R "${PUID:-1000}:${PGID:-1000}" .' EXIT
git clean -dfx

# Ensure repo directory exists
mkdir -p "$_repo_path"

# Remove generated pacakge signature files
rm -f /tmp/repo/*.sig

# Only copy packages which are not already present in database
_pkgs=()
while IFS= read -r -d '' _pkg; do
    _pkginfo="$(tar -Oxf "$_pkg" .PKGINFO)"
    _pkgver="$(echo "$_pkginfo" | awk -F' = ' '{ if ($1 == "pkgver") print $2 }')"
    _pkgname="$(echo "$_pkginfo" | awk -F' = ' '{ if ($1 == "pkgname") print $2 }')"
    if ! grep -q "${_pkgname}-${_pkgver}" /tmp/packages.txt; then
        mv "$_pkg" "${_repo_path}/"
        _pkgs+=("${_repo_path}/$(basename "$_pkg")")
    fi
done < <(find /tmp/repo -type f -name '*.pkg.*' -print0 | sort -zt-)

# Generate new repository database
echo "${_pkgs[@]}" | xargs -r repo-add -n -R "${_repo_path}/${REPO}.db.tar.zst"

# Resolve symlinks to hard copies
find . -type l -print0 | xargs -0rI{} sh -c 'cp --remove-destination "$(realpath "$1")" "$1"' sh {}

# Commit/push new packages
git add -A
if git commit -m "$(printf 'Update repository packages:\n%s' "$(git diff --cached --name-status)")"; then
    git push gitlab repo
fi
chown -R "${PUID:-1000}:${PGID:-1000}" .

if [ "${#_failures[@]}" -gt 0 ]; then
    echo "Failed to build packages:" 1>&2
    printf ' - %s\n' "${_failures[@]}" 1>&2
    exit 1
fi
