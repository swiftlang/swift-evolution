# SE-NNNN: Allow Deprecating Package Products

* Proposal: [SE-NNNN](NNNN-swiftpm-product-deprecation.md)
* Authors: [Sam Khouri](https://github.com/bkhouri)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [swiftlang/swift-package-manager#NNNNN](https://github.com/swiftlang/swift-package-manager/pull/NNNNN)
* Review: ([pitch](https://forums.swift.org/))

> **Note on version numbers.** References to Swift tools version `6.5` and `_PackageDescription` availability `6.5` throughout this proposal are illustrative placeholders. The actual version in which the API becomes available depends on when this proposal is accepted and when the implementation lands in a released Swift toolchain. The final version will be substituted before this document is merged and again at implementation time.

## Introduction

Package authors currently have no first-class way to signal that a product vended from a Swift package is on a path to removal. Swift Package Manager (SwiftPM) supports rich deprecation semantics for Swift source APIs through `@available(*, deprecated, ...)`, but a `Package.swift` manifest cannot express that same intent for a `.library`, `.executable`, or `.plugin` product.

This proposal introduces a way to mark products as deprecated directly in the `Package.swift` manifest. Package authors describe the deprecation using a small set of state-specific factories — `.deprecated`, `.renamed`, `.supersededBy`, `.supersededByMajorVersion`, and `.retired`. When a consumer package depends on a deprecated product, SwiftPM emits a warning at build time that surfaces the deprecation message and any replacement information declared by the producing package. A companion `swift package audit` command lists every deprecated product in a package graph on demand, with an exit status that lets CI treat findings as failures.

## Motivation

Deprecation is a common part of the software lifecycle: package authors need to  evolve their APIs, rename products, split libraries into smaller pieces, or retire executables that have been superseded. Today, the manifest offers no mechanism to communicate any of that to package consumers.

The current workarounds are all lossy:

- Source-level `@available(*, deprecated, ...)` annotations apply to Swift declarations, not to products. If a package vends a library product whose entire purpose is superseded, source-level deprecations must be sprinkled across every public symbol in the module, which is noisy and easy to miss. They also don't apply to executable or plugin products at all.
- README notes, CHANGELOG entries, or GitHub release notes rely on consumers reading external documentation. They provide no build-time signal, so downstream packages continue using the product silently until a future major version removes it.
- Renaming or deleting the product outright is a hard break. It forces every consumer to react immediately, even when the producer intends to provide a grace period.
- Emitting warnings via a custom build tool plugin is possible only for packages that already ship a plugin and does not integrate with SwiftPM's diagnostic pipeline.

Package authors need a lightweight, declarative way to communicate that a product should no longer be used and, when applicable, to point consumers at a replacement. SwiftPM is already the natural place for this signal because it is what resolves and links the product, and it is where the consumer's `Package.swift` declares the dependency.

## Proposed solution

Add a `deprecated:` parameter to the `.library(...)`, `.executable(...)`, and `.plugin(...)` factory methods on `Product`. The parameter accepts a `Product.Deprecation` value describing the deprecation. `Product.Deprecation` values are constructed through a small set of state-specific factories so the intent — renamed, superseded by another package, superseded by a newer major, retired, or generically deprecated — is explicit at the call site. Every factory accepts an optional human-readable `message:`.

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
            deprecated: .renamed(
                to: "Paper",
                message: "PaperLegacy is superseded by Paper."
            )
        ),

        // Retired with no replacement.
        .library(
            name: "PaperExperimental",
            targets: ["PaperExperimental"],
            deprecated: .retired(
                message: "PaperExperimental is going away with no replacement."
            )
        ),

        // Superseded by a product in another package.
        .executable(
            name: "paper-tool-old",
            targets: ["paper-tool-old"],
            deprecated: .supersededBy(
                package: "paper-tools",
                product: "paper-tool",
                message: "Migrate to the standalone paper-tools package."
            )
        ),

        // Superseded by a newer major version of the same package.
        .library(
            name: "PaperClassic",
            targets: ["PaperClassic"],
            deprecated: .supersededByMajorVersion(
                3,
                product: "Paper",
                message: "Adopt Paper from Paper 3.x."
            )
        ),
    ],
    targets: [
        .target(name: "Paper"),
        .target(name: "PaperLegacy", dependencies: ["Paper"]),
        .target(name: "PaperExperimental"),
        .target(name: "PaperClassic"),
        .executableTarget(name: "paper-tool-old"),
    ]
)
```

When any consumer package (or another product within the same package) depends on a deprecated product, SwiftPM emits a warning that includes the product name, the producing package's identity, the author-supplied message, and any replacement information implied by the deprecation kind. In addition, this proposal introduces a `swift package audit` subcommand that lists every deprecated product reachable from the current package graph so authors and consumers can survey their migration surface without having to trigger a full build.

Existing manifests are unaffected as the `deprecated:` parameter is optional and defaults to `nil`.

## Detailed design

### `PackageDescription` API

A new nested type, `Product.Deprecation`, models a product deprecation. The type is an **opaque** struct: it exposes only a set of state-specific static factories for construction, and vends no public properties or nested `Kind` enum. The `Package.swift` manifest is a write-only DSL from the author's perspective — nothing needs to read a deprecation back — so keeping the type opaque minimizes the public API surface of `PackageDescription` and preserves maximum implementation freedom.

The variant (renamed, superseded by another package, superseded by a newer major, retired, or generically deprecated) and any associated replacement information are captured as internal storage. The manifest-loading pipeline translates each constructed `Product.Deprecation` into the model-layer representation described in [Manifest and model changes](#manifest-and-model-changes), which is where SwiftPM's diagnostics, `swift package audit`, and `swift package dump-package` inspect the variant.

```swift
extension Product {
    /// Describes the deprecation state of a product.
    ///
    /// Values of this type are constructed exclusively through the
    /// state-specific static factories below. The type intentionally
    /// exposes no public properties so that new deprecation variants
    /// and metadata can be added in future evolution without a source
    /// or ABI break.
    public struct Deprecation: Sendable, Equatable {
        /// Marks a product as deprecated with no advertised replacement.
        public static func deprecated(
            message: String? = nil
        ) -> Deprecation

