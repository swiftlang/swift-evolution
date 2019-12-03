# Package Manager Binary Dependencies

* Proposal: [SE-0272](0272-swiftpm-binary-dependencies.md)
* Authors: [Braden Scothern](https://github.com/bscothern), [Daniel Dunbar](https://github.com/ddunbar), [Franz Busch](https://github.com/FranzBusch)
* Review Manager: [Boris Bügling](https://github.com/neonichu)
* Status: **Returned for revision**
* Decision Notes: [Rationale](https://forums.swift.org/t/returned-for-revision-se-0272-package-manager-binary-dependencies/30994)

## Contents

+ [Introduction](#introduction)
+ [Motivation](#motivation)
+ [Proposed solution](#proposed-solution)
+ [Detailed design](#detailed-design)
+ [New `PackageDescription` API](#new-packagedescription-api)
+ [New `Package.resolved` Behavior](#new-packageresolved-behavior)
+ [Binary Target Artifact Format](#binary-target-artifact-format)
+ [Security](#security)
+ [Impact on existing packages](#impact-on-existing-packages)
+ [Future directions](#future-directions)
+ [Alternatives considered](#alternatives-considered)

## Introduction

SwiftPM currently supports source-only packages for several languages, and with
a very proscriptive build model which considerably limits exactly how the
compilation of the source can be performed. While this makes packages consistent
and to some extent "simple", it limits their use in several important cases:
* Software vendors who wish to provide easy integration with the package
  manager, but do not deliver source code, cannot integrate.
* Existing code bases which would like to integrate "simply" with SwiftPM, but
  require more complicated build processes, have no recourse.

For example, consider these use cases:

 * Someone wants to create a Swift package for
   generating [LLVM](https://llvm.org) code. However, LLVM's build process is
   far more complex than can be currently fit into SwiftPM's build model. This
   makes building an *easy to use* package difficult.
 * A third-party wants to provide a Swift SDK for easily integrating their
   service with server-side Swift applications. The SDK itself relies on
   substantial amounts of internal infrastructure the company does not want to
   make available as open source.
 * A large company has an internal team which wants to deliver a Swift package
   for use in their iOS applications, but for for business reasons cannot publish
   the source code.

This proposal defines a new SwiftPM feature to allow SwiftPM to accept some
forms of "binary packages". This proposal is intentionally written to
address the above use cases *explicitly*, it **does not** define a general
purpose "binary artifact" mechanism intended to address other use cases (such as
accelerating build performance). The motivations for this are discussed in more
detail below.

Swift-evolution thread: [\[PITCH\] Support for binary dependencies](https://forums.swift.org/t/pitch-support-for-binary-dependencies/27620)
                        
## Motivation

SwiftPM has a large appeal to certain developer communities, like the iOS
ecosystem, where it is currently very common to rely on closed source
dependencies such as Firebase, GoogleAnalytics, Adjust and many more. Existing
package managers like Cocoapods support these use cases. By adding such support
to SwiftPM, we will unblock substantially more adoption of SwiftPM within those
communities.

Prior to Swift 5.1, the Swift compiler itself did not expose all of the features
(like ABI compatibility) required to build a workable solution. Now that those
features are present, it makes sense to re-evaluate the role of binary packages.

The goal of this proposal is to make *consumption* of binary packages as
described above *easy*, *intuitive*, *safe*, and *consistent*. This proposal
**does not** attempt to provide any affordances for the creation of the binary
package itself. The overall intent of this proposal is to allow consumption of
binary packages *where necessary*, but not to encourage their use or facilitate a
transition from the existing source-based ecosystem to a binary one.

This proposal is also focused at packages which come exclusively in binary form,
it explicitly **does not** introduce a mechanism which allows a package to be
present in either source or binary form. See alternatives considered for more
information on this choice.

## Proposed solution

To enable binary dependencies we have to make changes in the `Package.swift` manifest file. First, we propose to add a new target type which describes a binary target. Such a target needs to declare where to retrieve the artifact from and the checksum of the expected artifact. An example of such a package can be seen below:

```swift
let package = Package(
    name: "SomePackage",
    platforms: [
        .macOS(.v10_10), .iOS(.v8), .tvOS(.v9), .watchOS(.v2),
    ],
    products: [
        .library(name: "SomePackage", targets: ["SomePackageLib"])
    ],
    targets: [
        .binaryTarget(
            name: "SomePackageLib",
            url: "https://github.com/some/package/releases/download/1.0.0/SomePackage-1.0.0.zip",
            checksum: "839F9F30DC13C30795666DD8F6FB77DD0E097B83D06954073E34FE5154481F7A"
        ),
        .binaryTarget(
            name: "SomeLibOnDisk",
            path: "artifacts/SomeLibOnDisk.zip"
        )
    ]
)
```

Packages are allowed to contain a mix of binary and source targets. This is
useful when, for example, providing a pre-built or closed source C library
alongside an open source set of Swift bindings for the library.

The use case will be limited to Apple platforms in the beginning. In the future, we can add support for other platforms. A potential approach is outlined in the future directions section.

## Detailed design

The design consists of the following key points:
* New `PackageDescription` API for defining a binary target.
* New requirements for the `Package.resolved` file when using binary packages.
* A new command to compute a checksum for a file.
* A new mechanism for downloading binary target artifacts.
* Support for artifact mirroring.

Terminology:

* Technically, a *target* is binary or not. However, we anticipate that often a
  single package will consist of either exclusively source or binary targets. We
  will use the term *binary package* to refer to any package which contains at
  least one binary product. Similarly, a *binary product* is one which contains
  at least one binary target.

Our design attempts to optimize for the following goals:

* Ease of use for clients
* Ease of implementation in existing SwiftPM
* Ease of maintenance in the face of an evolving SwiftPM
* Understandable composition with current and upcoming SwiftPM features
* Support existing well-known occurrences of binary artifacts in the existing
  (often iOS focused) target developer market.

while keeping the following as non-goals:

* Ease of production of binary packages
* Simplicity of binary artifact distribution mechanism
* Widespread use of binary packages

## New `PackageDescription` API

### BinaryTarget
Since a binary target is different compared to a source only target, we propose to introduce two new static method on `Target` to declare a binary target. We propose to support local and remote artifacts from the beginning. In the alternatives considered section is a larger collection of potential artifact stores. However we opted to simplify the initial implementation by just supporting a url and a path based definition. Later, we can implement different types of providers with different authentication methods.

```swift
extension Target {
    /// Declare a binary target with the given url.
    public static func binaryTarget(
        name: String,
        url: String,
        checksum: String
    ) -> Target

    /// Declare a binary target with the given path on disk.
    public static func binaryTarget(
        name: String,
        path: String
    ) -> Target
}
```

## Checksum computation
We propose to add a new command to SwiftPM `swift package compute-checksum <file>` which is going to be used to compute the checksum of individual files. This implementation can then evolve in the future and is tied to the tools version of the package to avoid breaking compatibility with older tools.

## New `Package.resolved` Behavior

For binary targets we store the checksum of the artifact in the `Package.resolved`. This lets us check for errors during resolution where a package's version did not change but the checksum did. In this case we will throw an error alerting the user about this.

### Resolution

Package resolution and dependency expression will not be impacted by this change (except where explicitly noted).

#### Multiple references to same artifact
During resolution SwiftPM will check that all references to an artifact in a dependency graph have the same checksum.


#### Exported product with binary dependency that specifies a type
SwiftPM will emit an error during resolution when a product that directly exports a binary dependency declares a type, e.g.: `.product(name: "MyBinaryLib", type: .static, targets: ["MyBinaryLib"])`.

#### Resolution on non-Apple platforms
When resolving a package that contains a binary dependency on non-Apple platforms, SwiftPM will throw an error and explicitly state that this dependency is not valid for the current platform. During the review it was brought up that we could ignore these dependencies but that would make the behavior of SwiftPM very unexpected. In the future, when properly supporting other platforms this can be solved easily with a proper condition mechanism.

## Binary Target Artifact Format

SwiftPM currently supports multiple platforms; however, this proposal only adds support for binary targets on Apple platforms. The reason for this is that Apple platforms provide ABI guarantees and an already existing format we can leverage to simplify the initial implementation. For Apple platforms we propose to use the `XCFramework` format for artifacts. This format already supports dynamic and static linking. Furthermore, it can contain products for every individual Apple platform at once.

SwiftPM expects url-based artifacts to be packaged inside a `.zip` file where the artifact is lying at the root of the archive. Furthermore, the artifact needs to have the same name as the name provided inside the manifest file for SwiftPM to locate it. 

For path-based artifact SwiftPM supports artifacts as a `.zip` and as a raw `XCFramework`.

During resolution SwiftPM won't do any verification of the format of the artifact. This is up to the vendor to provide correct and valid artifact. In the future, this can be extended and further validation, such as checking that the module name matches, can be implemented.

## Security

When adding new external dependencies, it is always important to consider the security implication that it will bring with it. Comparing the trust level of a source-based to a binary-based dependency the first thought is that the trust level of the source-based dependency is higher since on can inspect its source code. However, there is no difference between a binary and source dependency since source-based dependencies can have security issues as well. One should have better reasons to trust a dependency than source being inspectable.

There is still a significant difference between having a dependency with zero vs. any binary dependency. For example, the portability of a library with binary dependencies is far worse than the one with only source-based dependencies. For this reason, we propose to add an additional configuration point in the manifest that allows package authors to opt-out of binary dependencies.

However, there are still some security related aspects when it comes to binary artifacts that we should mitigate. For example, when declaring a `binaryTarget` the hash of the artifact is required similar to Homebrew. By doing this an attacker needs to compromise both the server which provides the artifact as well as the git repository which provides the package manifest. A secondary reason is that the server providing the binary might be out of the package author's control and this way we can ensure that the expected binary is used.

Lastly, the hash of the binary is stored in the package resolved to avoid that the vendor changes the artifact behind a version without anyone noticing.

## Mirroring support
Binary artifacts can also be mirrored. We propose to extend the current mirroring API by one new command:

```
$ swift package config set-mirror \
    --artifact-url <original URL> \
    --mirror-url <mirror URL>

# Example:

$ swift package config set-mirror \
    --artifact-url https://github.com/Core/core/releases/download/1.0.0/core.zip \
    --mirror-url https://mygithub.com/myOrg/core/releases/download/1.0.0/core.zip
```

Additionally, we propose to add a command to unset a mirror URL for an artifact:

```
$ swift package config unset-mirror \
    --artifact-url https://github.com/Core/core/releases/download/1.0.0/core.zip
```

The other unset command options `--mirror-url` and `--all` will be working the same for artifacts as they do for packages. 

## Impact on existing packages

No current package should be affected by this change since this is only an additive change in enabling SwiftPM to use binary dependencies.

## Future directions

### Support for non-Apple platforms
Non-Apple platforms provide non-trivial challenges since they are not always giving guarantees of the ABI of the platform. Additionally, further conditions such as the corelibs-foundation ABI or if the hardware supports floating points need to be taken into consideration when declaring a package for non-Apple platforms. Various other communities tried to solve this, e.g. Python's [manylinux](https://www.python.org/dev/peps/pep-0600/).

In the future, we could add an `Artifact` struct and `ArtifactCondition`s to SwiftPM which provides the possibility to declare under which conditions a certain artifact can be used. Below is a potential `Artifact` and `ArtifactCondition` struct which does **not** include a complete set of conditions that need to be taken into consideration.

```swift
public struct Artifact {
    public enum Source {
        case url(String, checksum: String)
        case path
    }

    public let source: Source
}

public struct ArtifactCondition: Encodable {
    public struct LLVMTriplet: Encodable {
        // Should be only the subset that Swift supports
        enum ArchType: String, Encodable {
            case arm5
            case arm7
            case x86
            case x86_64
            // And the rest
        }

        // Should be only the subset that Swift supports
        enum Vendor: String, Encodable {
            case apple
            case ibm
            case bgp
            case suse
            // And the rest
        }

        // Should be only the subset that Swift supports
        enum OSType: String, Encodable {
            case linux
            case openBSD
            case win32
            case darwin
            case iOS
            case macOSX
            // And the rest
        }

        let archType: ArchType
        let vendor: Vendor
        let osType: OSType
        // Do we need the LLVM environment here?
        public init(archType: ArchType, vendor: Vendor, osType: OSType) {
            self.archType = archType
            self.vendor = vendor
            self.osType = osType
        }
    }

    private let llvmTriplets: [LLVMTriplet]

    private init(llvmTriplets [LLVMTriplet]) {
        self.llvmTriplets = llvmTriplets
    }

    /// Create an artifact condition.
    ///
    /// - Parameters:
    ///   - llvmTriplets: The llvm triplets for which this condition will be applied.
    public static func when(
        llvmTriplets: [LLVMTriplet]
        ) -> ArtifactCondition {
        return ArtifactCondition(llvmTriplets: llvmTriplets)
    }
}
```

## Alternatives considered

### General Approach

There are three popular use cases for binary packages (terminology courtesy
of
[Tommaso Piazza](https://forums.swift.org/t/spm-support-for-binaries-distribution/25549/32)). They
are all related, but for the purposes of this proposal we will distinguish them:

1. "Vendored binaries" (no source available, or cannot be built from source)
2. "Artifact cache" (pre-built version of packages which are available in source form)
3. "Published & tagged binaries" (the package manager heavily depends on
   published and tagged binary artifacts)

In the first case, binary packages are used because there is no other viable
alternative. In the second case, binary artifacts are used to either accelerate
development (by eliminating existing build or analysis steps), or to simplify
cognitive load (e.g. by removing uninteresting sources from display in an IDE
with package integration). In the third case, the very mechanism the package
manager uses to resolve dependencies is deeply integrated with the publishing of
a binary artifact. While the third approach is popular in certain ecosystems and
package managers like Maven, we consider it out of scope given SwiftPM's current
decentralized architecture, and we will ignore it for the remained of this
proposal.

The proposal explicit sets out to solve the first use case; a natural question
is should the second use case be supported by the same feature. In this
proposal, we chose not to go that route, for the following reasons:

* When used as a build or space optimization, artifact caching is a general
  purpose strategy which can be applied to *any* package. SwiftPM was explicitly
  designed in order to allow the eventual implementation of performant,
  scalable, and even distributed caches for package artifacts. Artifact caching
  is something we would like to "just work" in order to give the best possible
  user experience.
  
  In particular, when artifact is employed "manually" to achieve the above
  goals, it often introduces certain amounts of ambiguity or risk. From the
  user's perspective, when the source of a package is available, then one would
  typically like to think of the artifact cache as a perfect reproduction of
  "what would have been built, if I built it myself". However, leveraging a
  binary package like mechanism instead of explicit tool support for this often
  means:
  
  * There is almost no enforcement that the consumed binary artifact matches the
    source. The above presumption of equivalence makes such artifact caches a
    ripe opportunity for embedding malware into an ecosystem.

  * The consumer does not always have control over the artifact production. This
    interacts adversely with potential future SwiftPM features which would allow
    the build of a package to be more dependent on its consumer (e.g. allowing
    compile-time configuration "knobs & switches").

  * The artifact cache "optimization" may not apply to all packages, or may
    require substantial manual effort to maintain.

* When used as a workflow improvement (e.g. to reduce the scope of searches),
  our position is that the user would ultimately have a better user experience
  by explicitly enumerating and designing features (either in SwiftPM, or in
  related tools) to address these use cases. When analyzed, it may become clear
  that there is more nuance to the solution than an artifact caching scheme
  could reasonably support.

* The choice to support both source and binary packages in the same mechanism
  imposes certain requirements on the design which make it more complex than the
  existing proposal. In particular, it means that the metadata about how the
  source and artifacts are mapped must be kept somewhere adjacent to but
  distinct from the package description (since a source package needs to define
  its source layout). However, such a mechanism must also be defined in a way
  that works when no source layout is present to support binary only packages.
  
  Finally, since it would be a feature with user-authored metadata, such a
  mechanism would need to be updated when any other SwiftPM enhancement
  introduces or changes the nature of the source layout specification.

Taken together, the above points led us to focus on a proposal focused at
"vendored binaries", while our hope is that artifact caching eventually becomes
a built-in and automatic feature of the package manager which applies to all
packages.

### Binary Signatures

We considered adding signature checks during the checkout of binary dependencies but when these have transitive dependencies it gets complicated expressing that in the `Package.swift`.

```
     let package = Package(
         name: "Paper",
         products: [...],
         dependencies: [
             .package(url: "http://some/other/lib", .exact("1.2.3"), binarySignature: .any),
             .package(url: "http://some/other/lib", .exact("1.2.3"), binarySignature: .gpg("XXX")"),
         ],
         targets: [...]
     )
```

### Binary target vs. binary product
During the discussion, it was brought up whether a binary dependency should be declared as a target or a product. Below is a list of what we took into consideration when deciding between target and product. In the end, a target seems like a better choice for a binary dependency.

- Targets allow configuring linker/compiler flags; this ability might be necessary for static libraries
- There are already `systemLibraryTargets` which are essentially dependencies on pre-existing binaries on the host system
- Targets represent a single module, the same is true for one XCFramework
- Currently there is no way to depend on products, so mixed binary and source packages might be harder if we go with a binary product approach
- Analogy with what currently is being produced by source packages (dylibs => product)

### .o file format
During the discussion of the proposal, the idea of using `.o` files was brought up. This would follow what SwiftPM creates for source-based dependencies right now; therefore, making the integration potentially easier. The main benefit of using `.o` files would be that the product linking the binary artifact can decide whether to link it dynamically or statically. However, further discussion needs to happen here how this would work. For now XCFrameworks are the initial format. XCFrameworks will allow current framework authors to package their existing XCFrameworks and distribute them via SwiftPM.

### Avoiding duplicate symbols with static libraries/frameworks
When multiple products depend on a static library or framework it will result in duplicated symbols. SwiftPM could be smart enough to figure this out from the manifest and provide an error. This is a potential future improvement, but would require SwiftPM to know the linkage type of the artifact.

### Opt-in to allow binaries
In the beginning, we considered making binary support an opt-in feature so that only when somebody explicitly allows it then SwiftPM tried to use them. However, after discussion in the Swift forum we came to the conclusion that the trust one has to extend to a dependency is no different between a source-based and binary-based one; therefore, we removed the opt-in behavior but added an opt-out behavior.

Using an opt-in mechanism for binary dependencies would also mean that any package that adds a binary dependencies would need to do a major version bump, because it will require any client to change something in their manifests.

### Whitelist for allowed URLs for binary dependencies
During the discussion of this proposal another solution to the `allowsBinary` flag was brought up. That is to create a whitelist for URLs that are allowed origins for binary artifacts. This way one can still control from where binary dependencies come but it doesn't require to allow them for a complete dependency tree; therefore, giving more fine-grained control. However, we propose an opt-out mechanism instead. 

### Opt-out configuration in separate file
During the discussion of this proposal it was decided that an opt-out mechanism was good to give package users and vendors an escape hatch. However, it was discussed whether this configuration should live inside the manifest or a separate configuration file. In this proposal, we opted to keep the configuration inside the manifest file.

### Opt-out in package manifest
In the first round, we proposed to add a configuration flag in the manifest to opt-out of binary dependencies; however, during the review it became apparent that this flag doesn't provide as much value and can make some dependencies actually more restricted when they add this flag. Therefor, we opted to not include such a configuration flag and let workflow tooling provide this functionality if needed.

```swift
public final class Package {
    ...
    /// This disallows any binary dependency or any transitive binary dependency.
    public var disallowsBinaryDependencies: Bool
    ...
}
```

```swift
let package = Package(
    name: "SomeOtherPackage",
    disallowsBinaryDependencies: true,
    products: [
        .library(name: "SomeOtherPackage", targets: ["SomeOtherPackageLib"])
    ],
    targets: [
        .target(name: "SomeOtherPackageLib")
     ]
)
```

### Support for various artifact stores
Initially, we considered the various artifact stores on the market and how we can integrate with them. We decided to support a URL based artifact definition for the first implementation since the various providers require each their own method of authentication. However, we wanted to keep the possibility for future additions of providers open; therefore, we made the source of an artifact an enum which can be extended.

Possible artifact stores we considered:
- Github releases
- Github packages
- Gitlab
- Bitbucket
- Artifactory, Nexus etc.

### Conditional Linkage
During the discussion of this proposal it was brought up to support conditional linkage of binary targets. This is in itself a very useful feature; however, it applies to binary and source based targets. In the end, conditional linkage is an orthogonal feature which can be pitched separately.