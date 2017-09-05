# SwiftPM System Module Search Paths

* Proposal: [SE-0063](0063-swiftpm-system-module-search-paths.md)
* Author: [Max Howell](https://github.com/mxcl)
* Review Manager: [Anders Bertelrud](https://github.com/abertelrud)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-April/000103.html)
* Implementation: [apple/swift-package-manager#257](https://github.com/apple/swift-package-manager/pull/257)

## Introduction

Swift is able to `import` C libraries in the same manner as Swift libraries.

For this to occur the library must be represented by a clang module-map file.

The current system for using these module-map files with SwiftPM works, but with
a number of caveats that must be addressed.


[swift-evolution thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160321/013201.html)


## Terminology

* **SwiftPM Source Package**: A package consumed by SwiftPM that comes with sources that SwiftPM builds into modules
* **SwiftPM System Package**: A package consumed by SwiftPM that refers to a modular system library not installed by SwiftPM
* **System Package**: A package provided by a system packager like, eg. `apt`, `pacman` or `brew`.
* **System Packager**: A system package manager like, eg. `apt`, `pacman` or `brew`.


## Motivation

The current implementation of SwiftPM System Packages have a number of problems:

 1. Install locations vary across platforms and `.modulemap` files require absolute paths
 2. `/usr/lib:/usr/local/lib` is not always a sufficient `-L` linker search path
 3. `/usr/include:/usr/local/include` is not always a sufficient `-I` C compiler search path
 4. Installing the system library is left up to the end-user to figure out

For example to import a module map representing the GTK library, the include search
path must be supplemented with `-I/usr/include/gtk` so that a number of includes in
the `gtk.h` header can be sourced for the complete modular definition of GTK.

For example to import a module map representing the GTK library a user must first have
a copy of GTK and its headers installed. On Debian based systems the install name for
this System Package is `libgtk-3-0-dev` which is not entirely intuitive.

For example, Homebrew and MacPorts on OS X install to prefixes other than `/usr`.
`.modulemap` files must specify headers with absolute paths. The standard we
encourage with modulemaps is for the headers to  be specified with an assumed
prefix of `/usr`, but you will not find eg. `jpeglib.h` at `/usr/include/jpeglib.h`
if it is installed with Homebrew or MacPorts.


## Proposed Solution

We propose that SwiftPM gains the ability to read `.pc` files written for the
cross-platform `pkg-config` tool. These files describe the missing search paths		
that SwiftPM requires. They also specify the install location of system libraries
and will allow SwiftPM to preprocess the modulemap changing the specified header 
prefixes.

We propose that `Package.swift` is supplemented with metadata that provides the
package-install-name for specific platforms.


## Detailed Design

### Solving Path/Flags Issues

A system library should provide a pkg-config file (`.pc`) which describes:

 1. Its install location
 2. Supplementary flags that should be used when compiling against this library
 3. Supplementary flags that should be used when linking against this library

If SwiftPM read the `.pc` file that comes with System Packages, this solves problems 1 through 3.

Of the tickets we currently have open describing issues using SwiftPM System Packages,
reading the `.pc` file would fix all of them.

It is a convention to name the `.pc` file after the library link-name, so we can determine
which `.pc` file to ask `pkg-config` for by parsing the `.modulemap` file in the SwiftPM Package.
However sometimes this is not true, (eg. GTK-3 on Ubuntu), so we will allow an override in
the `Package.swift` file, for example:

```swift
let package = Package(
    name: "CFoo",
    pkgConfigName: "gtk-3"
)
```

Thus we would search for a filename: `gtk-3.pc`.

We don’t want to introduce a new dependency (on `pkg-config`) to Swift, so we will
implement the reading of `.pc` files according to the pkg-config specification, including:

 1. Obeying the correct search .pc file search paths
 2. Following overrides due to any `PKG_CONFIG_PATH` environment variable


### Hinting At System-Package Install-Names

`Package.swift` would be supplemented like so:

```swift
let package = Package(
    name: "CFoo",
    pkgConfigName: "foo",
    providers: [
        .Brew(installName: "foo"),
        .Apt(installName: "libfoo-dev"),
    ],
)
```

Thus, in the event of build failure for modules that depend on this
SwiftPM Package we would output additional help to the user:

```
error: failed to build module `bar'
note: you may need to install `foo' using your system-packager:

    apt-get install libfoo-dev
```

Since the syntax to provide this information uses an explicit enum we can
add code for each enum to detect which system packagers should be 
recommended. The community will need to write the code for their own
platforms. It also means that if a specific system-packager requires additional
parameters, they can be added on a per enum basis.

#### Install-names are not standard

`apt` is used across multiple distirbutions and the install-names for
tools vary. Even for the same distribution install-names may vary
across releases (eg. from Ubuntu 15.04 to Ubuntu 15.10) or even on
occasion at finer granularity.

We will not add explicit handling for this, but one can imagine the
enums for different system packagers could be supplemented in a backwards
compatible way to provide specific handling as real-world uses emerge, eg:

```swift
case Apt(installName: String)

// …could be adapted to:

struct Debian: Linux {}
struct Ubuntu: Debian {
    enum Variant {
        case Gubuntu
        case Kubuntu(Version)
    }
    enum Version {
        case v1510
        case v1504
    }
}
case Apt(installName: String, distribution: Linux? = nil)
```

## Impact on Existing Code

There will be no impact on existing code as this feature simply improves
an existing feature making new code possible.


## Alternatives Considered

A clear alternative is allowing additional flags to be specified in a SwiftPM System Package’s `Package.swift`.

However since these paths and flags will vary by platform this would because a large matrix that is quite a maintenance burden. Really this information is recorded already, in the System Package itself, and in fact almost all System Packages nowadays provide it in a `.pc` `pkg-config` file.

Also we do not want to allow arbitrary flags to be specified in `Package.swift`, this allows packages too much power
to break a large dependency graph with bad compiles. The only entity that understands the whole graph and can manage
the build without breakage is SwiftPM, and allowing packages themselves to add arbitrary flags prevents SwiftPM from
being able to understand and control the build ensuring reliability and preventing “Dependency Hell”.


## Unsolved Problems

Some (usually more legacy) system libraries do not provide `.pc` files instead they may provide
a tool named eg. `foo-config` that can be queried for compile and link flags. We do not yet
support these tools, and would prefer to take a wait and see approach to determine how
important supporting them may be.

Some libraries on OS X do not come with `.pc` files. Again we'd like to see which libraries
are affected before potentially offering a solution here.


## Future Directions

The build system could be made more reliable by having the specific system packager provide the information that this
proposal garners from `pkg-config`. For example, Homebrew installs everything into independent directories, using these
directories instead of more general POSIX search paths means there is no danger of edge-case search path collisions and the wrong libraries being picked up.

If this was done `pkg-config` could become just one option for providing this data, and be used only as a fallback.

---

We do not wish to provide a flag to automatically install dependencies via the
system packager. We feel this opens us up to security implications beyond the
scope of this tool.

Instead we can provide JSON output that can be parsed and executed by some
other tooling developed outside of Apple.
