# HTML Coverage Report

* Proposal: [SE-0501](0501-swiftpm-html-coverage-report.md)
* Authors: [Sam Khouri](https://github.com/bkhouri)
* Review Manager: [David Cummings](https://github.com/daveyc123)
* Status: **Active Review (December 7, 2025 - January 30th, 2026)**
* Implementation: [swiftlang/swift-package-manager#9076](https://github.com/swiftlang/swift-package-manager/pull/9076)
* Review:
    * [Pitch](https://forums.swift.org/t/pitch-adding-html-coverage-support/82358)
    * [Review](https://forums.swift.org/t/se-0501-html-coverage-report/83601/1)


## Introduction

Currently, `swift test` supports generating a JSON coverage report, which is
great for ingesting into various systems. The JSON, however, is not very
"human-readable" during iterative development at-desk.

This proposal introduces an additional command line argument for `swift test` that
enables users to generate HTML coverage reports.


## Motivation

JSON coverage reports are well-suited for ingestion into external tools that post-process
coverage data. The ability for SwiftPM to generate HTML coverage reports would provide:
 - Reports that can be uploaded to CI systems for visual inspection
 - Immediate feedback for developers during development, enabling rapid assessment of test coverage adequacy for current changes

## Proposed solution

Currently, users requiring an HTML report must manually invoke the
`llvm-cov` binary with the appropriate command line arguments.

For example:
```sh
❯ swift test --enable-code-coverage

❯ swift test --show-codecov-path

❯ llvm-cov show \
  --project-title="HelloWorld" \
  --format="html" \
  --output-dir=".coverage" \
  --instr-profile=".build/arm64-apple-macosx/debug/codecov/default.profdata" \
  ".build/.../HelloWorldPackageTests.xctest/Contents/MacOS/HelloWorldPackageTests" \
  "Sources"
```

Since SwiftPM currently orchestrates JSON coverage data generation, this proposal introduces
a new command line argument `--coverage-format` for `swift test`. This option can
be specified multiple times to generate multiple coverage report types from a
single test execution.

While processing the coverage data, SwiftPM will loop through all the unique coverage
format options to generate the specified reports.

Unless otherwise specified, this proposal addresses only HTML coverage report
generation. The existing JSON coverage report functionality remains unchanged and
is outside the scope of this proposal.

## Detailed design

LLVM provides mature, well-documented tools for code coverage analysis that have been
extensively used in production environments. SwiftPM will leverage these existing
LLVM tools by constructing the appropriate command line arguments for the
`llvm-cov show` utility to generate HTML reports.

The proposed command line changes are as follows:

### Format Selection

The `swift test` command line will have an option named `--coverage-format`,
which accepts either `json` or `html`.  This option can be specified multiple
times on the command line, and a report will be generated for each format
specified.

The command line option will be similar to:

```sh
  --coverage-format <format>
                          Format of the code coverage output. Can be specified multiple times. (default: json)
        json              - Produces a JSON coverage report.
        html              - Produces an HTML report produced by llvm-cov.
```


### Coverage report configuration

The `llvm-cov show` utility provides extensive configurability options. To enable
HTML coverage report customization while avoiding command line argument proliferation
in `swift test`, a `-Xcov` command line option will be introduced. These
arguments will be passed through directly to the underlying `llvm-cov` executable in the
order specified.

The `-Xcov` arguments will be supported for all coverage formats.

Since multiple coverage report formats can be specified in a single `swift test` invocation,
a mechanism must be provided to specify which arguments apply to specific formats.

Consider the following example:

```
swift test --enable-coverage --coverage-format html --coverage-format json -Xcov --title -Xcov "My title"
```

<!-- The `--title` argument is not supported with the `llvm-cov` subcommand used to generate the JSON report. -->
The value of `-Xcov` follows this syntax:

```
-Xcov [<coverage-format>=]<value>
```

Some `llvm-cov` options accept `=` in their value.  In order to preserve this
functionality, the parsing of the `-Xcov` argument value will split on the
first `=` value to determine the `<coverage-format>`.

- `-Xcov html=--title`: argument `--title` is only sent to the HTML coverage report generation
- `-Xcov json=myarg`: argument `myarg` is only sent to the JSON coverage report
- `-Xcov commonArg`: the argument `commonArg` is sent to all coverage format reports
- `-Xcov notASupportedFormat=value`: the argument `notASupportedFormat=value` is sent
  to all coverage format reports as the `<coverage-format>` is an unsupported format
- `-Xcov html=--project-title="SwiftPM"`: the argument `--project-title="SwiftPM"` is only sent to
  the HTML coverage report generation.


### Coverage report location

By default, the HTML report will be created in a location under the scratch path
(i.e.: the build directory).  However, this can be overridden using the `-Xcov` argument.

Certain CI systems, such as [Jenkins](https://www.jenkins.io), restrict archiving
to content files and directories within designated sandbox locations. Since CI systems
typically maintain repository copies within these sandbox environments, this constraint
allows for HTML report uploading while maintaining security boundaries.

### Show coverage path

Prior to this proposal, `swift test --show-coverage-path` displays a single
absolute path to the JSON coverage report location.

Since `--coverage-format` can be specified multiple times, its output must be
changed to reflect the new functionality.

If the `--coverage-format` option is specified on the `swift test` command line
a single time (or is not specified at all), there is no change to the output.


When `--coverage-format` is specified multiple times, the output must reflect this capability.
The `--show-coverage-path` command line argument will be enhanced to accept an optional
parameter with a default value. The supported values are `json` or `text`, with the default
being `text` to preserve existing behavior.

The help text for the `--show-coverage-path` option with its default flag is:
```
  --show-coverage-path  [<mode>]
                          Print the path of the exported code coverage files.  The mode specifies how to
                          display the paths of the selected code coverage file formats. (default: text)
        json              - Display the output in JSON format.
        text              - Display the output as plain text.
```

A value of `json` will output a JSON object with the key representing the format,
and the value representing the output location of said format.

A value of `text` will omit the format in the output if a single `coverage-format`
is requested.  Otherwise, the output will be similar to

```sh
❯ swift test -c release --build-system swiftbuild --show-coverage-path --coverage-format html --coverage-format json
Building for debugging...
[5/5] Write swift-version-4B9677C1F510A69F.txt
Build complete! (0.37s)
Html: /swift-package-manager/.build/arm64-apple-macosx/Products/Release/codecov/Simple-html
Json: /swift-package-manager/.build/arm64-apple-macosx/Products/Release/codecov/Simple.json


❯ swift test -c release --build-system swiftbuild --show-coverage-path text --coverage-format html --coverage-format json
Building for debugging...
[5/5] Write swift-version-4B9677C1F510A69F.txt
Build complete! (0.37s)
Html: /swift-package-manager/.build/arm64-apple-macosx/Products/Release/codecov/Simple-html
Json: /swift-package-manager/.build/arm64-apple-macosx/Products/Release/codecov/Simple.json


❯ swift test -c release --build-system swiftbuild --show-coverage-path json --coverage-format html --coverage-format json
Building for debugging...
[1/1] Write swift-version-4B9677C1F510A69F.txt
Build of product 'swift-test' complete! (0.40s)
{
  "html" : "/Users/bkhouri/Documents/git/public/swiftlang/swift-package-manager/.build/arm64-apple-macosx/Products/Release/codecov/SwiftPM-html",
  "json" : "/Users/bkhouri/Documents/git/public/swiftlang/swift-package-manager/.build/arm64-apple-macosx/Products/Release/codecov/SwiftPM.json"
}
```

### Consolidate coverage options to use same argument style

Prior to this feature, there are 2 coverage option formats:

```
  --show-codecov-path, --show-code-coverage-path, --show-coverage-path
                          Print the path of the exported code coverage JSON
  --enable-code-coverage/--disable-code-coverage
                          Enable code coverage. (default:
                          --disable-code-coverage)
```

Currently, there are 3 ways to display the coverage path. This proposal recommends
consolidating all coverage command line options into a single, more comprehensive option:

```
  --show-coverage-path  [<mode>]
                          Print the path of the exported code coverage files.  The mode specifies how to
                          display the paths of the selected code coverage file formats. (default: text)
        json              - Display the output in JSON format.
        text              - Display the output as plain text.
  --enable-coverage/--disable-coverage
                          Enable code coverage. (default: --disable-coverage)
```

This change requires a graceful deprecation path for the previous options in favor of the new unified approach.

### Coverage command line options

The following represents the complete coverage command line options:

```
COVERAGE OPTIONS:
  --show-coverage-path [<mode>]
                          Print the path of the exported code coverage files. (values: json, text; default as flag: text)
  --show-codecov-path, --show-code-coverage-path
                          Print the path of the exported code coverage files. (deprecated. use `--show-coverage-path [<mode>]` instead)
  --enable-coverage/--disable-coverage
                          Enable code coverage. (default: --disable-coverage)
  --enable-code-coverage/--disable-code-coverage
                          Enable code coverage. (deprecated. use '--enable-coverage/--disable-coverage' instead)
  --coverage-format <format>
                          Format of the code coverage output. Can be specified multiple times. (default: json)
        json              - Produces a JSON coverage report.
        html              - Produces an HTML report produced by llvm-cov.
  -Xcov <Xcov>            Pass flag, with optional format specification, through to the underlying coverage report tool. Syntax: '[<coverage-format>=]<value>'. Can be specified multiple times.
```

In addition, for consistency, the `swift build` coverage option help will be modified to the following:

```
  --enable-coverage/--disable-coverage
                          Enable code coverage. (default: --disable-coverage)
  --enable-code-coverage/--disable-code-coverage
                          Enable code coverage. (deprecated. use '--enable-coverage/--disable-coverage' instead)
```

## Security

SwiftPM's use of `llvm-cov show` may inherit security implications from the underlying
utility, which falls outside the Swift organization's direct control.

The LLVM project maintains an [LLVM Security Response Group](https://llvm.org/docs/Security.html)
with established processes for addressing security vulnerabilities.

## Impact on existing packages

No impact is expected.

## Alternatives considered


<!-- ### Using `-Xcov`-style argument

In addition to the response file, the coverage report generation can support
a command line argument similar to `-Xlinker`, `-Xcc` and others, which will
pass the arguments to `llvm-cov show` and override the values in the response
file.

One benefit of having a response file in the repository is the ability of
generating a repeatable HTML report.  In addition, since `llvm-cov` has many
subcommands, we would need careful considering on how to handle the case where
we demand JSON and HTML report, but the associated `llvm-cov`  subcommand does
not support all the `-Xcov` arguments provided via the `swift test` command line
option.

The intent is that when demanding an HTML coverage report, the same HTML report is
produced for all users. Granted, this does not prevent a user from modifying the
response file arguments and create a "temporary HTML" report, but the repository
will be the source of truth for these HTML report command options.

As a result, it was decided to only support a response file, where said response
file is in a given location relative to the repository root.

Support for `-Xcov` (or similar) is to be made in a subsequent proposal.
 -->
### `--show-coverage-path` alternative

An alternative approach would preserve the original `--show-coverage-path` behavior
while introducing an additional command line argument to specify output mode. This
command line argument would be `--show-coverage-path-mode <mode>`, where `<mode>` is either `text` or `json`.
This approach was rejected because `--show-coverage-path-mode` would create a dependency on
the `--show-coverage-path` argument, potentially leading to user confusion.
