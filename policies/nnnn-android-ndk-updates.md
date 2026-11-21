# Android NDK Update Policy

* Policy: [SP-NNNN](NNNN-android-ndk-updates.md)
* Authors: [Platform Steering Group](https://forums.swift.org/g/platform-steering-group)
* Review Manager: TBD
* Status: **Request for Comments**
* Review: ([rfc](https://forums.swift.org/...))

## Introduction

The Android NDK is distributed separately from the Swift toolchain, but
because some of the components used by the Swift runtime are not ABI stable,
the runtime distributed as part of the toolchain must exactly match the
Android NDK version against which the toolchain was built.

Note that the ABI instability we are talking about here does not affect the
deployment of built applications; it is just that a particular build of the
Swift runtime _requires_ a particular build of the Android NDK.  Attempting
to use the wrong version may cause link errors or even runtime crashes.

This means that it is important for us to know which Android NDK corresponds
to which Swift build, which, combined with the fact that Android NDK releases
take place whenever the Android NDK developers decide to do one, makes it
desirable for us to have a policy about when we will adopt a new Android NDK
version.

An additional consideration here is that some Android NDK versions are
designated Long Term Support (LTS) releases.  Given the likely lifecycle of
a Swift release, we would prefer to use NDK LTS releases where possible.

## Adopting a new NDK

A Swift release is identified by a version number in the form
*major*.*minor*.*bugfix*.

Swift will adopt the latest available LTS release of the NDK _on the date
the release branch is cut_ for every change of the *major* or *minor*
version numbers.

The NDK version will remain the same for every Swift release with the same
`<major>.<minor>` pair.

## Example

For instance, imagine we are going to release Swift 9.3.0, and, at the
point where the 9.3.0 branch is cut, the Android NDK is at version 65.
This will mean, unless there is a good reason to avoid doing so, that
Swift 9.3.0 will build against and will require NDK version 65, and that
requirement will remain the same for 9.3.1, 9.3.2 and so on.

## Deviations from this policy

If there is a reason to deviate from this policy, a representation should
be made to the Platform Steering Group, explaining why the NDK version
should not follow the above rules.

The Platform Steering Group may reject such a representation or ask for more
information as required to come to a decision.

If the Platform Steering Group agrees with the representation put forward
to it, the Group will then co-ordinate with others as required to ensure
that the release uses an appropriately selected NDK version.
