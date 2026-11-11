# Feature development

## Require an approved specification

Do not infer product behavior from an issue title or implement a preferred
solution while requirements remain open. The approved specification defines
the goal, non-goals, users, observable behavior, and acceptance evidence for
the physical-host Linux x86 KVM main path.

Define relevant contracts before editing:

- CLI, API, VM-configuration, and persisted-state compatibility.
- Defaults, validation, error messages, rollback, and failure recovery.
- Host resource ownership, naming, lifecycle, concurrency, and cleanup.
- Privilege boundaries, helper behavior, security properties, and privacy.
- Interaction with KVM/NEM, storage, networking, and existing front ends.
- Migration behavior, observability, support diagnostics, and test coverage.

Hyper-V, GUI, and Guest Additions testing are not acceptance requirements.
This exclusion must not remove, bypass, or degrade existing GUI integration
code or silently change shared front-end contracts.

## Classify every requirement and issue

Use these explicit classifications in the plan and review:

- **`spec-required`:** mandatory approved behavior or compatibility. It cannot
  be dropped or deferred without changing the approved specification.
- **`technical tradeoff`:** multiple implementations satisfy the contract but
  differ in complexity, risk, performance, maintainability, or compatibility.
  Present options, evidence, recommendation, and selected approach.
- **`product decision`:** externally observable policy or UX is unspecified.
  Stop the affected implementation until the decision is made; do not choose a
  policy by convenience.
- **`deferred`:** work explicitly excluded by the approver, with scope, reason,
  impact, and a follow-up owner or trigger. Deferral is not a silent disposal
  mechanism.

A failed build, unresolved contract, security concern, data-loss risk, or
missing acceptance criterion is a blocker. Mark it **blocked** and report the
required decision or evidence. It cannot be reclassified as `deferred` without
explicit approval. Partial delivery must identify every unmet `spec-required`
item.

## Implement within the patch ownership model

Keep changes on the VirtualBox work branch after `kvm-base`, with focused
commits and tests appropriate to the changed layer. Root `patches/` remains
canonical; packaging entries remain symlinks, and package version/source
selection stays in PKGBUILD.

Use `scripts/export-patches.sh` to stage canonical `0001` unchanged and format
local commits from `0002`. Review staged patches before an approved canonical
update. Do not hand-edit generated exports in two places.

Preserve unrelated behavior and existing integration surfaces. If a contract
change is discovered during implementation, pause that part and obtain a
classification and decision rather than broadening scope.

## Acceptance

Map each `spec-required` item to concrete evidence. Include negative cases,
invalid input, permission failures, cleanup after failure, and compatibility
with existing configurations where relevant. Run the checks in `testing.md`,
including the pinned, headless physical-host KVM smoke test for runtime-affecting
changes. State any optional latest-ISO result separately and never as a
substitute.
