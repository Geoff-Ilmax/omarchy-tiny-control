import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// tiny-control bar widget: one widget for every connected OBSBOT camera.
//
// The camera picked in the drop-down becomes tinyctl's "selected" camera
// (`tinyctl select`), so the keybindings and menu snippets that use
// `-c selected` follow the same choice. Every command names the camera
// explicitly (`tinyctl -c <serial> …`); nothing acts on an implicit default.
// Switches show confirmed camera state; persistent intent is enforced per
// camera by tiny-guard.
Panel {
  id: root
  moduleName: "io.github.geoff-ilmax.tiny-control"
  ipcTarget: "io.github.geoff-ilmax.tiny-control"
  manageIpc: false

  // --- cameras (from `tinyctl list --json`; sysfs + cached serials, cheap) ---
  property var cameras: []          // [{ id, label, model, usb_power, selected }]
  property string selectedId: ""    // serial (or port-…) of the selected camera
  readonly property var selectedCam: {
    for (var i = 0; i < cameras.length; i++)
      if (cameras[i].id === selectedId) return cameras[i]
    return null
  }
  readonly property bool present: cameras.length > 0
  readonly property bool haveCam: selectedCam !== null
  readonly property string camLabel: haveCam ? selectedCam.label : "No camera selected"
  readonly property string powerState: haveCam ? selectedCam.usb_power : "unknown"

  // --- selected camera state, refreshed while the popup is open ---
  property bool stateValid: false
  property string actionError: ""
  property string powerPolicy: "auto"
  property bool guardActive: false
  readonly property bool busy: actionProc.running || statusProc.running || selectProc.running
  property bool asleep: false
  property string tracking: "off"
  property bool autoWb: true
  property int wbTemp: 4000
  property bool hdr: false
  // Gimbal (UVC readback = last host-commanded angle; see tinyctl README).
  property real panDeg: 0
  property real tiltDeg: 0
  property int zoomVal: 0
  property real panMin: -130
  property real panMax: 130
  property real tiltMin: -90
  property real tiltMax: 90
  // 5° steps; "Fine control" switches to 1°.
  property bool fineControl: false
  readonly property int gimbalStep: fineControl ? 1 : 5
  readonly property bool tracking_on: tracking !== "off"

  // Tracking modes this model supports (from `tinyctl support --json`).
  property var trackModes: []
  // On-camera presets (from `tinyctl preset list --json`).
  property var presets: []          // [{ slot, occupied, name, power_on }]
  property int powerOnSlot: 0

  // Preview capture resolution, chosen in the popup dropdown.
  property string previewRes: "1920x1080"

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fam: bar ? bar.fontFamily : Style.font.family
  readonly property real rowW: Style.space(300)

  // Whimsy: a little rotating tagline under the header, and a live pulse.
  readonly property var phrases: [
    "Watching the room",
    "Framing you up",
    "Lights, camera…",
    "Eyes on you",
    "Keeping you centered",
    "Ready for your close-up",
    "Rolling",
    "Looking sharp"
  ]
  property int phraseIndex: 0
  property real pulse: 1.0

  // Status label -> the `tinyctl support` command that gates it.
  readonly property var allModes: [
    { value: "normal", label: "Normal", cmd: "track on" },
    { value: "upper-body", label: "Upper body", cmd: "track upper" },
    { value: "close-up", label: "Close-up", cmd: "track close" },
    { value: "headless", label: "Headless", cmd: "track headless" },
    { value: "lower-body", label: "Lower body", cmd: "track lower" },
    { value: "group", label: "Group", cmd: "track group" },
    { value: "hand", label: "Hand", cmd: "track hand" },
    { value: "whiteboard", label: "Whiteboard", cmd: "track whiteboard" },
    { value: "desk", label: "Desk", cmd: "track desk" }
  ]

  // A control row where ONLY the switch is clickable (unlike the stock Toggle,
  // which makes the whole row a hit target). Label + optional sub-label on the
  // left, a ToggleSwitch on the right.
  component SwitchRow: Item {
    id: sr
    property string label: ""
    property string sub: ""
    property bool value: false
    property color fg: "white"
    property string fam: Style.font.family
    signal switched()
    enabled: root.stateValid && !root.busy
    opacity: root.stateValid ? 1 : 0.5
    width: parent ? parent.width : Style.space(300)
    implicitHeight: Math.max(labelCol.implicitHeight, sw.implicitHeight) + Style.space(12)
    Column {
      id: labelCol
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)
      Text {
        text: sr.label
        color: sr.fg
        font.family: sr.fam
        font.pixelSize: Style.font.subtitle
      }
      Text {
        text: sr.sub
        visible: sr.sub !== ""
        color: Qt.darker(sr.fg, 1.4)
        font.family: sr.fam
        font.pixelSize: Style.font.caption
      }
    }
    ToggleSwitch {
      id: sw
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: sr.value
      foreground: sr.fg
      onToggled: sr.switched()
    }
  }

  // Report the bar-slot size from the icon button, or the bar collapses this
  // widget to zero width and nothing shows (mirrors omarchy.power).
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // --- data plumbing ---

  function refreshCameras() {
    if (!listProc.running) listProc.running = true
    if (!guardProc.running) guardProc.running = true
  }
  function refreshStatus() {
    if (!haveCam || statusProc.running || actionProc.running) return
    statusProc.running = true
  }
  function refreshCameraInfo() {
    if (!haveCam) return
    if (!supportProc.running) supportProc.running = true
    if (!presetProc.running) presetProc.running = true
  }

  // Run a command against the selected camera.
  function act(args) {
    if (root.busy || !haveCam) return
    root.actionError = ""
    actionProc.command = ["tinyctl", "-c", root.selectedId].concat(args)
    actionProc.running = true
  }

  // Step the gimbal from its last known position, within the camera's range.
  function nudgePan(dir) {
    var t = Math.max(root.panMin, Math.min(root.panMax, Math.round(root.panDeg + dir * root.gimbalStep)))
    root.panDeg = t
    root.act(["pan", String(t)])
  }
  function nudgeTilt(dir) {
    var t = Math.max(root.tiltMin, Math.min(root.tiltMax, Math.round(root.tiltDeg + dir * root.gimbalStep)))
    root.tiltDeg = t
    root.act(["tilt", String(t)])
  }
  function nudgeZoom(dir) {
    var t = Math.max(0, Math.min(100, root.zoomVal + dir * 10))
    root.zoomVal = t
    root.act(["zoom", String(t)])
  }

  function selectCamera(id) {
    if (id === root.selectedId || selectProc.running) return
    root.actionError = ""
    root.stateValid = false
    root.presets = []
    root.trackModes = []
    selectProc.command = ["tinyctl", "select", id]
    selectProc.running = true
  }

  function preview() {
    if (haveCam) Quickshell.execDetached(["tiny-preview", root.selectedId, root.previewRes])
  }

  // Panel base's open() — refresh full state as the popup appears.
  function open() {
    refreshCameras()
    refreshStatus()
    refreshCameraInfo()
    root.controller.show()
  }

  Component.onCompleted: refreshCameras()

  Timer { interval: 8000; running: true; repeat: true; onTriggered: root.refreshCameras() }
  Timer { interval: 1000; running: root.opened; repeat: true; onTriggered: root.refreshStatus() }

  Process {
    id: listProc
    command: ["tinyctl", "list", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var j = JSON.parse(text)
          var cams = []
          var sel = ""
          for (var i = 0; i < j.length; i++) {
            var c = j[i]
            cams.push({
              id: String(c.camera),
              label: c.alias ? (c.alias + " · " + c.model.replace("OBSBOT ", ""))
                             : (c.model.replace("OBSBOT ", "") + " · " + c.camera),
              model: String(c.model),
              usb_power: String(c.usb_power || "unknown"),
              selected: c.selected === true
            })
            if (c.selected === true) sel = String(c.camera)
          }
          var changed = sel !== root.selectedId
          root.cameras = cams
          root.selectedId = sel
          if (changed) {
            root.stateValid = false
            if (root.opened) { root.refreshStatus(); root.refreshCameraInfo() }
          }
        } catch (e) {
          root.cameras = []
          root.stateValid = false
        }
      }
    }
  }

  Process {
    id: selectProc
    stderr: StdioCollector { id: selectStderr; waitForEnd: true }
    onExited: function(code, status) {
      if (code !== 0 || status !== 0) root.actionError = selectStderr.text.trim() || "Could not select the camera"
      root.refreshCameras()
    }
  }

  Process {
    id: actionProc
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(code, status) {
      if (code !== 0 || status !== 0) root.actionError = actionStderr.text.trim() || "Camera command failed"
      root.refreshStatus()
      root.refreshCameras()
    }
  }

  Process {
    id: guardProc
    command: ["systemctl", "--user", "is-active", "tiny-guard.service"]
    onExited: function(code, status) { root.guardActive = code === 0 && status === 0 }
  }

  // Rotate the tagline only while the popup is open.
  Timer {
    interval: 3200
    running: root.opened
    repeat: true
    onTriggered: root.phraseIndex = (root.phraseIndex + 1) % root.phrases.length
  }

  Process {
    id: statusProc
    command: ["tinyctl", "-c", root.selectedId, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var j = JSON.parse(text)
          if (typeof j.asleep !== "boolean" || typeof j.tracking !== "string"
              || typeof j.hdr !== "boolean" || typeof j.auto_wb !== "boolean") throw new Error("Incomplete status")
          if (String(j.camera) !== root.selectedId) return  // stale reply after a switch
          root.asleep = j.asleep
          root.powerPolicy = j.power_policy || "auto"
          root.tracking = String(j.tracking || "off")
          root.autoWb = j.auto_wb === true
          root.wbTemp = j.wb_temp | 0
          root.hdr = j.hdr === true
          root.panDeg = Number(j.pan_deg) || 0
          root.tiltDeg = Number(j.tilt_deg) || 0
          root.zoomVal = j.zoom | 0
          if (j.pan_range) { root.panMin = j.pan_range[0]; root.panMax = j.pan_range[1] }
          if (j.tilt_range) { root.tiltMin = j.tilt_range[0]; root.tiltMax = j.tilt_range[1] }
          root.stateValid = true
        } catch (e) {
          root.stateValid = false
        }
      }
    }
  }

  Process {
    id: supportProc
    command: ["tinyctl", "-c", root.selectedId, "support", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var j = JSON.parse(text)
          var unsupported = {}
          for (var i = 0; i < j.features.length; i++)
            if (j.features[i].support === "unsupported") unsupported[j.features[i].command] = true
          var modes = []
          for (var k = 0; k < root.allModes.length; k++)
            if (!unsupported[root.allModes[k].cmd])
              modes.push({ value: root.allModes[k].value, label: root.allModes[k].label })
          root.trackModes = modes
        } catch (e) {
          root.trackModes = []
        }
      }
    }
  }

  Process {
    id: presetProc
    command: ["tinyctl", "-c", root.selectedId, "preset", "list", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var j = JSON.parse(text)
          var list = []
          for (var i = 0; i < j.presets.length; i++) {
            var p = j.presets[i]
            if (p.occupied)
              list.push({ slot: p.slot, name: p.name ? String(p.name) : "", power_on: p.power_on === true })
          }
          root.presets = list
          // The slot whose pose matches the power-on pose, else the slot the
          // power-on state was copied from (the Tiny 3 reports no positions).
          root.powerOnSlot = !j.power_on ? 0
            : (j.power_on.slot || j.power_on.copied_from || 0)
        } catch (e) {
          root.presets = []   // model without readable presets, or none saved
        }
      }
    }
  }

  // --- bar icon ---

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Nerd Font webcam glyph.
    text: "󰖠"
    // Full opacity whenever a camera is present; faint only when none is.
    opacity: root.present ? 1.0 : 0.4
    tooltipText: root.present ? root.camLabel : "No OBSBOT camera connected"
    // Gentle "live" pulse while the selected camera is in use (USB active).
    scale: (root.powerState === "active") ? root.pulse : 1.0
    Behavior on opacity { NumberAnimation { duration: 220 } }
    Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
    onPressed: function(b) {
      if (b === Qt.MiddleButton) { root.preview(); return }
      if (b === Qt.RightButton) { root.act(["toggle"]); return }
      root.toggle()
    }
  }

  // The heartbeat that drives the icon's live pulse.
  SequentialAnimation on pulse {
    running: root.powerState === "active"
    loops: Animation.Infinite
    NumberAnimation { to: 1.14; duration: 720; easing.type: Easing.InOutSine }
    NumberAnimation { to: 1.0; duration: 720; easing.type: Easing.InOutSine }
  }

  // --- popup ---

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.rowW)
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(6)

        // Entrance: fade in and rise with a little overshoot each time the
        // popup opens.
        opacity: 0
        transform: Translate { id: slideT; y: 16 }
        Connections {
          target: root
          function onOpenedChanged() {
            if (root.opened) revealAnim.restart()
          }
        }
        Component.onCompleted: if (root.opened) { column.opacity = 1; slideT.y = 0 }
        ParallelAnimation {
          id: revealAnim
          NumberAnimation { target: column; property: "opacity"; from: 0; to: 1; duration: 240; easing.type: Easing.OutCubic }
          NumberAnimation { target: slideT; property: "y"; from: 16; to: 0; duration: 340; easing.type: Easing.OutBack }
        }

        PanelSectionHeader {
          text: "OBSBOT CAMERAS"
          foreground: root.fg
        }

        // Whimsical rotating tagline (soft crossfade on change).
        Text {
          id: tagline
          width: parent.width
          color: Color.accent
          font.family: root.fam
          font.pixelSize: Style.font.caption
          font.italic: true
          elide: Text.ElideRight
          text: root.present ? root.phrases[root.phraseIndex] : "Say hi to the camera"
          opacity: 0.85
          Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.InOutSine } }
          Connections {
            target: root
            function onPhraseIndexChanged() { tagline.opacity = 0; taglineIn.restart() }
          }
          Timer { id: taglineIn; interval: 180; onTriggered: tagline.opacity = 0.85 }
        }

        // Camera picker: sets tinyctl's selected camera (shared with hotkeys).
        Dropdown {
          width: parent.width
          visible: root.present
          label: "Camera"
          value: root.selectedId
          options: {
            var o = root.haveCam ? [] : [{ value: "", label: "Choose a camera…" }]
            for (var i = 0; i < root.cameras.length; i++)
              o.push({ value: root.cameras[i].id, label: root.cameras[i].label })
            return o
          }
          onChanged: function(v) { if (v !== "") root.selectCamera(v) }
        }

        Text {
          width: parent.width
          color: Qt.darker(root.fg, 1.2)
          font.family: root.fam
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          text: !root.present ? "No OBSBOT camera connected"
            : !root.haveCam ? "Pick a camera to control it"
            : !root.stateValid ? "Camera state unavailable"
            : ((root.asleep ? "Asleep" : "Awake")
               + " · tracking " + root.tracking
               + " · WB " + (root.autoWb ? "auto" : (root.wbTemp + "K"))
               + (root.hdr ? " · HDR" : ""))
        }

        PanelSeparator { foreground: root.fg }

        Text {
          width: parent.width
          visible: root.actionError !== ""
          text: root.actionError
          color: Color.accent
          wrapMode: Text.WordWrap
          font.pixelSize: Style.font.caption
        }
        Text {
          width: parent.width
          visible: root.haveCam
          text: root.busy ? "Checking camera…" : "Power: " + root.powerPolicy + (root.guardActive ? " · guard active" : " · guard not running")
          color: root.fg
          font.pixelSize: Style.font.caption
        }
        // Switches show confirmed hardware state; serialize actions and surface errors.
        SwitchRow {
          width: parent.width
          visible: root.haveCam
          label: "Awake"
          sub: root.asleep ? "camera asleep" : ""
          value: !root.asleep
          fg: root.fg
          fam: root.fam
          onSwitched: root.act([root.asleep ? "wake" : "sleep"])
        }
        SwitchRow {
          width: parent.width
          visible: root.haveCam
          label: "AI tracking"
          value: root.tracking !== "off"
          fg: root.fg
          fam: root.fam
          onSwitched: root.act(["track", root.tracking === "off" ? "on" : "off"])
        }
        Dropdown {
          width: parent.width
          visible: root.haveCam && root.trackModes.length > 0
          enabled: root.stateValid && !root.busy
          label: "Tracking mode"
          value: root.tracking
          options: {
            var o = [{ value: "off", label: "Off" }]
            for (var i = 0; i < root.trackModes.length; i++) o.push(root.trackModes[i])
            return o
          }
          onChanged: function(v) { if (v !== root.tracking) root.act(["track", v]) }
        }
        SwitchRow {
          width: parent.width
          visible: root.haveCam
          label: "HDR"
          value: root.hdr
          fg: root.fg
          fam: root.fam
          onSwitched: root.act(["hdr", root.hdr ? "off" : "on"])
        }
        SwitchRow {
          width: parent.width
          visible: root.haveCam
          label: "Auto white balance"
          sub: root.autoWb ? "" : ("pinned " + root.wbTemp + "K")
          value: root.autoWb
          fg: root.fg
          fam: root.fam
          onSwitched: root.act(["wb", root.autoWb ? "pin" : "auto"])
        }

        // On-camera presets (the same slots OBSBOT Center uses). Recall also
        // applies the preset's saved tracking and image settings.
        PanelSeparator { foreground: root.fg; visible: root.haveCam && root.presets.length > 0 }
        Repeater {
          model: root.haveCam ? root.presets : []
          delegate: Button {
            required property var modelData
            width: column.width
            leftAlign: true
            foreground: root.fg
            enabled: root.stateValid && !root.busy && !root.asleep
            text: "Preset " + modelData.slot
                  + (modelData.name !== "" ? " · " + modelData.name : "")
                  + (root.powerOnSlot === modelData.slot ? "  (power-on)" : "")
            onClicked: root.act(["preset", "recall", String(modelData.slot)])
          }
        }

        PanelSeparator { foreground: root.fg; visible: root.haveCam }

        Button {
          width: parent.width
          visible: root.haveCam
          foreground: root.fg
          text: "Wake automatically for calls"
          enabled: !root.busy
          onClicked: root.act(["auto"])
        }

        // --- gimbal ---
        PanelSeparator { foreground: root.fg; visible: root.haveCam }
        Text {
          width: parent.width
          visible: root.haveCam
          color: root.fg
          font.family: root.fam
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          text: "Gimbal · pan " + Math.round(root.panDeg) + "°, tilt " + Math.round(root.tiltDeg)
                + "°, zoom " + root.zoomVal
                + (root.tracking_on ? "\nAI tracking is steering — turn it off to move manually" : "")
        }
        // D-pad: up on top, left / center / right in the middle, down below.
        Item {
          visible: root.haveCam
          width: parent.width
          implicitHeight: pad.implicitHeight
          Grid {
            id: pad
            anchors.horizontalCenter: parent.horizontalCenter
            columns: 3
            spacing: Style.space(4)
            readonly property real cell: Style.space(76)
            readonly property real cellH: Style.space(52)
            readonly property bool can: root.stateValid && !root.busy && !root.asleep && !root.tracking_on
            Item { width: pad.cell; height: pad.cellH }
            Button { width: pad.cell; height: pad.cellH; foreground: root.fg; text: "▲"; enabled: pad.can; onClicked: root.nudgeTilt(1) }
            Item { width: pad.cell; height: pad.cellH }
            Button { width: pad.cell; height: pad.cellH; foreground: root.fg; text: "◀"; enabled: pad.can; onClicked: root.nudgePan(1) }
            Button { width: pad.cell; height: pad.cellH; foreground: root.fg; text: "⌖"; enabled: pad.can; onClicked: root.act(["recenter"]) }
            Button { width: pad.cell; height: pad.cellH; foreground: root.fg; text: "▶"; enabled: pad.can; onClicked: root.nudgePan(-1) }
            Item { width: pad.cell; height: pad.cellH }
            Button { width: pad.cell; height: pad.cellH; foreground: root.fg; text: "▼"; enabled: pad.can; onClicked: root.nudgeTilt(-1) }
            Item { width: pad.cell; height: pad.cellH }
          }
        }
        Row {
          id: zoomRow
          visible: root.haveCam
          width: parent.width
          spacing: Style.space(4)
          readonly property real cell: (width - spacing) / 2
          readonly property bool can: root.stateValid && !root.busy && !root.asleep
          Button { width: zoomRow.cell; foreground: root.fg; text: "Zoom −"; enabled: zoomRow.can; onClicked: root.nudgeZoom(-1) }
          Button { width: zoomRow.cell; foreground: root.fg; text: "Zoom +"; enabled: zoomRow.can; onClicked: root.nudgeZoom(1) }
        }
        SwitchRow {
          width: parent.width
          visible: root.haveCam
          label: "Fine control"
          sub: root.fineControl ? "1° steps" : "5° steps"
          value: root.fineControl
          fg: root.fg
          fam: root.fam
          onSwitched: root.fineControl = !root.fineControl
        }
        PanelSeparator { foreground: root.fg; visible: root.haveCam }
        Dropdown {
          width: parent.width
          visible: root.haveCam
          label: "Preview resolution"
          value: root.previewRes
          options: [
            { value: "1280x720", label: "720p" },
            { value: "1920x1080", label: "1080p" },
            { value: "3840x2160", label: "2160p (4K)" }
          ]
          onChanged: function(v) { root.previewRes = v }
        }

        Button {
          width: parent.width
          visible: root.haveCam
          leftAlign: true
          foreground: root.fg
          text: "Live preview"
          onClicked: root.preview()
        }
      }
    }
  }
}
