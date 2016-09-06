# Package Manager Test Naming Conventions

* Proposal: [SE-0129](0129-package-manager-test-naming-conventions.md)
* Author: [Anders Bertelrud](https://github.com/abertelrud)
* Review Manager: [Daniel Dunbar](https://github.com/ddunbar)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-build-dev/Week-of-Mon-20160725/000572.html)

## Introduction

The Swift Package Manager uses a convention-based rather than a declarative
approach for various aspects of package configuration.  This is as true of the
naming and structure of tests as of other kinds of targets.

However, the current conventions are somewhat inconsistent and unintuitive, and
they also do not provide enough flexibility.  This proposal seeks to address
these problems through updated conventions.

## Motivation

### Predictability of test target names

Module names for test targets are currently formed by appending the suffix
`TestSuite` to the name of the corresponding directory under the top-level
`Tests` directory in the package.

This makes it non-obvious to know what name to pass to `swift package test` in
order to run just one set of tests.  This is also the case for any other context
in which the module name is needed.

### Ability to declare test target dependencies

The way in which the test module name is formed also makes it difficult to add
target dependencies that specify the name of the test.  This makes it hard to
make a test depend on a library, such as a helper library containing shared code
for use by the tests.

Another consequence of unconditionally appending a `TestSuite` suffix to every
module under the `Tests` directory is that it becomes impossible to add modules
under `Tests` that define helper libraries for use only by tests.

### Reportability of errors

In order for error messages to be understandable and actionable, they should
refer to names the user can see and control.  Also, the naming convention needs
to have a reliable way of determining user intent so that error messages can be
made as clear as possible.

## Proposed solution

The essence of the proposed solution is to make the naming of tests be more
predictable and more under the package author's control.  This is achieved in
part by simplifying the naming conventions, and in part by reducing the number
of differences between the conventions for the the `Tests` and the `Sources`
top-level directories.

First, the naming convention will be changed so a module will be considered a
test if it:

1. is located under the `Tests` directory
2. has a name that ends with `Tests`

A future proposal may want to loosen the restriction so that tests can also be
located under `Sources`, if we feel that there is any use for that.  As part of
this proposal, SwiftPM will emit an error for any tests located under `Sources`.

Allowing non-test targets under the `Tests` directory will unblock future
improvements to allow test-only libraries to be located there.  It will also
unblock the potential to support test executables in the future, though this
proposal does not specifically address that.

Like any other target, a test will be able to be mentioned in a dependency
declaration.  As a convenience, if there is a target named `Foo` and a test
target named `FooTests`, a dependency between the two will be automatically
established.

It will still be allowed to have a `FooTests` test without a corresponding `Foo`
source module.  This can be useful for integration tests or for fixtures, etc.

## Detailed design

1. Change the naming conventions so that a module will be considered a test if
   it:
    - is located under the top-level `Tests` directory, and
    - has a name that ends with `Tests`
   
2. Allow a target dependency to refer to the name of a test target, which will
   allow package authors to create dependencies between tests and libraries.

3. Add an implicit dependency between any test target a non-test target that has
   the same name but without the `Tests` suffix.

4. For now, make it an error to have executables or libraries under `Tests` (for
   technical reasons, a `LinuxMain.swift` source file is permitted, and indeed
   expected, under the `Tests` top-level directory).  The intent is to loosen
   this restriction in a future proposal, to allow test-specific libraries and
   test executables under `Tests`.
   
5. For now, make it an error to have tests under `Sources`.  We may loosen this
   this restriction at some point, but would need to define what it would mean
   from a conceptual point of view to have tests under `Sources` instead of
   `Tests`.

6. Improve error reporting to reflect the new conventions.  This includes adding
   more checks, and also auditing all the error messages relating to testing to
   see if there is more information that should be displayed.
   
## Impact on existing code

The change in naming conventions does mean that any module under the top-level
`Tests` directory whose name ends with the suffix `Tests` will be considered a
test module.  The fact that this proposal does not involve allowing tests to be
located under `Sources`, and the fact that any module under `Tests` already had
an unconditional `TestSuite` suffix string appended, makes it unlikely that any
current non-test module under `Tests` would suddenly be considered a test.

Any module with a `Tests` suffix under `Sources` would need to be renamed.

Any current package that refers to a test module using a `TestSuite` suffix will
need to be changed.

## Alternatives considered

An alternative that was considered was to enhance the PackageDescription API to
let package authors explicitly tag targets as tests.  While we might still want
to add this for cases in which the author doesn't want to use any of the naming
conventions, we don't want such an API to be the only way to specify tests.
