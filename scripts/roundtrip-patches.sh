#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
    cat <<'EOF'
Usage: roundtrip-patches.sh VANILLA_SOURCE_REPO BASELINE_REF REFERENCE_PATCH_DIR CANDIDATE_PATCH_DIR

Clone the local vanilla source repository twice, detach both clones at
BASELINE_REF, and git-am each directory's *.patch files in LC_ALL=C sorted order.
Success requires equal HEAD^{tree} IDs and recursive equality of working-tree
content, file types, modes, and symlink targets without dereferencing symlinks.

Only local inputs are used. Inputs are never modified, and temporary clones are
removed on success or failure.
Temporary clones default to the user cache directory. Set VBOX_KVM_TMPDIR to
select a different parent; neither /tmp nor the input repositories are required.
EOF
}

die() {
    printf 'roundtrip-patches.sh: %s\n' "$*" >&2
    exit 1
}

collect_patches() {
    local directory=$1
    local label=$2
    local patch

    [[ -d $directory ]] || die "$label is not a directory: $directory"
    PATCHES=()
    shopt -s nullglob
    PATCHES=("$directory"/*.patch)
    shopt -u nullglob
    for patch in "${PATCHES[@]}"; do
        [[ -f $patch && -r $patch ]] ||
            die "$label contains an unreadable patch: $patch"
    done
}

apply_patches() {
    local repository=$1
    shift
    local -a patches=("$@")

    ((${#patches[@]} > 0)) || return 0
    git -C "$repository" \
        -c user.name=virtualbox-kvm-automation \
        -c user.email=virtualbox-kvm@localhost \
        -c commit.gpgsign=false \
        am -- "${patches[@]}"
}

write_metadata_manifest() {
    local repository=$1
    local output=$2

    (
        cd "$repository"
        find -P . -path ./.git -prune -o -printf '%y %m %P -> %l\0'
    ) | sort -z >"$output"
}

if (($# == 1)) && [[ $1 == -h || $1 == --help ]]; then
    usage
    exit 0
fi
if (($# != 4)); then
    usage >&2
    exit 2
fi

for command_name in git realpath mktemp mkdir rm diff cmp find sort; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

source_repo=$(realpath -e -- "$1") || die "source repository does not exist: $1"
[[ -d $source_repo ]] || die "source repository is not a directory: $source_repo"
[[ $(git -C "$source_repo" rev-parse --is-inside-work-tree 2>/dev/null) == true ]] ||
    die "not a non-bare Git repository: $source_repo"
baseline_ref=$2
baseline_commit=$(git -C "$source_repo" rev-parse --verify --end-of-options "${baseline_ref}^{commit}") ||
    die "baseline ref is not a commit: $baseline_ref"
reference_dir=$(realpath -e -- "$3") || die "reference patch directory does not exist: $3"
candidate_dir=$(realpath -e -- "$4") || die "candidate patch directory does not exist: $4"

collect_patches "$reference_dir" reference
reference_patches=("${PATCHES[@]}")
collect_patches "$candidate_dir" candidate
candidate_patches=("${PATCHES[@]}")

cache_home=${XDG_CACHE_HOME:-${HOME:-}}
if [[ -z ${VBOX_KVM_TMPDIR:-} && -z $cache_home ]]; then
    die 'set VBOX_KVM_TMPDIR when neither XDG_CACHE_HOME nor HOME is available'
fi
temporary_parent=${VBOX_KVM_TMPDIR:-"$cache_home/virtualbox-kvm"}
mkdir -p -- "$temporary_parent"
temporary_root=$(mktemp -d "$temporary_parent/roundtrip-patches.XXXXXX")
cleanup() {
    if [[ -n ${temporary_root:-} && -d $temporary_root ]]; then
        rm -rf -- "$temporary_root"
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

reference_clone=$temporary_root/reference
candidate_clone=$temporary_root/candidate
git clone --quiet --no-local --no-checkout -- "$source_repo" "$reference_clone"
git clone --quiet --no-local --no-checkout -- "$source_repo" "$candidate_clone"
git -C "$reference_clone" checkout --quiet --detach "$baseline_commit"
git -C "$candidate_clone" checkout --quiet --detach "$baseline_commit"

apply_patches "$reference_clone" "${reference_patches[@]}"
apply_patches "$candidate_clone" "${candidate_patches[@]}"

reference_tree=$(git -C "$reference_clone" rev-parse 'HEAD^{tree}')
candidate_tree=$(git -C "$candidate_clone" rev-parse 'HEAD^{tree}')
write_metadata_manifest "$reference_clone" "$temporary_root/reference.manifest"
write_metadata_manifest "$candidate_clone" "$temporary_root/candidate.manifest"

filesystem_status=0
diff --recursive --no-dereference --exclude=.git -- \
    "$reference_clone" "$candidate_clone" || filesystem_status=$?
((filesystem_status <= 1)) || die "filesystem comparison failed"
metadata_equal=1
if ! cmp -s "$temporary_root/reference.manifest" "$temporary_root/candidate.manifest"; then
    metadata_equal=0
    printf '%s\n' 'Filesystem metadata differs (file type, mode, path, or symlink target).' >&2
fi

if [[ $reference_tree != "$candidate_tree" ]] ||
    ((filesystem_status != 0)) || ((metadata_equal == 0)); then
    printf 'Reference tree: %s\nCandidate tree: %s\n' \
        "$reference_tree" "$candidate_tree" >&2
    die "reference and candidate patch sets are not equivalent"
fi

printf 'Round trip matches: tree %s; content, modes, and symlinks are equal.\n' \
    "$reference_tree"
