# marzipanify
marzipanify is an unsupported commandline tool to take an existing iOS Simulator binary (with minimum deployment target of iOS 12.0) and statically convert it and its embedded libraries & frameworks to run on macOS 10.14's UIKit runtime (Marzipan).

This isn't a tool to automatically port your iOS app to the Mac — moreso something to get you up and running quickly.

As an iOS Simulator app links against the iOS Simulator version of UIKit, it won't contain Marzipan-specific APIs like menu & window toolbar support. It's up to the user to know how to class-dump UIKitCore from /System/iOSSupport/System/Library/PrivateFrameworks and check for the macOS-specific UIKit APIs at runtime so the app can be a good Mac citizen.

N.B. You will still need all the relevant Marzipan-related enabler steps (like disabling SIP & AMFI) before a converted app will run with your signature.

# Usage
`marzipanify MyApp.app|MyFramework.framework|MyBinary`

# Screenshot
![screenshot](https://hccdata.s3.amazonaws.com/gh_marzipanify.jpg)
