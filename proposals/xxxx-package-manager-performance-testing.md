# Package Manager Performance Testing Conventions

* Proposal: [SE-XXXX](xxx-package-manager-performance-testing.md)
* Author: [Ankit Aggarwal](https://github.com/aciidb0mb3r)
* Review Manager: TBD
* Status: Discussion

## Introduction

This is a proposal for adding package manager support for building and running performance tests in release mode.

## Motivation

The package manager supports building and running tests using the `swift test` subtool. The sources are built in debug mode with swift compiler's
`-enable-testing` flag allowing testable imports in test modules (which gives it internal level access to the imported module). 
This works well for normal unit tests, however for performance tests we are usually interested in release build test results which takes advantages of compiler 
optimizations.

We can provide an option to compile and run the tests in release mode with `-enable-testing` flag. However that will disable some of the compiler optimizations, which 
may be of interest to packages having very performance sensitive code (which critically depends on those optimization).

Since performance tests usually take more time to run than other tests, there is also a requirement to have a way to run performance tests separate from unit tests.
As a concrete example, package manager's own performance tests are disabled from running on Swift CI.

## Proposed solution

A test module in a Swift package is a directory inside `Tests/` having suffix "Tests". Some properties of test modules are:

* Implicit dependency between any test target and a non-test target that has the same name but without the `Tests` suffix.
* Executed using `swift test` in debug mode with `-enable-testing` flag.

We propose to extend this convention and consider a directory as "performance test module" which has a suffix "PerformanceTests" with properties:

* Implicit dependency between any test target and a non-test target that has the same name but without the `PerformanceTests` suffix.
* Executed using `swift test --performance` in release mode without `-enable-testing` flag.

Note that this means the performance tests will not have access to testable imports.

Rest of the rules will still apply to performance test modules for e.g. it would be possible to declare explict dependencies of a performance test module
using the manifest's target property:

```swift
let package = Package(
    name: "MyPackage",
    targets: [
        Target(name: "UmbrellaPerformanceTests", dependencies: ["Foo", "Bar", "Baz"])
    ]
)
```

## Detailed Design

Currently one XCTest product (bundle on macOS, executable on Linux) is created and run for all the test modules with name `<package-name>PackageTests.xctest`.

We propose to create another test product with name `<package-name>PackagePerformanceTests.xctest` which will contain only performance tests.
This will allow package manager to run either or both of these test products.

## Impact on existing code

There will be no impact on exisiting code as this is purely additive.

## Alternative considered

None at this time.
