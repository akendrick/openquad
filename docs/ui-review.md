# OpenQuad UI/UX review (macOS app)

Scope: `swift/OpenQuadApp/Sources/OpenQuadUI` (and `OpenQuad/OpenQuadApp.swift`), judged against the macOS Human Interface Guidelines, from the point of view of a photographer at the printer. Read-only review; nothing was changed or printed.

**Status:** written 2026-11-22 against main at `d571f1b`. The top 5 changes below were made in PR 75, with one exception: Registration and step wedges stays one section at the owner's request (finding 2's split was not made). The other findings are still open.

## How this was done

- Debug build, snapshots rendered with `--snapshot … --wait 10 --tab <tab> --photo <synthetic 900×600 colour gradient TIFF>`. The snapshots were not kept; re-render them with the same flags.
- **Not covered:** Dark mode (the snapshot mode has no appearance flag and I did not change the system appearance, so every finding about dark mode is from code only: system colours and materials are used throughout, hard-coded `Color.green/accentColor.opacity` fills are the only things worth a look). Mid-run wizard states (after Start, with scan data), the Separations section populated, the Settings window and the How-to guide were read in code, not rendered. The snapshots use the default sidebar state (several sections collapsed), so expanded Separations, Position and Step wedges were judged from code.
- Note for whoever re-renders: the Process Calibration snapshot shows the heading tight against the toolbar and no Wizard/Advanced picker in view; I could not tell whether that is a snapshot artefact (scroll offset) or a real clip. Worth a look in the live app (finding 9).

## Overall impression

The structure is sound and unusually well thought through for a niche tool: a clear tab order (Print, Negative, Contact Sheet, then the two calibrations), a "next step" card in the printer wizard that tells you what to do and offers the one prominent button, collapsed sections that summarise their settings in the header, and plain, helpful explanatory text. The problems are mostly density and consistency: the sidebar is long and carries a lot of explanatory prose, a few labels mean different things in different places, and several states (disabled, busy, empty) give too little feedback.

---

## Findings, ranked by impact

### 1. The Print/Negative sidebar is too long, and the first screen is spent on things you rarely change (High)

**Screens:** Print, Negative (`print.png`, `negative.png`).
**What's wrong:** Before any real control, the photo block takes about a third of the sidebar: file name, Resolution, "Photo's own", a two-line note on Fit to page, and a colour-to-greyscale note. With the three open sections below, the Negative tab already runs off the bottom (the "Guide line in black" row is clipped in `negative.png`) on a 720 pt-high window, and **Print…** is the only thing that never moves. A photographer's real work is: pick toning/process, pick paper and size, print. Those are split between the top (Toning/Negative) and the *bottom* (Printer and size), with registration in between.
**Change:**
- Fold Resolution, "Photo's own" and both notes into one line under the file name ("900 × 600 px · 120 ppi fitted (photo has none)"), and show the editable resolution field only when Fit to page is off, in place of the explanatory sentence. Move the "converted to greyscale" note to the preview caption.
- Reorder to the order of work: Photo → Toning/Negative → Printer and size → Registration and step wedges. Registration/wedges are set-once and belong last.
- Default both Printer and size and Toning open, Registration closed (already the default), and keep all explanatory `.caption` text behind a `ⓘ` popover/`.help` rather than inline (see finding 8).
**Files:** `ContentView.swift` (`controls`, `photoSection`, `resolutionRows`).

### 2. "Registration and step wedges" mixes three different jobs and nests a second disclosure inside the first (High)

**Screen:** Print and Negative, sidebar (`print.png`).
**What's wrong:** One section holds the printable-area fit rule, the darkroom marks (guide line, registration marks) and the step wedge, and the step wedge sits in its own `DisclosureGroup` with a different chevron style and no header weight, inside a `FoldingSection`. "Fit within printable area" is the first row yet it only matters once marks or wedges are on, and its name collides with "Fit to page" in Printer and size (two "fit" controls with different meanings, in two sections). On the Print tab "Fit within printable area" is ambiguous: within the printable area of what? The wedge description row ("Step wedges: none") shows the summary text, but also an expanded state with the toggle directly under it, which repeats the same information.
**Change:**
- Split into two top-level sections, "Marks" (guide line, registration marks, safe edge/outline for negatives, plus the fit rule, renamed "Keep marks inside the printable area") and "Step wedge" (own `FoldingSection`, summary "31 steps, left"). This removes the nested disclosure and gives wedges a header like every other section.
- Rename "Fit within printable area" to "Keep marks inside the printable area" and show it only when a mark or wedge is on.
- Rename "Fit to page" to "Scale to fill the page" so the two no longer share a word.
**Files:** `ContentView.swift` (`controls`, `registrationOptions`, `wedgeControls`).

