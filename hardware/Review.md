# obd2Dash compact prototype revision

The board outline has been reduced from **95 × 54.5 mm to 82.5 × 49 mm**, a **21.9% reduction in PCB area** (5,177.5 to 4,042.5 mm²). This is the PCB outline, not the assembled envelope: the USB connector and ESP32 antenna extend beyond it.

Open `obd2Dash.kicad_pro` in KiCad 10 with the other files in this folder. The original OneDrive project was not modified. The schematic, component values, net assignments, and two-layer construction are preserved.

## What changed

- Moved the DE-9 connector J1 10 mm inward and moved fuse F1 5 mm upward; reduced unused space at the left and top edges.
- Rerouted the J1 power feed and CANH/CANL connections to accommodate the connector move.
- Replaced the long IO4/IO5 routes around the lower and right edges with shorter routes on the back layer. This removes the copper-at-the-board-edge defects.
- Connected the previously isolated C3 ground, R7 3.3 V supply, and J2 CC2 connection to R3.
- Adjusted the ESP32 enable trace near SW2 to restore clearance.
- Added a front ground pour, retained the back ground pour, and refilled both. The ESP32 footprint's antenna keepout remains present, prohibiting tracks, vias, and zone fill.
- Corrected USB ground thermal connections and SW2 ground thermal clearance.
- Increased the twelve 0.20 mm ESP32 ground-pad holes to 0.30 mm to meet the existing minimum-hole rule. This is a deliberate footprint customization; the associated copper pads are retained and pass annular-width checks.
- Corrected the undersized fuse reference text and moved board-edge-crossing connector/module graphics to the fabrication layer. Repositioned J1's reference inside the outline.

## Verification

Checked with KiCad CLI **10.0.4**, with copper zones refilled and schematic parity enabled.

| Check | Original | Revised |
|---|---:|---:|
| DRC errors, excluding separately reported missing connections | 51 | 0 |
| Missing connections | 3 | 0 |
| Schematic parity issues | 0 | 0 |
| DRC warnings | 28 | 1 |

The original 79 DRC violations comprised 29 clearance, 8 copper-edge clearance, 12 hole-size, 2 incomplete thermal relief, 2 dangling-via, 3 silkscreen-edge, 1 text-height, and 22 unavailable-library findings. The three missing connections were reported separately.

The remaining warning is **U1 footprint does not match the RF_Module library copy**. It is visible in `drc-final.json` and has not been excluded. Local footprint libraries are bundled as project snapshots to make the supplied project portable; they are not independent manufacturer verification of the footprints. Review the customized ESP32 footprint before updating it from any library, since a library update could overwrite its drill and graphics changes.

The project retains its existing rule severities and exclusions. It adds one narrowly scoped rule in `obd2Dash.kicad_dru`: **0.15 mm clearance between pads of J2 only**, matching the supplied USB4085 footprint's pad spacing. Other default net clearance remains 0.20 mm; minimum copper-to-board-edge clearance remains 0.50 mm. Confirm that the chosen fabricator supports 0.15 mm spacing. This rule acknowledges the connector geometry; it is not a rerouting repair or a blanket relaxation of clearances. See [GCT's USB4085 documentation](https://gct.co/connector/usb4085) when checking the exact connector variant and land pattern.

The original USB D+/D− routes were retained. Their total segment lengths are approximately 45.78 mm and 45.65 mm, respectively; these totals include connector branches and are not a full differential-path or signal-integrity measurement. No controlled-impedance stackup was supplied, so USB impedance has not been validated. DRC does not verify signal integrity, EMC, thermal performance, or power-supply stability.

Native top and bottom copper plots were exported and visually reviewed. The PNG shows the top copper and silkscreen; the SVG files preserve more detail. The bottom plot is viewed through the board from above, not mirrored for assembly.

## Electrical issues still present in the source design

These were identified during the layout review and are not solved by reconnecting the existing nets:

1. **AP2112 USB regulator U4 has no local input or output capacitor in the supplied schematic.** C1 is on the vehicle-side converter input; C2 is on the combined 3.3 V rail after U5; C3 is on ESP32 EN. Add suitable local capacitors at U4 VIN and VOUT as part of a schematic revision. The manufacturer's typical application uses 1 µF input and output capacitors. [AP2112 datasheet](https://www.diodes.com/datasheet/download/AP2112.pdf).
2. **TCAN337 U3 has no dedicated local supply bypass capacitor.** Its shared bulk capacitor C2 is some distance away. Add a local 100 nF ceramic bypass at U3 VCC/GND and review bulk decoupling. [TI TCAN337 datasheet](https://www.ti.com/lit/ds/symlink/tcan337.pdf).
3. **The vehicle-input protection parts are not fully specified.** D1 is labeled only `D_Zener`, D2 only `D_Schottky`, and F1's 0.75 A value differs from the current footprint's `1812L200_12DR` name. Verify actual part numbers, ratings, and land patterns before ordering. This review does not establish automotive transient immunity or validate simultaneous vehicle/USB power operation.

The antenna overhang and keepout were preserved, consistent with Espressif's preference for placing the module antenna outside the base board. The assembled enclosure and nearby metal still need consideration. [Espressif PCB layout guidance](https://docs.espressif.com/projects/esp-hardware-design-guidelines/en/latest/esp32s3/pcb-layout-design.html).

## Further size reduction

This revision keeps the current parts and most of the established placement. Additional reduction would require a broader rearrangement of the regulator, USB circuit, and switches. The through-hole DE-9 connector, two large pushbuttons, and ESP32 module are the major physical constraints. A smaller connector or smaller switches would permit a more substantial reduction but would change the parts list. The present revision is a compact, connected prototype layout for review, not a fabrication-qualified electrical design.

## Included files

- Native board, unchanged schematic, project settings, and connector-specific design rule.
- Project-local footprint libraries and `fp-lib-table`.
- Original and final machine-readable DRC reports.
- `top.svg`, `bottom.svg`, and `top.png` previews.

