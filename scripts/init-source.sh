#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
    cat <<'EOF'
Usage: init-source.sh OFFICIAL_ARCHIVE PATCH_DIR DESTINATION

Extract one official VirtualBox source archive into a new or empty directory,
create a vanilla Git commit and vbox-base branch, then apply PATCH_DIR/*.patch
in LC_ALL=C sorted order with git am. The kvm-base branch is created immediately
after the first patch, and the work branch is left checked out.

No network access is performed. DESTINATION is published only after every patch
applies successfully; an existing nonempty destination is never overwritten.
EOF
}

die() {
    printf 'init-source.sh: %s\n' "$*" >&2
    exit 1
}

assert_empty_destination() {
    local destination=$1
    local -a entries=()

    if [[ -e $destination || -L $destination ]]; then
        [[ -d $destination && ! -L $destination ]] ||
            die "destination is not a real directory: $destination"
        shopt -s nullglob dotglob
        entries=("$destination"/*)
        shopt -u nullglob dotglob
        ((${#entries[@]} == 0)) ||
            die "destination is not empty: $destination"
    fi
}

if (($# == 1)) && [[ $1 == -h || $1 == --help ]]; then
    usage
    exit 0
fi
if (($# != 3)); then
    usage >&2
    exit 2
fi

for command_name in git tar realpath mktemp mv rmdir rm; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

archive=$(realpath -e -- "$1") || die "archive does not exist: $1"
[[ -f $archive && -r $archive ]] || die "archive is not a readable file: $archive"
patch_dir=$(realpath -e -- "$2") || die "patch directory does not exist: $2"
[[ -d $patch_dir ]] || die "patch input is not a directory: $patch_dir"
[[ ! -L $3 ]] || die "destination must not be a symbolic link: $3"
destination=$(realpath -m -- "$3") || die "cannot resolve destination: $3"
[[ $destination != / ]] || die "destination must not be the filesystem root"
assert_empty_destination "$destination"
parent=${destination%/*}
[[ -n $parent ]] || parent=/
[[ -d $parent ]] || die "destination parent does not exist: $parent"

shopt -s nullglob
patches=("$patch_dir"/*.patch)
shopt -u nullglob
((${#patches[@]} > 0)) || die "no .patch files found in: $patch_dir"
for patch in "${patches[@]}"; do
    [[ -f $patch && -r $patch ]] || die "patch is not a readable file: $patch"
    patch_name=${patch##*/}
    [[ $patch_name =~ ^[0-9]{4}-.+\.patch$ ]] ||
        die "patch name must start with a four-digit sequence: $patch_name"
done
[[ ${patches[0]##*/} == 0001-*.patch ]] ||
    die "the first sorted patch must be numbered 0001"

staging=$(mktemp -d --tmpdir="$parent" .init-source.XXXXXX)
cleanup() {
    if [[ -n ${staging:-} && -d $staging ]]; then
        rm -rf -- "$staging"
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -- "$staging/extract"
if ! tar -tf "$archive" >/dev/null; then
    die "cannot read source archive: $archive"
fi
tar -xf "$archive" -C "$staging/extract"

shopt -s nullglob dotglob
archive_entries=("$staging/extract"/*)
shopt -u nullglob dotglob
((${#archive_entries[@]} == 1)) ||
    die "archive must contain exactly one top-level directory"
source_root=${archive_entries[0]}
[[ -d $source_root && ! -L $source_root ]] ||
    die "archive top level must be a real directory"

git init --quiet --initial-branch=work "$source_root"
git_local=(
    git -C "$source_root"
    -c user.name=virtualbox-kvm-automation
    -c user.email=virtualbox-kvm@localhost
    -c commit.gpgsign=false
)
"${git_local[@]}" add -A -- .
"${git_local[@]}" commit --quiet -m "VirtualBox vanilla source"
"${git_local[@]}" branch vbox-base

"${git_local[@]}" am -- "${patches[0]}"
"${git_local[@]}" branch kvm-base
for patch in "${patches[@]:1}"; do
    "${git_local[@]}" am -- "$patch"
done

assert_empty_destination "$destination"
if [[ -d $destination ]]; then
    rmdir -- "$destination"
fi
[[ ! -e $destination && ! -L $destination ]] ||
    die "destination appeared during initialization: $destination"
mv -T -- "$source_root" "$destination"

printf 'Initialized %s\n' "$destination"
printf 'Current branch: work; baseline refs: vbox-base, kvm-base\n'
