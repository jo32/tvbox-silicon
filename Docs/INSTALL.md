# Install Yingxia on iPhone, iPad and Apple TV

The Mac version is a regular [signed download](https://yingxia.getmegaportal.com). The iPhone, iPad and Apple TV versions aren't on the App Store yet, so you install them yourself with [Sideloadly](https://sideloadly.io/). Sideloadly signs the app with your own Apple account and installs it on your device. No jailbreak is required.

## What you need

- **iPhone or iPad** with iOS / iPadOS 26 or later, or **Apple TV** with tvOS 26 or later.
- An **Apple account**. A free account works.
- A **Mac or Windows computer** with [Sideloadly](https://sideloadly.io/) installed. For Apple TV, use a Mac (see [Install on Apple TV](#install-on-apple-tv)).
- The **Yingxia IPA** for your device:

  | Device | IPA | Bundle identifier |
  | --- | --- | --- |
  | iPhone / iPad | built from `TVBox-iOS` | `com.tvbox.yingxia.ios` |
  | Apple TV | built from `TVBox-tvOS` | `com.tvbox.yingxia.tv` |

  The two IPAs are not interchangeable. Sideloadly installs an existing IPA; it doesn't compile this repository's source code. Look for the IPAs on the [Releases page](https://github.com/jo32/tvbox-silicon/releases), or build them yourself with the [developer guide](DEVELOPMENT.md).

## Install on iPhone or iPad

1. Open Sideloadly on your Mac or Windows computer.
2. Connect your device with a USB cable.
3. Unlock the device and tap **Trust** if prompted.
4. Select your device in Sideloadly.
5. Drag the **iOS IPA** into Sideloadly.
6. Enter your Apple account email, then click **Start**.
7. Complete the sign-in and verification prompts.
8. When installation finishes, open **Settings → General → VPN & Device Management** on the device. If prompted, trust the developer entry for your Apple account.
9. If required, turn on **Settings → Privacy & Security → Developer Mode**, then follow the restart and confirmation prompts.
10. Open **Yingxia**. 🎉

## Install on Apple TV

Apple TV 4K has no USB data connection, so Sideloadly installs to it over the network. Use **Sideloadly on a Mac**: Sideloadly's official instructions say it can't install to these models from Windows.

1. Connect your Mac and Apple TV to the same local network.
2. On Apple TV, open **Settings → Remotes and Devices → Remote App and Devices**.
3. Keep that screen open.
4. Open Sideloadly on your Mac and select the Apple TV. Complete any pairing prompts.
5. Drag the **tvOS IPA** into Sideloadly.
6. Enter your Apple account email, then click **Start**.
7. Complete the sign-in and verification prompts.
8. Wait for installation to finish, then open **Yingxia** on Apple TV. 🎉

## Keep the app working

Apps you sideload stop opening when their signature expires:

| Apple account | Signature lasts |
| --- | --- |
| Free | **7 days** |
| Paid Apple Developer Program | Up to **1 year** |

Turn on **automatic app refreshing** in Sideloadly when you install. Its background helper renews the signature, but only while your computer is running and the device is reachable.

If the app expires, install the IPA again with the **same Apple account and bundle identifier**. Don't delete the existing app first if you want to keep your subscriptions, favorites and history.

## Troubleshooting

| Problem | Try this |
| --- | --- |
| iPhone or iPad isn't detected | Unlock it, reconnect the USB cable, and confirm **Trust**. |
| Apple TV isn't detected | Make sure both devices are on the same network, and leave **Remote App and Devices** open. |
| Wrong platform or architecture error | Check that you chose the IPA for your device (iOS or tvOS) and that it's a device build, not a simulator build. |
| The app stopped opening after a week | Its signature expired. Refresh or reinstall it to renew the signature. |
| It installed, but videos won't play | Installing the app doesn't guarantee that every subscription source or plugin works. Try another source. |

## Links

- [Download Sideloadly](https://sideloadly.io/)
- [Sideloadly FAQ and Apple TV connection instructions](https://sideloadly.io/faq)
- [Yingxia website](https://yingxia.getmegaportal.com)
