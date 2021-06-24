#!/usr/bin/env bash

set -xeu

### WORKAROUND https://bugs.archlinux.org/index.php?do=details&task_id=69563 ###
# Install CPAN URI
env PERL_MM_USE_DEFAULT=1 perl -MCPAN -e 'CPAN::Shell->install("URI")'

# Parse glic package direct URL from arch repository and Manually install glibc package
curl -L# "$(
    perl -MURI -se 'print URI->new($glibc_path)->abs("https://repo.archlinuxcn.org/x86_64/")' -- \
        -glibc_path="$(
            curl -L# 'https://repo.archlinuxcn.org/x86_64/' |
                perl -ne 'print($_,"\n") for /<a\shref="(glibc-linux.*\.zst)"\s*>/' |
                sort -Vr | head -n1
        )"
)" | bsdtar -C / -xvf-
################################################################################

# makepkg needs a non root user
groupadd builder -g "${PGID:-1000}"
useradd builder -m -u "${PUID:-1000}" -g "${PGID:-1000}"
echo "builder ALL=(ALL) NOPASSWD: ALL" >>/etc/sudoers
chown -R builder:builder .

# Make output repository for packages
mkdir -p /tmp/repo
chown builder:builder /tmp/repo &>/dev/null

# Change some makepkg options
cp /etc/makepkg.conf /tmp/makepkg.conf
sed -Ei 's\^#?PKGEXT=.*$\PKGEXT=.pkg.tar.zst\' /tmp/makepkg.conf
sed -Ei "s\\^#?PKGDEST=.*$\\PKGDEST=/tmp/repo\\" /tmp/makepkg.conf
sed -Ei "s\\^#?MAKEFLAGS=.*$\\MAKEFLAGS=$(nproc)\\" /tmp/makepkg.conf
eval "$(grep 'CARCH' /etc/makepkg.conf)"

# Change keyserve to something that works better
echo "$(cat /etc/pacman.d/gnupg/gpg.conf | sed -e 's@^keyserver\s\s*.*$@keyserver hkp://keyserver.ubuntu.com@')" > /etc/pacman.d/gnupg/gpg.conf

# Add zuepfe-original repo for pacman-hacks
cat <<EOF >>/etc/pacman.conf
[zuepfe-repkg]
SigLevel = Required DatabaseRequired
Server = http://archlinux.zuepfe.net/\$repo/os/\$arch

[zuepfe-original]
SigLevel = Required DatabaseRequired
Server = http://archlinux.zuepfe.net/\$repo/os/\$arch
EOF

# Add zuepfe-original repo keys
pacman-key --init
pacman-key --recv-keys FE8CF63AD2306FD41A5500E6DCD45EAF921A7822
pacman-key --recv-keys BFA8FEC40FE5207557484B35C8E50C5960ED8B9C
pacman-key --edit-key FE8CF63AD2306FD41A5500E6DCD45EAF921A7822
pacman-key --edit-key BFA8FEC40FE5207557484B35C8E50C5960ED8B9C

# Install build dependencies
pacman -Syuq --needed --noconfirm --noprogressbar --overwrite '*' git git-lfs pacman openssh base-devel pacman-hacks-build docker

trap 'git clean -dfX' EXIT

set +x

# Configure gitlab SSH key and remote access
mkdir -p ~/.ssh
printf -- '%s\n' "$GITLAB_DEPLOY_KEY" >~/.ssh/id_ed25519
ssh-keyscan -H gitlab.com >~/.ssh/known_hosts
cat <<EOF >~/.ssh/config
Host gitlab
    HostName gitlab.com
    IdentityFile ~/.ssh/id_ed25519
    User git
EOF
chmod -R 600 ~/.ssh
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519

set -x

# Update submodules
git submodule update --init --remote --recursive

# Remove Github origin
git remote rm origin

# Add Gitlab origin
git remote add origin "$GITLAB_REPO"

# Initialize LFS
git lfs install

# Update repo with new remote
git fetch -apP --all

# Initialize repo branch
git fetch origin repo:repo

# Retrieve repository database and resolve current packages
_repo_path="${REPO}/${CARCH}"
git show "repo:${_repo_path}/${REPO}.db.tar.zst" | tar -tvf - --zst |
    grep -e "^d" | awk '{print $6}' | tr -d '/' >/tmp/packages.txt

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

# Cleanup build leftovers
cd ..
git clean -dfX

# Stash any changes to avoid error when changing branches
restore_stash="true"
if ! git diff-index --quiet HEAD --; then
    git stash -uaq
    restore_stash="git stash apply"
fi

# Change branch to repo
git checkout repo
trap 'git stash -uaq && git checkout main && $restore_stash && chown -R "${PUID:-1000}:${PGID:-1000}" .' EXIT
git clean -dfx

# Ensure repo directory exists
mkdir -p "$_repo_path"

# TODO: Setup repository signing and stop removing signature files
# Remove generated package signature files
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
    git push origin repo
fi

# Avoid any errors on future stages due to permission
chown -R builder:builder .

# Report any package build faulure
if [ "${#_failures[@]}" -gt 0 ]; then
    echo "Failed to build packages:" 1>&2
    printf ' - %s\n' "${_failures[@]}" 1>&2
    exit 1
fi
