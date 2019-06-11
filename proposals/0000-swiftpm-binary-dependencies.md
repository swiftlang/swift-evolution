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

Add support for binary dependencies to SwiftPM. This would allow vendors to make their closed source packages available in SwiftPM.

Swift-evolution thread: [Discussion thread topic for that
proposal](https://forums.swift.org/)

## Motivation

Currently, SwiftPM only supports source packages which are then compiled locally. With the integration of SwiftPM into Xcode, it now has the chance to replace the current usages of Cocoapods and similar package managers. One important part they cover is the integration of binary-only dependencies such as Firebase, GoogleAnalytics, Adjust and many more. Especially, for commercially licensed dependencies, it is often the case that these are distributed as pre-built binary frameworks. As these are often used third party frameworks enabling SwiftPM to integrate these is crucial for its success as an Xcode dependency manager.

Another goal of this proposal is to make the integration of binary-only dependencies the same as source dependencies and let the vendor of such frameworks do the heavy lifting.

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

## Detailed design

Describe the design of the solution in detail. If it involves adding or
modifying functionality in the package manager, explain how the package manager
behaves in different scenarios and with existing features. If it's a new API in
the `Package.swift` manifest, show the full API and its documentation comments
detailing what it does.  The detail in this section should be sufficient for
someone who is *not* one of the authors of the proposal to be able to reasonably
implement the feature.

### Metadata
Convention based (always expect XCFrameworks e.g.)
Non-mac: bin, lib, include

Products vs Target

Target to have source and binary dependencies
Allow recursive dependencies?

Example, FirebaseMessaging having FirebaseCor
Optimizely, Adjust

Force to specify type (static, dynamic)

### Artifact fromats of the binaries
|                 	| Dynamic                                                                                                                                                        	| Static              	| Executables 	|   	|
|-----------------	|----------------------------------------------------------------------------------------------------------------------------------------------------------------	|---------------------	|-------------	|---	|
| Apple (Swift)   	| XCFramework                                                                                                                                                    	| XCFramework?        	| bin         	|   	|
| Apple (C)       	| XCFramework                                                                                                                                                    	| XCFramework         	| bin         	|   	|
| "POSIX" (Swift) 	| module.swiftmodule/architecture.swiftmodule module.swiftmodule/architecture.swiftinterface module.swiftmodule/architecture.swiftinterface lib/libTargetName.so 	| lib/libTargetName.a 	| bin         	|   	|
| "POSIX" (C)     	| lib/libTargetName.so headers                                                                                                                                   	| lib/libTargetName.a 	| bin         	|   	|
|                 	|                                                                                                                                                                	|                     	|             	|   	|


### Resolution
It should be possible to use the current resolver

### How to fetch binary dependencies
Potential storage places:

- Github releases
- Github packages?
- Gitlab?
- Bitbucket?
- git
- git-lfs
- URLs (Http and local)
- Artifactory, Nexus etc. 

System credentials store to put authentication for artifact stores

Initial implementation urls, github

## Security

Since binary only dependencies are not inspectable and one has to extend a certain trust to the third party it should be an opt-in feature. This means when declaring a dependency one has to explicitly allow the usage of binary frameworks. Furthermore, the hash of the binary should also be stored in the package resolved to avoid that the vendor changes the artifact behind a version without anyone noticing.

## Impact on existing packages

No current package should be affected by this change since this is only an additive in enabling SwiftPM to use binary dependencies.

## Alternatives considered

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
