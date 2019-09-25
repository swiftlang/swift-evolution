# Binary dependencies

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Braden Scothern](https://github.com/bscothern), [Daniel Dunbar](https://github.com/ddunbar), [Franz Busch](https://github.com/FranzBusch)
* Review Manager: TBD
* Status: **Awaiting implementation**

*During the review process, add the following fields as needed:*

* Implementation: [apple/swift-package-manager#NNNNN](https://github.com/apple/swift-package-manager/pull/NNNNN)
* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

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

 * Someone want's to create a Swift package for
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
forms of "binary packages". This proposal is intentionally written to be a
address the above use cases *explicitly*, it **does not** define a general
purpose "binary artifact" mechanism intended to address other use cases (such as
accelerating build performance). The motivations for this are discussed in more
detail below.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/)

Pitch Thread: https://forums.swift.org/t/spm-support-for-binaries-distribution/25549/24
                        
## Motivation

SwiftPM has a large appeal to certain developer communities, like the iOS
ecosystem, where it is currently very common to rely on closed source
dependencies such as Firebase, GoogleAnalytics, Adjust and many more. Existing
package managers like Cocoapods support these use cases. By adding such support
to SwiftPM, we will unblock substantially more adoption of SwiftPM within those
communities.

Prior to Swift 5.1, the Swift compiler itself did not expose all of the features
(like ABI compatibility) required to build a workable solution. Now that those
features are present, it makes sense to reevaluate the role of binary packages.

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

To enable binary dependencies we have to make changes in the `Package.swift` manifest file. First, we propose to add a new target type which describes a binary target. An example of such a package can be seen below:

```swift
let package = Package(
    name: "SomePackage",
    products: [
        .library(name: "SomePackage", targets: ["SomePackageLib"])
    ],
    targets: [
        .binaryTarget(
            name: "SomePackageLib",
            artifacts: [
                .artifact(
                    source: .url("https://github.com/some/package/releases/download/1.0.0/SomePackage-1.0.0.zip"),
                    .when(llvmTriplets: [.init(archType: .x86_64, vendor: .apple, osType: .macOSX)])
                ),
            ]
        )
     ]
)
```


Secondly we propose to add a new configuration point to the package description that allows packages to opt-out of binary dependencies. This will enforce that nothing in its transitive dependencies brings a binary dependency with it.

**Note:** This could also be moved into a configuration file. Secondly, we can bikeshed a proper name in the review phase.

```swift
let package = Package(
    name: "SomeOtherPackage",
    disallowsBinaryDependencies: true
    products: [
        .library(name: "SomeOtherPackage", targets: ["SomeOtherPackageLib"])
    ],
    targets: [
        .target(
            name: "SomeOtherPackageLib",
        ),
     ]
)
```

Packages are allowed to contain a mix of binary and source targets. This is
useful when, for example, providing a pre-built or closed source C library
alongside an open source set of Swift bindings for the library.

When a package is built that depends upon any product with a binary target, the
package manager will search the `artifacts` declaration list to find an artifact
which matches the current build conditions. This list
will be searched in order, and the first matching artifact will be used. It is
the job of the package author/published to provide an appropriate set of
artifacts for the use cases the package wishes to support.

## Detailed design

The design consists of the following key points:
* New `PackageDescription` API for defining a binary target.
* New `PackageDescription` conditional APIs (as used in `BuildSettingCondition`)
  for describing a specific artifact with an appropriate level of granularity.
* New parameter on a package declaration level to opt-out of binary dependencies.
* A new convention-based platform-specific layout for a binary target artifact.
* New requirements for the `Package.resolved` file when using binary packages.
* A new mechanism for downloading binary target artifacts.

Terminology:

* Technically, a *target* is binary or not. However, we anticipate that often a
  single package will consist of either exclusively source or binary targets. We
  will use the term *binary package* to refer to any package which contains at
  least one binary product. Similarly, a *binary product* is one which contains
  at least one binary target.

Our design attempts to optimize for the following goals:

* Ease of use for clients
* Easy of implementation in existing SwiftPM
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
Since, a binary target is different compared to a source only target, we propose to introduce a new struct `Artifact`. This struct defines a targets associated artifacts.

We propose to support local and remote artifacts from the beginning. In the alternatives considered section is larger collection of potential artifact stores. However we opted to simplify the initial implementation by just supporting a url and a path based definition. Later, we can implement different types of providers with different authentication methods.

```swift
public struct Artifact {
    public enum Source {
        case url(String)
        case path()
    }

    public let source: Source
    public let condition: ArtifactCondition
}
```

Furthermore, we propose to add a new `artifacts: [Artifacts]?` property to the `Target`, as well as extend the initializer with this parameter and create a new static method called `.binaryTarget()`. Lastly, we propose to extend the `TargetType` enum with a new case called `binary`.

### ArtifactCondition
To describe for what platform and architecture any given artifact is, we propose to create a new `ArtifactCondition`, similar to the `BuildSettingCondition`. Since the different platforms provide a multitude of ABIs we propose to construct an `ArtifactCondition` based on the LLVM triplet.

**Note:** Should we also consider the core-libs-foundation ABI here?

```swift
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

### PackageDescription
To opt out of binary packages we propose a new configuration point inside the package description.

```swift
public final class Package {
    // ...
    /// This disallows any binary dependency or any transitive binary dependency.
    public var disallowsBinaryDependencies: Bool
    // ...
}
```

## New `Package.resolved` Behavior

TODO: This still needs to be investigated.

### Resolution

Package resolution and dependency expression will not be impacted by this change (except where explicitly noted).

## Binary Target Artifact Format

SwiftPM supports various platforms and for each of them we need to find a format for the artifacts. Below is a list with a convention for the artifacts that we expect for each platform. (Courtesy to [Jake Petroules](https://forums.swift.org/t/pitch-support-for-binary-dependencies/27620/74?u=franzbusch))

### Apple

We use XCFrameworks. A single XCFramework can support any or all of the ABIs relevant for Apple OSes (macOS, iOS, tvOS, watchOS) as well as the special cases of Mac Catalyst and DriverKit.

### Windows

Nest artifacts inside architecture folders using the same naming convention as Microsoft does: ARM, ARM64, X86, X64.

### Android

Similar with Windows, nest inside architecture folders using the platform naming convention: armeabi-v7a, arm64-v8a, x86, x86_64.

**Note:** That armeabi (armv5), mips and mips64 are obsolete since NDK r17; let's not worry about those.

### Linux

TODO: This section is still open for discussion since Linux brings a lot of its own problems with unstable ABI etc. with it.

### Open discussion .o files
During the discussion of the proposal, the idea of using `.o` files was brought up. This would follow what SwiftPM creates for source-based dependencies right now; therefor, making the integration potentially easier. However, further discussion needs to happen here.

- Product could determine linkage when using .o files

## Security

When adding new external dependencies, it is always important to consider the security implication that it will bring with it. Comparing the trust level of a source-based to a binary-based dependency the first thought is that the trust level of the source-based dependency is higher since on can inspect its source code. However, there is no difference between a binary and source dependency since source-based dependencies can have security issues as well. One should have better reasons to trust a dependency than source being inspectable.

There is still a significant difference between having a dependency with zero vs. any binary dependency. For example, the portability of a library with binary dependencies is far worse than the one with only source-based dependencies. For this reason, we propose to add an additional configuration point in the manifest that allows package authors to opt-out of binary dependencies.

However, there are still some security related aspects when it comes to binary artifacts that we should mitigate. For example, when declaring a `binaryTarget` the hash of the artifact is required similar to Homebrew. By doing this an attacker needs to compromise both the server which provides the artifact as well as the git repository which provides the package manifest. A secondary reason is that the server providing the binary might be out of the package author's control and this way we can ensure that the expected binary is used.

Lastly, the hash of the binary is stored in the package resolved to avoid that the vendor changes the artifact behind a version without anyone noticing.

## Impact on existing packages

No current package should be affected by this change since this is only an additive in enabling SwiftPM to use binary dependencies.

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
  by explicitly enumarting and designing features (either in SwiftPM, or in
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

### Opt-in to allow binaries
In the beginning, we considered to make binary support a opt-in feature so that only when somebody explicitly allows it then SwiftPM tried to use them. However, after discussion in the Swift forum we came to the conclusion that the trust one has to extend to a dependency is no different between a source-based and binary-based one; therefor, we made removed the opt-in behavior but added a opt-out behavior.

Using an opt-in mechanism for binary dependencies would also mean that any package that adds a binary dependencies would need to do a major version bump, because it will require any client to change something in their manifests.

### Whitelist for allowed URLs for binary dependencies
During the discussion of this proposal another solution to the `allowsBinary` flag was brought up. That is to create a whitelist for URLs that are allowed origins for binary artifacts. This way one can still control from where binary dependencies come but it doesn't require to allow them for a complete dependency tree; therefore, giving more fine-grained control. However, we propose an opt-out mechanism instead. 

### Support for various artifact stores
Initially, we considered the various artifact stores on the market and how we can integrate with them. We decided to support a URL based artifact definition for the first implementation since the various providers require each their own method of authentication. However, we wanted to keep the possibility for future additions of providers open; therefore, we made the source of an artifact an enum which can be extended.

Possible artifact stores we considered:
- Github releases
- Github packages
- Gitlab
- Bitbucket
- Artifactory, Nexus etc.

### Dynamic frameworks


### Resources
The intial version of the proposal used `XCFrameworks` as the format for artifacts on Apple platforms. As a side effect that would have allowed for resources to be included via these frameworks. However, we changed the format for artifacts to `.o` files to follow current standards in SwiftPM. After all, SwiftPM itself does not support resources yet; therefore, we consider not supporting them via binary targets is fine. Once SwiftPM supports resources, binary targets should gain support for them as well.

### Conditional Linkage
During the discussion of this proposal it was brought up to support conditional linkage of binary targets. This is in itself a very useful feature; however, it applies to binary and source based targets. In the end, conditional linkage is an orthogonal feature which can be pitched separately.