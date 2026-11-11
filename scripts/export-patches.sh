#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
    cat <<'EOF'
Usage: export-patches.sh VIRTUALBOX_REPO CANONICAL_PATCH_REPO_OR_DIR OUTPUT_DIR [BASE_REF]

Copy the canonical 0001 patch unchanged and format commits after BASE_REF from
VIRTUALBOX_REPO with numbering starting at 2. BASE_REF defaults to kvm-base.
CANONICAL_PATCH_REPO_OR_DIR may be a repository containing patches/ or the patch
directory itself.

OUTPUT_DIR must be new or empty and is used only for staged export. No canonical
patch is modified, no network access is performed, and a nonempty destination
is never overwritten.
EOF
}

die() {
    printf 'export-patches.sh: %s\n' "$*" >&2
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
if (($# < 3 || $# > 4)); then
    usage >&2
    exit 2
fi

for command_name in git realpath mktemp cp mv rmdir rm; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

vbox_repo=$(realpath -e -- "$1") || die "VirtualBox repository does not exist: $1"
[[ -d $vbox_repo ]] || die "VirtualBox repository is not a directory: $vbox_repo"
[[ $(git -C "$vbox_repo" rev-parse --is-inside-work-tree 2>/dev/null) == true ]] ||
    die "not a non-bare Git repository: $vbox_repo"
canonical_input=$(realpath -e -- "$2") || die "canonical patch input does not exist: $2"
[[ -d $canonical_input ]] || die "canonical patch input is not a directory: $canonical_input"
canonical_dir=$canonical_input
if [[ -d $canonical_input/patches ]]; then
    canonical_dir=$canonical_input/patches
fi
[[ ! -L $3 ]] || die "output directory must not be a symbolic link: $3"
output_dir=$(realpath -m -- "$3") || die "cannot resolve output directory: $3"
[[ $output_dir != / ]] || die "output directory must not be the filesystem root"
assert_empty_destination "$output_dir"
parent=${output_dir%/*}
[[ -n $parent ]] || parent=/
[[ -d $parent ]] || die "output parent does not exist: $parent"
base_ref=${4:-kvm-base}

base_commit=$(git -C "$vbox_repo" rev-parse --verify --end-of-options "${base_ref}^{commit}") ||
    die "base ref is not a commit: $base_ref"
git -C "$vbox_repo" rev-parse --verify --end-of-options 'HEAD^{commit}' >/dev/null ||
    die "VirtualBox repository HEAD is not a commit"
if ! git -C "$vbox_repo" merge-base --is-ancestor "$base_commit" HEAD; then
    die "base ref is not an ancestor of HEAD: $base_ref"
fi

shopt -s nullglob
first_patches=("$canonical_dir"/0001-*.patch)
shopt -u nullglob
((${#first_patches[@]} == 1)) ||
    die "canonical patch directory must contain exactly one 0001-*.patch"
first_patch=${first_patches[0]}
[[ -f $first_patch && -r $first_patch ]] ||
    die "canonical first patch is not a readable file: $first_patch"

staging=$(mktemp -d --tmpdir="$parent" .export-patches.XXXXXX)
cleanup() {
    if [[ -n ${staging:-} && -d $staging ]]; then
        rm -rf -- "$staging"
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cp -- "$first_patch" "$staging/${first_patch##*/}"
git -C "$vbox_repo" format-patch --quiet --start-number 2 \
    --output-directory "$staging" "${base_commit}..HEAD"

assert_empty_destination "$output_dir"
if [[ -d $output_dir ]]; then
    rmdir -- "$output_dir"
fi
[[ ! -e $output_dir && ! -L $output_dir ]] ||
    die "output directory appeared during export: $output_dir"
mv -T -- "$staging" "$output_dir"

printf 'Exported patches to %s (base %s)\n' "$output_dir" "$base_ref"
