# Environment Constrained Shared Libraries

* Proposal: [SE-0490](0490-environment-constrained-shared-libraries.md)
* Authors: [tayloraswift](https://github.com/tayloraswift)
* Review Manager: [Alastair Houghton](https://github.com/al45tair)
* Status: **Active Review (September 5th...September 18th, 2025)**
* Implementation: [swiftlang/swift-package-manager#8249](https://github.com/swiftlang/swift-package-manager/pull/8249)
* Documentation: [How to use Environment-Constrained Shared Libraries](https://github.com/swiftlang/swift-package-manager/blob/1eaf59d2facc74c88574f38395aa49983b2badcc/Documentation/ECSLs.md)
* Bugs: [SR-5714](https://github.com/swiftlang/swift-package-manager/issues/5714)
* Review: ([pitch](https://forums.swift.org/t/pitch-replaceable-library-plugins/77605)) ([review](https://forums.swift.org/t/se-0490-environment-constrained-shared-libraries/81975))

## Introduction

SwiftPM currently has no support for non-system binary library dependencies on Linux. This proposal adds support for **Environment Constrained Shared Libraries**, which are a type of dynamic library that is shared across a fleet of machines and can be upgraded without recompiling and redeploying all applications running on those machines. We will distribute Environment Constrained Shared Libraries through the existing `.artifactbundle` format.

Swift-evolution thread: [Discussion thread](https://forums.swift.org/t/pitch-replaceable-library-plugins/77605)

Example Producer: [swift-dynamic-library-example](https://github.com/tayloraswift/swift-dynamic-library-example)

Example Consumer: [swift-dynamic-library-example-client](https://github.com/tayloraswift/swift-dynamic-library-example-client)

## Motivation

Many of us in the Server World have a Big App with a small component that changes very rapidly, much more rapidly than the rest of the App. This component might be something like a filter, or an algorithm, or a plugin that is being constantly tuned.

We could, for argument’s sake, try and turn this component into data that can be consumed by the Big App, which would probably involve designing a bytecode and an interpreter, and maybe even a whole interpreted domain-specific programming language. But that is very hard and we would rather just write this thing in Swift, and let Swift code call Swift code.

While macOS has Dynamic Library support through XCFrameworks, on Linux we currently have to recompile the Big App from source and redeploy the Big App every time the filter changes, and we don’t want to do that. What we really want instead is to have the Big App link the filter as a Dynamic Library, and redeploy the Dynamic Library as needed.


## Proposed solution

On Linux, there are a lot of obstacles to having fully general support for Dynamic Libraries. Swift is not ABI stable on Linux, and Linux itself is not a single platform but a wide range of similar platforms that provide few binary compatibility guarantees. This means it is pretty much impossible for a public Swift library to vend precompiled binaries that will Just Work for everyone, and we are not going to try to solve that problem in this proposal.

Instead, we will focus on **Environment Constrained Shared Libraries** (ECSLs). We choose this term to emphasize the distinction between our use case and fully general Dynamic Libraries.

### Target environment

Unlike fully general Dynamic Libraries, you would distribute Environment Constrained Shared Libraries strictly for controlled consumption within a known environment, such as a fleet of servers maintained by a single organization.

ECSLs are an advanced tool, and maintaining the prerequisite environment to deploy them safely is neither trivial nor recommended for most users.

The organization that distributes an ECSL is responsible for defining what exactly constitutes a “platform” for their purposes. An organization-defined platform is not necessarily an operating system or architecture, or even a specific distribution of an operating system. A trivial example of two such platforms might be:

1. Ubuntu 24.04 with the Swift 6.1.2 runtime installed at `/home/ubuntu/swift`
2. Ubuntu 24.04 with the Swift 6.1.2 runtime installed at `/home/ubuntu/swift-runtime`

Concepts like Platform Triples are not sufficient to describe an ECSL deployment target. Even though both “platforms” above would probably share the Triple `aarch64-unknown-linux-gnu`, Swift code compiled (without `--static-swift-stdlib`) for one would never be able to run on the other.

Organizations will add and remove environments as needed, and trying to define a global registry of all possible environments is a non-goal.

The proposed ECSL distribution format does not support shipping multiple variants of ECSLs targeting multiple environments in the same Artifact Bundle, nor does it specify a standardized means for identifying the environment in which a particular ECSL is intended to execute in.
Users are responsible for computing the correct URL of the Artifact Bundle for the environment they are building for, possibly within the package manifest. Swift tooling will not, on its own, diagnose or prevent the installation of an incompatible ECSL.

### Creating ECSLs

To compile an ECSL, you just need to build an ordinary SwiftPM library product with the `-enable-library-evolution` flag. This requires no modifications to SwiftPM.

You would package an ECSL as an `.artifactbundle` just as you would an executable, with the following differences:

-   The `info.json` must have `schemaVersion` set to `1.2` or higher.
-   The artifact type must be `dynamicLibrary`, a new enum case introduced in this proposal.
-   The artifact must have exactly one variant in the `variants` list, and the `supportedTriples` field is forbidden.
-   The artifact payload must include the `.swiftinterface` file corresponding to the actual library object.

Because SwiftPM is not (and cannot be) aware of a particular organization’s set of deployment environments, this enforces the requirement that each environment must have its own Artifact Bundle.

The organization that distributes the ECSL is responsible for upholding ABI stability guarantees, including the exact Swift compiler and runtime versions needed to safely consume the ECSL.


### Consuming ECSLs

To consume an ECSL, you would add a `binaryTarget` to your `Package.swift` manifest, just as you would for an executable. Because organizations are responsible for defining their set of supported environments, they are also responsible for defining the URLs that the Artifact Bundles for each environment are hosted under, so there are no new fields in the `PackageDescription` API.

We expect that the logic for selecting the correct ECSL for a given environment would live within the `Package.swift` file, that it would be highly organization-specific, and that it would be manipulated using existing means such as environment variables.


### Deploying ECSLs

Deploying ECSLs does not involve SwiftPM or Artifact Bundles at all. You would deploy an ECSL by copying the latest binaries to the appropriate `@rpath` location on each machine in your fleet. The `@rpath` location is part of the organization-specific environment definition, and is not modeled by SwiftPM.

Some organizations might choose to forgo the `@rpath` mechanism entirely and simply install the ECSLs in a system-wide location.


## Detailed design

### Schema extensions

We will extend the `ArtifactsArchiveMetadata` schema to include a new `dynamicLibrary` case in the `ArtifactType` enum.

```diff
public enum ArtifactType: String, RawRepresentable, Decodable {
    case executable
+   case dynamicLibrary
    case staticLibrary
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
            "type": "dynamicLibrary",
            "version": "1.0.0",
            "variants": [{ "path": "MyLibrary" }]
        }
    }
}
```

The artifact must have exactly one variant in the `variants` list, and the `supportedTriples` field is forbidden. An ECSL Artifact Bundle can contain multiple libraries at the top level.

Below is an example of the layout of an Artifact Bundle containing a single library called `MyLibrary`. Only the `info.json` must appear at the root of the Artifact Bundle; all other files can appear at whatever paths are defined in the `info.json`, as long as they are within the Artifact Bundle.

```text
📂 example.artifactbundle
    📂 MyLibrary
        ⚙️ libMyLibrary.so
        📝 MyLibrary.swiftinterface
    📝 info.json
```

A macOS Artifact Bundle would contain a `.dylib` instead of a `.so`. ECSLs will be supported on macOS, although we expect this will be an exceedingly rare use case, as this need is already well-served by the XCFramework.


## Security

ECSLs are not intended for public distribution, and are not subject to the same security concerns as public libraries. Organizations that distribute ECSLs are responsible for ensuring that the ECSLs are safe to consume.


## Impact on existing packages

There will be no impact on existing packages. All Artifact Bundle schema changes are additive.


## Alternatives considered

### Extending Platform Triples to model deployment targets

SwiftPM currently uses Platform Triples to select among artifact variants when consuming executables. This is workable because it is usually feasible to build executables that are portable across the range of platforms encompassed by a single Platform Triple.

We could extend Platform Triples to model ECSL deployment targets, but this would privilege a narrow set of predefined deployment architectures, and if you wanted to add a new environment, you would have to modify SwiftPM to teach it to recognize the new environment.

### Supporting multiple variants of an ECSL in the same Artifact Bundle

We could allow an Artifact Bundle to contain multiple variants of an ECSL, but we would still need to support a way to identify those variants, which in practice forces SwiftPM to become aware of organization-defined environments.

We also don’t see much value in this feature, as you would probably package and upload ECSLs using one CI/CD workflow per environment anyway. Combining artifacts would require some kind of synchronization mechanism to await all pipelines before fetching and merging bundles.

One benefit of merging bundles would be that it reduces the number of checksums you need to keep track of, but we expect that most organizations will have a very small number of supported environments, with new environments continously phasing out old environments.

### Using a different `ArtifactType` name besides `dynamicLibrary`

We intentionally preserved the structure of the `variants` list in the `info.json` file, despite imposing the current restriction of one variant per library, in order to allow this format to be extended in the future to support fully general Dynamic Libraries.