### 3. Inline explanatory text is the main source of density; it is also the right place to be careful with wording (High)

**Screens:** every tab; worst on Negative and Separations.
**What's wrong:** There are 20+ multi-line `.caption` paragraphs in the sidebar (e.g. `wedgeControls`, `fitWithin`, `registrationOptions`, `DarkroomMarks`, `SeparationControls`, the soft-proof note). Each one is useful once, then permanent clutter; several are 3–4 lines and written in the conditional ("With a colour background the space is opaque like the safe edge (clear film if made separately, when the wedge has its own safe edge); or make it black or white."), which is hard to parse. They also push the Print button's context off screen.
**Change:** keep one short sentence only where a mistake costs a sheet of film (e.g. "Marks print in black, so they block UV"). Move the rest into a `.help` tooltip on the row or an `ⓘ` button that opens a popover, and rewrite the wedge-background text as a single sentence per option: "Colour: the paper (or the negative's own colour)", "Black", "White". The existing guide and the help menu already carry the long explanations.
**Files:** `ContentView.swift`, `DarkroomControls.swift`, `SeparationControls.swift`.

### 4. Feedback while busy and for disabled controls is thin (High)

**Screens:** Print, Negative, Contact Sheet, wizards.
**What's wrong:**
- Print/Negative: a small `ProgressView` appears beside the buttons while `busy`, with no text. While a print file is being built or a separation saved, nothing says what is happening, and **Print…** is simply disabled. When `canPrint` is false because the photo does not fit the page (`session.fitsOnPaper()` throws), the button is dimmed with no explanation. The reason is only in `model.error`, if set. Nothing tells you *why* you cannot print.
- The status and error lines are two stacked `.callout` lines above the buttons; a red error and a grey status share the same position, and neither can be dismissed or selected.
- Contact Sheet: the loading progress is good (bar plus "Opening frame-03.tif (3 of 12) · about 8 s left"), but "Make a Negative" / "Print It" are disabled without a reason while photos are loading or the sheet is empty. "Print It" does not print: it builds the file and *opens it in the Print tab*, which is a surprise (finding 6).
- Wizards: the printer wizard has a spinner at the bottom of the page, far from the button you pressed. Scanning can take a minute; there is no "Scanning…" text or cancel.
**Change:** (a) replace the blank-disabled Print button with a tooltip on the disabled button explaining the reason ("This photo is larger than the page at this size: turn on Fit to page or choose a larger paper"), or show a one-line warning with an icon in the footer; (b) put busy text next to the spinner ("Making the print file…", "Scanning…"); (c) use `Label(…, systemImage: "exclamationmark.triangle.fill")` for errors everywhere, as the wizards already do, and make them selectable; (d) show the spinner next to the pressed button in the wizards.
**Files:** `ContentView.swift` (footer), `AppModel.swift` (`canPrint`, `status`), `ContactSheetView.swift`, `CalibrationWizardView.swift`, `ProcessWizardView.swift`.

### 5. First-run and empty states leave the next action unclear (Medium-High)

