# Swift `run` Command

* Proposal: [SE-0179](0179-swift-run-command.md)
* Authors: [David Hart](http://github.com/hartbit/)
* Review Manager: [Daniel Dunbar](https://github.com/ddunbar)
* Status: **Active review (May 15...24)**

## Introduction

The proposal introduces a new `swift run` command to build and run an executable defined in the current package.

## Motivation

It is common to want to build and run an executable during development. For now, one must first build it and then execute it from the build folder:

```bash
$ swift build
$ .build/debug/myexecutable
```
  
In Swift 4, the Swift Package Manager will build to a different path, containing a platform sub-folder (`.build/macosx-x86_64/debug` for mac and `.build/linux-x86_64/debug` for linux), making it more cumbersome to run the executable from the command line.
  
To improve the development workflow, the proposal suggests introducing a new first-level `swift run` command that will build if necessary and then run an executable defined in the `Package.swift` manifest, replacing the above steps into just one.

## Proposed solution

The swift `run` command would be defined as:

```bash
$ swift run --help
OVERVIEW: Build and run executable

USAGE: swift run [options] [executable] [--] [arguments]

OPTIONS:
  --build-path            Specify build/cache directory [default: ./.build]
  --chdir, -C             Change working directory before any other operation
  --in-dir, -I            Change working directory before running the executable
  --color                 Specify color mode (auto|always|never) [default: auto]
  --configuration, -c     Build with configuration (debug|release) [default: debug]
  --enable-prefetching    Enable prefetching in resolver
  --skip-build            Skip building the executable product
  --verbose, -v           Increase verbosity of informational output
  -Xcc                    Pass flag through to all C compiler invocations
  -Xlinker                Pass flag through to all linker invocations
  -Xswiftc                Pass flag through to all Swift compiler invocations
  --help                  Display available options
```

If needed, the command will build the product before running it. As a result, it can be passed any options `swift build` accepts. As for `swift test`, it also accepts an extra `--skip-build` option to skip the build phase. A new `--in-dir` option is also introduced to run the executable from another directory.

After the options, the command optionally takes the name of an executable product defined in the `Package.swift` manifest and introduced in [SE-0146](0146-package-manager-product-definitions.md). If called without an executable and the manifest defines one and only one executable product, it will default to running that one. In any other case, the command fails.

All other arguments are passed as-is to the executable. When passing arguments to an implicit executable, the `--` argument should prefix the executable's arguments. For example:

```bash
$ swift run # .build/debug/exe
$ swift run exe # .build/debug/exe
$ swift run exe arg1 arg2 # .build/debug/exe arg1 arg2
$ swift run -- arg1 arg2 # .build/debug/exe arg1 arg2
$ swift run arg1 arg2 # error: could not find product executable named arg1
```

## Alternatives considered

One alternative to the Swift 4 change of build folder would be for the Swift Package Manager to create and update a symlink at `.build/debug` and `.build/release` that point to the latest build folder for that configuration. Although that should probably be done to retain backward-compatibility with tools that depended on the build location, it does not completely invalidate the usefulness of the `run` command.
