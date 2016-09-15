# Swift Testing

* Proposal: [SE-0019](0019-package-manager-testing.md)
* Authors: [Max Howell](https://github.com/mxcl), [Daniel Dunbar](https://github.com/ddunbar), [Mattt Thompson](https://github.com/mattt)
* Review Manager: [Rick Ballard](https://github.com/rballard)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160118/007278.html)
* Bug: [SR-592](https://bugs.swift.org/browse/SR-592)

## Introduction

Testing is an essential part of modern software development.
Tight integration of testing into the Swift Package Manager
will help ensure a stable and reliable packaging ecosystem.

[SE Review Link](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160104/005397.html), [Second Review](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160111/006758.html)

## Proposed Solution

We propose to extend our conventional package directory layout
to accommodate test modules.
Any subdirectory of the package root directory named "Tests"
or any subdirectory of an existing module directory named "Tests"
will comprise a test module.
For example:

    Package
    ├── Sources
    │   └── Foo
    │       └──Foo.swift
    └── Tests
        └── Foo
            └── Test.swift

Or:

    Package
    └── Sources
        ├── Foo.swift
        └── Tests
            └── Test.swift

Or, for projects with a single module:

    Package
    ├── Sources
    │   └── Foo.swift
    └── Tests
        └── TestFoo.swift
        

The filename: `TestFoo.swift` is arbitrary.

In the examples above
a test case is created for the module `Foo`
based on the sources in the relevant subdirectories.

A test-module is created per subdirectory of Tests, so:

    Package
    ├── Sources
    │   └── Foo
    │       └──Foo.swift
    └── Tests
        └── Foo
            └── Test.swift
        └── Bar
            └── Test.swift

Would create two test-modules. The modules in this example may
test different aspects of the module Foo, it is entirely up
to the package author.

Additionally, we propose that building a module
also builds that module's corresponding tests.
Although this would result in slightly increased build times,
we believe that tests are important enough to justify this
(one might even consider slow building tests to be a code smell).
We would prefer to go even further by executing the tests
each time a module is built as well,
but we understand that this would impede debug cycles.

As an exception, when packages are built in release mode we will
not build tests because for release builds we should not enable
testability. However, considering the need for release-mode testing
this will be a future direction.

This feature is controversial; many are worried always building
tests will slow debug cycles. We understand these concerns but
think knowing quickly tests have been broken by code changes is
important. However we will provide an command line option to not
build tests and will be open to reversing this decision in future
should it be proven unwise.


### Command-Line Interface

We propose the following syntax to execute all tests (though not the tests
of any dependent packages):

    $ swift test

The command line should accept the names of specific test cases to run:

    swift test TestModule.FooTestCase

Or specific tests:

    swift test TestModule.FooTestCase.test1

In the future we would like to support running specific kinds of tests:

    swift test --kind=performance

`swift test` would forward any other arguments to the underlying testing framework and it
would decide how to interpret them.

---

Sometimes test sources cannot compile and fixing them is not the most
pressing priority. Thus it will be possible to skip building tests
with an additional flag:

    swift build --without-tests

---

It is desirable to sometimes specify to only build specific tests, the
command line for this will fall out of future work that allows specification
of targets that `swift build` should specifically build in isolation.

---

Users should be able to run the tests of all their dependencies.
This is not the default behavior, but a flag will be provided.


### Command Output

Executing a test from the terminal will produce user-readable output.
This should incorporate colorization and other formatting
similar to other testing tools
to indicate the success and failure of different tests.
For example:

    $ swift test --output module
    Running tests for PackageX (x/100)
    .........x.....x...................

    Completed
    Elapsed time: 0.2s

    98 Success
     2 Failure
     1 Warning

    FAILURE: Tests/TestsA.swift:24 testFoo()
    XCTAssertTrue expected true, got false

    FAILURE: Tests/TestsB.swift:10 testBar()
    XCTAssertEqual

    WARNING: Tests/TestsC.swift:1
    "Some Warning"

An additional option may be passed to the testing command
to output JUnit-style XML or other formats that can be integrated
with continuous integration (CI) and other systems.

Running `swift test` will firstly trigger a build. We feel this
is the most expected result considering tests must be built before
they can be run and almost all other tools build before running
tests. However we will provide a flag to not build first.


### Test-only Dependencies

There is already a mechanism to specify test-only dependencies.
It is very basic, but a new proposal should be made for more
advanced `Package.swift` functionality.

This proposal also does not cover the need for utility code, ie.
a module that is built for tests to consume that is provided as
part of a package and is not desired to be an external package.
This is something we would like to add as part of a future proposal.


### Test-target configuration

This proposal does not allow a test-module to have module dependencies
from its own package, and thus there is no provided mechanism to 
specify or configure tests in the `Package.swift` file.

This will be added, but as part of a broader proposal for the future
of the `Package.swift` file.


### Automatic Dependency Determination

Testing is important and it is important to make the barrier to testing
as minimal as possible. Thus, by analyzing the names of test targets,
we will automatically determine the most likely dependency of that test
and accommodate accordingly.
For example,
a test for "Foo" will depend on compilation of the library target `Foo`.
Any additional dependencies or dependencies that could not be automatically determined
would need to be specified in a package manifest separately.


### Debug / Release Configuration

Although tests built in debug configuration
are generally run against modules also build in debug configuration,
it is sometimes necessary to specify the build configuration for tests separately.
It is also sometimes necessary to explicitly specify this information for every build,
such as when building in a release configuration to execute performance tests.
We would like to eventually support these use cases,
however this will not be present in the initial implementation of this feature.


### Testability

Swift can build modules with "testability",
which allows tests to access entities with `internal` access control.
Because it would be tedious for users to specify this requirement for tests,
we intend to build debug builds with testability by default.

It is desirable that modules that are built for testing can identify this
fact in their sources. Thus at a future time we will provide a define.


### Test Frameworks

Initially,
the Swift Package Manager will use `XCTest` as its underlying test framework.

However, testing is an evolving art form,
so we'd like to support other approaches
that might allow frameworks other than XCTest
to be supported by the package manager.
We expect that such an implementation would take the form of
a Swift protocol that the package manager defines,
which other testing frameworks can adopt.

## Impact On Existing Code

Current releases of the package manager already exclude directories named
"Tests" from target-determination. Directories named `FooTests` are not
excluded, but as it stands this is a cause of compile failure, so in fact
these changes will positively impact existing code.


## Alternatives Considered

We considered supporting the following layout:

    Package
    └── Sources
    │   └── Foo.swift
    └── FooTests
        └── Test.swift

This was considered because of the vast number of existing
Xcode projects out there that are laid out in the fashion.
However it was decided that the rules for these layouts are
inconsistent with our existing simple set. When users experience
unexpected consequences of layouts with our convention approach
it can be confusing and tricky to diagnose, so we should instead
submit another proposal in the future that allows easy
configuration of targets in `Package.swift`.

---
We considered decoupling testing from SwiftPM altogether.

However, since tests must be built and dependencies of tests
must be managed complete decoupling is not possible. The coupling
will be minimal, with a separate library and executable for tests,
this is about as far as we think it is prudent to go.

---

We considered not baking in support for XCTest and only having
a protocol for testing.

We would like to get testing up to speed as soon as possible.
Using XCTest allows this to occur. We also think there is value
in packages being able to depend on a testing framework being 
provided by the Swift system.

However nothing stops us eventually making the support for XCTest
work via our protocol system.