**Screens:** Print/Negative with no photo, Contact Sheet (`contact-sheet.png`), wizards (`printer-calibration.png`, `process-calibration.png`).
**What's wrong:**
- Print/Negative: the preview says "Open a photo to begin" but has no button, and the photo isn't droppable (only the contact sheet accepts drops). A photographer's first instinct is to drag a TIFF onto the window.
- Contact Sheet: an empty bordered list about 240 px tall, with "Drag to reorder, or drop photos on the sheet" under it, while the drop target is the *preview pane on the right*, not the list. The empty list takes the most prominent space for nothing.
- Printer Calibration: no scanner is set at first run, and **Start** is enabled; the error surfaces only later. The chart area below shows a large empty chart icon.
- Neither calibration says what you need before you begin (a flatbed scanner, a test print, time). The tabs offer no entry for a user without a scanner.
**Change:** add `.dropDestination` for image files to the Print/Negative preview and to the sidebar photo row; add an **Open Photo…** button to `ContentUnavailableView` (`actions:`); hide the empty contact-sheet list and show a one-line prompt with the Add Photos button until the first photo exists, then size the list to its rows; make the drop zone the whole window; in the printer wizard, disable **Start** (with the reason as help) until a printer and scanner are set, and add a short "What you need" line to the setup card.
**Files:** `ContentView.swift` (`previewPane`), `ContactSheetView.swift`, `CalibrationWizardView.swift`, `ProcessWizardView.swift`.

### 6. Tab and button naming is inconsistent, and some labels promise the wrong thing (Medium-High)

**What's wrong:**
- Contact Sheet's buttons: "Make a Negative" and "Print It". "Print It" does not print, it creates the sheet and sends it to the Print tab; "Make a Negative" likewise sends it to the Negative tab. Clicking either also switches tabs without warning (a green notice appears afterwards).
- "Step wedge" vs "Black and white step wedge" vs "Greyscale step wedge" (Contact Sheet) vs "Step wedges" (section row) are four names for one thing. Use "Grey step wedge" everywhere (and "Colour gamut wedge" for the colour one).
- Spelling is consistent: I found no American "color", "gray" or "center" in user-visible strings. Keep it that way.
- "Choose in the print panel" (Printer picker) is a good escape hatch but reads like a menu command; "Ask each time (print panel)" is clearer.
- The Process Calibration step buttons are numbered ("1. Print Chart Page…", "2. Scan the Contact Print and Read It", "3. Refine the Curves") but the Printer Calibration uses a card with "Step 1/2/3" titles; the two wizards teach the same idea in two vocabularies. Printer wizard says "Round"; process wizard says "Run" and "round" interchangeably.
- Sizes are formatted "7.50 x 10.00 in" (letter x) in the Contact Sheet and "×" elsewhere.
**Change:** rename the Contact Sheet buttons to "Send to Print Tab" and "Send to Negative Tab" (or "Make Sheet for Print" / "Make Sheet for Negative") and keep one default button; standardise wedge naming, the multiplication sign and the Run/Round terms.
**Files:** `ContactSheetView.swift`, `ContentView.swift`, `DarkroomControls.swift`, `Lengths.swift`, `ProcessWizardView.swift`.

### 7. Accessibility is largely absent beyond SwiftUI defaults (Medium-High)

**What's wrong (from code; only 5 explicit accessibility modifiers in the app):**
- The custom `TabBar` is a row of plain buttons in the toolbar with `.isSelected` only. It has no `accessibilityLabel` (the label is an image+text stack, which is read as two items) and no tab-group semantics (`.accessibilityElement(children: .combine)`, `.isTabBar`). ⌘1–⌘5 exist (good), but the tab strip is not reachable as a tab view by VoiceOver and is not a native segmented/tab control.
- Icon-only buttons have `.help` but no accessibility label: the contact-sheet remove (`minus.circle`), coat remove, the "ⓘ"/ellipsis setup menu, notice dismiss. `.help` does give VoiceOver a hint, but not a name.
- The page preview is a drag-only interaction (`DragGesture`) for placing the negative. There is a keyboard-accessible alternative (the From-the-left/From-the-top steppers), which is good, but it is hidden inside a closed "Position on the page" disclosure, and the draggable image has only a label, no `.accessibilityAdjustableAction` or hint "Use the position fields to move".
- Status colour: the wizards' progress ticks rely on green vs orange/grey (`RoundsTable`, `StepChip`). The ✓/✗ glyphs are present in the card text, but the table uses `checkmark.circle.fill` vs `xmark.circle` with no `accessibilityLabel` ("goal met"/"not met").
- The contact-sheet photo list reorders only by dragging; there is no Move Up/Down for keyboard users.
- Charts (`Charts.swift`, `ToneChartView`, `WedgeChartView`) and `SheetPreview` have no accessibility summary. `BandDiagram` has one (good, a model to copy).
**Change:** give the tab bar `.accessibilityLabel(tab.title)`, `.accessibilityElement(children: .ignore)` and a "tab" hint, or switch to `Picker(.segmented)` with `Label` in the toolbar; add `.accessibilityLabel` to every icon-only button; add a one-line `accessibilityLabel`/`Value` to the charts (e.g. "Uncorrected: worst error 4.1 L*; Corrected: 1.2 L*"); add `accessibilityLabel` to the rounds-table ticks; add Move Up/Move Down buttons or `.accessibilityAction(named:)` to contact-sheet rows.
**Files:** `Tabs.swift`, `ContactSheetView.swift`, `SeparationControls.swift`, `CalibrationWizardView.swift` (`RoundsTable`), `Charts.swift`, `PagePreview.swift`.