        /// Marks a product as renamed to a product in the same package.
        ///
        /// - Parameters:
        ///   - newName: The name of the replacement product in the same package.
        ///   - message: A human-readable explanation of the deprecation.
        public static func renamed(
            to newName: String,
            message: String? = nil
        ) -> Deprecation

        /// Marks a product as superseded by a product in another package.
        ///
        /// - Parameters:
        ///   - package: The identity of the replacement package.
        ///   - product: The name of the replacement product in that package.
        ///   - message: A human-readable explanation of the deprecation.
        public static func supersededBy(
            package: String,
            product: String,
            message: String? = nil
        ) -> Deprecation

        /// Marks a product as superseded by a product in a newer major version
        /// of the same package.
        ///
        /// - Parameters:
        ///   - majorVersion: The major version that contains the replacement.
        ///   - product: The name of the replacement product, if it differs
        ///     from the current product's name.
        ///   - message: A human-readable explanation of the deprecation.
        public static func supersededByMajorVersion(
            _ majorVersion: Int,
            product: String? = nil,
            message: String? = nil
        ) -> Deprecation

        /// Marks a product as retired: going away with no replacement.
        public static func retired(
            message: String? = nil
        ) -> Deprecation
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
    /// The deprecation variant and any associated replacement information.
    ///
    /// The manifest loader constructs one of these cases from the opaque
    /// `Product.Deprecation` value returned by the corresponding
    /// `PackageDescription` factory. This enum is the single point at
    /// which SwiftPM's diagnostics, `swift package audit`, and
    /// `swift package dump-package` inspect the deprecation.
    ///
    /// This enum is non-frozen: new cases may be added in future evolution.
    /// Consumers that switch over `Kind` must include an `@unknown default`
    /// clause.
    public enum Kind: Hashable, Codable, Sendable {
        case deprecated
        case renamed(to: String)
        case supersededBy(package: String, product: String)
        case supersededByMajorVersion(Int, product: String?)
        case retired
    }

