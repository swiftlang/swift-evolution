# Swift Platform Support Tiers

* Policy: [POL-0001](0001-platform-support-tiers.md)
* Authors: [Platform Steering Group](https://forums.swift.org/g/platform-steering-group)
* Review Manager: TBD
* Status: **Request for Comments**
* Review: ([rfc](https://forums.swift.org/...))

## Introduction

The Swift programming language has evolved into a versatile and powerful tool
for developers across a wide range of platforms. As the ecosystem continues to
grow, it is essential to establish a clear and forward-looking policy for
platform support. This policy has two main goals:

1. To establish common terminology and definitions for platform support.

2. To document a process for platforms to become officially supported in Swift.

## Understanding Platforms in the Swift Ecosystem

The term "platform" carries multiple interpretations. For our purposes, a
platform represents the confluence of operating system, architecture, and
environment where Swift code executes. Each platform is identified using a
version-stripped LLVM `Triple`—a precise technical identifier that captures the
essential characteristics of a host environment (e.g.,
`x86_64-unknown-windows-msvc`).

## The Anatomy of a `Triple`

At its core, a `Triple` comprises 11 distinct elements arranged in a specific
pattern:

```
[architecture][sub-architecture][extensions][endian]-[vendor]-[kernel/OS][version]-[libc/environment][abi][version]-[object format]
```

This naming convention might initially appear complex, but it offers remarkable
precision. When a public entity isn't associated with a toolchain, the
placeholder `unknown` is used for the vendor field. Similarly, bare-metal
environments—those without an operating system—employ `none` as their OS/kernel
designation.

While many of these fields may be elided, for use in Swift, the vendor and OS
fields are always included, even if they are placeholder values.

Consider these illustrative examples:

- `armv7eb-unknown-linux-uclibceabihf-coff`: A Linux system running on ARMv7 in big-endian mode, with the µClibc library and PE/COFF object format.
- `aarch64-unknown-windows-msvc-macho`: Windows NT on the ARM64 architecture using the MSVC runtime with Mach-O object format.
- `riscv64gcv-apple-ios14-macabi`: An iOS 14 environment running on a RISC-V processor with specific ISA extensions.

This nomenclature creates a shared language for discussing platform capabilities
and constraints—an essential foundation for our support framework.

## Distributions within Platforms

A platform and distribution, while related, serve distinct roles in the Swift
ecosystem. A platform refers to the broader combination of Operating System,
architecture, and environment where Swift code executes and establishes the
foundational compatibility and functionality of Swift.

A distribution, on the other hand, represents a specific implementation or
variant within a platform. For example, while Linux as a platform is supported,
individual distributions such as Ubuntu, Fedora, or Amazon Linux require
additional work to ensure that Swift integrates seamlessly. This includes
addressing distribution-specific configurations, dependencies, and conventions.

Distributions are treated similarly to platforms in that they require a
designated owner. This owner is responsible for ensuring that Swift functions
properly on the distribution, adheres to the distribution's standards, and
remains a responsible citizen within that ecosystem. By assigning ownership, the
Swift community ensures that each distribution receives the attention and
stewardship necessary to maintain a high-quality experience for developers.

## Platform Stewardship

The health of each platform depends on active stewardship. Every platform in the
Swift ecosystem requires a designated owner who reviews platform-specific
changes and manages release activities. Platforms without active owners enter a
dormant state, reverting to exploratory status until new leadership emerges.

This ownership model ensures that platform support remains intentional rather
than accidental—each supported environment has an advocate invested in its
success.

The Platform Steering Group will regularly review the list of supported
platforms against the tier criteria below.  While the Platform Steering Group
reserves the right to update the list or the tier criteria at any time, it is
expected that most such changes will be aligned with the Swift release cycle.

## A Tiered Approach to Platform Support

Swift's platform support strategy employs three distinct tiers, each
representing a different level of maturity. The requirements for each tier build
upon those of the previous tier.

### Tier 1: "Supported" Platforms

These are Swift's most mature environments, where the language must consistently
build successfully and pass comprehensive test suites. Swift on these platforms
offers the strongest guarantees of stability and performance.

Platforms that are in Tier 1 should:

- [ ] Digitally sign their release artifacts.
- [ ] Include a Software Bill of Materials (SBOM).

- [ ] Include at a minimum the following Swift libraries:

    - [ ] Swift Standard Library
    - [ ] Swift Supplemental Libraries
    - [ ] Swift Core Libraries
    - [ ] Swift Testing Frameworks (if applicable)

     (See [the Swift Runtime Libraries
     document](https://github.com/swiftlang/swift/blob/main/Runtimes/Readme.md#layering)
     in [the Swift repository](https://github.com/swiftlang/swift) for the list of definitions.)

- [ ] Maintain a three-version window of support, including:

    - [ ] At least one stable release.
    - [ ] The next planned release.
    - [ ] The development branch (`main`).

- [ ] Have a clear, documented, story for debugging, to allow users to set up
      an environment where their products can be executed on a device or
      simulator and be debugged.

- [ ] Have testing in CI, including PR testing.

- [ ] Ship SDKs as regular release from [swift.org](https://swift.org)

- [ ] Ensure that instructions needed to get started on the platform
      are publicly available, ideally on or linked to from
      [swift.org](https://swift.org).

An important aspect of Tier 1 platforms is that maintenance of support
of these platforms is the collective responsibility of the Swift
project as a whole, rather than falling entirely on the platform
owner.  This means:

- Contributions should not be accepted if they break a Tier 1 platform.

- If a Tier 1 platform does break, whoever is responsible for the code
  that is breaking must work with the platform owner on some kind of
  resolution, which may mean backing out the relevant changes.

- New features should aim to function on all Tier 1
  platforms, subject to the availability of appropriate supporting
  functionality on each platform.

- There is a presumption that a release of Swift will be blocked if a
  Tier 1 platform is currently broken.  This is not a hard and fast
  rule, and can be overridden if it is in the interests of the Swift
  project as a whole.

### Tier 1: "Supported" Toolchain Hosts

Each toolchain host is an expensive addition to the testing matrix.
In addition to the requirements above, a toolchain host platform should:

- [ ] Have CI coverage for the toolchain, including PR testing.

- [ ] Offer toolchain distributions from
      [swift.org](https://swift.org) as an official source, though
      other distributions may also be available.

- [ ] Include the following toolchain components:

    - [ ] Swift compiler (`swiftc`).
    - [ ] C/C++ compiler (`clang`, `clang++`).
    - [ ] Assembler (LLVM integrated assembler, built into `clang`).
    - [ ] Linker (_typically_ `lld`).
    - [ ] Debugger (`lldb`).
    - [ ] Swift Package Manager (SwiftPM).
    - [ ] Language Server (`sourcekit-lsp`).
    - [ ] Debug Adapter (`lldb-dap`).

- [ ] Code-sign individual tools as appropriate for the platform.

Note that the bar for accepting a platform as a toolchain host is somewhat
higher than the bar for accepting a non-toolchain-host platform.

### Tier 2: "Experimental" Platforms

Experimental platforms occupy the middle ground—they must maintain the ability
to build but may experience occasional test failures.  These platforms
represent Swift's expanding frontier.

Platforms in this tier should:

- [ ] Ensure that dependencies beyond the platform SDK can build from source.

- [ ] Provide provenance information to validate the software supply chain.

- [ ] Include at a minimum the following Swift libraries:

    - [ ] Swift Standard Library
    - [ ] Swift Supplemental Libraries
    - [ ] Swift Core Libraries
    - [ ] Swift Testing Frameworks (if applicable)

     (See [the Swift Runtime Libraries
     document](https://github.com/swiftlang/swift/blob/main/Runtimes/Readme.md#layering)
     in [the Swift repository](https://github.com/swiftlang/swift) for the list of definitions.)

- [ ] Maintain at least a two-version window of support, including

    - [ ] The next planned release.
    - [ ] The development branch (`main`).

Unlike Tier 1, the Swift project does not assume collective
responsibility for experimental platforms.  Platform owners should
work with individual contributors to keep their platform in a
buildable state.

### Tier 3: "Exploratory" Platforms

At the boundary of Swift's reach are exploratory platforms.
Exploratory status offers an entry point for platforms taking their
first steps into the Swift ecosystem.

Platforms in this tier should:

- [ ] Support reproducible builds without requiring external
      patches, though there is no requirement that these build completely
      or consistently.

- [ ] Maintain support in the current development branch (`main`).

The Swift Project does not assume collective responsibility for
exploratory platforms.  Platform owners are responsible for keeping
their platform in a buildable state.

## Platform Inclusion Process and Promotion

Adding platform support begins with a formal request to the Platform Steering
Group, accompanied by a platform owner nomination. This structured yet
accessible approach balances Swift's need for stability with its aspiration for
growth.

The request should include:

- [ ] The preferred name of the platform.

- [ ] The name and contact details of the platform owner.

- [ ] The support tier into which the platform should be placed.

- [ ] Instructions to build Swift for the platform, assuming someone
      is starting from scratch, including any requirements for the
      build system.

- [ ] A list of tier requirements that are currently _not_ met by the
      platform, including an explanation as to _why_ they are not met
      and what the proposal is to meet them, if any.

- [ ] Whether there has been any discussion about provisioning of CI
      resources, and if so a copy of or link to that discussion.  This
      is particularly relevant for a Tier 1 platform request.

Note that it is _not_ the case that a platform _must_ meet every
requirement of the requested tier in order to be placed into that
tier.  The Platform Steering Group will consider each case on its
merits, and will make a decision based on the information at hand as
well as the overall benefit to the Swift Project.  It should be
emphasized that the Platform Steering Group reserves the right to
consider factors other than those listed here when making decisions
about official platform support.

The same process should be used to request a promotion to a higher
tier.

## Existing Platforms and Demotion

The following existing platforms are in Tier 1 regardless of any
text in this document:

- All Apple platforms (macOS, iOS and so on).
- Linux
- Windows

The Platform Steering Group reserves the right to demote any
platform to a lower tier, but regards demotion as a last resort
and will by preference work with platform owners to maintain
support appropriate for their platform's existing tier.

Note that if your platform is one of the above special cases, and
there is some requirement in this document that is not being met, it
is expected that either there is a very good reason for the
requirement not being met, or that there is some plan to meet it in
future.
