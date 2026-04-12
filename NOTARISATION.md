From: https://developer.apple.com/forums/thread/737894

macOS allows you to independently distribute a Network Extension using Developer ID signing, but with an important wrinkle. This post explains that wrinkle, its affect on Xcode, and how you get around it.

* * * * *

Exporting a Developer ID Network Extension

macOS supports a variety of Network Extension (NE) provider types. Starting with macOS 10.15, it's possible to distribute an app containing NE providers independently, using Developer ID signing. See TN3134 [Network Extension provider deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment) for the full list of supported provider types.

For your NE provider to work when distributed independently, it must:

-   Be packaged as a system extension.

-   Use Developer ID specific entitlements

This post is focused on that second point, because it's common source of confusion.

This post assumes that you're building your app with Xcode; if you're building your app outside of Xcode, you'll have to adapt these steps to your build system.

Entitlement Matters

A Network Extension system extension and its container app must be signed with the [Network Extension entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_developer_networking_networkextension) (`com.apple.developer.networking.networkextension`). That entitlement is an array, with a variety of different element values based on the provider type. For example, a standard NE content filter provider must include the `content-filter-provider` value.

There are two groups of these values: the standard ones and the ones with the `-systemextension` suffix. During development and for App Store distribution, use the appropriate standard value. For independent distribution using Developer ID, use the corresponding value with the `-systemextension` suffix. For example, a Developer ID signed NE content filter must use `content-filter-provider-systemextension`instead of `content-filter-provider`.

Xcode Issues

Xcode is currently not aware of this requirement. If you build your NE provider container app using Xcode, you might expect to export it for independent distribution using the Direct Distribution workflow in the Xcode organiser. This does not work (r. 108838909).

To get around this, manually export your app from your Xcode archive. Before attempting that, there's a few things to confirm:

-   By default Xcode's Signing & Capabilities editor uses the standard values for the NE entitlement. Leave them that way. During day-to-day development it's best to use an Apple Development signing identity [1], and the standard values work with that.

-   Continue to use Build > Archive [2] to create an Xcode archive for your product. The steps below replace the Direct Distribution workflow, and they assume you're starting with an Xcode archive.

[1] Don't use Developer ID for day-to-day development; see [The Care and Feeding of Developer ID](https://developer.apple.com/forums/thread/732320) for more on that topic.

[2] Or, if you're automating this, the `archive` action in `xcodebuild`.

Assemble Your Assets

Imagine you're working on a content filter for the Mac called WaffleFilter. You've used Xcode to build the app into an Xcode archive:

```
% ls "WaffleFilter.xcarchive／Products／Applications"
WaffleFilter.app

```

That app is development signed:

```
% codesign -d -vvv "WaffleFilter.xcarchive／Products／Applications／WaffleFilter.app"
...
Authority=Apple Development: ...
...

```

**IMPORTANT** The steps in this section are based on the much more comprehensive instructions in [Creating Distribution-Signed Code for Mac](https://developer.apple.com/forums/thread/701514). If anything is unclear, read that post for clarification.

To re-sign this app for independent distribution you'll need three things:

-   A Developer ID application signing identity. This is named `Developer ID Application: TTT`, where `TTT` identifies your team.

-   A Developer ID provisioning profile for the app. In this example I've called this `WaffleFilter_Dev_ID.provisionprofile`.

-   A Developer ID provisioning profile for the system extension. In this example I've named this `WaffleFilter_WFProvider_DevID.provisionprofile`.

If you're not sure how to create these things, see [Developer Account Help](https://developer.apple.com/help/account/).

Re-sign the App

To start, make a copy of the app:

```
% ditto "WaffleFilter.xcarchive／Products／Applications／WaffleFilter.app" "WaffleFilter.app"

```

Dump the entitlements of the app and its embedded system extension:

```
% codesign -d --entitlements "WaffleFilter.entitlements" --xml "WaffleFilter.app"
% codesign -d --entitlements "WaffleFilter_WFProvider.entitlements" --xml "WaffleFilter.app／Contents／Library／SystemExtensions／com.example.apple-samplecode.WaffleFilter.WFProvider.systemextension"

```

And reformat them to make them more readable:

```
% plutil -convert xml1 "WaffleFilter.entitlements"
% plutil -convert xml1 "WaffleFilter_WFProvider.entitlements"

```

Now edit these files to add the `-systemextension` suffix. The result will look something like this:

```
% cat "WaffleFilter.entitlements"
...
＜dict＞
    ...
    ＜key＞com.apple.developer.networking.networkextension＜／key＞
    ＜array＞
        ＜string＞content-filter-provider-systemextension＜／string＞
    ＜／array＞
    ...
＜／dict＞
＜／plist＞
% cat "WaffleFilter_WFProvider.entitlements"
...
＜dict＞
    ...
    ＜key＞com.apple.developer.networking.networkextension＜／key＞
    ＜array＞
        ＜string＞content-filter-provider-systemextension＜／string＞
    ＜／array＞
    ...
＜／dict＞
＜／plist＞

```

Before you re-sign with these entitlements, replace the embedded provisioning profiles with their Developer ID profiles variants:

```
% cp "WaffleFilter_Dev_ID.provisionprofile" "WaffleFilter.app／Contents／embedded.provisionprofile"
% cp "WaffleFilter_WFProvider_DevID.provisionprofile" "WaffleFilter.app／Contents／Library／SystemExtensions／com.example.apple-samplecode.WaffleFilter.WFProvider.systemextension／Contents／embedded.provisionprofile"

```

Now re-sign the app and the system extension with their new entitlements, from the inside out:

```
% codesign -s "Developer ID Application" -f --entitlements "WaffleFilter_WFProvider.entitlements" --timestamp -o runtime "WaffleFilter.app／Contents／Library／SystemExtensions／com.example.apple-samplecode.WaffleFilter.WFProvider.systemextension"
WaffleFilter.app／Contents／Library／SystemExtensions／com.example.apple-samplecode.WaffleFilter.WFProvider.systemextension: replacing existing signature
% codesign -s "Developer ID Application" -f --entitlements "WaffleFilter.entitlements" --timestamp -o runtime "WaffleFilter.app"
WaffleFilter.app: replacing existing signature

```

If you have multiple Developer ID Application signing identities, you'll need to replace `Developer ID Application` with the name of the specific identity you want to use.

**IMPORTANT** If your app contains other code items, like frameworks or an app extension, re-sign those as well. For advice on how to manually re-sign a more complex app, see [Creating Distribution-Signed Code for Mac](https://developer.apple.com/forums/thread/701514).

And you're done!

Manually Notarise

Xcode's Direct Distribution workflow also deals with notarisation. As you're not using that workflow, manually notarise your app. For advice on how to do that, see [Customizing the notarization workflow](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow).

You should also look at [Packaging Mac Software for Distribution](https://developer.apple.com/forums/thread/701581), which has a bunch of general info about packaging Mac apps.