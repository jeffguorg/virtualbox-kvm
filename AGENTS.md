# Agent invariants

## Scope

- The main path is VirtualBox with the KVM backend on a physical Linux x86 host.
- Do not claim Hyper-V, GUI, or Guest Additions testing. This exclusion does not
  authorize removing or degrading existing GUI integration code.
- Use `.agents/skills/virtualbox-kvm/SKILL.md` for bug triage, upgrades,
  features, and testing. Keep this file limited to stable invariants; put
  procedures in that skill's references.

## Ownership and patch flow

- `patches/` is the canonical patch directory. Edit or regenerate patches there,
  never an independent packaging copy.
- `packaging/arch/*.patch` entries are symlinks to the canonical patches.
- `packaging/arch/PKGBUILD` owns package version and package source selection.
  Do not move that ownership into documentation or helper scripts.
- The vanilla source baseline is `vbox-base`; `kvm-base` is the ref immediately
  after the imported KVM patch. Local commits after `kvm-base` are exported with
  numbering starting at `0002`; canonical `0001` is copied byte-for-byte.
- Use `scripts/init-source.sh`, `scripts/export-patches.sh`, and
  `scripts/roundtrip-patches.sh` for their documented workflows. They are
  local-only, non-destructive helpers, not package-version managers.

## Engineering rules

- Start from an approved scope. Keep changes minimal and preserve behavior
  outside that scope.
- A clean patch application is not evidence of semantic compatibility. Review
  API, lifecycle, configuration, security, and error-path effects.
- Treat privacy and read-only operation as defaults during diagnosis. Do not
  change host settings, VM definitions, or coredump configuration for triage.
- Do not silently defer a blocker. Distinguish specification requirements,
  technical tradeoffs, product decisions, and explicitly approved deferrals.
- Documentation states mechanisms and policy only. Keep concrete versions,
  dates, current patch inventories, and verification-result snapshots in their
  authoritative sources or change records, not in these documents.

## Definition of done

- The result matches the approved contracts and every decision or deferral is
  explicit.
- Canonical patches, packaging symlinks, and package metadata retain their
  respective ownership rules.
- Patch changes have a fresh-baseline application check and a round-trip tree
  and filesystem equivalence check where applicable.
- Relevant static checks, build checks, and focused regression tests pass.
  Runtime KVM changes use the pinned, verified Alpine `virt` ISO in a headless
  physical-host smoke test; a latest ISO is optional additional coverage only.
- No excluded test surface is claimed, and existing GUI integration remains.
- The report names exact files and commands, distinguishes observed evidence
  from inference, and identifies every unrun check or unresolved blocker.
