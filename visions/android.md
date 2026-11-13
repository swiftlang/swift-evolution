# A Vision for Swift on Android

## Introduction

The establishment of a dedicated [Android workgroup](https://www.swift.org/android-workgroup/) within the Swift open-source project marked a major step towards making Android an officially-supported platform for Swift development. The workgroup aims to further integrate Swift into Android development, offering developers a robust, performant, and memory-safe language alternative for building Android applications.

Previously, using Swift for Android development involved relying on unofficial SDKs, custom toolchains, or other third-party solutions. The workgroup seeks to streamline this build process, providing consistent official tooling and improved integration with Android's native APIs and conventions. This should increase Swift's adoption in the broader mobile development space, allowing for greater code sharing between iOS and Android projects and reducing development costs for cross-platform applications.

While Kotlin remains the recommended language for Android development, Swift's expansion offers a compelling choice for developers seeking a modern language with strong performance and safety guarantees. Ongoing work will focus on making Swift a first-class citizen on Android, ensuring that Swift applications feel native and perform optimally on the platform.

## The Android platform

For those unfamiliar with Android's technical underpinnings, it uses a forked linux kernel optimized for mobile use, replacing the GNU libc with its own Bionic libc and dynamic linker. There is no libc++ available on-device for all apps to use, but the Android Native Development Kit (NDK) comes with a version of the LLVM libc++ that can be bundled with each app that needs it. Most apps are written in Java or Kotlin and run on the Android RunTime (ART), distributed as bytecode and either compiled to machine code when installed or Just-In-Time (JIT) when run.

C and C++ code are compiled Ahead-Of-Time (AOT) and packaged as native shared libraries- that's how Swift on Android is also distributed- which have to be accessed through the Java Native Interface (JNI), since most Android APIs are only made available through Java.

All four of the Android target architectures work well with Swift- 64-bit arm64-v8a and x86_64 and 32-bit armeabi-v7a and x86- and we will support [the new RISC-V riscv64 arch](https://github.com/google/android-riscv64#status) as it gets rolled out.

## Use Cases for Swift on Android

The potential applications of Swift on Android are diverse and extend beyond simply sharing code between iOS and Android:

*	Shared Business Logic - A prominent use case is sharing core business logic, algorithms, and data models across iOS and Android applications. This minimizes duplication and ensures consistency in application behavior.
*	Performance-Critical Modules - Swift's strong performance characteristics make it ideal for developing performance-sensitive components, such as image/audio processing, game engines, or other computationally-intensive tasks within an Android app, similar to using C or C++ via the NDK.
*	Cross-Platform Libraries and SDKs - Developers can leverage Swift to build libraries and SDKs that can be easily integrated into existing Android and iOS applications, providing a consistent API surface across platforms.

## Build tool integration

Integration with existing Android build systems and developer tools is essential in order to provide a usable experience for developers. Dependency management between Swift packages and Android-native dependencies within the existing Gradle build flow will be important. We are looking into providing a Gradle plugin that simplifies the process.

Improved debugging capabilities for Swift libraries on Android are a key focus. This involves enhancing integration with existing debugging tools and protocols. The aim is to make debugging Swift on Android work as well as debugging Swift on other officially supported platforms, including support for Swift-specific metadata and expression evaluation.

Integration of all these tools into various Android-capable IDEs and editors, such as Android Studio and VS Code - including syntax highlighting, code completion, refactoring, and project navigation- will need to be developed further.

## App packaging

Packaging Swift code and its runtime into Android application packages (APKs) is necessary in order to create a distributable application. Guidelines and tooling for correctly packaging compiled Swift binaries and necessary runtime libraries into the native `lib/<arch>` folder of an APK will be provided.

## Testing

Comprehensive testing is important for maintaining code quality on any platform, including running test code on Android emulators and devices. The standard Swift unit and integration testing frameworks, such as XCTest and Swift Testing, work well now, but we will iron out any remaining incompatibilities and establish more Continuous Integration (CI) jobs within the Swift project, such as including Android testing as part of pull request checks, to guarantee ongoing compatibility and stability.

## Bridging to Java and Kotlin

Interoperability between Swift and Android's primary languages- Java and Kotlin- is vital for integrating Swift into existing Android projects and accessing the rich Android SDK. Since JNI is the fundamental mechanism for communicating between native languages like Swift or C/C++ and Java/Kotlin, [automated bridging tools like swift-java](https://github.com/swiftlang/swift-java) should simplify the use of JNI, abstracting away much of its complexity.

Given Kotlin's prominence on Android, specific bridging mechanisms that handle Kotlin-exclusive features (e.g., suspending functions, specific Jetpack Compose integrations) would be highly beneficial. Recommendations for best practices in designing Swift APIs for optimal interoperability with Kotlin will be provided.

## NDK version support

Alignment with Android NDK versions is important for stability and access to platform features. We clearly define the Android NDK versions that the latest Swift release/snapshots on Android are compatible with, prioritizing support for Long Term Support (LTS) releases to provide a stable development environment.

## UI recommendations

There will not be a single official UI framework, instead we will acknowledge and support various approaches: the UI for Swift on Android applications will primarily rely on Android's native UI frameworks or existing cross-platform solutions. This means developers will likely choose from:

*	Jetpack Compose - Android's modern, declarative UI toolkit in Kotlin: Swift applications could interact with Compose through robust bridging layers.
*	Android Views (XML-based) - The traditional imperative UI
*	Third-Party Cross-Platform UI Frameworks - Such as Flutter, with Swift as the business logic language via [FlutterSwift](https://github.com/PADL/FlutterSwift), or potentially others that offer C/C++ interop, which Swift can pull in.
*	Bridging Solutions - Projects such as [Skip](https://github.com/skiptools) provide a declarative SwiftUI-like API surface atop Android's Jetpack Compose, offering a path to native shared cross-platform UI.

The goal is to ensure Swift works well with these existing UI approaches, allowing developers to select the most suitable option for their project while deploying Swift for the underlying logic.

## Non-goals

Defining what is not a goal is as important as defining what is:

*	Full SwiftUI/UIKit Port - To reiterate, a direct, full port of existing UI frameworks to Android will not be attempted. The official Swift on Android effort will focus on language and core library support and integrating with existing UI frameworks, not building our own cross-platform UI framework.
*	Compilation to JVM Bytecode - Direct compilation of Swift to JVM bytecode is not being contemplated. Swift's native AOT compilation model targets machine code, and employing the NDK allows for direct interaction with Android's native layer.
