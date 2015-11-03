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

This release will provide the baseline for ongoing binary
compatibility with a stable ABI for future releases to build upon.

* **Stable ABI**: stabilize the binary interface (ABI) to gaurantee a level of binary compatibility moving forward. This involves finalizing runtime data structures, name mangling, calling conventions, and so on.
* **Resilience**: allow libraries to change their implementations without forcing all clients of those libraries to be recompiled.

## Development minor version:  Swift 2.5

Expected release date: Spring 2016

This release will focus on fixing bugs and improving performance.  It may also put some finishing touches on features introduced in Swift 2.0, and include some small additive features that 

