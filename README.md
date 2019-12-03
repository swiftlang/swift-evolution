# Swift Evolution Staging

This repository is the starting point for Swift Evolution proposal
implementations. See the [Swift Evolution Process][se-process] to learn about
how ideas are pitched, refined, and then proposed for inclusion in the Swift
standard library.

[se-process]: https://github.com/apple/swift-evolution/blob/master/process.md

Complete this checklist when preparing your implementation pull request:

- In `Package.swift` and in the _Usage_ section below, rename the package to the
  lowercased name of your proposed feature, using dashes between words (ex:
  `se-NNNN-my-feature`). Your review manager will replace `NNNN` with your
  proposal assigned number.
  
- In `Package.swift` and in the _Introduction_ section below, rename your module
  to the camel-cased name of your proposed feature, using underscores between
  words (ex: `SE_NNNN_MyFeature`).
  
- Rename the folders and files in the `Sources` and `Tests` directories to match
  your new module name.
  
- Implement your proposed feature in the `Sources` directory, and add tests in
  the `Tests` directory.
  
- Make sure the Swift project code header is at the beginning of every source
  file.
  
- Finish editing the section below, and then remove this checklist and
  everything else above the line. That's it!

--------------------------------------------------------------------------------

# Package Name

> **Note:** This package is a part of a Swift Evolution proposal for
  inclusion in the Swift standard library, and is not intended for use in
  production code at this time.

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/proposals/NNNN-filename.md)
* Author(s): [Author 1](https://github.com/author1), [Author 2](https://github.com/author1)


## Introduction

A short description of the proposed library. 
Provide examples and describe how they work.

```swift
import SE_NNNN_PackageName

print(Placeholder.message)
// Prints("Hello, world!")
```


## Usage

To use this library in a Swift Package Manager project,
add the following to your `Package.swift` file's dependencies:

```swift
.package(
    url: "https://github.com/apple/swift-evolution-staging.git",
    branch: "SE_NNNN_PackageName"),
```


