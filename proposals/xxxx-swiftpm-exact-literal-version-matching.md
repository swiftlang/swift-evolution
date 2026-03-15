# Opt-in exact matching for version identifiers with build metadata

* Proposal: [SE-xxxx](xxxx-swiftpm-exact-literal-version-matching.md)
* Authors: [Byoungchan Lee](https://github.com/bc-lee)
* Review Manager: TBD
* Status: **Pitch**
* Bugs: [swiftlang/swift-package-manager#6675](https://github.com/swiftlang/swift-package-manager/issues/6675), [swiftlang/swift#80711](https://github.com/swiftlang/swift/issues/80711)
* Implementation: TBD
* Review: ([Pitch](https://forums.swift.org/t/pitch-swiftpm-opt-in-exact-matching-for-version-tags-that-include-semver-build-metadata/84691))

## Introduction

Swift Package Manager follows Semantic Versioning 2.0.0 for version precedence,
so build metadata (`+...`) is ignored when comparing versions. That is correct
for ranges, but it prevents a package from explicitly selecting a published
variant such as `1.0.0+debug` over `1.0.0+release`.

This proposal adds an opt-in manifest API, `.exactLiteral(...)`, that matches a
version identifier literally, including build metadata, while leaving existing
`.exact(...)` and range behavior unchanged.

## Motivation

SemVer says build metadata should be ignored for version *precedence*. SwiftPM
correctly applies that rule today, but precedence and exact selection are not
the same problem.

Some publishers use build metadata to distinguish variants that should share the
same SemVer ordering:

- `1.0.0+debug` vs. `1.0.0+release`
- `1.0.0+vendor.1`
- `1.0.0+corp.20250324`

Today, `.exact("1.0.0+debug")` does not guarantee selection of that exact
identifier because SwiftPM ignores build metadata when matching exact version
requirements.

The existing workarounds are poor fits:

- `revision:` is not a version-level selector and does not work for registry
  dependencies.
- Pre-release versions such as `1.0.0-debug` are semantically different from
  build metadata and change ordering.
- Separate package names fragment the dependency graph.

SwiftPM needs a small, explicit way to select a specific published variant
without changing existing dependency semantics.

## Proposed solution

Add a new requirement constructor:

```swift
.exactLiteral("1.0.0+debug")
```

The semantics become:

- `.exact(...)`: current behavior, ignoring build metadata for the match
- `.exactLiteral(...)`: full identifier match, including build metadata
- Range requirements: unchanged

This keeps existing manifests source- and behavior-compatible while allowing
packages to opt into metadata-aware selection when needed.

## Detailed design

SwiftPM adds a new requirement case for both source-control and registry
dependencies:

```swift
extension Package.Dependency {
    public enum SourceControlRequirement {
        case exact(Version)
        case exactLiteral(Version)
        case range(Range<Version>)
        case revision(String)
        case branch(String)
    }

    public enum RegistryRequirement {
        case exact(Version)
        case exactLiteral(Version)
        case range(Range<Version>)
    }
}
```

SwiftPM also adds overloads that accept those requirement types directly:

```swift
extension Package.Dependency {
    @available(_PackageDescription, introduced: 999.0)
    public static func package(
        url: String,
        _ requirement: Package.Dependency.SourceControlRequirement
    ) -> Package.Dependency

    @available(_PackageDescription, introduced: 999.0)
    public static func package(
        id: String,
        _ requirement: Package.Dependency.RegistryRequirement
    ) -> Package.Dependency
}
```

Manifest usage:

```swift
dependencies: [
    .package(url: "https://example.com/Foo.git", .exactLiteral("1.0.0+debug")),
    .package(id: "mona.Bar", .exactLiteral("2.1.3+vendor.1")),
]
```

Resolver behavior:

- `.exact(R)` keeps current semantic-exact matching behavior.
- `.exactLiteral(R)` matches only when the candidate version is identical to `R`,
  including build metadata.
- Version ordering and range containment continue to ignore build metadata.

This means:

- `.exact("1.0.0")` and `.exactLiteral("1.0.0+debug")` are compatible, with the
  literal requirement narrowing selection to `1.0.0+debug`.
- `.exactLiteral("1.0.0+debug")` and `.exactLiteral("1.0.0+release")` are
  incompatible.

The new requirement applies equally to source-control and registry
dependencies. If resolution fails, diagnostics should report the full requested
identifier so the conflicting metadata variant is visible.

`Package.resolved` already records full version identifiers, so this proposal
does not require a schema change.

## Security

This proposal does not introduce new trust relationships or network behavior.
It can improve supply-chain clarity by letting a manifest express an intended
published variant directly.

## Impact on existing packages

Existing manifests are unchanged. `.exact(...)` and range requirements keep
their current behavior, and only packages that opt into `.exactLiteral(...)`
observe new behavior.

As with other manifest APIs, use of `.exactLiteral(...)` can be gated by tools
version.

## Alternatives considered

### Change `.exact(...)` to include build metadata

This would change the behavior of existing manifests and break SwiftPM's
long-standing interpretation of exact version requirements.

### Add a flag to `.exact(...)`

A dedicated API is clearer at the call site than a boolean parameter on an
existing requirement constructor.

### Require revision pinning

Revision pinning is not a version-level API, does not work for registry
dependencies, and is less readable in manifests.

### Use pre-release identifiers instead

Pre-release versions change SemVer ordering, so they are not an accurate model
for variants that should share the same release precedence.
