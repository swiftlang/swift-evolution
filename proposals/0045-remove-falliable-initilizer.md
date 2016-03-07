# Remove Falliable Initilizers

* Proposal: [SE-0045](https://github.com/apple/swift-evolution/blob/master/proposals/0045-name.md)
* Author(s): [Swift Developer](https://github.com/jcampbell05)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Falliable initilizers were originally introduced in Swift 1.1 because of the lack of an ability to indicate an object wasn't able to be constructed. They have played a key part in the migration from Objective-C to Swift since in the former you could return nil in the initilizer.

However in Swift 2.0 it is now possible to throw errors instead. Intilizers are complex machines and many things can fail, by allowing a user to return nil we are encouraging a user to build initlisers which return nil for reasons that may not be clear without spending the time to debug.

In addition Swift has the `try?` and `try!` keywords to return nil upon an error or to trigger an exception. It is my opinion this makes it more explicit and that an initliser can fail.

```swift
MyObject() //Not obvious that is a init?
try? MyObject() //This one fails so it forces us to handle it.
```

To quote Tino Heth:

"Without "try?", it would be really inconvenient to not have "init?" — but failable initializers as they are now are somewhat odd, because they are half-function and half-procedure:
Regular init-methods have no return, so you can basically think of them as a configuration that is called on an allocated object.
This isn't true anymore for "init?", as it not only it turns a "void-function" into something that returns an optional, but also doesn't explicitly model the non-nil case (there is no "return self").
Replacing this mechanism with an error would actually make initializers more method-like, and less special."

Swift-evolution thread: [link to the discussion thread for that proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160229/thread.html#11631)

## Motivation

The purpose of this proposal is to improve the information initilisers provide about failing. Additionally as a by-product of this proposal wheather if removing falliable initilisers is approved or not, I would like to see additions added to the upcoming API Guideline on reccomendations for when to return nil or to throw an error. If rejected there should be some consistency between initilisers that return nil and those that throw errors.

## Proposed solution

Take this Model which takes a Dictionary of JSON data, with fallaible initlisers we have this:

```swift
class Model {

let name: String
let age: Int

init?(json: [String: AnyObject]) {

guard name = json["name"] as? String else {
 return nil
}

guard age = json["age"] as? Int else {
 return nil
}
```

You could combine these into one guard statement to make it concise, but you wouldn't know if it failed. Was it because the key doesn't exist? was it the correct type?.


```swift
class Model {

let name: String
let age: Int

init(json: [String: AnyObject]) throws {

guard name = json["name"] as? String else {
 throw Error.FailedToParse("Name", to:String)
}

guard age = json["age"] as? Int else {
 throw Error.FailedToParse("Age", to:Int)
}
```

With this we know instantly what the issue is and we can easily still use `try?` to convert it to an optional where we need it.

## Detailed design

This is simpily remove falliable initlisers. We could introduce some standard ErrorTypes in the stdlib to remove the need to define your own in common cases.

## Impact on existing code

### Swift

This would break all existing code. One way we can mitigate this is to introduce a warning initially. When we finally remove falliable initlisers we could introduce a fix-it provided we had some standard error types in the language, like so:

```swift
class Model {
  init?() {
    return nil
  }
}

Model()
```

Would become:

```swift
class Model {
  init() throws {
    return GenericError
  }
}

try? Model()
```

### Objective-C

When importing Objective-C types we could have two choices:

Choice 1) Instead of importing them as `init?()` we would import them as `init() throws`. Like above we would have a fix-it provided for call-sites to convert `init()` to `try? init()`.

Provided we had some sort of generic error types in the language, the swift library could throw this generic error when the Objective-C initlizer returns nil. 

Choice 2) Since alot of the libraries use Objective-C code, this may cause a penalty hit when bridging from Objective-C and wonky code when bridging back to Objective-C from Swift. We could instead only allow `init?` when working with Swift classes marked with the `@objc` attribute. This would fit nicely with other magic Objective-C functionality and API (Like KVC) which is exposed to Swift which only works when marked as `@objc`

## Alternatives considered

An alternative is to change the falliable initiliser to have the optional symbol required at the call-site:

```swift
MyModel?()
```

In addition to this we should update the forthcoming API Guidelines to provide guidence on when and when-not to use falliable initilisers and throwing initilisers. Currently the decision behind the error handling system in swift is burried in the Swift Repo. I think it would benefit the community to have a consistent approach to error handling applied across all API especially the initizers.

