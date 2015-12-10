# Import Objective-C Code as Optional by Default

* Proposal: [SE-0000](https://github.com/apple/swift-evolution/blob/master/proposals/0000-import-as-optional-by-default.md)
* Author(s): [Fabian Ehrentraud](https://github.com/fabb)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Objective-C code that does not yet include nullability annotations should be either be imported into Swift using `Optionals` rather than `Implicitly Unwrapped Optionals` (`IUO`s) or generate warnings for unsafe accesses in order to prevent runtime crashes.

This proposal contains 2 solution variants where one should be chosen during the review.

## Motivation

Swift code accessing Objective-C methods can easily crash. If the Objective-C code does not include nullability attributes, it is brought as `IUO` into Swift. If the value of the `IUO` is accessed, and it is `nil` at that time, a crash occurrs. These unsafe accesses do not produce compiler warnings and can not be identified by only looking at the according Swift code. So these problematic places are not easy to track down in a code base.

Short example:

```
// Objective-C  
- (NSString *)giveMeAString { return nil; }  

// Swift  
func thisWillCrash() {  
   let string = someObjectiveCObject.giveMeAString()  
   let length = string.length // crash  
}
```

### Use cases

This affects all uses of Objective-C code from Swift, may it be the **System SDK**, an integrated **Framework**, or the same **application's code**. 

Very important would be the use case of an application that is written in Objective-C where Swift code is added. The new Swift code (e.g. in an extension to an Objective-C class) is bound to call a lot of the application's old Objective-C code.

Example:

```
func someSwiftFuncInAnExtension() {
	myDataModel.someProperty.someMethod()
}
```

In a call like that it is not immediately obvious if `myDataModel`, `someProperty` or `someMethod` is written in Objective-C and missing nullability annotations. Swift should help with writing safe code and be supportive at gradually migrating an application to Swift.

## Proposed solution

2 solution variants exist that would result in similar safety.

### Solution #1

Objective-C code that does not yet include nullability annotations should be imported into Swift using `Optionals`.

Exempted are `input parameters` to initializers and methods/functions. Keeping these as `IUO`s would not reduce safety. There are some corner cases like closures which have `IUO` parameters themselves.

### Solution #2

Additional **warnings** shall be added when implicitly unwrapping an `IUO` that was inferred from a lack of nullability information in the Objective-C API.

Example:

```
// Objective-C  
- (NSString *)giveMeAString { return nil; }  

// Swift  
func someFunction() {  
   let string = someObjectiveCObject.giveMeAString()  
   let length = string.length // warning  
   let length2 = string!.length // no warning  
   if let unwrappedString = string { // no warning  
       let length3 = unwrappedString.length
   }
}
```

## Detailed design

### Solution #1

* The `ClangImporter` needs to be adapted to return `Optional`s instead of `IUO`s from `init`, `func`, `subscript`, `let`, `var`, `static var` that stem from a lack of nullability information in the Objective-C API
* Additionally, `output parameters` and `parameters to closures that are input parameters` shall be imported as `IUO`s
* Migration of existing code by explicit use of `!`
* Xcode Fix-It already exists
* **To be discussed during review:** keep the old behavior for "system" frameworks in order to minimize unnecessary `Optional`s that will later become Non-`Optional`s when being audited for nullability

### Solution #2

* Create 2 separate warnings when implicitly unwrapping an `IUO` that was inferred the from a lack of nullability information in the Objective-C API - one for "system" and the other for "user" frameworks
* The warning levels shall be `NO`, `YES` and `YES_ERROR`
* The warning for "system" frameworks shall default to `NO`, the one for "user" frameworks to `YES`
* Xcode Fix-It in case of a compile error

## Impact on existing code

### Solution #1

The migration will ensure that existing code compiles again. Although the migration will use forced unwrapping using `!`, it will be equally safe as the previous implicit forced unwrapping.

#### Affected APIs in System SDKs

In order to help with the decision whether to exclude "system" frameworks or not, the Apple SDKs have been analyzed using this script: <https://github.com/fabb/swift-3-api-guidelines-review/blob/swift-3_stats/generate_reports>

**iOS:**

| category | total count | not containing any IUOs | containing any IUOs | returning IUO |
| ----- | ----- | ----- | ----- | ----- |
| init: |     4176 |     4128 |       48 |       21 |
| func: |    10970 |    10009 |      961 |      411 |
| subscript: |       27 |       23 |        4 |        4 |
| var: |    11875 |    11602 |      273 |      273 |
| static var: |      882 |      882 |        0 |        0 |
| let: |     4449 |     4113 |      336 |      336 | 

**OSX:**

| category | total count | not containing any IUOs | containing any IUOs | returning IUO |
| ----- | ----- | ----- | ----- | ----- |
| init: |     6295 |     6032 |      263 |      116 |
| func: |    17433 |    13922 |     3511 |     1404 |
| subscript: |       23 |       19 |        4 |        4 |
| var: |    35174 |    33145 |     2029 |     2029 |
| static var: |     1086 |     1086 |        0 |        0 |
| let: |     6818 |     5702 |     1116 |     1116 | 

**tvOS:**

| category | total count | not containing any IUOs | containing any IUOs | returning IUO |
| ----- | ----- | ----- | ----- | ----- |
| init: |     2994 |     2961 |       33 |        8 |
| func: |     9064 |     8299 |      765 |      333 |
| subscript: |       25 |       21 |        4 |        4 |
| var: |     9328 |     9173 |      155 |      155 |
| static var: |      723 |      723 |        0 |        0 |
| let: |     3437 |     3162 |      275 |      275 | 

**watchOS:**

| category | total count | not containing any IUOs | containing any IUOs | returning IUO |
| ----- | ----- | ----- | ----- | ----- |
| init: |     1110 |     1089 |       21 |        1 |
| func: |     2754 |     2092 |      662 |      272 |
| subscript: |        5 |        5 |        0 |        0 |
| var: |     2395 |     2284 |      111 |      111 |
| static var: |      301 |      301 |        0 |        0 |
| let: |     1923 |     1637 |      286 |      286 | 

The statistics do not consider `IUOs` in `output parameters` and `parameters to closures that are input parameters`.

There are still many Apple APIs that have not yet been audited for nullability. `CoreFoundation` contains the most `IUO` return values. There exists concern that this solution will result in unnecessary `Optional`-related boilerplate code, as many of the APIs never return `nil`, but until audited, the API consumer would need to deal with that case.

Therefore the possibility of excluding "system" frameworks should be discussed as the user cannot do anything about the nullability annotations missing there, as opposed to "user" frameworks.

### Solution #2

The new warnings will not harm productivity. If a project has "Treat warnings as errors" activated, and there are issues with "user" frameworks, that warning could be selectively deactivated if fixing the errors would take too much time.

## Alternatives considered

### Counter arguments to Solution #1 / Keep the status quo

These counter arguments were collected before Solution #2 was proposed. The arguments for keeping the status quo do not hold for Solution #2.

* Solution #1 would make many changes to existing code bases necessary, even significantly more if "system" frameworks would also default to `Optional` returns
* Many methods of the "system" frameworks would return `Optional`s although they never return `nil` in practice, and just have not yet been audited

**Pro-Keep-Status-Quo:**

* Existing code bases do not need to be touched
* Looking at the Swift-compiled headers or generated documentation one can see the use of `IUO`s and therefore be alert to check herself if values possibly can be `nil`

**Con-Keep-Status-Quo:**

* Existing code bases need to be adapted iff they do not yet use explicit forced/optional unwrapping of the `IUO`s - see above for affected system APIs
* It can easily be overlooked that a called method returns an `IUO`s if it comes from Objective-C
* Accessing such `IUO`s can result in **runtime crashes**
* This might hamper the gradual migration of a project to Swift, as there is no compiler support to help avoiding such issues

### Import only annotated code

As an alternative, it was suggested that only Objective-C code that already includes nullability annotations should be imported. On the swift-evolution mailing list, this alternative was suspected to lead to issues with third-party and closed-source frameworks, or linux system headers. One would need to adapt the header files and add nullability annotations, or use apinotes before the framework could be used, which would involve too much work and not be practicable.

## Community responses

### Solution #1

#### Negative

* I’m opposed to this. First of all, this affects a lot of APIs. I went ahead and grepped through the API dumps [..] to see how often implicitly-unwrapped optionals came through in the Cocoa APIs, and there are lots of them. [..] Most of the implicitly unwrapped optionals we currently get from (Objective-)C APIs can, in fact, never be nil. Forcing programmers to deal with all of these values as full optionals leads to a ton of optional-related boilerplate that doesn’t actual help users write better code. Rather, it dilutes the effectiveness of optionals as a language feature: optionals should mean “nil matters here, think about it carefully!”. But if some large number of optionals people deal with on a day-to-day basis are instead “the compiler didn’t know, so you have to write !”, the useful meaning of the “true” optionals gets lost in the noise. That said, I’d love for implicitly-unwrapped optionals to be used less often, and getting them further out of the type system would be beneficial for the Swift experience. -- Douglas Gregor <dgregor@apple.com>

#### Positive

* I think the decision to import Obj-C APIs with implicitly unwrapped optionals was a very pragmatic decision at the time. However, given it's been over a year (I think?) since the nullability specifiers have been available, I agree with you this could now be improved. -- Javier Soto <javier.api@gmail.com>
* Given the availability and prevalence of nullability annotations, I think it's reasonable to update this behavior, but while I suspect most Swift projects that only use Apple-supplied Objective-C frameworks, there will still be a considerable number that rely on third-party, possibly closed-source frameworks. It may not be possible or economical for those projects to get updated versions of those frameworks with nullability attributes. -- Michael Buckley <thebuckley@gmail.com>
* This is a very interesting idea, one I haven’t considered recently.  I agree with you that this is worth considering, and I would love to see IUO just get summarily deleted :-) -- Chris Lattner <clattner@apple.com>
* I, on the other hand, totally agree with this proposal, even though it would break a lot of existing code. I believe that forcing the unwrap doesn’t cost much, especially with the new guard syntax introduced in Swift 2.0. This is obviously not a change that can be done in a minor release, but because we are in process of getting Swift 3.0 I believe we could introduce such behavior. This would somewhat force both Apple and 3rd party developers to make them use the nullability keywords even more in their code. -- Michał Kałużny <maku@justmaku.org>

### Solution #2

#### Negative

None yet.

#### Positive

* No, it's easier because warnings (especially opt-in ones) have far less impact on existing code. I think what you're asking for is a warning when implicitly unwrapping an IUO when we inferred the IUO from a lack of nullability information in the Objective-C API. For me, that's no longer even a language proposal: it's a smallish proposal for an opt-in warning. [..] If it's opt-in or one can selectively downgrade it to a warning, it shouldn't harm productivity. -- Douglas Gregor <dgregor@apple.com>
