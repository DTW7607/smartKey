<p align="center">
  <img src="packaging/AppIcon.png" width="112" alt="smartKey app icon">
</p>

# 智键 · smartKey for macOS

[简体中文](README.md) | **English**

A new life on the Mac for the tiny button that plugged into your phone a decade ago.

smartKey brings **macOS support to legacy 3.5 mm 智键 hardware**. Assign a single click, double click, or long press to a keyboard shortcut, media control, shell script, or Apple Shortcut. The app lives in the menu bar, connecting one physical button to your everyday actions.

**macOS 26+ · Native Swift / SwiftUI · MIT License · Chinese app interface**

## Why this project exists

Remember the small 智键 button that plugged into a phone's headphone jack about ten years ago? This project aims to make that old hardware useful on today's Macs. For background on the hardware, see this Chinese Bilibili video: [《手机上的这个小玩意儿，你用过吗？》](https://www.bilibili.com/video/BV1714y1Z7QQ/) (roughly, “Have you ever used this little gadget on your phone?”). That video introduces the hardware; the demo and screenshots below show this project.

This is a personal project with no affiliation to the original hardware manufacturer. **Chinese and English READMEs are available, but the app itself is only available in Chinese. An English app version is not provided due to limited maintenance capacity.** Community adaptations for English or other interface languages are welcome.

## Demo

![smartKey triggering Notch Note and displaying an action-name bubble](docs/assets/demo.gif)

[Watch the MP4 recording](docs/assets/demo.mp4). **Notch Note** in the demo and **Codex** in the screenshots are examples of personally configured actions. They are not built-in features or required dependencies. All three gestures are unassigned on first launch.

## Features

| Feature | Description |
| --- | --- |
| Three gestures | Configure single click, double click, and long press independently; adjust gesture timing |
| Keyboard actions | Record a single key or key combination to trigger an app shortcut or other keyboard operation |
| Media controls | Play / pause, previous track, next track, volume up / down, and output mute |
| Shell scripts | Manage zsh / bash scripts, configure working directories, environment variables, and timeouts, and inspect results |
| Apple Shortcuts | Select a local shortcut and bind it by its system ID |
| Device and audio setup | Choose between an audio device and 智键 when plugging in; keep sound routed to another output in 智键 mode |
| Menu bar and feedback | Pause / resume actions, launch at login, button-press animation, and Liquid Glass action-name bubbles |

<img src="docs/assets/actions.png" width="900" alt="Action settings for single click, double click, long press, and gesture timing">

<details>
<summary>More screenshots: menu bar, general settings, action picker, scripts, and device setup</summary>

Menu bar:

<img src="docs/assets/menu-bar.png" width="280" alt="smartKey menu bar menu">

General settings:

<img src="docs/assets/general.png" width="900" alt="Device mode, accessibility permission, and launch-at-login settings">

Action picker:

<img src="docs/assets/action-picker.png" width="900" alt="Choosing a keyboard, media, script, or Apple Shortcuts action">

Script library:

<img src="docs/assets/scripts.png" width="900" alt="Script library, read-only source preview, and execution settings">

Device insertion prompt:

<img src="docs/assets/device-setup.png" width="900" alt="Choosing an audio device or 智键 after plugging into the 3.5 mm jack">

</details>

The screenshots and recording show the interface and personal configuration during development. Refer to the current implementation for exact behavior. The interface remains in Chinese; this guide includes the relevant Chinese labels alongside English explanations.

## Requirements and compatibility

- **macOS 26 or later.** The app uses native Liquid Glass APIs introduced in macOS 26. Older systems are not currently supported.
- **A Mac with a built-in 3.5 mm headphone jack and legacy 智键 hardware.** The backend accepts only Consumer Control events on the built-in audio path with `Transport=Audio`.
- **Another available audio output**, such as built-in speakers, Bluetooth headphones, or a USB audio device. Sound needs to be routed elsewhere while the button occupies the headphone jack.
- To build from source, **full Xcode 26 or later**, including the macOS 26 SDK and Swift Testing. The project uses Swift Package Manager and has no third-party package dependencies.

There is no complete compatibility list covering Mac models and hardware batches yet; reports from actual devices are welcome. **USB / USB-C to 3.5 mm adapters, USB buttons, and Bluetooth buttons are outside the current support scope.** Bluetooth and USB audio devices can serve as sound outputs, but that does not make them supported button inputs.

## Build and install

Download and extract the source ZIP, or clone the repository, then open a terminal in the project root. The current installation method is building from source. The scripts produce an ad-hoc-signed app for local use; they do not include Developer ID signing or notarization.

Build the app:

```bash
./scripts/build-app.sh
```

The output is `.build/release-app/smartKey.app`. This command builds the app and verifies its signature without installing or launching it. By default, it targets the current Mac's architecture rather than producing a Universal Binary.

Install and launch:

```bash
./scripts/install-app.sh
```

The installation script quits running smartKey instances, rebuilds the release configuration, replaces `/Applications/smartKey.app`, and removes the old `/Applications/智键.app` bundle. User configuration is stored separately in Application Support. On first launch from `/Applications`, the app attempts to register a login item. Disable 「登录时打开」 (Open at Login) from the menu bar or general settings if desired.

For development, run directly:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run smartKey
```

If Xcode is installed elsewhere, adjust `DEVELOPER_DIR`. The build scripts prefer `/Applications/Xcode.app` when present. Command Line Tools alone may not provide the `Testing` module required by the tests.

## First use

1. Launch the app and find the 智键 icon in the menu bar. It does not appear in the Dock.
2. Plug in the button and choose 「智键」 in the lower-right prompt. By default, the prompt accepts the focused option after five seconds. The initial selection is 智键; subsequent prompts remember the last choice. For ordinary headphones, choose 「音频设备」 (Audio Device).
3. Choose a sound output when prompted. A single available output other than the headphone jack is selected automatically; multiple outputs require confirmation. Button input becomes active only after the audio switch and HID connection succeed.
4. Open 「设置 → 动作配置」 (Settings → Action Configuration), select an action for a gesture, and save the binding. For keyboard or media event control, grant accessibility permission as prompted under 「通用」 (General).
5. Click 「测试」 (Test), then try the physical button. Keyboard tests give you three seconds to switch to the target app. Testing really executes the selected action.

Assigning a double-click action makes single clicks wait for the double-click window. Clearing that binding makes a single click resolve on release. A long press executes once at the threshold and does not also trigger a single click on release. Both the double-click window and long-press threshold default to 450 ms.

## Scripts and Apple Shortcuts

Create, import, or drag scripts into 「脚本管理」 (Script Management). Importing copies a script into the app's library and leaves the original unchanged. The interface provides a read-only source preview. Use 「使用默认应用打开」 (Open with Default App) to edit the managed copy in a text editor. Each execution reads the latest saved content.

Scripts run as the current user in a noninteractive background shell. Both zsh and bash are supported, with configurable working directories, environment variables, and timeouts. The default timeout is 30 seconds. Only one script runs at a time; repeated triggers are not queued. A `.smartkeyscript` export includes source and metadata, but excludes environment variables and external dependencies. A plain `.sh` export contains only the source. Scripts relying on neighboring files need their dependency paths handled after import.

Apple Shortcuts are selected from the local system list and bound by ID, so renaming a shortcut does not break its binding. The default wait timeout is 300 seconds. The app waits for at most one shortcut at a time, independently of script execution. First use may require system permission or interaction. 「停止等待」 (Stop Waiting) only stops the local command process; the shortcut may continue running in the system.

Scripts and shortcuts perform real operations, so review imported content before running it. Execution results appear in settings; bubbles display only the action name. See the [action and script development guide](docs/action-development.md) (Chinese) for detailed execution rules.

## FAQ

**Nothing happens after plugging in the button.** Check that it is connected directly to the Mac's built-in 3.5 mm jack, 智键 mode is selected, another audio output is available, and the HID connection has completed. Quit other apps that might hold the audio remote-control device, then try reconnecting it. Compatibility still needs testing on individual hardware combinations.

**Why is sound no longer coming from the headphone jack?** 智键 mode routes sound to the selected output so audio is not sent into the button. For ordinary headphones, switch to 「音频设备」 (Audio Device) under 「设置 → 通用」 (Settings → General). Pausing actions retains the current device mode and audio protection.

**A script works in Terminal but fails in smartKey.** Scripts run in a noninteractive background shell. The default working directory is the managed script's directory, and your interactive terminal environment is not automatically loaded. Check dependency paths, interpreter, working directory, and environment variables.

**Playback or volume control behaves unexpectedly.** The system's media routing determines which app receives playback commands. Volume and output mute require software control support from the current output device. Output mute is not microphone mute.

**Where is configuration stored, and how do I uninstall?** Configuration and scripts are stored in `~/Library/Application Support/smartKey/`. Changes to `smartKey.conf` reload when saved; manual edits to `actions.json` require a restart. To uninstall, disable 「登录时打开」 (Open at Login), quit the app, and move `/Applications/smartKey.app` to the Trash. To remove personal data as well, back up and manually remove the configuration directory.

## Development and contributions

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Default tests use simulated devices, temporary configuration, and temporary scripts. They do not change real audio outputs or seize real HID hardware. Physical button presses, insertion and removal, system permissions, and sleep / wake behavior still need hardware validation. The GitHub Actions workflow runs tests and builds the app; it cannot replace that validation.

| Directory | Contents |
| --- | --- |
| `Sources/SmartKey` | Jack detection, HID input, gesture recognition, and audio output protection |
| `Sources/SmartKeyActions` | Action definitions, configuration storage, script library, and executors |
| `Sources/smartKeyPopup` | Menu bar, native settings, device setup, and animations |
| `Tests` | Actions, gestures, configuration, device flows, and UI rendering tests |
| `scripts` / `packaging` | Build and installation scripts, icons, and app metadata |

Issues with hardware compatibility reports or clear reproduction steps are welcome, as are code, documentation, and interface localization contributions. Please include your macOS version, Mac model and chip, button model, connection method, and audio output. Remove private information from logs or screenshots. Maintenance capacity is limited, so responses may take time.

The supporting guides below are currently in Chinese:

- [Contribution guide](CONTRIBUTING.md)
- [Detailed usage and configuration](docs/usage.md)
- [Action extensions and script execution](docs/action-development.md)
- [Initial validation record (historical)](docs/v1-validation.md) · [Shortcuts validation record (historical)](docs/shortcuts-validation.md)
- [Maintainer upload and publishing guide](docs/publishing.md)
- [GitHub preparation validation record](docs/github-preparation-validation.md)

## License

Project code is available under the [MIT License](LICENSE). Rights to the linked video and third-party apps, trademarks, and desktop wallpaper appearing in screenshots or recordings belong to their respective owners.
