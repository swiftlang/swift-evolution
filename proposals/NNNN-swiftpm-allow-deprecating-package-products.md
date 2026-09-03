# SE-NNNN: Allow Deprecating Package Products

* Proposal: [SE-NNNN](NNNN-swiftpm-product-deprecation.md)
* Authors: Sam Khouri ([GitHub](https://github.com/bkhouri)) ([Swift Forums](https://forums.swift.org/u/bkhouri/))
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift-package-manager#10437](https://github.com/swiftlang/swift-package-manager/pull/10437) [swiftlang/swift-package-manager#10438](https://github.com/swiftlang/swift-package-manager/pull/10438)
* Review: ([pitch](https://forums.swift.org/t/pitch-deprecating-package-products-in-the-package-manifest/88468))

> **Note on version numbers.** References to Swift tools version `6.5` and `_PackageDescription` availability `6.5` throughout this proposal are illustrative placeholders. The actual version in which the API becomes available depends on when this proposal is accepted and when the implementation lands in a released Swift toolchain. The final version will be substituted before this document is merged and again at implementation time.

## Introduction

Package authors currently have no first-class way to signal that a product vended from a Swift package is on a path to removal. Swift Package Manager (SwiftPM) supports rich deprecation semantics for Swift source APIs through `@available(*, deprecated, ...)`, but a `Package.swift` manifest cannot express that same intent for a `.library`, `.executable`, or `.plugin` product.

This proposal introduces a way to mark products as deprecated directly in the `Package.swift` manifest. Package authors describe the deprecation with a single factory, `.unsupported(message:replacement:)`, where the optional `replacement:` locator points at another product (in the same package or in a different package) that consumers should adopt instead. When a consumer package depends on an unsupported product, SwiftPM emits a warning at build time that surfaces the deprecation message and any replacement information declared by the producing package. A companion `swift package audit` command lists every unsupported product in a package graph on demand, with an exit status that lets CI treat findings as failures.

## Motivation

Deprecation is a common part of the software lifecycle: package authors need to  evolve their APIs, rename products, split libraries into smaller pieces, or retire executables that have been superseded. Today, the manifest offers no mechanism to communicate any of that to package consumers.

The current workarounds are all lossy:

- Source-level `@available(*, deprecated, ...)` annotations apply to Swift declarations, not to products. If a package vends a library product whose entire purpose is superseded, source-level deprecations must be sprinkled across every public symbol in the module, which is noisy and easy to miss. They also don't apply to executable or plugin products at all.
- README notes, CHANGELOG entries, or GitHub release notes rely on consumers reading external documentation. They provide no build-time signal, so downstream packages continue using the product silently until a future major version removes it.
- Renaming or deleting the product outright is a hard break. It forces every consumer to react immediately, even when the producer intends to provide a grace period.
- Emitting warnings via a custom build tool plugin is possible only for packages that already ship a plugin and does not integrate with SwiftPM's diagnostic pipeline.

Package authors need a lightweight, declarative way to communicate that a product should no longer be used and, when applicable, to point consumers at a replacement. SwiftPM is already the natural place for this signal because it is what resolves and links the product, and it is where the consumer's `Package.swift` declares the dependency.

## Proposed solution

Add a `deprecated:` parameter to the `.library(...)`, `.executable(...)`, and `.plugin(...)` factory methods on `Product`. The parameter accepts a `Product.Deprecation` value describing the deprecation. `Product.Deprecation` is constructed through a single factory, `.unsupported(message:replacement:)`, where the optional `replacement:` parameter points at the product a consumer should adopt instead. A replacement is described by a single `.renamed(_:package:)` factory — pass the replacement product's name, and optionally the identity of a different package that vends it.

```swift
// swift-tools-version: 6.5
import PackageDescription

let package = Package(
    name: "Paper",
    products: [
        .library(name: "Paper", targets: ["Paper"]),

        // Replaced by another product in the same package.
        .library(
            name: "PaperLegacy",
            targets: ["PaperLegacy"],
            deprecated: .unsupported(
                message: "PaperLegacy is superseded by Paper.",
                replacement: .renamed("Paper")
            )
        ),

        // Retired with no replacement.
        .library(
            name: "PaperExperimental",
            targets: ["PaperExperimental"],
            deprecated: .unsupported(
                message: "PaperExperimental is going away with no replacement."
            )
        ),

        // Superseded by a product in another package.
        .executable(
            name: "paper-tool-old",
            targets: ["paper-tool-old"],
            deprecated: .unsupported(
                message: "Migrate to the standalone paper-tools package.",
                replacement: .renamed("paper-tool", package: "paper-tools")
            )
        ),
    ],
    targets: [
        .target(name: "Paper"),
        .target(name: "PaperLegacy", dependencies: ["Paper"]),
        .target(name: "PaperExperimental"),
        .executableTarget(name: "paper-tool-old"),
    ]
)
```

When any consumer package (or another product within the same package) depends on an unsupported product, SwiftPM emits a warning that includes the product name, the producing package's identity, the author-supplied message, and any replacement information declared by the producer. In addition, this proposal introduces a `swift package audit` subcommand that lists every unsupported product reachable from the current package graph so authors and consumers can survey their migration surface without having to trigger a full build.

Existing manifests are unaffected as the `deprecated:` parameter is optional and defaults to `nil`.

## Detailed design

### `PackageDescription` API

A new nested type, `Product.Deprecation`, models a product deprecation. The type is an **opaque** struct: it exposes only a single static factory for construction and vends no public properties. The `Package.swift` manifest is a write-only DSL from the author's perspective — nothing needs to read a deprecation back — so keeping the type opaque minimizes the public API surface of `PackageDescription` and preserves maximum implementation freedom.

Every deprecation carries the same base state: the product is unsupported. Producers optionally attach a human-readable `message:` and an optional `replacement:` locator that points consumers at the product they should adopt instead. The manifest-loading pipeline translates each constructed `Product.Deprecation` into the model-layer representation described in [Manifest and model changes](#manifest-and-model-changes), which is where SwiftPM's diagnostics, `swift package audit`, and `swift package dump-package` inspect the value.

```swift
extension Product {
    /// Describes the deprecation state of a product.
    ///
    /// Values of this type are constructed exclusively through the
    /// static factory below. The type intentionally exposes no public
    /// properties so that new deprecation metadata can be added in
    /// future evolution without a source or ABI break.
    public struct Deprecation: Sendable, Equatable {
        /// Marks a product as unsupported.
        ///
        /// - Parameters:
        ///   - message: A human-readable explanation of the deprecation.
        ///   - replacement: An optional locator identifying the product
        ///     consumers should adopt instead. When `nil`, the product is
        ///     retired with no advertised replacement.
        public static func unsupported(
            message: String? = nil,
            replacement: Replacement? = nil
        ) -> Deprecation

        /// Identifies the product a consumer should adopt in place of an
        /// unsupported product.
        ///
        /// Values of this type are constructed exclusively through the
        /// static factory below.
        public struct Replacement: Sendable, Equatable {
            /// The replacement product a consumer should adopt.
            ///
            /// - Parameters:
            ///   - product: The name of the replacement product.
            ///   - package: The identity of the package that vends the
            ///     replacement. Omit (or pass `nil`) when the replacement
            ///     lives in the same package as the deprecated product.
            public static func renamed(
                _ product: String,
                package: String? = nil
            ) -> Replacement
        }
    }
}
```

The existing factory methods gain a new trailing parameter:

```swift
extension Product {
    @available(_PackageDescription, introduced: 6.5)
    public static func library(
        name: String,
        type: Library.LibraryType? = nil,
        targets: [String],
        deprecated: Deprecation? = nil
    ) -> Product

    @available(_PackageDescription, introduced: 6.5)
    public static func executable(
        name: String,
        targets: [String],
        deprecated: Deprecation? = nil
    ) -> Product

    @available(_PackageDescription, introduced: 6.5)
    public static func plugin(
        name: String,
        targets: [String],
        deprecated: Deprecation? = nil
    ) -> Product
}
```

The existing overloads without `deprecated:` remain available so that manifests targeting older tools versions continue to compile unchanged.

### Manifest and model changes

`ProductDescription` in `PackageModel` gains a new field:

```swift
public struct ProductDescription: Hashable, Codable, Sendable {
    public let name: String
    public let targets: [String]
    public let type: ProductType
    public let settings: [ProductSetting]
    /// The deprecation information declared for the product, if any.
    public let deprecation: ProductDeprecation?
}

public struct ProductDeprecation: Hashable, Codable, Sendable {
    /// The product a consumer should adopt in place of an unsupported product.
    ///
    /// The manifest loader constructs one of these cases from the opaque
    /// `Product.Deprecation.Replacement` value declared in the manifest.
    /// SwiftPM's diagnostics, `swift package audit`, and
    /// `swift package dump-package` inspect this enum to render the
    /// replacement.
    ///
    /// This enum is non-frozen: new cases may be added in future evolution.
    /// Consumers that switch over `Replacement` must include an
    /// `@unknown default` clause.
    public enum Replacement: Hashable, Codable, Sendable {
        /// The replacement product. When `package` is nil the replacement
        /// lives in the same package as the deprecated product; otherwise
        /// it lives in the named package.
        case renamed(_ product: String, package: String? = nil)
    }

    public let message: String?
    public let replacement: Replacement?
}
```

The manifest loader serializes and deserializes the new field. Because `ProductDescription` is `Codable`, the field is added as an optional to keep existing serialized manifests compatible. `ProductDeprecation.Replacement` is encoded using a discriminated representation (a `kind` string plus per-case fields) so future replacement kinds can be added without breaking existing consumers.

### Diagnostic behavior at build time

When SwiftPM resolves a package graph, for every product dependency it inspects the resolved `ProductDescription` for a non-`nil` `deprecation` value. For each such use, SwiftPM emits a warning through its existing `ObservabilityScope`. The wording matches the `.unsupported` factory used to declare the deprecation:

```
warning: product 'PaperLegacy' from package 'paper' is unsupported: <trailing message>
```

The trailing sentence is composed from the deprecation's `message` (if any) followed by a sentence derived from the `replacement`:

- `nil` replacement — no replacement sentence beyond the author-supplied `message`. The product is retired with no advertised replacement.
- `.renamed(N)` (same-package) — `Use 'N' instead.`
- `.renamed(N, package: P)` (cross-package) — `Use 'N' from package 'P' instead.`

The warning is emitted:

1. At most once per consumer target that references the deprecated product, so consumers are not flooded with duplicate messages.
2. Only when the *consumer* package's manifest sees the dependency. A package that vends a deprecated product but does not consume it does not receive a diagnostic about its own product.
3. Independently of whether the product is a library, executable, or plugin.

SwiftPM does not verify that a replacement product named by `.renamed(_:package:)` actually exists in the referenced package; unresolved names are surfaced as-is in the diagnostic, mirroring the behavior of `@available(..., renamed:)` in Swift.

The warning is emitted by SwiftPM itself rather than by the Swift compiler, so it applies uniformly to executable and plugin products for which the compiler has no notion of "product."

The diagnostic honors existing warning-as-error controls. When the consumer target declares `.treatAllWarnings(as: .error)` in its Swift build settings, or when the build invocation passes `-Xswiftc -warnings-as-errors`, the deprecation diagnostic is escalated from a warning to an error, matching how Swift's own compiler-emitted deprecation warnings behave.

### `swift package audit` subcommand

Warnings surface deprecations only for products a package currently consumes. Package authors often want a broader view — for example, "which of my direct or transitive dependencies vend an unsupported product?" — without waiting for each warning to appear during a build. This proposal adds a new subcommand:

```
swift package audit [--format <text|json>] [--include-transitive[=<reachable|all|non-reachable>]] [--allow-deprecations]
```

Behavior:

- Loads the current package graph without triggering a build.
- Classifies every deprecated product in the resolved graph using a three-value `transitive` field:
  - **`"direct"`** — at least one root-package target declares a `.product(name:package:)` dependency on the product.
  - **`"transitiveReachable"`** — no root-package target names the product directly, but a root target reaches it via another consumed product's internal target chain (e.g. `MyApp → PaperLegacy → Paper → OldFoo` makes `OldFoo` transitively reachable from the consumer's perspective).
  - **`"transitiveUnreachable"`** — the deprecated product exists in the resolved package graph (i.e. a package the consumer transitively depends on vends it) but no root-target dependency chain touches it.
- The report always includes `"direct"` entries. Whether `"transitiveReachable"` and/or `"transitiveUnreachable"` entries are included is controlled by `--include-transitive` (see below).
- Each included entry other than `"transitiveUnreachable"` carries a `breadcrumb` field: an array of paths, one per distinct route from a root-package target down to the deprecated product. Consumers use these breadcrumbs to understand *why* a product ended up in the report. `"transitiveUnreachable"` entries omit `breadcrumb` — no reaching path exists.
- Groups the text output by producing package under up to three sections — "Directly consumed", "Transitively reachable", and "Transitively unreachable" — each present only when non-empty.
- **Exit status**:
  - `0` — the audit completed successfully and no deprecated products were reported.
  - Non-zero — either the audit encountered a load failure, or one or more deprecated products were reported.
  - When `--allow-deprecations` is passed, the exit status is `0` on any successful audit regardless of whether deprecated products were found. Load failures still exit non-zero. This mode is intended for humans running audits interactively who do not want a failing shell prompt.

Defaulting to a non-zero exit when deprecations are found lets CI systems fail builds automatically without having to parse the machine-readable output.

Flags:

- `--include-transitive[=<mode>]` — controls which transitive violations are included in the report. Accepts an optional value:
  - Omitted from the command line — only `"direct"` entries are included.
  - Passed with no value (bare `--include-transitive`) — equivalent to `--include-transitive=reachable`.
  - `--include-transitive=reachable` — include `"direct"` + `"transitiveReachable"`.
  - `--include-transitive=all` — include all three (`"direct"` + `"transitiveReachable"` + `"transitiveUnreachable"`).
  - `--include-transitive=non-reachable` — include `"direct"` + `"transitiveUnreachable"` (skip `"transitiveReachable"`, useful for producers auditing which deprecated products in their transitive dependency graph aren't yet being pulled in by a consumer target chain).
- `--allow-deprecations` — treat the audit as successful even when deprecated products are found; forces exit status `0` unless a load failure occurs.
- `--format <value>` (default: `text`) — selects the output format. Accepted values:
  - `text` (default) — a human-readable listing grouped by producing package, split into "Directly consumed", "Transitively reachable", and "Transitively unreachable" sections.
  - `json` — machine-readable JSON with the schema below.

  Passing any value other than `text` or `json` is an error.

  Each entry carries the invariant fields (`package`, `product`, `transitive`, `type`, `usedBy`) plus optional `message`, `replacement`, and `breadcrumb` fields. `replacement` is a discriminated union on `kind`. `breadcrumb` is required whenever `transitive` is `"direct"` or `"transitiveReachable"`, and omitted when `transitive` is `"transitiveUnreachable"`.

  Object keys in the output are emitted in **alphabetical order** at every nesting level (matching `JSONSerialization.WritingOptions.sortedKeys` / `JSONEncoder.OutputFormatting.sortedKeys`). This makes the output byte-stable across runs, so it is safe to diff, hash, or check into version control.

  Here is a sample `json` output, from auditing a `consumer-transitive` package (which depends on `consumer`, which in turn depends on `producer`) with `--include-transitive`. `consumer-transitive`'s `MyTransitiveApp` target consumes `MyLib` from `consumer`, and `MyLib` internally consumes `PaperExperimental` (deprecated) from `producer`:

  ```json
  {
    "deprecated": {
      "products": [
        {
          "breadcrumb": [
            [
              { "package": "consumer-transitive", "target": "MyTransitiveApp" },
              { "package": "consumer", "product": "MyLib" },
              { "package": "producer", "product": "PaperExperimental" }
            ]
          ],
          "message": "PaperExperimental is going away with no replacement.",
          "package": "producer",
          "product": "PaperExperimental",
          "transitive": "transitiveReachable",
          "type": "library",
          "usedBy": ["MyTransitiveApp"]
        }
      ]
    }
  }
  ```

  And a `"direct"` example, from auditing `consumer` (whose targets consume `producer`'s deprecated products directly):

  ```json
  {
    "deprecated": {
      "products": [
        {
          "breadcrumb": [
            [
              { "package": "consumer", "target": "MyApp" },
              { "package": "producer", "product": "PaperLegacy" }
            ]
          ],
          "message": "PaperLegacy is superseded by Paper.",
          "package": "producer",
          "product": "PaperLegacy",
          "replacement": {
            "kind": "renamed",
            "product": "Paper"
          },
          "transitive": "direct",
          "type": "library",
          "usedBy": ["MyApp"]
        },
        {
          "breadcrumb": [
            [
              { "package": "consumer", "target": "MyLib" },
              { "package": "producer", "product": "PaperExperimental" }
            ]
          ],
          "message": "PaperExperimental is going away with no replacement.",
          "package": "producer",
          "product": "PaperExperimental",
          "transitive": "direct",
          "type": "library",
          "usedBy": ["MyLib"]
        }
      ]
    }
  }
  ```

  And a `"transitiveUnreachable"` example. Auditing `consumer` with `--include-transitive=all` surfaces `paper-tool-old` (deprecated in `producer`, in the resolved graph, but no target reaches it):

  ```json
  {
    "deprecated": {
      "products": [
        {
          "message": "Migrate to the standalone paper-tools package.",
          "package": "producer",
          "product": "paper-tool-old",
          "replacement": {
            "kind": "renamed",
            "package": "paper-tools",
            "product": "paper-tool"
          },
          "transitive": "transitiveUnreachable",
          "type": "executable",
          "usedBy": []
        }
      ]
    }
  }
  ```

  Note the absence of `breadcrumb` on the `transitiveUnreachable` entry, and the empty `usedBy` list (no root target reaches it).

  The output conforms to the following JSON Schema (draft 2020-12). Each `breadcrumb` element is a path — an array of "hop" objects, where each hop identifies a package-scoped entity: either a target (`{"package": ..., "target": ...}`) or a product (`{"package": ..., "product": ...}`). The `replacement` object always has `kind: "renamed"`; a `package` field is present iff the replacement lives in a package other than the one that vends the deprecated product.

  ```json
  {
    "$id": "https://swift.org/schemas/swiftpm/audit-v1.json",
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$defs": {
      "deprecatedProduct": {
        "additionalProperties": false,
        "properties": {
          "breadcrumb": {
            "description": "One or more paths that reach this deprecated product. Each path starts at a root-package entity and ends at the deprecated product itself. Required whenever `transitive` is `\"direct\"` or `\"transitiveReachable\"`; must be omitted when `transitive` is `\"transitiveUnreachable\"`.",
            "items": {
              "items": { "$ref": "#/$defs/breadcrumbHop" },
              "minItems": 1,
              "type": "array"
            },
            "minItems": 1,
            "type": "array"
          },
          "message": {
            "description": "Author-supplied human-readable explanation.",
            "type": "string"
          },
          "package": {
            "description": "Identity of the producing package.",
            "type": "string"
          },
          "product": {
            "description": "Name of the deprecated product.",
            "type": "string"
          },
          "replacement": {
            "description": "The product a consumer should adopt in place of the deprecated product. Omitted when the deprecation has no replacement.",
            "$ref": "#/$defs/replacement"
          },
          "transitive": {
            "description": "Classification of how this deprecated product is reached from the root package graph. `\"direct\"`: at least one root-package target has a `.product(name:package:)` dependency on it. `\"transitiveReachable\"`: reached only via another consumed product's internal target chain. `\"transitiveUnreachable\"`: exists in the resolved graph but no root-target dependency chain touches it. Which values are included in the report is controlled by the `--include-transitive` flag.",
            "enum": ["direct", "transitiveReachable", "transitiveUnreachable"],
            "type": "string"
          },
          "type": {
            "description": "SwiftPM product type.",
            "enum": ["executable", "library", "plugin"],
            "type": "string"
          },
          "usedBy": {
            "description": "Root-package targets whose dependency chain reaches this product. Non-empty for `\"direct\"` and `\"transitiveReachable\"` entries; empty for `\"transitiveUnreachable\"` entries.",
            "items": { "type": "string" },
            "type": "array"
          }
        },
        "required": ["package", "product", "transitive", "type", "usedBy"],
        "allOf": [
          {
            "if": {
              "properties": { "transitive": { "const": "transitiveUnreachable" } },
              "required": ["transitive"]
            },
            "then": {
              "not": { "required": ["breadcrumb"] }
            },
            "else": {
              "required": ["breadcrumb"]
            }
          }
        ],
        "type": "object"
      },
      "breadcrumbHop": {
        "description": "One step in a breadcrumb path. Identifies either a root-package target or a consumed product by (package, entity name).",
        "oneOf": [
          { "$ref": "#/$defs/breadcrumbHopTarget" },
          { "$ref": "#/$defs/breadcrumbHopProduct" }
        ]
      },
      "breadcrumbHopTarget": {
        "additionalProperties": false,
        "properties": {
          "package": {
            "description": "Identity of the package containing the target.",
            "type": "string"
          },
          "target": {
            "description": "Name of the target.",
            "type": "string"
          }
        },
        "required": ["package", "target"],
        "type": "object"
      },
      "breadcrumbHopProduct": {
        "additionalProperties": false,
        "properties": {
          "package": {
            "description": "Identity of the package containing the product.",
            "type": "string"
          },
          "product": {
            "description": "Name of the product.",
            "type": "string"
          }
        },
        "required": ["package", "product"],
        "type": "object"
      },
      "replacement": {
        "description": "The replacement product a consumer should adopt. `package` is present only when the replacement lives in a package other than the one that vends the deprecated product.",
        "additionalProperties": false,
        "properties": {
          "kind": { "const": "renamed" },
          "product": {
            "description": "Name of the replacement product.",
            "type": "string"
          },
          "package": {
            "description": "Identity of the package that vends the replacement, when it lives in a package other than the one that vends the deprecated product. Omitted for same-package replacements.",
            "type": "string"
          }
        },
        "required": ["kind", "product"],
        "type": "object"
      }
    },
    "additionalProperties": false,
    "properties": {
      "deprecated": {
        "additionalProperties": false,
        "properties": {
          "products": {
            "items": { "$ref": "#/$defs/deprecatedProduct" },
            "type": "array"
          }
        },
        "required": ["products"],
        "type": "object"
      }
    },
    "required": ["deprecated"],
    "title": "swift package audit output",
    "type": "object"
  }
  ```

  The schema is versioned via `$id` (`audit-v1.json`). Additive changes — new optional fields, new `replacement` variants — remain compatible with `v1`; any breaking change would increment to `audit-v2.json` and be introduced through a subsequent evolution proposal.

The subcommand is purely a reporting tool. It does not modify any files, does not fail the build, and does not require network access beyond what a normal package graph load already performs. It also suppresses the graph-load-time deprecation warnings described in [Diagnostic behavior at build time](#diagnostic-behavior-at-build-time) so that the structured audit report is not duplicated on stderr and so that a consumer target's own warnings-as-errors escalation does not prevent the audit from completing.

### Interaction with existing features

- `swift package dump-package`: The dumped JSON gains an optional `deprecation` object on each product containing `message` and, when present, a `replacement` object with a `kind` discriminator plus its associated fields. Tools that already consume `dump-package` output are unaffected because the field is additive and optional.
- Package traits (SE-0450): Deprecation applies to the product itself, independent of which traits enable it. If a product is only available under a particular trait, its deprecation is reported when that trait is enabled and the product is consumed.
- Registry and source-control dependencies: The deprecation information travels with the manifest, so the mechanism works uniformly for packages fetched from a registry (SE-0292) or from source control.
- Tools-version gating: Manifests that use the new `deprecated:` parameter must declare `swift-tools-version:6.5` or later. Older tools versions parse the manifest without recognizing the parameter, matching existing behavior for other version-gated API.

### Command-line surface

Beyond the new `swift package audit` subcommand described above, no other command-line flags are introduced. Consumers who wish to silence a specific deprecation warning can already suppress diagnostics through SwiftPM's existing mechanisms; a dedicated opt-out for product deprecation warnings is deliberately out of scope for this proposal.

## Security

This proposal introduces no new trust boundaries, network behavior, or privileged operations. Deprecation information is metadata that already lives in the producing package's manifest and is treated with the same trust as any other manifest content.

If anything, this feature *improves* supply-chain hygiene by giving package authors a formal way to warn consumers about products they should stop using (for example, a library product that is a thin wrapper around a soon-to-be-retired transitive dependency).

## Impact on existing packages

- Existing `Package.swift` manifests are unchanged: the `deprecated:` parameter defaults to `nil`, and the previous overloads remain available.
- Existing consumers of packages that adopt product deprecation will begin to see new warnings when they depend on a deprecated product. Warnings are non-fatal and can be addressed at the consumer's pace.
- The change is gated on the producing package declaring `swift-tools-version:6.5` or later. Producers who need to support older toolchains can continue to use README/CHANGELOG-based communication until they raise their tools version.
- The wire format of `dump-package` gains an optional field. Consumers that parse this output with strict schemas may need to update, but the field is optional and additive.
- The new `swift package audit` subcommand is additive and does not change the behavior of any existing subcommand. Its default non-zero exit on findings is a new signal for CI systems, but the command itself is opt-in — existing CI pipelines are unaffected until they choose to run `swift package audit`.

## Alternatives considered

### Do nothing; rely on source-level `@available`

Source-level deprecations are already available for library APIs, but they:

- Do not cover executable or plugin products.
- Force package authors to annotate potentially hundreds of public declarations to communicate a single "stop using this library" signal.
- Cannot express the intent "this whole product is deprecated, use that product instead" cleanly.

A product-level marker is a better fit for the semantic being communicated.

### Piggy-back on `deprecated`-style version annotations

We considered modeling deprecation with a version at which the product is deprecated and (optionally) obsoleted, similar to `@available(_, introduced:, deprecated:, obsoleted:)`. Embedding a *deprecation* version in the manifest creates opportunities for the manifest and the actual package version to drift out of sync, because a package's version is external to the manifest (it comes from git tags or registry metadata) and the *state* of being deprecated does not depend on it — declaring `deprecated:` at all is sufficient to communicate "this product should no longer be used." Extending the model with a future *obsolescence* version is discussed in [Future directions](#future-directions).

### State-specific factories per deprecation kind

An alternative design exposes five state-specific factories — `.deprecated`, `.renamed`, `.supersededBy`, `.supersededByMajorVersion`, and `.retired` — each with its own signature. This design carries more API surface than the semantic distinctions warrant:

- `.deprecated(message:)` reads redundantly at the call site (`deprecated: .deprecated(...)`).
- `.renamed` and `.supersededBy(package:product:)` differ only in whether the replacement is in the same package, which is a locator concern, not a state concern.
- `.supersededByMajorVersion` couples the replacement to a version that the current manifest cannot itself verify, and the same intent can be conveyed via `message:` until a stronger versioned mechanism (see [Future directions](#future-directions)) exists.
- `.retired` is `deprecated with no replacement`.

The `.unsupported(message:replacement:)` shape adopted by this proposal collapses these five factories into a single deprecation state with an optional replacement locator. The intent that state-specific factories would make explicit at the call site — "renamed", "superseded by another package", "retired" — is expressed by the presence, kind, and contents of the `replacement` argument. This preserves the fidelity of the state-specific design (SwiftPM can still tailor diagnostic wording per replacement kind) while keeping the surface small.

### Single generic factory with a `renamed:` string

An even smaller shape would expose `.unsupported(message:renamed:)` with `renamed:` as a bare product name string. This is smaller still but loses fidelity:

- It cannot distinguish "renamed within this package" from "superseded by another package's product," which are meaningfully different for consumers and for the diagnostic wording SwiftPM emits.
- It has no natural extension point for future replacement kinds (a same-package major-version pointer, for example, discussed in [Future directions](#future-directions)).

The `Replacement` type used by this proposal keeps the top-level factory surface small (one `.unsupported` factory) while letting each replacement locator carry the fields it actually needs.

### Enum-based `Deprecation` type

We considered exposing `Deprecation` as a public enum. Modeling `Deprecation` as an opaque struct with a single static factory keeps the construction API self-documenting at the call site (`.unsupported(replacement: .renamed("Paper"))` reads better than `.init(replacement: .renamed("Paper"))`) without committing `PackageDescription` to a specific layout. Because manifests are a write-only DSL — nothing on the `PackageDescription` side needs to read a `Deprecation` back — the struct exposes no public properties, and the replacement variant is inspected only in the model layer (`PackageModel.ProductDeprecation.Replacement`), where SwiftPM's diagnostics, `audit`, and `dump-package` consume it. This split keeps the manifest-facing surface small and lets future evolution add metadata without a source or ABI break on `PackageDescription`.

We also considered exposing a public `Replacement`-shaped enum on `Product.Deprecation` alongside the factories, mirroring the model-layer type so tooling that inspects live manifest values could switch on it. We rejected that direction: `PackageDescription` values are consumed by the manifest loader, not by third-party tooling in general, and doubling the surface (public enum on both `PackageDescription` and `PackageModel`) locks in a case-for-case correspondence that constrains later evolution without a clear payoff.

### Chainable modifier on `Product`

An alternative shape is a `Product.deprecated(_:renamed:)` instance method:

```swift
.library(name: "PaperLegacy", targets: ["PaperLegacy"])
    .deprecated("Use Paper", renamed: "Paper")
```

This reads well but complicates `Product`, which is currently a simple class hierarchy with no mutation. Adding a parameter to the factory functions is consistent with how other product configuration (`type:`, `targets:`) is expressed.

### Boolean-only deprecation

A `deprecated: Bool = false` parameter is simpler but strictly less useful: it cannot convey a message, a replacement product, or an obsolescence version, all of which are the primary value of the feature. A struct-based API gives us a place to grow as evolution demands more metadata.

### Emit an error instead of a warning

Making deprecation an error would break consumer builds the moment a producer marks a product as deprecated, which is the opposite of the "gentle migration" behavior the mechanism is meant to enable. A warning matches existing Swift deprecation semantics and lets consumers opt into stricter handling via their own warning-as-error policies. A future evolution could add a declarative way for producers to signal that a deprecation has become fatal (see [Future directions](#future-directions)).

### `swift package audit` exits zero regardless of findings

A quieter design for `swift package audit` would exit `0` on any successful audit, reserving non-zero exits for load failures. That framing treats the command as a pure reporting tool and lets CI decide, by parsing the output, whether to fail the build.

The exit-code design chosen for this proposal instead defaults to a non-zero exit when any deprecated product is found, matching the convention established by tools such as `npm audit` and `cargo audit`. This lets CI systems fail builds directly on the process exit status without having to parse JSON. The `--allow-deprecations` flag is provided for humans running audits interactively who prefer the "reporting-only" semantics.

### Warnings only at explicit `swift package resolve`

Emitting deprecation notices only during resolution — not at build — would be quieter but would let deprecations sit undiscovered for as long as the resolved graph is cached. Emitting at build (with the `audit` command as an on-demand supplement) mirrors how Swift's own source-level deprecations are surfaced.

## Future directions

### Reporting available-but-unresolved newer package versions

Pitch feedback observed that SwiftPM does not currently inform users when a newer version of a resolved package exists but was not selected — for example, because a version constraint pins the graph to an older range or the consumer is stuck on an outdated major. Being able to surface these "you're behind" signals alongside deprecation reports would give consumers a more complete picture of their dependency health.

This is a distinct feature that touches the resolver and registry client rather than product metadata, and is out of scope for this proposal. A future evolution could extend `swift package audit` (or introduce a companion subcommand) to combine deprecation reporting with newer-version reporting, giving users a single command to survey the health of their dependency graph.

### Same-package major-version replacement locator

A producer preparing a breaking release may want to point consumers at a product in a *future major version of the same package* — for example, "this v2.x product is superseded by a v3.x product of the same package." The `Replacement` type in this proposal deliberately omits such a locator: a v2.x manifest cannot verify the existence or name of a v3.x product, and consumers resolving v2.x cannot resolve v3.x, so the locator would serve only as documentation. Producers who want to communicate this today can do so via `message:` (for example, `"Adopt Paper from 3.x."`).

A future evolution could add a `.inMajorVersion(_ major: Int, product: String? = nil)` case to `Replacement`, most naturally in combination with the "obsolete on" mechanic below so the locator can be validated against the resolved producing-package version. The shape of that case, and whether it should be validated during graph resolution, are left to that proposal.

### Escalating deprecations to errors via an "obsolete on" version

The warnings introduced by this proposal give consumers time to migrate, but they rely on the consumer eventually paying attention. Package authors often want a stronger commitment: "you may keep using this product through version *X*, but starting in version *X+1* it is a hard error." Today, there is no declarative way for a producer to express that deadline in the manifest — the alternatives are either continuing to warn indefinitely (which invites indefinite delay) or removing the product outright (which forces every consumer to react in a single release).

A follow-up evolution could let producers attach an "obsolete on" version to a deprecation. Before that version, the deprecation stays a warning; once a consumer resolves the producing package at or beyond that version, the same deprecation escalates to an error. This gives producers a declarative, forward-dated cutoff without forcing consumers to opt in to a stricter policy.

The design has several attractive properties:

- No manifest/version drift: The deadline is compared against the *resolved* producing package's version at consumer build time, so the manifest never needs to know its own version. Producers who want to shift the deadline simply move it in a subsequent release.
- Producer-controlled deadline: The consumer does not need to opt in with a flag or a warnings-as-errors policy; the escalation is a property of the deprecation itself. Producers who want to give consumers a longer runway can pick a later cutoff; those who want to force migration on the next major bump can point at that version.
- Grace period on both sides: Consumers see a warning for as long as they resolve a version older than the cutoff. Once they choose to upgrade past that line, the diagnostic becomes a hard error — but they still control *when* to cross it by pinning their dependency range.

The specific API shape, type used to express the version, and diagnostic-emission mechanics are left to that future proposal.



### Deprecating executable targets directly

An `executableTarget` in `Package.swift` is (implicitly or explicitly) exposed as an executable product, so it is conceptually reasonable to place a `deprecated:` parameter on `.executableTarget(...)` as a shortcut for deprecating the executable that target exposes:

```swift
.executableTarget(
    name: "paper-tool-old",
    deprecated: .unsupported(
        message: "Migrate to the standalone paper-tools package.",
        replacement: .renamed("paper-tool", package: "paper-tools")
    )
)
```

This is currently outside the scope of this pitch.

