# Swift Testing

* Authors:
  [Max Howell](https://github.com/mxcl),
  [Daniel Dunbar](https://github.com/ddunbar),
  [Mattt Thompson](https://github.com/mattt)
* Status: **Under revision**
* Review Manager: Rick Ballard

## Introduction

Testing is an essential part of modern software development.
Tight integration of testing into the Swift Package Manager
will help ensure a stable and reliable packaging ecosystem.

## Proposed Solution

We propose to extend our conventional package directory layout
to accomodate test modules.
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

Or, for simpler projects:

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

Additionally we will support directories called `FooTests`.
This layout style is prevalent in existing open source projects
and supporting it will minimize vexation for their authors.
However in the interest of consistency and the corresponding 
reduction of cognitive-load when examining new Swift packages
we will not recommend this layout. For example:

    Package
    └── Sources
    │   └── Foo.swift
    └── FooTests
        └── Test.swift

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

### Command-Line Interface

We propose the following syntax to execute tests:

    $ swift build --test

Or:

    $ swift build -t

In the future, we may choose to promote the `--test` option
to be a subcommand of the `swift` command itself:

    $ swift test

However, any such decision would warrant extensive design consideration,
so as to avoid polluting or crowding the command-line interface.
Should there be sufficient demand and justification for it, though,
it would be straightforward to add this functionality.

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

### Backwards Compatibility

In order to accomodate existing packages,
we will allow test module targets and their targets
to be overridden in the `Package.swift` manifest file.
However, this functionality will likely not be implemented
in the initial release of this feature,
and instead be added at a later point in time.

### Automatic Dependency Determination

Testing is important and it is important to make the barrier to testing
as minimal as possible. Thus, by analyzing the names of test targets,
we will automatically determine the most likely dependency of that test
and accomodate accordingly.
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

### Test Frameworks

Initially,
the Swift Package Manager will use `XCTest` as its underlying test framework.

However, testing is an evolving artform,
so we'd like to support other approaches
that might allow frameworks other than XCTest
to be supported by the package manager.
We expect that such an implementation would take the form of
a Swift protocol that the package manager defines,
which other testing frameworks can adopt.


### Command Line Interface

The command line should accept the names of specific test cases to run:

    swift build -t FooTestCase

Or specific tests:

    swift build -t FooTestCase.test1

SwiftPM would forward arguments to the underlying testing framework and it
would decide how to interpret them.

---

Sometimes test sources cannot compile and fixing them is no the most
pressing priority. Thus it will be possible to skip building tests
with an additional flag:

    swift build --without-tests

---

It is desirable to sometimes specify to only build specific tests, the
command line for this will fall out of future work that allows specification
of targets that `swift build` should specifically build in isolation.


## Impact On Existing Code

Current releases of the package manager already exclude directories named
"Tests" from target-determination. Directories named `FooTests` are not
excluded, but as it stands this is a cause of compile failure, so in fact
these changes will positively impact existing code.

## Alternatives Considered

Because this is a relatively broad proposal,
no complete alternatives were considered.
