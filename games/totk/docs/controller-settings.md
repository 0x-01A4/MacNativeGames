# Controller settings on macOS

Press both triggers and click the left stick together to toggle the settings panel:

| Controller | Open / close | Select | Back |
| --- | --- | --- | --- |
| PlayStation | L2 + R2 + L3 | × | ○ |
| Xbox | LT + RT + LS | A | B |
| Switch | ZL + ZR + left stick click | A | B |

Use the D-pad or left stick up/down to select a row. Left/right changes its value. Select cycles a choice, toggles a switch or activates the selected footer button. Disabled options are skipped. A mint outline identifies the selected row, and the footer shows the current controller labels. The existing mouse controls and keyboard shortcuts (1 and Escape) remain available.

The shortcut uses simultaneous physical button states, before gameplay remapping, and fires once per hold. Separate successive taps do not count as a chord. The complete chord is blocked from gameplay before the UI timer runs. Buttons pressed individually before the chord is complete retain their normal gameplay behavior.

While settings are open, gameplay receives no controller input. Closing waits for held buttons and sticks to return to neutral. Focus loss and controller disconnection disarm navigation until neutral input is seen again. Settings cannot open over the text keyboard; a software-keyboard request closes settings first, and the settings timer never consumes the keyboard's input edges.

The shortcut is enabled by the macOS frontend only. iOS retains its existing input path.

## Verification

```sh
python3 games/totk/tests/settings_controller/test.py
python3 games/totk/tests/settings_controller/test.py --preview
python3 games/totk/tests/text_keyboard/test.py
python3 games/totk/tests/command_q/test.py
python3 -m unittest discover -s tests
```

The settings probe compiles the actual frontend and gamepad implementation. It verifies the chord latch, gameplay suppression, disabled rows, choice and switch changes, each controller convention, navigation repeat, focus recovery and exclusion with text entry. The preview uses a temporary controls directory and graphics-setting stubs: it does not modify the installed game's settings or saves.

This change builds on the input capture introduced by the controller text keyboard. Keep the settings changes in a separate pull request after that prerequisite is merged.