    public let kind: Kind
    public let message: String?
}
```

The manifest loader serializes and deserializes the new field. Because `ProductDescription` is `Codable`, the field is added as an optional to keep existing serialized manifests compatible. `ProductDeprecation.Kind` is encoded using a discriminated representation (a `type` string plus per-kind fields) so future kinds can be added without breaking existing consumers.

### Diagnostic behavior at build time

When SwiftPM resolves a package graph, for every product dependency it inspects the resolved `ProductDescription` for a non-`nil` `deprecation` value. For each such use, SwiftPM emits a warning through its existing `ObservabilityScope`. The base wording is:

```
warning: product 'PaperLegacy' from package 'paper' is deprecated: <trailing message>
```

The trailing sentence is derived from the deprecation `Kind`:

- `.deprecated` — no trailing sentence beyond the author-supplied `message`.
- `.renamed(to: N)` — `Use 'N' instead.`
- `.supersededBy(package: P, product: N)` — `Use 'N' from package 'P' instead.`
- `.supersededByMajorVersion(M, product: N)` — `A replacement is available in major version M of package '<producing-package>'.` If `product` is non-`nil` and differs from the current product name, the sentence names it explicitly: `Use 'N' from major version M of package '<producing-package>'.`
- `.retired` — `This product is retired and will be removed with no replacement.`

The warning is emitted:

1. At most once per consumer target that references the deprecated product, so consumers are not flooded with duplicate messages.
2. Only when the *consumer* package's manifest sees the dependency. A package that vends a deprecated product but does not consume it does not receive a diagnostic about its own product.
3. Independently of whether the product is a library, executable, or plugin.

SwiftPM does not verify that a replacement product named by `.renamed(to:)`, `.supersededBy(package:product:)`, or `.supersededByMajorVersion(_:product:)` actually exists in the referenced package or version; unresolved names are surfaced as-is in the diagnostic, mirroring the behavior of `@available(..., renamed:)` in Swift.

The warning is emitted by SwiftPM itself rather than by the Swift compiler, so it applies uniformly to executable and plugin products for which the compiler has no notion of "product."

### `swift package audit` subcommand

Warnings surface deprecations only for products a package currently consumes. Package authors often want a broader view — for example, "which of my direct or transitive dependencies vend a deprecated product?" — without waiting for each warning to appear during a build. This proposal adds a new subcommand:

```
swift package audit [--format <text|json>] [--include-transitive] [--allow-deprecations]
```

Behavior:

- Loads the current package graph without triggering a build.
- Walks every resolved product (direct or transitive) and reports each one whose `deprecation` is non-`nil`.
- Groups output by producing package, then product, and includes the deprecation kind, the author-supplied `message`, and any associated replacement information.
- **Exit status**:
  - `0` — the audit completed successfully and no deprecated products were reported.
  - Non-zero — either the audit encountered a load failure, or one or more deprecated products were reported.
  - When `--allow-deprecations` is passed, the exit status is `0` on any successful audit regardless of whether deprecated products were found. Load failures still exit non-zero. This mode is intended for humans running audits interactively who do not want a failing shell prompt.

Defaulting to a non-zero exit when deprecations are found lets CI systems fail builds automatically without having to parse the machine-readable output.

Flags:

- `--include-transitive` (default: `false`) — also lists deprecated products in transitive dependencies that the current package does not directly consume. Useful for producers auditing their own reach.
- `--allow-deprecations` — treat the audit as successful even when deprecated products are found; forces exit status `0` unless a load failure occurs.
- `--format <value>` (default: `text`) — selects the output format. Accepted values:
  - `text` (default) — a human-readable listing grouped by producing package.
  - `json` — machine-readable JSON with the schema below.

  Passing any value other than `text` or `json` is an error.

  Each entry carries the invariant fields (`package`, `product`, `type`, `message`, `usedBy`) at the top level and nests the deprecation-kind discriminator plus any kind-specific fields under a `payload` object. This keeps the invariant surface flat while grouping the variant-specific fields together — parsers can dispatch on `payload.kind` and consume the sibling fields without probing the outer object.

  Object keys in the output are emitted in **alphabetical order** at every nesting level (matching `JSONSerialization.WritingOptions.sortedKeys` / `JSONEncoder.OutputFormatting.sortedKeys`). This makes the output byte-stable across runs, so it is safe to diff, hash, or check into version control.

  Here is a sample `json` output:

  ```json
  {
    "deprecated": {
      "products": [
        {
          "message": "PaperLegacy is superseded by Paper.",
          "package": "paper",
          "payload": {
            "kind": "renamed",
            "to": "Paper"
          },
          "product": "PaperLegacy",
          "type": "library",
          "usedBy": ["MyApp"]
        },
        {
          "message": "Migrate to the standalone paper-tools package.",
          "package": "paper",
          "payload": {
            "kind": "supersededBy",
            "package": "paper-tools",
            "product": "paper-tool"
          },
          "product": "paper-tool-old",
          "type": "executable",
          "usedBy": ["MyApp"]
        },
        {
          "message": "Adopt Paper from Paper 3.x.",
          "package": "paper",
          "payload": {
            "kind": "supersededByMajorVersion",
            "majorVersion": 3,
            "product": "Paper"
          },
          "product": "PaperClassic",
          "type": "library",
          "usedBy": ["MyApp"]
        },
        {
          "message": "PaperExperimental is going away with no replacement.",
          "package": "paper",
          "payload": {
            "kind": "retired"
          },
          "product": "PaperExperimental",
          "type": "library",
          "usedBy": ["MyApp"]
        }
      ]
    }
  }
  ```

  The output conforms to the following JSON Schema (draft 2020-12). The `payload.kind` discriminator selects one of the payload variants below.

  ```json
  {
    "$id": "https://swift.org/schemas/swiftpm/audit-v1.json",
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$defs": {
      "deprecatedProduct": {
        "additionalProperties": false,
        "properties": {
          "message": {
            "description": "Author-supplied human-readable explanation.",
            "type": "string"
          },
          "package": {
            "description": "Identity of the producing package.",
            "type": "string"
          },
          "payload": {
            "oneOf": [
              { "$ref": "#/$defs/payloadDeprecated" },
              { "$ref": "#/$defs/payloadRenamed" },
              { "$ref": "#/$defs/payloadSupersededBy" },
              { "$ref": "#/$defs/payloadSupersededByMajorVersion" },
              { "$ref": "#/$defs/payloadRetired" }
            ]
          },
          "product": {
            "description": "Name of the deprecated product.",
            "type": "string"
          },
          "type": {
            "description": "SwiftPM product type.",
            "enum": ["executable", "library", "plugin"],
            "type": "string"
          },
          "usedBy": {
            "description": "Consumer targets in the local package graph that depend on this product. Empty when the product is only reached transitively and '--include-transitive' is passed.",
            "items": { "type": "string" },
            "type": "array"
          }
        },
        "required": ["package", "payload", "product", "type", "usedBy"],
        "type": "object"
      },
      "payloadDeprecated": {
        "additionalProperties": false,
        "properties": {
          "kind": { "const": "deprecated" }
        },
        "required": ["kind"],
        "type": "object"
      },
      "payloadRenamed": {
        "additionalProperties": false,
        "properties": {
          "kind": { "const": "renamed" },
          "to": {
            "description": "Name of the replacement product in the same package.",
            "type": "string"
          }
        },
        "required": ["kind", "to"],
        "type": "object"
      },
      "payloadRetired": {
        "additionalProperties": false,
        "properties": {
          "kind": { "const": "retired" }
        },
        "required": ["kind"],
        "type": "object"
      },
      "payloadSupersededBy": {
        "additionalProperties": false,
        "properties": {
          "kind": { "const": "supersededBy" },
          "package": {
            "description": "Identity of the replacement package.",
            "type": "string"
          },
          "product": {
            "description": "Name of the replacement product in that package.",
            "type": "string"
          }
        },
        "required": ["kind", "package", "product"],
        "type": "object"
      },
      "payloadSupersededByMajorVersion": {
        "additionalProperties": false,
        "properties": {
          "kind": { "const": "supersededByMajorVersion" },
          "majorVersion": {
            "description": "Major version that contains the replacement.",
            "minimum": 0,
            "type": "integer"
          },
          "product": {
            "description": "Replacement product name if it differs from the current product's name.",
            "type": "string"
          }
        },
        "required": ["kind", "majorVersion"],
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

  The schema is versioned via `$id` (`audit-v1.json`). Additive changes — new optional fields, new `payload` variants — remain compatible with `v1`; any breaking change would increment to `audit-v2.json` and be introduced through a subsequent evolution proposal.

The subcommand is purely a reporting tool. It does not modify any files, does not fail the build, and does not require network access beyond what a normal package graph load already performs.

### Interaction with existing features

- `swift package dump-package`: The dumped JSON gains an optional `deprecation` object on each product containing `kind`, `message`, and any kind-specific replacement fields (`renamed`, `supersededBy`, `supersededByMajorVersion`) when present. Tools that already consume `dump-package` output are unaffected because the field is additive and optional.
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

### Single generic factory with a `renamed:` string

A simpler shape would expose a single factory, `Product.Deprecation.deprecated(message:renamed:)`, with `renamed:` as an optional product name string. This is smaller at the type level but loses fidelity:

- It cannot distinguish "renamed within this package" from "superseded by another package's product," which are meaningfully different for consumers.
- It cannot express "retired: going away with no replacement" without overloading `message:` semantics.
- It cannot signal "the replacement is in a future major version," which is common for packages planning a breaking release.

The state-specific factories chosen for this proposal (`.deprecated`, `.renamed`, `.supersededBy`, `.supersededByMajorVersion`, `.retired`) make each of these intents explicit at the call site, and let SwiftPM tailor the diagnostic wording per case.

### Enum-based `Deprecation` type

We considered exposing `Deprecation` as a public enum with one case per kind. Modeling `Deprecation` as an opaque struct with static factories keeps the primary construction API self-documenting at the call site (`.renamed(to: "Paper")` reads better than `.init(kind: .renamed(to: "Paper"))`) without committing `PackageDescription` to a specific case layout. Because manifests are a write-only DSL — nothing on the `PackageDescription` side needs to read a `Deprecation` back — the struct exposes no public properties, and the variant is inspected only in the model layer (`PackageModel.ProductDeprecation.Kind`), where SwiftPM's diagnostics, `audit`, and `dump-package` consume it. This split keeps the manifest-facing surface small and lets future evolution add variants or metadata without a source or ABI break on `PackageDescription`.

We also considered exposing a public `Kind` enum on `Product.Deprecation` alongside the factories, mirroring the model-layer type so tooling that inspects live manifest values could switch on it. We rejected that direction: `PackageDescription` values are consumed by the manifest loader, not by third-party tooling in general, and doubling the surface (public enum on both `PackageDescription` and `PackageModel`) locks in a case-for-case correspondence that constrains later evolution without a clear payoff.

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
    deprecated: .supersededBy(
        package: "paper-tools",
        product: "paper-tool",
        message: "Migrate to the standalone paper-tools package."
    )
)
```
This is currently output the score of this pitch.

