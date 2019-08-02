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
   for use in their iOS applications, but for security reasons cannot publish
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
binary packages *where necessary*, but not to encourage their use or faciliate a
transition from the existing source-based ecosystem to a binary one.

This proposal is also focused at packages which come exclusively in binary form,
it explicitly **does not** introduce a mechanism which allows a package to be
present in either source or binary form. See alternatives considered for more
information on this choice.

## Proposed solution

To enable binary dependencies we have to make two changes in the `Package.swift` manifest file, one for the vendor and one for the consumer. First, we propose to add a new target type which describes a binary target. An example of such a package can be seen below:

```
 let package = Package(
     name: "LibPNG",
     products: [
         .library(name: "LibPNG", targets: ["LibPNG"])
     ],
     dependencies: [
         .package(url: "http://example.com.com/ExamplePackage/ExamplePackage", from: "1.2.3")
     ],
     targets: [
         .target(
             name: "LibPNG",
             dependencies: [
                 "CLibPng"
             ]),
         .binaryTarget(
             name: "CLibPng",
             artifacts: [
             		.artifact(
             			source: .url("https://github.com/firebase/firebase-ios-sdk/releases/download/6.2.0/Firebase-6.2.0.zip"),
             			.when(platforms: [.macOS, .iOS])
         			),
         			.artifact(
             			source: .url("https://github.com/firebase/firebase-ios-sdk/releases/download/6.2.0/Firebase-6.2.0.zip")
             			.when(platforms: [.linux], architectures: [.x86])
             		],
         		dependencies: [
         			"ExamplePackage"
         		])
     ]
 )
```


Secondly to use such a binary dependency in another package we have to explicitly opt-in as showcased below.


```
     let package = Package(
         name: "Paper",
         products: [...],
         dependencies: [
             .package(url: "http://example.com.com/ExamplePackage/ExamplePackage", from: "1.2.3"),
             .package(url: "http://some/other/lib", .exact("1.2.3"), allowsBinary: true)
         ],
         targets: [...]
     )
```

Packages are allowed to contain a mix of binary and source targets. This is
useful when, for example, providing a pre-built or closed source C library
alongside an open source set of Swift bindings for the library.

To be built, a package which has binary targets *must* be either the root
package, or must be included via a `.package` declaration that includes the
`allowsBinary: true` attribute. Similarly, any package *must* follow the same
requirements to itself use the `allowsBinary: true`. This ensures that any areas
in a packages transitive graph which might add a dependency on a binary package
are explicitly declared. This is intended to prevent binary artifacts from being
transparently introduced without explicit consenst up the entire dependency
chain.

When a package is built that depends upon any product with a binary target, the
package manager will search the `artifacts` declaration list to find an artifact
which matches the current build target (platform, architecture, etc.). This list
will be searched in order, and the first matching artifact will be used. It is
the job of the package author/published to provide an appropriate set of
artifacts for the use cases the package wishes to support.

## Detailed design

The design consists of the following key points:
* New `PackageDescription` API for defining a binary target.
* New `PackageDescription` conditional APIs (as used in `BuildSettingCondition`)
  for describing a specific artifact with an appropriate level of granularity.
* New parameter on a package dependency declaration to allow use of binary artifacts.
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
* Support existing well-known occurences of binary artifacts in the existing
  (often iOS focused) target developer market.

while keeping the following as non-goals:

* Ease of production of binary packages
* Simplicity of binary artifact distribution mechanism
* Widespread use of binary packages

## New `PackageDescription` API

### BinaryTarget
Since, a binary target is different compared to a source only target, we propose to introduce a new struct `Artifact`. This struct defines a targets associated artifacts.

```swift
public struct Artifact {
    public enum Source {
        case url(String)
    }

    public let source: Source
    public let condition: ArtifactCondition
}
```

Furthermore, we propose to add a new `artifacts: [Artifacts]?` property to the `Target`, as well as extend the initlizer with this paramter and create a new static method called `.binaryTarget()`. Lastly, we propose to exten the `TargetType` enum with a new case called `binary`.



### ArtifactCondition
To describe for what platform and architecture any given artifact is, we propose to create a new `ArtifactCondition`, similar to the `BuildSettingCondition`.

```swift
/// Represents an architecture that usually corresponds to a processor architecture such as
/// x86 or ARM.
public struct Architecture {

    /// The name of the platform.
    fileprivate let name: String

    private init(name: String) {
        self.name = name
    }

    public static let x86: Platform = Platform(name: "x86")
    public static let arm: Platform = Platform(name: "ARM")

}

public struct ArtifactCondition: Encodable {

    private let platforms: [Platform]
    private let architectures: [Architecture]?

    private init(platforms: [Platform], architecture: [Architecture]?) {
        self.platforms = platforms
        self.architectures = architectures
    }

    /// Create an artifact condition.
    ///
    /// - Parameters:
    ///   - platforms: The platforms for which this condition will be applied.
    ///   - architectures: The architectures for which this condition will be applied.
    public static func when(
        platforms: [Platform],
        architectures: [Architecture]? = nil
        ) -> ArtifactCondition {
        return ArtifactCondition(platforms: platforms, architecture: architectures)
    }
}
```

