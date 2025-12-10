# HTML Coverage Report

* Proposal: [SE-0501](0501-swiftpm-html-coverage-report.md)
* Authors: [Sam Khouri](https://github.com/bkhouri)
* Review Manager: [David Cummings](https://github.com/daveyc123)
* Status: **Active Review (December 7 - December 22, 2025)**
* Implementation: [swiftlang/swift-package-manager#9076](https://github.com/swiftlang/swift-package-manager/pull/9076)
* Review:
    * [Pitch](https://forums.swift.org/t/pitch-adding-html-coverage-support/82358)
    * [Review](https://forums.swift.org/t/se-0501-html-coverage-report/83601/1)


## Introduction

Currently, `swift test` supports generating a JSON coverage report, which is
great for ingesting into various systems. The JSON, however, is not very
"human-readable" while iterating at-desk.

This proposes adding an additional command line argument to `swift test` that
would allow the caller to select the generation of an HTML coverage report.


## Motivation

JSON coverage report is great for ingesting into external tools that post-process
the coverage data.  If SwiftPM could generate an HTML coverage report:
 - said report can be uploaded to CI systems for visual inspection
 - developer can generate the report at-desk, giving faster feedback to determine
   if the current changes are sufficiently covered to their liking.

## Proposed solution

If users currently want an HTML report, the user must manually construct the
`llvm-cov` binary directly with the correct command line arguments.

e.g.:
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

Since SwiftPM currently orchestrates the JSON coverage data, the solution adds a
new command line argument, e.g.: `--coverage-format` to `swift test` which can
be specified multiple times, to generate multiple coverage report type from a
single test execution.

While processing the coverage data, SwiftPM will loop on all the unique coverage
format options to generate the specified reports.

Unless otherwise specified, this proposal applies only to the HTML Coverage
report.  The generation of the JSON Coverage report is unchanged and is out of
scope.

## Detailed design

Existing tools in LLVM have been around for several years (and maybe even decades),
and provide robust tools for code coverage analysis. The LLVM tools are
well-documented, and have been used in production for many years.  SwiftPM will
make use of LLVM's tools and construct the proper command line arguments to the
`llvm-cov show` utility, which will generate the HTML report.

The proposted command line changes are as follows:

### Consolidate coverage option to use same argument "style"

Prior to this feature, there are 2 coverage options

```
  --show-codecov-path, --show-code-coverage-path, --show-coverage-path
                          Print the path of the exported code coverage JSON
  --enable-code-coverage/--disable-code-coverage
                          Enable code coverage. (default:
                          --disable-code-coverage)
```

There are 3 ways to show the coverage path.  This proposal recommends to modify all
coverage command line option to be a single, more useful option

```
  --show-coverage-path
                          Print the path of the exported code coverage JSON
  --enable-coverage/--disable-coverage
                          Enable code coverage. (default:
                          --disable-coverage)
```

This requires gracefully phasing out the previous option in favour of the new one.

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


### Coverage Report configuration

`llvm-cov show` has several report configurability options. In order to
prevent a "command line arguments" explosion to `swift test`, the configuration
options will be read from a response file.  The optional response file will be
located in `<repo>/.swiftpm/configuration/coverage.html.report.args.txt`, which
is the same location used by other SwiftPM features, such as registration and
mirros configuration files.  The response file will be supported.

The user can include `--format=text`, or a variation thereof, in the response
file. In order to ensure SwiftPM will always generate an HTML report, SwiftPM
will add `--format=html` after the response file argument to ensure `llvm-cov`
will generate an HTML report.


SwiftPM will not perform any validation on the response file contents, except
to determine the output location.

### Coverage report location

By default, the HTML report will be created in location under the scratch path
(ie: the build directory).  However, this can be overridden using the response file.

Some CI system, such as [Jenkins](https://www.jenkins.io), only allow archiving
contents files/directories that belong in a "sandbox" location.  It can be a safe
assumption that the CI system will have a copy of the repository in the "sandbox"
location, allowing this system to upload the HTML report.

```
  --show-coverage-path  [mode]
                          Print the path of the exported code coverage files.  The mode specifies how to
                          display the paths of the selected code coverage file formats. (default: text)
        json              - Display the output in JSON format.
        text              - Display the output as plain text.
   --enable-coverage/--disable-coverage
                          Enable code coverage. (default: --disable-codecov)
  --coverage-format <format>
                          Format of the code coverage output. Can be specified multiple times. (values: json, html; default: Produces a JSON coverage report.)
```

### Show coverage path
Prior to this proposal `swift test --show-coverage-path` would display a single
absolute path location to the JSON coverage report.

Since `--coverage-format` can be specified multiple times, it's output must be
changed to reflect the new functionality.

If the `--coverage-format` option is specified on the `swift test` command line
a single time (or is not specified at all), there is no change to the output.


if `--coverage-format` is specified multiple times, the output must reflect this.
The `--show-coverage-path` command line argument will be modified to be an optional
with a default value.  The supported values are `json` or `text`, with the default
being `text` to preverse existing behaviour.

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

## Security

Since SwiftPM will use `llvm-cov show`, there may be security implications from
the `llvm-cov` utility, but this is outside of the Swift organizations control.

The LLVM project has a [LLVM Security Response Group](https://llvm.org/docs/Security.html),
which has a process for handling security vulnerabilities.

## Impact on existing packages

No impact is expected.

## Alternatives considered


### Using `-Xcov`-style argument

In addition to the response file, the coverage report generation can support
a command line argument similar to `-Xlinker`, `-Xcc` and others, which will
pass the arguments to `llvm-cov show` and override the values in the response
file.

Once benefit of having a response file in the repository is the ability of
generating a repeatable HTML report.  In addition, since `llvm-cov` has many
subcommands, we would need careful considering on how to handle the case where
we demand JSON and HTML report, but the associated `llvm-cov`  subcommand does
not support all the `-Xcov` arguments provided via the `swift test` command line
option.

The intent is that when demand an HTML coverage report, the same HTML report is
produced for all users. Granted, this does not prevent a user from modifying the
response file arguments and create a "temporary HTML" report, but the repository
will be the source of truth for these HTML report command options.

As a result, it was decided to only support a response file, where said response
file is in a given location relative to the repository root.

Support for `-Xcov` (or similar) is to be made in a subsequent proposal.

### `--show-coverage-path` alternative

Instead of having a `--show-coverage-path` as a tri-state, we could preserve
`--show-coverage-path` original behaviour and add an additional command line
argument to indicate the output mode.  The comand line argument would be
`--show-coverage-path-mode <mode>`, where `<mode>` is either `text` or `json`.
This was not favoured as `--show-coverage-path-mode` would have a dependency on
`--show-coverage-path` argument, and may lead to some confusion.
