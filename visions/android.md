# A Vision for Swift on Android

## Introduction

The establishment of a dedicated [Android workgroup](https://www.swift.org/android-workgroup/) within the Swift open-source project signifies a major step towards making Android an officially supported platform for Swift development. This initiative aims to integrate Swift into the Android development landscape, offering developers a robust, performant, and memory-safe language alternative for building Android applications.

Historically, using Swift for Android development involved relying on unofficial forks, custom toolchains, or third-party solutions. The new official effort seeks to streamline this process, providing consistent tooling and improved integration with Android's native APIs and conventions. This move is poised to increase Swift's adoption in the broader mobile development space, allowing for greater code sharing between iOS and Android projects and potentially reducing development costs for cross-platform applications.

While Kotlin remains the recommended language for Android development, Swift's expansion offers a compelling choice for developers seeking a modern language with strong performance and safety guarantees. The ongoing work will focus on making Swift a first-class citizen on Android, ensuring that Swift applications feel native and perform optimally on the platform.

## Use Cases for Swift on Android

The potential applications of Swift on Android are diverse and extend beyond simply sharing code between iOS and Android.

*	Shared Business Logic: A prominent use case is sharing core business logic, algorithms, and data models across iOS and Android applications. This minimizes duplication of effort and ensures consistency in application behavior.
*	Performance-Critical Modules: Swift's strong performance characteristics make it ideal for developing performance-sensitive components, such as image processing, audio manipulation, or computationally intensive tasks within an Android app, akin to using C++ via the NDK.
*	Cross-Platform Libraries and SDKs: Developers can leverage Swift to build libraries and SDKs that can be easily integrated into existing Android (and iOS) applications, providing a consistent API surface across platforms.
*	Full Native Applications: While requiring significant effort for UI, it's conceivable to build entire Android applications in Swift, using platform-native UI frameworks for each respective OS.

## Build tool integration

Integration with the existing Android build systems is essential in order to provide a friendly experience for developers.

*	Gradle Plugin: A strong recommendation is to provide a well-maintained Gradle plugin that simplifies the process of compiling Swift code for Android, managing dependencies, and integrating Swift libraries into Android projects. This should handle cross-compilation for various Android architectures.
*	Dependency Management: Support for integrating Swift packages and other native dependencies within the Gradle build flow.
IDE and debugging support
Robust IDE and debugging support are critical for a productive developer experience.
*	IDE Integration: Swift build integration with various Android-capable IDEs such as Android Studio and VSCode - this includes syntax highlighting, code completion, refactoring, and project navigation.
*	Debugging: Improved debugging capabilities for Swift code on Android are a key focus. This involves enhancing integration with existing debugging tools and protocols. The aim is to make debugging Swift on Android as good as debugging Swift on other officially supported platforms, including support for Swift-specific metadata and expression evaluation.

## App packaging support

Packaging Swift code and its runtime into Android application packages (APKs) is necessary in order to create a distributable application.

*	APK Inclusion: Guidelines and tooling for correctly packaging compiled Swift binaries and necessary runtime libraries into the `lib/<arch>` folder of an APK.
*	Android App Bundles (AABs): Support for generating optimized AABs that allow for efficient delivery of architecture-specific Swift code to end-user devices via the Play Store.

## Testing support

Comprehensive testing is important for maintaining code quality on any platform. Swift on Android should facilitate running test code on Android emulators and devices.

*	Unit and Integration Testing: Ensuring that the standard Swift testing frameworks (e.g., XCTest, Swift Testing) can be used effectively for unit and integration testing of Swift code on Android.
*	Continuous Integration (CI): Establishing CI jobs within the Swift project that include Android testing as part of pull request checks, guaranteeing ongoing compatibility and stability.
Bridging support for Java and Kotlin
Interoperability between Swift and Android's primary languages (Java/Kotlin) is vital for integrating Swift into existing Android projects and accessing the rich Android SDK.
*	Java Native Interface (JNI): JNI is the fundamental mechanism for communication between native (Swift) and Java/Kotlin code on Android. Bridging tools should simplify the use of JNI, abstracting away much of its complexity.
*	Automatic Binding Generation: Tools that can automatically generate Swift bindings from Java/Kotlin APIs and vice versa will significantly improve developer experience. This should cover common data types and method signatures.
*	Kotlin-specific Bridging: Given Kotlin's prominence on Android, specific bridging mechanisms that handle Kotlin-exclusive features (e.g., suspending functions, specific Jetpack Compose integrations) would be highly beneficial. Recommendations for best practices in designing Swift APIs for optimal interoperability with Kotlin will be provided.

## Supported target architectures

Swift on Android should target all major Android architectures.

*	ARM (armeabi-v7a, arm64-v8a): These are the most common architectures for Android devices and will be primary targets.
*	x86/x86_64: Support for Android emulators and certain desktop-class Android devices.
*	RISC-V: Once the RISC-V architecture matures and becomes a more prevalent target for Android devices, official support for riscv64 should be added, enabling Swift applications to run on this open-standard instruction set architecture.

## NDK version support

Alignment with Android NDK versions is important for stability and access to platform features.

*	Specific NDK Versions: Clearly define the supported Android NDK versions that Swift on Android targets, ensuring compatibility with the native toolchains and libraries provided by Google.
*	LTS Releases: Prioritize support for Long Term Support (LTS) NDK releases to provide a stable development environment.

## UI recommendations

The official Swift on Android initiative will not provide a single UI framework, but will acknowledge and support various approaches. 
The UI for Swift on Android applications will primarily rely on Android's native UI frameworks or existing cross-platform solutions. This means developers will likely choose from:

*	Jetpack Compose: Android's modern, declarative UI toolkit in Kotlin. Swift applications could interact with Compose through robust bridging layers.
*	Android Views (XML-based): The traditional imperative UI system.
*	Third-Party Cross-Platform UI Frameworks: Such as Flutter (with Swift as the business logic language via FlutterSwift) or potentially others that offer C/C++ interop, which Swift can leverage.
*	Bridging Solutions: Tools like Skip.tools demonstrate how SwiftUI-like code can be transformed and rendered using Jetpack Compose on Android, offering a path to "native-feeling" cross-platform UI.

The vision is to ensure Swift works well with these existing UI approaches, allowing developers to select the most suitable option for their project while leveraging Swift for the underlying logic. Documentation and best practices will guide developers in integrating Swift with their chosen UI framework.

## Non-goals

Defining what is not a goal is as important as defining what is.

*	Full SwiftUI/UIKit Port: A direct, full port of existing UI frameworks to Android is not a goal. While projects like Skip.tools demonstrate bridging SwiftUI to Jetpack Compose, the official Swift on Android effort will focus on language and core library support, not building our own cross-platform UI frameworks.
*	Compilation to JVM Bytecode: Direct compilation of Swift to JVM bytecode is not an immediate goal. Swift's current compilation model targets native machine code, and leveraging the NDK allows for direct interaction with Android's native layer. While interesting for future exploration, the current focus is on a performant, native execution model.
