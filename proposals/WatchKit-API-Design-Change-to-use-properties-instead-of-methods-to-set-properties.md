# Update WatchKit API Design to use properties instead of methods to set properties

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/WatchKit-API-Design-Change-to-use-properties-instead-of-methods-to-set-properties.md)
* Author: [Michie Ang](https://github.com/michieriffic)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

WKInterfaceLabel is still using methods for set Text (setText), set Text Color (setTextColor), set Attributed Text (setAttributedText) to set properties of WKInterfaceLabel. 
I think it's more appropriate to make these into properties rather than methods just like in the UILabel.
That would make it more consistent with building apps for both iOS, MacOS, WatchOS, and more.

Also, other objects in WatchKit needs to be updated too to use properties instead of methods to set properties so we can easily access it using dot notation.
WKInterfaceLabel is just an example.

## Motivation

While creating an app for watchOS, it has been a habit for me to use the dot notation to access a property of an object and set it using "=". 
And text, textColor, and attributedText are properties rather than methods of an object.

## Proposed solution & detailed design

```swift
public class WKInterfaceLabel : WKInterfaceObject {

   public var text: String?
   public var textColor: UIColor?
   @NSCopying public var attributedText: AttributedString?

}
```

**INSTEAD OF**
```swift
public class WKInterfaceLabel : WKInterfaceObject {

   public func setText(_ text: String?)
   public func setTextColor(_ color: UIColor?)
   public func setAttributedText(_ attributtedText: AttributedString?)

}
```

## Impact on existing code

Impact: **Would be more consistent and natural to the Swift language when building apps for WatchOS**

**Before:**
```swift

  watchLabel.setText("Text String")
  watchLabel.setTextColor(UIColor.red())

```

**After:**
```swift

  watchLabel.text = "Text String"
  watchLabel.textColor = UIColor.red()

```

Will some Swift applications stop compiling due to this change? **Possible**

Will applications still compile but produce different behavior than they used to? **No, if everything was migrated properly.**

Is it possible to migrate existing Swift code to use a new feature or API automatically? **Yes.**


## Alternatives considered

Just use what's currently available.
