# Controller text entry on macOS

When TOTK or BotW calls the software keyboard (for example, naming a horse), the Mac window displays a controller keyboard and an editable native text field. No game-code patch is needed.

The field still accepts physical keyboard input, selection, paste and input methods. Return confirms and Escape cancels. The on-screen keys are also clickable. The layout scales to fit the window. It does not provide an on-screen IME: its character pages cover Latin letters, French accents, digits and common punctuation; other scripts remain available through the Mac's input methods.

## Controller shortcuts

| Action | PlayStation | Xbox | Switch |
|---|---|---|---|
| Move between keys | D-pad / left stick | D-pad / left stick | D-pad / left stick |
| Enter selected key | × | A | A |
| Cancel text entry | ○ | B | B |
| Delete previous character or selection | □ | X | Y |
| Space | △ | Y | X |
| Toggle uppercase/lowercase | L3 | Left stick click | Left stick click |
| Toggle AZERTY/QWERTY | R3 | Right stick click | Right stick click |
| Move text cursor left/right | L1 / R1 | LB / RB | L / R |
| Toggle letters/symbols | L2 | LT | ZL |
| Confirm text | R2 / Options | RT / Menu | ZR / + |

Shortcut badges appear directly on the relevant keys, with shoulder-button cursor controls beside the text field and a compact navigation footer. The labels follow the runtime's controller type (automatic detection or the existing controller-type setting). Controller keyboard actions use physical positions, so a gameplay remap or tap/toggle binding cannot prevent text entry. Switch A selects at the east position; Xbox and PlayStation select at the south position. Unknown controllers use the south/east convention and positional labels. When multiple controllers are connected the existing first-controller detection determines the labels and convention.

Labels are available in English, French and Chinese, using the macOS preferred language and respecting `TOTK_UI_LANG`.

AZERTY is the initial choice when macOS's preferred language is French, otherwise QWERTY. The chosen layout is saved in `keyboard-layout.txt` beside `controls.txt`, using the existing setting-file helpers. Case and symbol mode reset for each request. Numeric-only requests show a number pad; case, layout, symbol and space shortcuts do nothing there.

## Input ownership and validation

- Gamepad input is suppressed for the guest while the text panel is open. It resumes only after the held buttons and sticks have been released.
- The opening button, focus changes and controller disconnection cannot select an accidental key: navigation waits for neutral input. D-pad/stick navigation repeats after a short delay; confirmation does not repeat.
- Short taps are latched separately for the panel, so guest HID polling cannot consume its button presses. UI presses cannot activate persistent gameplay tap/toggle bindings.
- The game's minimum, maximum UTF-16 length and disabled-character flags are respected. Text is limited at composed-character boundaries rather than cutting a surrogate pair or accent sequence in half. Empty text is accepted only when the request permits it.
- Native marked text is preserved while an input method is composing. Controller insertion, deletion and caret movement do not interrupt that composition.
- Completion invalidates the panel's timer and signals the waiting guest once. A second concurrent keyboard request is cancelled rather than replacing and stranding the first one.

## Validation without game content

From the repository root, on macOS:

```sh
python3 games/totk/tests/text_keyboard/test.py
python3 games/totk/tests/command_q/test.py
python3 -m unittest discover -s tests
```

The first command compiles the actual AppKit view and gamepad implementation. It checks navigation, shortcuts for all three controller families, selection replacement, paste filtering, numeric/secure fields, UTF-16 limits, IME composition, input capture/release, stale Switch HID fallback, resize and layout persistence. A second probe exercises `runtime_front_text_input` from a waiting thread, repeated completion/cancellation and concurrent requests.

```sh
python3 games/totk/tests/text_keyboard/test.py --preview
python3 games/totk/tests/text_keyboard/test.py /tmp/keyboard.png
```

The preview uses a temporary settings folder and does not read or write game files, keys or saves. The PNG option renders a deterministic PlayStation/AZERTY fixture. These probes do not replace an in-game test of the software-keyboard call on each supported game version.

The UI is macOS-only. The shared controller code retains its normal path when text capture is inactive; iOS does not call the new capture functions.
