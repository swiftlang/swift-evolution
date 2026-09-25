# Deployment target conditional compilation

* Proposal: [SE-NNNN](NNNN-deployment-target-conditional-compilation.md)
* Author: [Jiaxu Li](https://github.com/Jiaxu-Li)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swift prototype](https://github.com/Jiaxu-Li/swift/tree/deployment-target-ifconfig),
  [swift-syntax prototype](https://github.com/Jiaxu-Li/swift-syntax/tree/deployment-target-ifconfig)
* Review: ([pitch](https://forums.swift.org/t/pitch-conditional-compilation-for-the-deployment-target/89282))

## Summary of changes

Adds `deploymentTargetAtLeast(...)`, a conditional compilation predicate that
selects source according to the module's minimum deployment target, using
availability-style platform-version requirements.

## Motivation

Swift can test whether an API is available at runtime:

```swift
if #available(macOS 15, iOS 18, *) {
  useNewImplementation()
} else {
  useFallbackImplementation()
}
```

This cannot select between imports, type aliases, conformances, stored
properties, or complete declarations. Those choices have to be made while the
module is being compiled.

For example, a library rebuilt for an application's deployment target might use
`Mutex` when that target guarantees its availability, while retaining an older
lock representation for earlier targets:

```swift
#if deploymentTargetAtLeast(macOS 15, iOS 18, *)
import Synchronization
typealias Lock<State> = Mutex<State>
#else
import os
typealias Lock<State> = OSAllocatedUnfairLock<State>
#endif
```

A project can approximate this today by defining its own compilation condition:

```swift
#if USE_SYNCHRONIZATION_MUTEX
// New implementation
#else
// Backwards-compatible implementation
#endif
```

The build system must derive `USE_SYNCHRONIZATION_MUTEX` from the deployment
target and keep the two values in sync. If they diverge, the selected source no
longer reflects the binary's minimum OS requirement. The compiler already has
this information in the target triple.

This is distinct from an SDK check: two modules can use the same SDK while
targeting different minimum OS versions.

## Proposed solution

Introduce `deploymentTargetAtLeast(...)` as a condition accepted by `#if`:

```swift
#if deploymentTargetAtLeast(macOS 15, iOS 18, *)
// Compiled when the active platform's minimum deployment target meets the
// corresponding requirement, or when the active platform is not listed.
#else
// Compiled when the active platform's minimum deployment target is earlier
// than the corresponding requirement.
#endif
```

The arguments use the platform-version spelling of availability queries. Only
the active platform's requirement is tested. The final `*` means the condition
evaluates to `true` on all other platforms.

For the example above:

| Compilation target | Result |
| --- | --- |
| macOS 14 | `false` |
| macOS 15 or later | `true` |
| iOS 17 | `false` |
| iOS 18 or later | `true` |
| Linux | `true`, through `*` |

The prototype is enabled with
`-enable-experimental-feature DeploymentTargetCondition`. The flag is not part
of the proposed source syntax.

## Detailed design

### Syntax

The new condition has the following grammar:

```text
deployment-target-condition ->
  'deploymentTargetAtLeast' '(' deployment-target-arguments ')'

deployment-target-arguments -> '*'
deployment-target-arguments -> deployment-target-requirements ',' '*'

deployment-target-requirements -> deployment-target-requirement
deployment-target-requirements ->
  deployment-target-requirements ',' deployment-target-requirement

deployment-target-requirement -> identifier version
version -> decimal-digits
version -> version '.' decimal-digits
```

The wildcard is required, may appear only once, and must be the last argument.
`deploymentTargetAtLeast(*)` is valid and always evaluates to `true`.

As with other conditional compilation predicates, the condition can be combined
with `!`, `&&`, `||`, and parentheses:

```swift
#if deploymentTargetAtLeast(macOS 15, *) && canImport(Synchronization)
// ...
#endif
```

Versions consist of one or more unsigned decimal components separated by
periods. They are compared component by component, with omitted trailing
components treated as zero. For example, `15` and `15.0` compare as equal.

### Platform matching

Platform names, aliases, and the applicability of platform requirements follow
`if #available(...)`. A platform may not be listed twice. When more than one
requirement applies, the most specific one determines the version that is
tested. For example, a `macCatalyst` requirement takes precedence over an
`iOS` requirement on Mac Catalyst. If no requirement applies, `*` makes the
condition `true`.

The platform owner determines the applicability relationships and any version
mapping needed for this behavior. The proposal does not prescribe how the
compiler obtains or stores that information.

An unrecognized platform name produces a warning and cannot match a target
known to that compiler, so the wildcard determines the result. This allows
older compilers to encounter future platform names while still diagnosing
likely misspellings.

### Obtaining and comparing the deployment target

The condition uses the minimum deployment version in the current module's
target triple. The prototype exposes that value through the build configuration
used by both the compiler and `SwiftIfConfig`.

The initial implementation obtains meaningful versions for macOS, iOS, tvOS,
watchOS, visionOS, Mac Catalyst, Windows, and Android. Android uses the
environment version from its target triple, which represents the API level.
Targets such as Linux do not currently carry a deployment version that Swift can
use for this comparison.

If a requirement explicitly names the active platform but the compiler cannot
obtain a deployment version for it, compilation fails:

```swift
// Error when compiling for Linux because the target has no deployment version.
#if deploymentTargetAtLeast(Linux 6, *)
// ...
#endif
```

`if #available(...)` accepts such a platform and treats the check as satisfied,
because a runtime query can fall back on the running system. This condition has
nothing to compare against when the target carries no deployment version, and
silently answering `true` or `false` would select a branch for a reason the
source does not state, so it is diagnosed instead.

The same target can remain portable by leaving Linux to the wildcard:

```swift
// Evaluates to true on Linux through '*'.
#if deploymentTargetAtLeast(macOS 15, iOS 18, *)
// ...
#endif
```

Malformed arguments, invalid versions, duplicate platforms, a missing or
misplaced wildcard, and an unavailable deployment version are errors. An
unrecognized platform name produces a warning.

### Compilation model

`deploymentTargetAtLeast(...)` is an ordinary source-level `#if` condition. It
is evaluated in the context of the module containing it, and only the active
branch proceeds through the rest of compilation. A compiled module therefore
contains the branch selected for that module's deployment target.

The condition is not retained for reevaluation after serialization or
cross-module inlining. If a library is compiled for macOS 14 and later linked
into an application targeting macOS 15, its condition remains evaluated for
macOS 14. Rebuilding the library for another target evaluates it again.

The condition does not compare the SDK version, make declarations visible, or
bypass normal availability checking. Source in the selected branch must still
compile against the SDK used for the build.

## Source compatibility

This proposal is additive. `deploymentTargetAtLeast` is recognized only as a
conditional compilation predicate and does not become a keyword in ordinary
Swift source. Existing valid programs continue to parse and behave as before.

Source that adopts the condition requires compiler support. Packages supporting
older compilers can place uses behind an outer compiler-version condition.

## ABI compatibility

The condition requires no runtime or ABI changes. As with existing conditional
compilation, different builds can contain different declarations or stored
representations. Authors distributing binary variants remain responsible for
their ABI guarantees.

## Implications on adoption

No runtime or standard library support is required. Changing the deployment
target can change the selected branch, so the module must be rebuilt when its
target triple changes. A prebuilt module keeps the branch selected when it was
built; importing it does not reevaluate the condition for the client's target.

## Future directions

### An optimizer-visible deployment target condition

An expression such as `if #deploymentTarget(...)` could be preserved in SIL for
evaluation after cross-module inlining, allowing a choice to depend on the final
client's deployment target. That requires a different compilation model and is
outside this proposal.

### SDK conditional compilation

A separate condition could expose the SDK version. It would complement rather
than replace a deployment-target condition.

## Alternatives considered

### A platform-independent version comparison

The original pitch used a single version comparison:

```swift
#if deploymentTarget(>=27.0)
// ...
#endif
```

This is concise for one platform but cumbersome in cross-platform source. The
same facility can arrive in different platform releases, and many non-Apple
targets have no deployment version. The availability-style list keeps each
platform with its version and gives unlisted platforms explicit wildcard
behavior.

### User-defined compilation conditions

A build system can pass a condition with `-D`, but it must calculate the
condition independently and keep it synchronized with the deployment target.
This duplicates information already held by the compiler and makes builds
dependent on project-specific configuration.

### Runtime availability checks

`if #available(...)` should remain the preferred choice when the decision can be
made at runtime. It follows control flow and can make newer APIs available within
its guarded branch. It cannot, however, select imports, stored representation,
conformances, type aliases, or other declarations before type checking.

### Declaration-based compile-time availability

A spelling such as `#if available(Synchronization.Mutex)` would state the reason
for a check more directly than a platform version. Conditional compilation is
evaluated before imported modules are loaded and their declaration availability
can be inspected, so this does not fit the existing `#if` compilation model. It
also answers a different question from whether a module's minimum deployment
target meets an explicit requirement.

### An SDK version condition

Checking the SDK would not solve the deployment-target use case. A project can
use a current SDK while continuing to support older OS releases, and two modules
built with the same SDK can have different deployment targets.

## Acknowledgments

Thanks to everyone who participated in the
[pitch discussion](https://forums.swift.org/t/pitch-conditional-compilation-for-the-deployment-target/89282)
and helped refine the scope, platform-matching rules, and behavior for targets
without a deployment version.
