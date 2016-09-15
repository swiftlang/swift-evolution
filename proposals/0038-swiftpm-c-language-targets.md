# Package Manager C Language Target Support

* Proposal: [SE-0038](0038-swiftpm-c-language-targets.md)
* Author: [Daniel Dunbar](https://github.com/ddunbar)
* Review Manager: [Rick Ballard](https://github.com/rballard)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160222/011097.html)
* Bug: [SR-821](https://bugs.swift.org/browse/SR-821)


## Introduction

This is a proposal for adding initial package manager support for the C, C++,
Objective-C, and Objective-C++ languages (henceforth, simply referred to as "C"
languages). This proposal is limited in scope to only supporting targets
consisting entirely of C languages; there is no provision for supporting targets
which include both C and Swift sources.

[Swift Evolution Review Thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160215/010470.html)

## Motivation

Swift has easy interoperability with C based languages through the use of the
Clang modules system. We would like Swift packages to be able to include C
targets which can be exposed to Swift directly as part of a single package.

This gives developers a simple mechanism for "falling back" to C when they need
to access APIs which are inadequately or poorly bridged to Swift, or when they
need to implement behavior which is better done in low-level C than Swift.

## Proposed solution

Our proposed solution extends the convention based system to allow targets
composed only of C sources. The conventions will be amended as follows:

1. Any existing directory which defines a target will be allowed to contain a
   set of C sources, recognized by file extension. If a target contains any C
   sources, then all source code files must be C sources.

   Support for Objective-C and Objective-C++ source file extensions will be
   included, although those will be inherently less portable.

2. C targets *may* have a special subdirectory named `Includes` or `include`
   (the include directory). Only one such name may be used.

   The headers in this directory are presumed to be the "exported" interface of
   the C target, and will be made available for use in other targets.

   The names `Includes` and `include` are somewhat unfortunate because they do
   not clearly communicate that these folders define public API. However, this
   is an established convention for organizing C language header files, and
   there does not seem to be a better alternative.

3. If the include directory contains a header whose name matches that of the
   target, then that header will be treated as an "umbrella header" for the
   purposes of module map construction.

4. If the include directory includes any file named "module.modulemap", then
   those will be presumed to define the modules for the target, and no module
   maps will be synthesized.

5. As with Swift targets, we will use the presence of a source file named
   `main.c` (or `main.cpp`, etc.) to indicate an executable versus a library.

The following example layout would define a package containing a C library and a
Swift target:

    example/src/foo/include/foo/foo.h
    example/src/foo/foo.c
    example/src/foo/util.h
    example/src/bar/bar.swift

In this example, the `util.h` would be something internal to the implementation
of the `foo` target, while `include/foo/foo.h` would be the exported API to the
`foo` library.

The package manager will naturally gain support for building these targets:

1. The package manager will (a) construct a synthesized module map including all
   of the exported API headers, for use in Swift, and (b) will provide a header
   search path to this directory to any targets which transitively depend on
   this one.

   Module maps will only be synthesized for targets which either have a
   completely flat header layout (e.g., ``src/foo/include/*.h``) or a single
   subdirectory (e.g., ``src/foo/include/foo/**.h``). Any other structure
   requires the library author to provide explicit module maps. We may revisit
   this as we gain practical experience with it.

2. Most packages are encouraged to include the package or target name as a
   subfolder of the include directory, to clarify use (e.g.,
   ``src/foo/include/foo/``). However, this is not required and it may be useful
   for legacy projects whose headers have traditionally been installed directly
   into `/usr/include` to not use this convention. This allows client code of
   those projects to be source compatible with versions which use the installed
   library.

3. We expect C language targets to integrate with the other existing package
   manager features. For example, C language targets should be testable using
   the testing features (although such tests would initially need to be written
   in Swift until such time as a C language testing framework was usable by the
   package manager).

There are several obvious features related to C language support which *are not*
addressed with this proposal:
   
1. We anticipate the need to declare that only particular targets should have
   their API exported to downstream **packages** (for example, the package above
   might want to export the `bar` target to clients, and keep the C target as an
   implementation detail).

2. No provision is made in this proposal for controlling compiler arguments. We
   will support the existing debug and release configurations using a fixed set
   of compiler flags. We expect future proposals to accommodate the need to
   modify those flags.

3. We intend for the feature to be built in such a way as to support any
   standard compliant C compiler, but our emphasis will largely be on supporting
   the use of Clang as that compiler (and of course our modules support will
   require Clang).

4. We believe there *may* be a need for targets to define their own module
   map. If needed, we would expect this to go into the ``include`` directory as
   ``module.modulemap``. However, we intend to defer implementation of this
   support until after the initial feature is implemented and the use cases
   become clear.

## Detailed design

The package manager will undertake the following additional behaviors:

1. The project model will be extended to discover C language targets and
   diagnose issues (e.g., mixed C and Swift source files).

2. The build system will be extended to compile and link each C language
   target. We will make use of ``llbuild``'s existing support for compiling C
   source code and gather GCC-compatible compiler style header dependency
   information for incremental rebuilds.

3. When building a target, the package manager will automatically add an
   additional header search path argument to the include directory for each C
   language target in the transitive closure of the dependencies for the target
   being built.

   We should use ``-iquote`` as the header search argument for targets which are
   within the current package, and ``-I`` for targets which come from package
   dependencies. This allows projects to use ``#include "foo/foo.h"`` versus
   ``#include <foo/foo.h>`` syntax appropriately to distinguish between the
   inclusion of headers which are or are not within the package.

4. We will synthesize module map files for each C language target with
   includes. Module maps will be constructed by explicitly enumerating all the
   headers in the include directory. To ensure deterministic behavior this will
   be done in lexicographic order, but the documentation will convey to users
   that each include header describing API is expected to be able to be included
   "standalone", that is, in any order.

5. When building Swift targets, we will explicitly pass the synthesized module
   map for each C language target in the dependency closure to Clang (using the
   ``-fmodule-map-file=<PATH>`` argument). This will allow the Swift Clang
   importer to find those modules without needing to find them via the header
   search mechanism.

We explicitly have designed this support in such a way that it will be possible
to support any GCC-compatible compiler for building the C target itself, not
just Clang.

## Impact on existing packages

There is no serious impact on existing packages, as this was previously
unsupported. We will begin trying to build C family sources in existing
packages, but this is likely to be desirable.

It is worth considering the impact on existing C language projects which do not
follow the conventions above.

* Most projects will not conform to these conventions. However, this is expected
  of any "simple" convention; we don't think that there is any other
  straightforward convention that would allow a significant percentage of
  existing C language projects to "just work".

  We do anticipate allowing certain overrides to be present in the manifest file
  describing a C target, to allow some projects to work with the package manager
  with only the addition of a correct `Package.swift` file. We will determine
  the exact overrides allowed once we are able to test options against existing
  C projects.

  The package manager already provides support for "system module" packages
  which is explicitly designed to support existing projects. The C language
  target support described in this proposal is targeted at new C code which is
  written in support of Swift projects, and believe that adopting a clean,
  simple convention is the best approach for supporting that goal.

* Existing source code *using* existing projects (e.g., a source file using
  `libpng`) may be able to use well formed packages without modification. This
  is viewed as a significant advantage, as it will potentially help upstream
  projects ingest proper package manager support into their main tree.

## Risk of non-modular headers

As part of this proposal, we will be synthesizing module maps for C language
targets, for use in Swift via the Clang AST importer.

One risk with this proposal is when multiple C language targets are imported
into a Swift module and those targets reference common C headers which have no
defined module maps (i.e., they are "non-modular headers"). This situation can
occur frequently on Linux, where the system does not typically have module maps
for common headers, but can also occur on OS X if targets reference third-party
headers not part of the package ecosystem.

The current compiler behavior when this occurs is hard for users to
understand. The model the compiler *expects* is that all content is
modular. However, when this model is broken, and two modules contain duplicate
content, these issues (a) sometimes behave correctly, due to the subtleties of
the module implementation, and (b) are not diagnosed by the compiler. This can
lead to confusing failures or expose us to unintended package breaking changes
in the future if the compiler becomes more strict.

Ultimately, the anticipated solution to these problem is to continue work to
provide more module maps for all content used in Swift. Incorporation of this
proposal may make that work a higher priority, and may expose additional issues
which we need to tackle in the compiler implementation.

## Alternatives considered

### Avoid C language support

We could avoid supporting C language targets directly, and rely on external
build systems and features to integrate them into Swift packages. We may wish to
add such features independently from this proposal, but we think it is
worthwhile to have some native support for C targets. This will make it easy to
integrate small amounts of C code into what are otherwise Swift projects, and is
in line with a long term direction of making the Swift package manager useful
for non-Swift projects.

### Restrictions on C language target header layout

We considered requiring targets follow the naming convention that each
``include`` directory must have a subdirectory matching the name of the
target. This has the advantage that all clients of that target always include
its headers using the syntax ``#include <foo/header.h>``.

However, it reduces the usability of packages for traditional C libraries which
do not install their headers in this format. It also reduces the ability of the
project to impose additional organization on their own headers. For example,
LLVM has a convention of laying out top-level headers into both ``llvm`` and
``llvm-c`` (for the C++ vs C API).

Since we did not have other features or areas of development where we felt it
was important to restrict the layout of the headers, we felt it was best to
avoid imposing unnecessary restrictions, and instead simply treat it as a
recommendation.