### PackageDescription
To include binary packages it is required to opt-in. For this we propose to modify the `Dependency` struct and add a new property `allowsBinary`.

```swift
      public class Dependency: Encodable {
        public enum Requirement {
            ...
        }

        /// The url of the dependency.
        public let url: String

        /// The dependency requirement.
        public let requirement: Requirement

        public let allowsBinary: Bool

        /// Create a dependency.
        init(url: String, requirement: Requirement, allowsBinary: Bool = false) {
            self.url = url
            self.requirement = requirement
            self.allowsBinary = allowsBinary
        }
    }
```

## New `Package.resolved` Behavior

* FIXME

### Resolution

Package resolution and dependency expression will not be impacted by this change (except where explicitly noted).

## Binary Target Artifact Format

SwiftPM supports various platforms and for each of them we need to find a format for the artifacts. Below is a list with a convention for the artifiacts that we expect for each platform. 

|                 	| Dynamic                                                                                                                                                        	| Static              	| Executables 	|   	|
|-----------------	|----------------------------------------------------------------------------------------------------------------------------------------------------------------	|---------------------	|-------------	|---	|
| Apple (Swift)   	| XCFramework                                                                                                                                                    	| XCFramework        	| bin         	|   	|
| Apple (C)       	| XCFramework                                                                                                                                                    	| XCFramework         	| bin         	|   	|
| "POSIX" (Swift) 	| module.swiftmodule/architecture.swiftmodule module.swiftmodule/architecture.swiftinterface module.swiftmodule/architecture.swiftinterface lib/libTargetName.so 	| lib/libTargetName.a 	| bin         	|   	|
| "POSIX" (C)     	| lib/libTargetName.so headers                                                                                                                                   	| lib/libTargetName.a 	| bin         	|   	|
|                 	|                                                                                                                                                                	|                     	|             	|   	|

=======

* Ease of production of binary packages
* Simplicity of binary artifact distribution mechanism
* Widespread use of binary packages

* FIXME: Fill out detailed design.

## New `PackageDescription` API

* FIXME: `binaryTarget`
* FIXME: `BuildSettingCondition`
* FIXME: package declaration

## Binary Target Artifact Format

|                 	| Dynamic                                                                                                                                                        	| Static              	| Executables 	|   	|
|-----------------	|----------------------------------------------------------------------------------------------------------------------------------------------------------------	|---------------------	|-------------	|---	|
| Apple (Swift)   	| XCFramework                                                                                                                                                    	| XCFramework?        	| bin         	|   	|
| Apple (C)       	| XCFramework                                                                                                                                                    	| XCFramework         	| bin         	|   	|
| "POSIX" (Swift) 	| module.swiftmodule/architecture.swiftmodule module.swiftmodule/architecture.swiftinterface module.swiftmodule/architecture.swiftinterface lib/libTargetName.so 	| lib/libTargetName.a 	| bin         	|   	|
| "POSIX" (C)     	| lib/libTargetName.so headers                                                                                                                                   	| lib/libTargetName.a 	| bin         	|   	|
|                 	|                                                                                                                                                                	|                     	|             	|   	|

## New `Package.resolved` Behavior

* FIXME

### Resolution

Package resolution and dependency expression will not be impacted by this change (except where explicitly noted).

## Security

Since binary only dependencies are not inspectable and one has to extend a certain trust to the third party it should be an opt-in feature. This means when declaring a dependency one has to explicitly allow the usage of binary frameworks. Furthermore, the hash of the binary should also be stored in the package resolved to avoid that the vendor changes the artifact behind a version without anyone noticing.

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
"vendored binaries", while our hope is that artifact caching eventually becames
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

### Support for various artifact stores
Initially, we considered the various artifact stores on the market and how we can integrate with them. We decided to support a URL based artifact definition for the first implementation since the various providers require each their own method of authentication. However, we wanted to keep the possiblity for future additions of providers open; therefore, we made the source of an artifiact an enum which can be extended.

Possible artifact stores we considered:
- Github releases
- Github packages
- Gitlab
- Bitbucket
- Artifactory, Nexus etc.


## TODO

* FIXME: Add information on integration with any resources proposal (XFrameworks support them right, how about linux though?)
* FIXME: Add information on dSYMs (XCFrameworks support them out of the box right?)
* FIXME: More on security
* FIXME: Goals (easy for consumers)
* FIXME: Transitive behavior
* FIXME: Discuss concern with explosion of artifacts (consequence of putting at
  the target level).