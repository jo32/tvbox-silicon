# Install Yingxia on iPhone, iPad and Apple TV

The Mac version is a regular [signed download](https://yingxia.getmegaportal.com). The iPhone, iPad and Apple TV versions aren't on the App Store yet, so you sign and install them yourself with your own Apple account. No jailbreak is required.

We recommend **[cider](https://github.com/Battzz/cider-cli)**, a free command-line tool for macOS, Windows and Linux. If you'd rather use an app, [Impactor](https://github.com/claration/Impactor/releases), [iloader](https://iloader.app) (iPhone and iPad only) and [Sideloadly](https://sideloadly.io/) work too; see [Other tools](#other-tools). You can also [let an AI agent do it](#let-an-ai-agent-install-it).

## What you need

- **iPhone or iPad** with iOS / iPadOS 17 or later, or **Apple TV** with tvOS 17 or later.
- An **Apple account**. A free account works.
- A **Mac, Windows or Linux computer** for iPhone and iPad. For **Apple TV you need a Mac** on the same local network as the TV: installing to Apple TV over Wi-Fi isn't possible from Windows or Linux.
- The **Yingxia IPA** for your device:

  | Device | IPA | Bundle identifier |
  | --- | --- | --- |
  | iPhone / iPad | [Yingxia-1.8.1-ios.ipa](https://download.getmegaportal.com/yingxia/1.8.1/Yingxia-1.8.1-ios.ipa) | `com.jo32.yingxia.ios` |
  | Apple TV | [Yingxia-1.8.1-tvos.ipa](https://download.getmegaportal.com/yingxia/1.8.1/Yingxia-1.8.1-tvos.ipa) | `com.jo32.yingxia.tv` |

  From 1.7.8 the bundle identifiers are `com.jo32.yingxia.*`, so 1.7.8 installs next to an earlier Yingxia instead of replacing it: add your subscription in the new app, then delete the old one.

  The two IPAs are not interchangeable. To build your own, see the [developer guide](DEVELOPMENT.md).

## Install cider

```sh
# macOS (Homebrew)
brew tap Muonagi/cider-cli https://github.com/Muonagi/cider-cli
brew install cider

# or macOS / Linux, installs to /usr/local/bin
curl -fsSL https://raw.githubusercontent.com/Muonagi/cider-cli/main/install.sh | sh
```

On **Windows**, first install **iTunes** or **Apple Devices** from the Microsoft Store (cider uses Apple's device driver), then in PowerShell:

```powershell
$dir = "$env:LOCALAPPDATA\cider"
New-Item -ItemType Directory -Force $dir | Out-Null
curl.exe -L -o "$env:TEMP\cider.zip" https://github.com/Muonagi/cider-cli/releases/latest/download/cider-x86_64-pc-windows-msvc.zip
Expand-Archive "$env:TEMP\cider.zip" $dir -Force
[Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable("Path", "User") + ";$dir", "User")
```

Open a new PowerShell window afterwards so `cider` is on the PATH. On **Linux**, `usbmuxd` must be running. Building cider from source currently fails because one of its dependencies was removed from GitHub, so use a release build.

Then sign in once:

```sh
cider account login   # asks for your Apple account, password and 2FA code
cider account team    # only if your account belongs to several teams
```

> [!NOTE]
> The first time it signs an app, cider creates a development certificate for your account. If Apple says you already have too many, cider revokes an existing development certificate to make room. That's routine for a free account; if you have a paid developer account with certificates you use elsewhere, check `cider account certificates` first.

## Install on iPhone or iPad

1. Connect the device with a USB cable, unlock it, and tap **Trust** if prompted.
2. Pair it:
   ```sh
   cider device list
   cider device trust
   ```
3. In the folder with the IPA, sign and install it:
   ```sh
   cider sign Yingxia-1.8.1-ios.ipa --apple-id --install --refresh
   ```
4. On the device, open **Settings → General → VPN & Device Management** and trust the developer entry for your Apple account.
5. If required, turn on **Settings → Privacy & Security → Developer Mode**, then follow the restart and confirmation prompts.
6. Open **Yingxia**. 🎉

## Install on Apple TV

Apple TV 4K has no USB data connection, so cider installs to it over the network. This needs a **Mac** on the same network.

1. Connect your Mac and Apple TV to the same local network.
2. On Apple TV, open **Settings → Remotes and Devices → Remote App and Devices**, and keep that screen open.
3. Pair the Mac with the TV once. cider can only pair over USB, so use Xcode (free in the App Store): open **Window → Devices and Simulators**, select the Apple TV under Discovered, click **Pair** and type the PIN the TV shows. (Sideloadly's **Re-Pair** button works too.)
4. Find its UDID with `cider device list` (it's listed as `<your TV's name> [WiFi]` with an ID like `00008110-…`), then sign and install:
   ```sh
   cider sign Yingxia-1.8.1-tvos.ipa --apple-id --install --refresh -u <UDID>
   ```
   The IPA is about 140 MB, so the install can take a few minutes over Wi-Fi. It ends with `✓ Installed to <name>`.
5. Open **Yingxia** on Apple TV. 🎉

If cider can't install to your Apple TV (for example, a provisioning profile or platform error), use [Sideloadly on a Mac](#sideloadly) instead.

## Let an AI agent install it

If you use an AI agent that can run commands on your computer, such as [Claude Code](https://claude.com/product/claude-code), [WorkBuddy](https://www.workbuddy.ai), [Doubao](https://www.doubao.com/download) (desktop app, work mode), [Grok Build](https://x.ai/news/grok-build-cli), [Gemini CLI](https://github.com/google-gemini/gemini-cli) or [Codex](https://developers.openai.com/codex), choose **AI agent** under "How to install" on the [website](https://yingxia.getmegaportal.com/#install-ios): it copies a prompt like this one for your device. Or paste it yourself:

> Install Yingxia on my Apple TV from this Mac. First read https://raw.githubusercontent.com/jo32/tvbox-silicon/main/.agents/skills/install-yingxia/SKILL.md and follow it. Use cider to sign the latest Apple TV IPA with my Apple account and install it over Wi-Fi. Let me type my own password, and ask me before anything that could revoke a certificate.

The agent reads the [install skill](../.agents/skills/install-yingxia/SKILL.md), which covers downloads, cider on macOS, Windows and Linux, pairing, and what to do about common errors. A web chat can't do this, because it can't run commands on your computer; use the agent's desktop or terminal app. Type your Apple account password into cider yourself; never paste it into the chat.

## Keep the app working

Apps you sideload stop opening when their signature expires:

| Apple account | Signature lasts |
| --- | --- |
| Free | **7 days** |
| Paid Apple Developer Program | Up to **1 year** |

Apps signed with `--refresh` can be renewed before they expire, with the device connected or on the same network:

```sh
cider refresh list
cider refresh run
```

If the app expires, sign and install the IPA again with the **same Apple account and bundle identifier**. Don't delete the existing app first if you want to keep your subscriptions, favorites and history.

## Other tools

| Tool | Runs on | Installs to | Notes |
| --- | --- | --- | --- |
| [Impactor](https://github.com/claration/Impactor/releases) | macOS, Windows, Linux | iPhone, iPad, Apple TV | Desktop app (formerly PlumeImpactor); also `brew install --cask impactor`. cider is built on its code. |
| [iloader](https://iloader.app) | macOS, Windows, Linux | iPhone, iPad | Desktop app; use **Import IPA**. |
| [Sideloadly](https://sideloadly.io/) | macOS, Windows | iPhone, iPad; Apple TV from a Mac only | Steps below. |
| [AltStore](https://altstore.io) or [SideStore](https://sidestore.io) | iPhone, iPad | iPhone, iPad | Add the Yingxia source to get updates in the app; steps below. |

Download these only from the links above: the projects publish no other official sites.

### Sideloadly

**iPhone or iPad:** connect by USB and tap **Trust**, select the device in Sideloadly, drag in the iOS IPA, enter your Apple account email and click **Start**. Then trust your account under **Settings → General → VPN & Device Management** and turn on Developer Mode if asked.

**Apple TV (Mac only):** put both on the same network, open **Settings → Remotes and Devices → Remote App and Devices** on the TV, click Sideloadly's **Re-Pair** button and type the PIN, then select the Apple TV, drag in the tvOS IPA, enter your Apple account email and click **Start**.

Turn on **automatic app refreshing** in Sideloadly; it renews the signature only while your computer is running and the device is reachable.

### AltStore and SideStore

Yingxia has an AltStore source at `https://yingxia.getmegaportal.com/altstore.json`, which AltStore Classic and SideStore can also read. In AltStore or SideStore, open **Sources**, tap **+**, paste that address and tap **Add**, then install Yingxia from the source. New versions then show up under **Updates**. The source lists the iPhone and iPad app only: AltStore doesn't install on Apple TV.

## Troubleshooting

| Problem | Try this |
| --- | --- |
| The device isn't in `cider device list` | iPhone/iPad: use a data cable, unlock it, reconnect and confirm **Trust**. Windows: iTunes or Apple Devices must be installed. Apple TV: same network as the Mac, then pair it once in Xcode (see above). |
| `cider device trust` fails with `PasswordProtected` or `PairingDialogResponsePending` | Unlock the device, tap **Trust**, enter the passcode, and run it again. |
| `UserDeniedPairing` or `InvalidHostID` | On the device, go to Settings → General → Transfer or Reset → Reset → **Reset Location & Privacy**, reconnect and run `cider device trust` again. |
| `Bad 2FA code` | Run `cider account login` again with the newest code. |
| "maximum number of installed apps using a free developer profile" | A free account can have 3 sideloaded apps on a device. Delete one and try again. |
| "Untrusted Developer" or "Developer Mode Required" when opening the app | Trust your account under **Settings → General → VPN & Device Management**, and turn on **Settings → Privacy & Security → Developer Mode**. |
| `Too many certificates and failed to revoke any` | Your account is at Apple's certificate limit. Revoke an unused development certificate at developer.apple.com → Certificates, then try again. |
| The Apple TV install seems stuck | It's copying about 140 MB over Wi-Fi. Give it 5–10 minutes. |
| Sideloadly says `GSA returned a non-plist response (HTTP 503 …)` | Its log shows **"Will use Fake Local Anisette"**: Sideloadly couldn't get Apple's sign-in data from your Mac, so Apple rejected the sign-in. It isn't your network. Open Sideloadly settings (gear icon), switch anisette to **On-device Anisette** or **Local Anisette**, and click **Start** again. |
| Wrong platform or architecture error | Check that you chose the IPA for your device (iOS or tvOS) and that it's a device build, not a simulator build. |
| The app stopped opening after a week | Its signature expired. Run `cider refresh run`, or sign and install it again. |
| It installed, but videos won't play | Installing the app doesn't guarantee that every subscription source or plugin works. Try another source. |

## Links

- [cider](https://github.com/Battzz/cider-cli) and its [releases](https://github.com/Muonagi/cider-cli/releases)
- [Impactor](https://github.com/claration/Impactor) · [iloader](https://iloader.app) · [Sideloadly](https://sideloadly.io/) · [AltStore](https://altstore.io) · [SideStore](https://sidestore.io)
- [Yingxia AltStore source](https://yingxia.getmegaportal.com/altstore.json)
- [Install skill for AI agents](../.agents/skills/install-yingxia/SKILL.md)
- [Yingxia website](https://yingxia.getmegaportal.com)
