# Swift Release Roadmap

This document describes goals for the Swift language on a per-release
basis, usually listing minor releases adding to the currently shipping
version and one major release out.  Each release will have many
smaller features or changes independent of these larger goals, and not
all goals are reached for each release.

Goals for past versions are included at the bottom of the document for
historical purposes, but are not necessarily indicative of the
features shipped. The release notes for each shipped version are the
definitive list of notable changes in each release.

## Development major version:  Swift 3.0

Expected release date: Fall 2016

This release is focused on several key areas:

* **Stable ABI**: Stabilize the binary interface (ABI) to gaurantee a level of binary compatibility moving forward. This involves finalizing runtime data structures, name mangling, calling conventions, and so on, as well as finalizing some of the details of the language itself that have an impact on its ABI. Successful ABI stabilization means that applications and libraries compiled with future versions of Swift can interact at a binary level with applications and libraries compiled with Swift 3.0, even if the source language changes.
* **Resilience**: Solve the general problem of [fragile binary interface](https://en.wikipedia.org/wiki/Fragile_binary_interface_problem), which currently requires that an application be recompiled if any of the libraries it depends on changes. For example, adding a new stored property or overridable method to a class should not require all subclasses of that class to be recompiled. There are several broad concerns for resilience:
  * *What changes are resilient?*: Define the kinds of changes that can be made to a library without breaking clients of that library. Source-compatible changes to libraries are good candidates for resilient changes, but such decisions also consider the effects on the implementation.
  * *How is a resilient library implemented?*: What runtime representations are necessary to allow applications to continue to work after making resilient changes to a library? This dovetails with the stabilization of the ABI, because the stable ABI should be a resilient ABI.
  * *How do we maintain high performance?*: Resilient implementations often incur more execution overhead than non-resilient (or *fragile*) implementations, because resilient implementations need to leave some details unspecified until load time, such as the specific sizes of a class or offsets of a stored property.
* **Portability**: Make Swift available on other platforms and ensure that one can write portable Swift code that works properly on all of those platforms.
* **Type system cleanup and documentation**: Revisit and document the various subtyping and conversion rules in the type system, as well as their implementation in the compiler's type checker. The intent is to converge on a smaller, simpler type system that is more rigorously defined and more faithfully represented by the type checker.
* **Complete generics**: Generics are used pervasively in a number of Swift libraries, especially the standard library. However, there are a number of generics features the standard library requires to fully realize its vision, including recursive protocol constraints, the ability to make a constrained extension conform to a new protocol (i.e., an array of `Equatable` elements is `Equatable), and so on. Swift 3.0 should provide those generics features needed by the standard library.
* **Focusing the language**: Despite being a relatively young language, Swift's rapid development has meant that it has accumulated some language features and library APIs that don't fit will with the language as a whole. Swift 3 will remove or improve those features to provide better overall consistency for Swift.

For example, this allows 

## Development minor version:  Swift 2.5

Expected release date: Spring 2016

This release will focus on fixing bugs and improving performance.  It may also put some finishing touches on features introduced in Swift 2.0, and include some small additive features that don't break Swift code or fundamentally change the way Swift is used.