### 8. Control choice: several controls do not match their meaning (Medium)

- **Steppers used as sliders/number fields** (Negatives count, Step scale, "Negatives 1 | 2 meet at step N", Overlap): one stepper per split point is slow for values like 1–101. Use a number field with stepper or a slider with value label; `Saturation` already uses a slider and reads well.
- **"Fit within" picker with "The page / A set size"** is a two-state picker without a visible label of its own meaning; a segmented control would show both options at once. Same for Process Calibration's Size ("Standard / Fit within a set size").
- **"Sizes" menu** next to the width × height fields has a label with no hint of what it is (presets). Rename "Presets" and add a ▾ indicator (it already shows one in the render, but it looks like a button).
- **Resolution field** is a disabled text field while Fit to page is on, with an explanation sentence. A disabled field that you can't edit is noise; show it as plain text when fitted.
- **Print** is the only primary button, but the footer also holds **Save Print File…** at the same visual weight, split to the far left. Group them at the right, with Print… the default (⏎) and Save secondary; ⌘P works already.
- **Calibration "None (uncorrected)" and Toning "Neutral (no toning)"** are good, plain wording; keep.
**Files:** `ContentView.swift`, `SeparationControls.swift`, `DarkroomControls.swift`.

### 9. Wizard windows and layout: cramped forms and fixed heights (Medium)

