# Indicator LEDs

Both Switch and Light can program indicator LEDs declared by the optional HA Gesture Bridge integration. Ordinary entity selection, on/off control and dimming remain independent of that integration. LEDs are an explicit indicator capability, separate from the controlled load.

## Configure HA first

1. Add or edit the gesture control in HA Gesture Bridge and select its physical device. Leave **Customize LED mappings (advanced)** unchecked for automatic discovery.
2. Review the detected status indicator capabilities and save. Supported Zooz profiles discover color, mode and brightness directly through the existing Z-Wave JS connection; HA configuration entities can remain disabled. Standard Indicator discovery covers supported visual on/off/brightness controls and excludes identification-only blinking.
3. Refresh the selected gesture entity in Composer. **LED Status** reports the available channels. Direct HA-device mode has no companion LED metadata; choose a gesture control in a button-event mode to use LEDs.

For devices outside automatic support, the companion's advanced setup accepts explicit HA `select` and `number` indicator mappings. Never substitute a relay or target lamp. Discovery does not change smart-bulb mode, scene settings, relay state or DeviceSide execution.

Zooz profiles cover ZEN26, ZEN27, ZEN30, ZEN32, ZEN71, ZEN72, ZEN76, ZEN77 and ZEN78 hardware whose actual LED parameter metadata matches the reviewed schema. ZEN26/27/78 provide fixed-color on/off control, ZEN30 has two indicators and ZEN32 has five. The GE/Enbrighten 46201 / ZW4008 and Jasco 46562 / ZW4008 profiles reuse the same reviewed on/off mode schema. Jeff's Office ZEN76 has one shared indicator, exposed as `toggle`, with white/blue/green/red and 30/60/100% brightness. Do not declare fictional top and bottom LEDs for this device. Other devices can expose their actual independent channels.

## LED behavior in Properties

**LED Behavior** is on the main Properties screen in both drivers. Its default is **Use Device Setting**, which leaves the current hardware behavior alone. Supported devices offer **Follow Load**, **Follow Load (Inverted)**, **Always On** and **Always Off**. Local load means the physical device's own relay/dimmer, rather than an exported or connected C4 light.

The Light also offers **Follow Bound Device** in **Control Connected C4 Light** mode. Selecting it exposes **LED Feedback Source** in the compact screen. Choose the Top, Bottom or Toggle Controller Link connected to the C4 light you want to track. The first selection defaults a disabled source to Top and requests current feedback. Configure each indicator's saved On Color and Off Color for that tracking behavior.

In **HA Light**, use **LED On Color** and **LED Off Color** on the main Properties screen to open Composer's color picker, then click **Set**. These save the same preferences used by programming and native LED commands; they do not change the device's LED behavior or immediately write to the indicator. Black means off when tracking a bound device. The displayed color is adjusted to the device's supported palette. Devices with several indicators also show **LED Indicator** so each can have its own colors; a single indicator is selected automatically. The controls appear when current LED capabilities are available.

Switch supports immediate color, brightness and hardware behavior commands. It has no bound-device tracking policy, so it does not expose On/Off color preferences or an indicator selector for those preferences. Per-indicator immediate commands use their own indicator list.

Choosing a hardware behavior explicitly applies it to all available indicators without changing their stored color. **Use Device Setting** stops C4 tracking and leaves the current hardware mode unchanged; it does not restore an earlier mode. Startup, reconnect and snapshots never reapply a hardware behavior.

## Composer programming

| Command | Meaning |
|---|---|
| Set LED On Color (Light only) | Save the color to use when a bound C4 device reports on. No hardware write. |
| Set LED Off Color (Light only) | Save the color to use when a bound C4 device reports off. No hardware write. |
| Set LED Current Color | Change only the device's stored color, preserving its LED behavior. |
| Set All LED Colors | Change supported color endpoints, preserving behavior. Light also saves both tracking colors. |
| Set LED Brightness | Change supported brightness independently of behavior. |
| Set LED Behavior | Explicitly change one indicator's hardware behavior. |

Use six hexadecimal digits for a supported color, such as `FF0000` for red. On a ZEN76, color changes write parameter 14 only; brightness writes parameter 15 only. Parameter 2 changes only after an explicit hardware behavior selection or configured C4 bound-device feedback.

Black is valid as a saved C4 On Color / Off Color preference: when tracking a bound device, it explicitly turns the indicator off for that state. For an immediate off request, choose **Always Off** in LED Behavior or the programming command. Black is not a writable Zooz color parameter. Fixed-color indicators use behavior commands and do not appear in Set LED Current Color's button choices.

All available indicators appear by name in the command lists. Native Top/Bottom/Toggle choices remain compatible; other choices carry a stable channel ID so saved programming survives label changes. Brightness choices exclude unsupported indicators. Unsupported requests report an explanation in LED Status.

Current color and behavior are confirmed by HA feedback. A queued request is not hardware confirmation. On/off preferences retain stable control/channel identities. The per-channel Set LED Behavior command applies a device setting once; if Follow Bound Device remains selected, later target feedback can override it.

The native Light V2 LED UI is static, so LED commands can remain visible for unsupported devices. The driver checks live metadata before each request. Update HA Gesture Bridge and the C4 package together: the independent-color API requires the companion's LED command version 2. Older metadata remains readable but does not enable new hardware requests.

## Follow a connected C4 light

For Jeff's Office, use **LED Behavior = Follow Bound Device**, then choose the Controller Link attached to the light group in **LED Feedback Source**. All available indicator channels use their own saved On/Off colors for that light's confirmed state. A nonblack tracking color sends an explicit on behavior plus color; black sends an explicit off behavior. This intentionally controls the indicator separately from the Zooz relay.

Use **Actions → Refresh LED Feedback** after changing bindings when you want to apply current target feedback. Ordinary HA snapshots and restored gestures never issue LED writes. **Use Device Setting** disables this feedback policy without changing the device's current setting.

## Qualification

Tests cover actual driver entry points, native/custom color commands, explicit behaviors, all indicator channels, metadata/version rejection and the real HA service boundary. Color-only requests are checked to preserve mode. Physical discovery and configuration reads have been checked against Jeff's Office. Additional-model writes remain simulated until separately qualified.

## Multi-button controls

HA discovery supports up to 32 button inputs. Both C4 drivers register additional inputs as independent named programming events, including all five ZEN32 buttons. Native Light V2 events and direct Controller Links still use Top, Bottom and Toggle. No extra native button IDs or connection bindings are invented.
