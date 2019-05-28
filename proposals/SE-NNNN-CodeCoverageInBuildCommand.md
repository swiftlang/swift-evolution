# Package Manager Code Coverage

* Proposal: [SE-NNNN](NNNN-CodeCoverageInBuildCommand.md)
* Authors: [Cavelle Benjamin](https://github.com/thecb4)
* Review Manager: TBD
* Status: **Awaiting implementation**

*During the review process, add the following fields as needed:*

* Implementation: [apple/swift-package-manager#NNNNN](https://github.com/apple/swift-package-manager/pull/NNNNN)
* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

## Introduction

Ideally I would like to run 
```
swift build --enable-code-coverage
```

Currently generating code coverage is tied to running tests
```
swift test --enable-code-coverage
```

Swift-evolution thread: [Discussion thread topic for that
proposal](https://forums.swift.org/)

## Motivation

I would like to move enabling code coverage to the build phase as there are times where I would like to skip rebuilding of the source. 
```
swift test --skip-build
```

```
swift test --skip-build --enable-code-coverage // This fails
```

This would help with my continuous integration process.


## Proposed solution

There is no elaborate solution. The ask would be to move the option to the build command.
```
swift build --enable-code-coverage
```


## Detailed design

I would expect there to be limitations on combinations of build options with code coverage enabled. At this time, however, I cannot think of any.

## Security

This does not impact security, saftey, or privacy.


## Impact on exisiting packages

This should not impact the behavior of existing packages as this is an option for a command.

## Alternatives considered

The alternative is to leave the option where it is and not change the current behavior.
