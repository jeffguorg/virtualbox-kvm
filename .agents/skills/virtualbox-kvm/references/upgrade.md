# Source and patch upgrades

## Acquire authoritative inputs

Use the approved target VirtualBox release and its official source archive.
Obtain the archive and authenticity or integrity metadata from the official
VirtualBox distribution channel, and verify the local archive before extraction.
Use the corresponding authoritative KVM-patch source when refreshing the
imported patch. Do not substitute a moving development branch, an unofficial
mirror, or a latest-release guess for the approved inputs.

Acquisition and verification happen outside the helper scripts; the scripts
accept local files and perform no network access. Record provenance in the
change record rather than copying concrete versions or verification snapshots
into these documents.

## Create a fresh baseline

Work in a new or empty destination. Do not reuse a build tree as a vanilla
baseline and do not overwrite a nonempty worktree.

```bash
scripts/init-source.sh /path/to/official-source-archive /path/to/candidate-patches /path/to/new-worktree
```

The script creates `vbox-base` on the vanilla commit, applies patches in sorted
order with `git am`, creates `kvm-base` immediately after the first imported
patch, and leaves the remaining commits on the work branch. A failed import
removes its unpublished staging tree. Inspect the error output, resolve the
input or conflict deliberately, and retry in a fresh destination rather than
dropping hunks to make application succeed.

Regenerate local commits into an empty staging directory:

```bash
scripts/export-patches.sh /path/to/worktree /path/to/canonical-patch-repo /path/to/empty-export
```

The canonical `0001` patch is copied unchanged. Commits after `kvm-base` are
formatted from `0002`. Review the staged patches before any separately approved
canonical update. Packaging symlinks continue to reference root `patches/`, and
package version/source changes remain a separate, explicit PKGBUILD operation.

## Classify conflicts and changes

Classify each conflict or reviewed difference using all applicable categories:

- **Context drift:** unchanged logic moved or nearby text changed.
- **API or semantic change:** interfaces, invariants, locking, object lifetime,
  error handling, or execution ordering changed.
- **Relocation:** code moved between files or components and must be reapplied
  at the new owner.
- **Add/delete/rename or mode change:** patch paths, file types, executable
  bits, or symlink targets need reconciliation.
- **Already upstream or superseded:** the base now supplies equivalent behavior;
  prove equivalence before removing a hunk.
- **Patch dependency or ordering:** one local change relies on an earlier one or
  on imported KVM behavior.
- **Generated/source mismatch:** determine the authoritative source and the
  project's generation policy instead of editing both blindly.

Record unresolved conflicts as blockers. Do not hide them with whitespace-only
or compile-only repairs.

## Review semantic impact even when application is clean

A clean `git am` establishes textual application only. Review each patch against
the new source for changed callers and callees, configuration defaults, CLI and
VM-state compatibility, security and privilege boundaries, host resource
lifecycles, failure paths, and architecture assumptions. Pay particular
attention to KVM/NEM execution semantics and to shared code that also supports
existing GUI integration.

Behavior changes require the feature specification and decision classifications
in `feature.md`; an upgrade does not implicitly approve a new product behavior.

## Prove the candidate

Use a fresh candidate worktree and run focused build and runtime checks from
`testing.md`. Compare reference and candidate patch sets without modifying
either input:

```bash
scripts/roundtrip-patches.sh /path/to/vanilla-repo vbox-base /path/to/reference-patches /path/to/candidate-patches
```

The reference and candidate must produce the same `HEAD^{tree}` and equivalent
recursive file content, file types, modes, and symlink targets when equivalence
is the goal. If behavior is intentionally different, use the comparison to
review the expected difference rather than claiming equivalence. A latest ISO
run is optional extra information and cannot replace the pinned main smoke
test.
