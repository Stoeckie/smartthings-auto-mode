# Stoeckie Auto Mode (SmartThings Edge)

Automatic or Manual per zone. Routines pause for a while after someone operates a device by hand (app, wall switch, Hue button, remote, keypad), and continue by themselves afterwards. Everything stays visible and editable in the SmartThings app.

## How it works

* One **Automation** device per zone, e.g. "Automatisch Keuken licht", with an on/off switch: **on = Automatic, off = Manual**, and **Manual until 13:15**. Switch it on to go back to Automatic at once, or off to make it Manual on purpose.
* Your routines for that zone get two extra lines:
  * condition **"Automatisch Keuken licht is Automatic"** (they pause while the zone is Manual; it is also a trigger, so a routine runs again when the zone becomes Automatic and puts things right, for example turns a light off that was left on);
  * first action **"Automatisch Keuken licht: Routine is acting"**, so the changes that routine causes are not taken for manual ones.
* One hidden rule per zone sends a **signal** with the name of the device when one of the zone's devices changes (on/off, level, position, setpoint, mode), and one for every button press. A change only counts as the routine's own when that device starts changing within seconds after "Routine is acting" (lights 10 s, shades and heating 15 s) and keeps moving without pauses; anything else, also a minute after a routine, turns the zone Manual. A button press is always manual. The signal starts with the kind: `light:`, `level:`, `shade:`, `heat:` or `button:` plus the device name. Send brightness changes as `level:` and on/off as `light:`: a lamp that reports its end level later (a Hue lamp reported 48 % right away and 50 % a minute later) then still counts as the routine's while the routine window is open.
* A change of location mode makes all zones Automatic again (and opens the routine window, so the mode's own routines and scenes do not count as manual).

## Settings

| Device | Setting | Default |
|---|---|---|
| Automation zones | Zones (comma separated names, one device each) | empty |
| Automation zones | Time zone (for "manual until") | Central Europe |
| zone | Manual for (minutes): every new manual change starts it again; **0 = Manual until you switch the zone on** (no timer, a mode change does not reset it either) | 120, zones with "heating" or "verwarming" in the name 240, zones with "zonwering", "screen" or "awning" in the name 0 |
| zone | Routine window (seconds) | 120 |

## Install

1. Install the driver from the Stoeckie Edge Drivers channel.
2. App: Add device, Scan nearby. "Automation zones" appears.
3. Enter the zones in its settings. Names with accents (é, ï) are fine.
4. Add the condition and the first action to the routines of each zone, and one hidden or visible rule per zone: "if any device of the zone changes, set the zone to Change seen".

## Tips

* Put each button in a rule of its own. A rule checks all its conditions on every trigger, and a button keeps showing "pushed" after a press, so in a shared rule every light change would look like a button press.
* For "zone is Automatic" do not use "only when it changes": the condition is then only true at the moment the zone switches.

Forum: https://community.smartthings.com/t/312072

## Limits

* A manual change of a device in the first seconds after a routine switched that same device is taken for the routine's own.
* A device that changes by itself (its own schedule, a Hue app automation, a lamp that comes back after a power cut) counts as manual.
* Changes that are not reported (a lamp switched off at the wall) are not seen.