**Screens:** `printer-calibration.png`, `process-calibration.png`.
- Process wizard uses fixed `.frame(height: 150)` / `.frame(height: 330)` forms ("the form scrolls"): on a short window the form and the chart compete, and at larger Dynamic Type/larger windows the form stays small. In the render the heading sits right under the toolbar (y≈130 vs 163 on the printer wizard), suggesting the top inset differs between the two wizard pages.
- The process wizard's three rows of buttons ("Start", "1. Print Chart Page…", "…or I Printed It Elsewhere", "New Run…", "2. Scan the Contact Print and Read It", "…or Read a Scan File", "3. Refine the Curves") are all the same weight; there is no prominent "do this next". The printer wizard already solved this with the next-step card (and the Process *Guide* mode does too). Advanced mode should either reuse the card or visually highlight the next enabled step.
- The leading ellipsis in "…or I Printed It Elsewhere" and "…or Read a Scan File" is a writing convention, not a macOS one; use a secondary button style and a separator, e.g. "Printed Elsewhere" / "Read a Scan File…".
- Printer wizard setup grid: Printer/Paper/Print with/Scanner share a 4-column grid, with "Type" as an unlabeled free-text next to Paper (placeholder "plain, matte…" disappears once typed, so the field's meaning is lost). Add a label "Paper type".
- The wizard "Show Log" toggle is global state (`wizardLogShown`) and hides diagnostics that are the only explanation of failures. Surface the last log line next to errors.
- The Wizard/Advanced mode switch and the Blocking/Curve step picker sit in a strip above the content, separate from the toolbar's "New Process"; the toolbar button and "New Run…" overlap in meaning. Rename "New Process" to "Start Over" with a confirmation, since it discards a run.
**Files:** `ProcessWizardView.swift`, `CalibrationWizardView.swift`, `WizardWindows.swift`, `Tabs.swift`, `ProcessGuide.swift`.

### 10. Toolbar tab bar is custom and oversized (Medium-Low)

**Screens:** all (top of every snapshot).
**What's wrong:** Five custom 112 pt-wide icon+caption buttons with a hand-drawn selection highlight (accent colour at 14 %). They work, but: the selection rectangle is tight to the label, labels sit at slightly different baselines ("Print" vs "Contact Sheet" in the render), the bar is centred in the toolbar and shifts when a tab adds a trailing toolbar item (New Calibration / New Process), and the window's minimum width (900 pt) is largely set by it. The two calibration tabs are a different *kind* of thing from the three working tabs but get equal weight.
**Change:** use a native `Picker` with `.pickerStyle(.segmented)` (icons + labels) in the principal toolbar slot, or a visual separator between the three working tabs and the two calibration tabs; fix label baselines by giving the text a fixed line height.
**Files:** `Tabs.swift` (`TabBar`).

### 11. Layout inconsistency between Contact Sheet and Print/Negative (Medium-Low)

`ContactSheetView` does not apply `.controlSize(.small)` as `ContentView` does, so its controls are visibly larger and its sidebar wider (360 vs 340 ideal; max 440 vs 420); the sections use native `Section("Title")` headers while Print/Negative use custom folding rows with chevrons. In the renders the two sidebars look like different apps. Align control size, sidebar width and section style (use `FoldingSection` or plain section headers consistently). The error in the contact sheet is a plain red `Text` inside the form, not a Label with icon.
**Files:** `ContactSheetView.swift`, `ContentView.swift`.

### 12. Smaller issues (Low)

- Section header summaries are truncated with `…` and the summary text is `.caption` grey; the Registration section header can read "0.25 in edge, outlined, guide line, marks, outside, wedge 31 steps…". Use a count ("3 options on") or an icon row instead of a comma list.
- The "Setup" row in Negative: the ellipsis menu (`ellipsis.circle`) hides Save/Delete; discoverability would improve with a visible "Save Setup…" button next to the picker, since saved setups are the main time-saver.
- Setting "sidebar.*" open/closed states persist, but nothing indicates a collapsed section contains a *warning* (e.g. the orange registration note in Separations). Show a small warning glyph in the header when a section has an unresolved issue.
- The quit alert "Keep your photos for next time?" is a good idea; "Start Fresh" should be the non-default and the alert should be dismissible with ⎋ (Cancel is third; make it the cancel button).
- The green notice banner ("The Print tab now uses …") is fine, but it has no timeout and persists when you move to another tab; clear it on next user action.
- `NSOpenPanel`/`NSSavePanel` use `runModal()` (blocks the window); prefer `beginSheetModal` so the panel attaches to the window and Escape/⌘. work as people expect.
- Print confirmation uses `confirm("Print?", …)` with no printer icon or ink warning; the calibration confirm ("Print?" → "uses one sheet and about a quarter page of ink") is better; reuse its pattern.

---

## Top 5 changes to make first

1. **Shorten the Print/Negative sidebar** (finding 1): collapse the photo block to two lines, reorder sections to the order of work, and move explanatory captions into popovers/help (findings 1 and 3). Biggest day-to-day gain, mostly in `ContentView.swift`.
2. **Explain a disabled Print button and give busy text** (finding 4): tell the user why they cannot print and what the app is doing. Cheap, and it prevents the "is it broken?" moment at the printer.
3. **Make first run obvious** (finding 5): drag-and-drop and an Open Photo button on the empty preview, a compact empty state for the contact-sheet list, and Start disabled with a reason in the printer wizard until a printer and scanner are set.
4. **Fix the names that promise the wrong thing** (finding 6, plus 2): "Print It"/"Make a Negative" to "Send to Print/Negative Tab", one name for the step wedge, and split "Registration and step wedges" into two sections with "Keep marks inside the printable area".
5. **Accessibility pass** (finding 7): labels for the tab bar and every icon-only button, chart summaries, keyboard reorder in the contact sheet, and non-colour cues in the rounds table.

*Follow-ups, not in the top five:* the Process Calibration Advanced layout (finding 9), the tab bar (finding 10) and control-size alignment (finding 11).
