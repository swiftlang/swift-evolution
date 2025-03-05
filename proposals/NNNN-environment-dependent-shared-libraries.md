# Environment Dependent Shared Libraries

* Proposal: [SE-NNNN](NNNN-environment-dependent-shared-libraries.md)
* Authors: [tayloraswift](https://github.com/tayloraswift)
* Review Manager: TBD
* Implementation: [swiftlang/swift-package-manager#8249](https://github.com/swiftlang/swift-package-manager/pull/8249)
* Documentation: [How to use Environment-Dependent Shared Libraries](https://github.com/tayloraswift/swift-edsl-example-client/blob/master/Sources/KrustyKrab/docs.docc/Getting%20Started.md)
* Bugs: [SR-5714](https://github.com/swiftlang/swift-package-manager/issues/5714)

## Introduction

SwiftPM currently has no support for non-system binary library dependencies on Linux. This proposal adds support for **Environment Dependent Shared Libraries**, which are a type of dynamic library that is shared across a fleet of machines and can be upgraded without recompiling and redeploying all applications running on those machines. We will distribute Environment Dependent Shared Libraries through the existing `.artifactbundle` format.

Swift-evolution thread: [Discussion thread](https://forums.swift.org/t/pitch-replaceable-library-plugins/77605)

Example Producer: [swift-edsl-example](https://github.com/tayloraswift/swift-edsl-example)

Example Consumer: [swift-edsl-example-client](https://github.com/tayloraswift/swift-edsl-example-client)

## Motivation

Many of us in the Server World have a Big App with a small component that changes very rapidly, much more rapidly than the rest of the App. This component might be something like a filter, or an algorithm, or a plugin that is being constantly tuned.

We could, for argument’s sake, try and turn this component into data that can be consumed by the Big App, which would probably involve designing a bytecode and an interpreter, and maybe even a whole interpreted domain-specific programming language. But that is very hard and we would rather just write this thing in Swift, and let Swift code call Swift code.

While macOS has Dynamic Library support through XCFrameworks, on Linux we currently have to recompile the Big App from source and redeploy the Big App every time the filter changes, and we don’t want to do that. What we really want instead is to have the Big App link the filter as a Dynamic Library, and redeploy the Dynamic Library as needed.


## Proposed solution

On Linux, there are a lot of obstacles to having fully general support for Dynamic Libraries. Swift is not ABI stable on Linux, and Linux itself is not a single platform but a wide range of similar platforms that provide few binary compatibility guarantees. This means it is pretty much impossible for a public Swift library to vend precompiled binaries that will Just Work for everyone, and we are not going to try to solve that problem in this proposal.

Instead, we will focus on **Environment Dependent Shared Libraries** (EDSLs). We choose this term to emphasize the distinction between our use case and fully general Dynamic Libraries.

### Organization-Defined Platforms (ODPs)

Unlike fully general Dynamic Libraries, you would distribute Environment Dependent Shared Libraries strictly for internal consumption within an organization, or to a small set of paying clients.

The organization that distributes an EDSL is responsible for defining what exactly constitutes a “platform” for their purposes. An Organization-Defined Platform (ODP) is not necessarily an operating system or architecture, or even a specific distribution of an operating system. A trivial example of two ODPs might be:

1. Ubuntu 24.04 with the Swift 6.0.3 runtime installed at `/home/ubuntu/swift`
2. Ubuntu 24.04 with the Swift 6.0.3 runtime installed at `/home/ubuntu/swift-runtime`

Concepts like Platform Triples are not sufficient to describe an ODP. Even though both ODPs above would probably share the Triple `aarch64-unknown-linux-gnu`, Swift code compiled (without `--static-swift-stdlib`) for one would never be able to run on the other.

Organizations add and remove ODPs as needed, and trying to define a global registry of all possible ODPs is a non-goal.

To keep things simple, we identify ODPs by the URL of the Artifact Bundle that contains the EDSL.

### Creating EDSLs

To compile an EDSL, you just need to build an ordinary SwiftPM library product with the `-enable-library-evolution` flag. This requires no modifications to SwiftPM.

You would package an EDSL as an `.artifactbundle` just as you would an executable, with the following differences:

-   The `info.json` must have `schemaVersion` set to `1.2` or higher.
-   The artifact type must be `library`, a new enum case introduced in this proposal.
-   The artifact must have exactly one variant in the `variants` list, and the `supportedTriples` field is forbidden.
-   The artifact payload must include the `.swiftinterface` file corresponding to the actual library object.

Because SwiftPM is not (and cannot be) aware of a particular organization’s ODPs, this enforces the requirement that each ODP must have its own Artifact Bundle.

The organization that distributes the EDSL is responsible for upholding ABI stability guarantees, including the exact Swift compiler and runtime versions needed to safely consume the EDSL.


### Consuming EDSLs

To consume an EDSL, you would add a `binaryTarget` to your `Package.swift` manifest, just as you would for an executable. Because ODPs are identified by the URL of the Artifact Bundle, there are no new fields in the `PackageDescription` API.

We expect that the logic for selecting the correct EDSL for a given ODP would live within the `Package.swift` file, that it would be highly organization-specific, and that it would be manipulated using existing means such as environment variables.


### Deploying EDSLs

Deploying EDSLs does not involve SwiftPM or Artifact Bundles at all. You would deploy an EDSL by copying the latest binaries to the appropriate `@rpath` location on each machine in your fleet. The `@rpath` location is part of the ODP definition, and is not modeled by SwiftPM.

Some organizations might choose to forgo the `@rpath` mechanism entirely and simply install the EDSLs in a system-wide location.


## Detailed design

### Schema extensions

We will extend the `ArtifactsArchiveMetadata` schema to include a new `library` case in the `ArtifactType` enum.

```diff
public enum ArtifactType: String, RawRepresentable, Decodable {
    case executable
+   case library
    case swiftSDK
}
```

This also bumps the latest `schemaVersion` to `1.2`.


### Artifact Bundle layout

Below is an example of an `info.json` file for an Artifact Bundle containing a single library called `MyLibrary`.

```json
{
    "schemaVersion": "1.2",
    "artifacts": {
        "MyLibrary": {
            "type": "library",
            "version": "1.0.0",
            "variants": [{ "path": "MyLibrary" }]
        }
    }
}
```

The artifact must have exactly one variant in the `variants` list, and the `supportedTriples` field is forbidden. An EDSL Artifact Bundle can contain multiple libraries at the top level.

Below is an example of the layout of an Artifact Bundle containing a single library called `MyLibrary`. Only the `info.json` must appear at the root of the Artifact Bundle; all other files can appear at whatever paths are defined in the `info.json`, as long as they are within the Artifact Bundle.

```text
📂 example.artifactbundle
    📂 MyLibrary
        ⚙️ libMyLibrary.so
        📝 MyLibrary.swiftinterface
    📝 info.json
```

A macOS Artifact Bundle would contain a `.dylib` instead of a `.so`. EDSLs will be supported on macOS, although we expect this will be an exceedingly rare use case.


## Security

EDSLs are not intended for public distribution, and are not subject to the same security concerns as public libraries. Organizations that distribute EDSLs are responsible for ensuring that the EDSLs are safe to consume.


## Impact on existing packages

There will be no impact on existing packages. All Artifact Bundle schema changes are additive.


## Alternatives considered

### Extending Platform Triples to model ODPs

SwiftPM currently uses Platform Triples to select among artifact variants when consuming executables. This is workable because it is usually feasible to build executables that are portable across the range of platforms encompassed by a single Platform Triple.

We could extend Platform Triples to model ODPs, but this would privilege a narrow set of predefined deployment architectures, and if you wanted to add a new ODP, you would have to modify SwiftPM to teach it to recognize the new ODP.

### Supporting multiple variants of an EDSL in the same Artifact Bundle

We could allow an Artifact Bundle to contain multiple variants of an EDSL, but we would still need to support a way to identify those variants, which in practice makes SwiftPM aware of ODPs.

We also don’t see much value in this feature, as you would probably package and upload EDSLs using one CI/CD workflow per ODP anyway. Combining artifacts would require some kind of synchronization mechanism to await all pipelines before fetching and merging bundles.

One benefit of merging bundles would be that it reduces the number of checksums you need to keep track of, but we expect that most organizations will have a very small number of ODPs, with new ODPs continously phasing out old ODPs.

### Using a different `ArtifactType` name besides `library`

We intentionally preserved the structure of the `variants` list in the `info.json` file, despite imposing the current restriction of one variant per library, in order to allow this format to be extended in the future to support fully general Dynamic Libraries.
