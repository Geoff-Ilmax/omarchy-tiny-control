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
  // Only the user's own commands count as busy. The once-a-second status
  // poll does not, so the popup never flickers or drops a click because of
  // it (tinyctl serializes camera access itself).
  readonly property bool busy: actionProc.running || selectProc.running
  property bool asleep: false
  property string tracking: "off"
  property bool autoWb: true
  property int wbTemp: 4000
  property bool hdr: false
  // Popup tab: 0 Camera, 1 Gimbal, 2 Image.
  property int currentTab: 0
  // {hue:{value,min,max,default}, contrast:…} from `status --json`.
  property var imageCtl: ({})
  property bool imageFine: false
  // Gimbal (UVC readback = last host-commanded angle; see tinyctl README).
  property real panDeg: 0
  property real tiltDeg: 0
  property int zoomVal: 0
  property real panMin: -130
  property real panMax: 130
  property real tiltMin: -90
  property real tiltMax: 90
  // Per-camera pad preferences, saved by tinyctl in the camera's config
  // section (`tinyctl -c <cam> ui …`) and read back through `status --json`.
  // 5° steps; "Fine control" switches to 1°. The swaps invert one axis each.
  property bool fineControl: false
  property bool swapPan: false
  property bool swapTilt: false
  readonly property int gimbalStep: fineControl ? 1 : 5
  // Modes where the camera steers the gimbal itself. Desk mode only frames
  // the desk, so manual adjustment stays available there.
  readonly property bool tracking_on: tracking !== "off" && tracking !== "desk"

  // Tracking modes this model supports (from `tinyctl support --json`).
  property var trackModes: []
  // On-camera presets (from `tinyctl preset list --json`).
  property var presets: []          // [{ slot, occupied, name, power_on }]
  property int powerOnSlot: 0
  // Only offered where `tinyctl preset power-on` is verified for the model.
  property bool powerOnSupported: false

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

  // A D-pad key: a stock Button with no text and a large glyph drawn on top,
  // so the arrow can be bigger than the theme's button text.
  component PadButton: Button {
    id: pb
    property string glyph: ""
    text: ""
    foreground: root.fg
    Text {
      anchors.centerIn: parent
      text: pb.glyph
      color: root.fg
      opacity: pb.enabled ? 1 : 0.35
      font.family: root.fam
      font.pixelSize: Math.round(Style.font.subtitle * 2)
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
    var t = Math.max(root.panMin, Math.min(root.panMax, Math.round(root.panDeg + dir * (root.swapPan ? -1 : 1) * root.gimbalStep)))
    root.panDeg = t
    root.act(["pan", String(t)])
  }
  function nudgeTilt(dir) {
    var t = Math.max(root.tiltMin, Math.min(root.tiltMax, Math.round(root.tiltDeg + dir * (root.swapTilt ? -1 : 1) * root.gimbalStep)))
    root.tiltDeg = t
    root.act(["tilt", String(t)])
  }
  function nudgeImage(key, dir) {
    var c = root.imageCtl[key]
    if (!c) return
    var t = Math.max(c.min, Math.min(c.max, c.value + dir * (root.imageFine ? 1 : 5)))
    var copy = Object.assign({}, root.imageCtl)
    copy[key] = Object.assign({}, c, { value: t })
    root.imageCtl = copy
    root.act(["image", key, String(t)])
  }
  function nudgeZoom(dir) {
    var t = Math.max(0, Math.min(100, root.zoomVal + dir * 10))
    root.zoomVal = t
    root.act(["zoom", String(t)])
  }

  // Save a pad preference for the selected camera (optimistic; the next
  // status poll confirms it).
  function setUi(name, on) {
    if (name === "fine_control") root.fineControl = on
    else if (name === "swap_pan") root.swapPan = on
    else if (name === "swap_tilt") root.swapTilt = on
    // Own process: a preference save must not be dropped because a status
    // poll happens to be running (act() refuses while busy).
    uiQueue.push(["tinyctl", "-c", root.selectedId, "ui", name, on ? "on" : "off"])
    runUiQueue()
  }
  property var uiQueue: []
  // Global: desktop notifications from tiny-remote (`tinyctl notify`).
  property bool remoteNotifications: false
  function setRemoteNotifications(on) {
    root.remoteNotifications = on
    uiQueue.push(["tinyctl", "notify", on ? "on" : "off"])
    runUiQueue()
  }
  function runUiQueue() {
    if (uiProc.running || uiQueue.length === 0) return
    uiProc.command = uiQueue.shift()
    uiProc.running = true
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
    id: uiProc
    stderr: StdioCollector { id: uiStderr; waitForEnd: true }
    onExited: function(code, status) {
      if (code !== 0 || status !== 0) root.actionError = uiStderr.text.trim() || "Could not save the setting"
      root.runUiQueue()
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
          if (typeof j.notifications === "boolean" && !uiProc.running && root.uiQueue.length === 0)
            root.remoteNotifications = j.notifications
          if (j.ui && !uiProc.running && root.uiQueue.length === 0) {
            root.fineControl = j.ui.fine_control === true
            root.swapPan = j.ui.swap_pan === true
            root.swapTilt = j.ui.swap_tilt === true
          }
          if (j.image && !actionProc.running) root.imageCtl = j.image
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
          var powerOn = false
          for (var i = 0; i < j.features.length; i++) {
            if (j.features[i].support === "unsupported") unsupported[j.features[i].command] = true
            if (j.features[i].command === "preset power-on" && j.features[i].support === "verified") powerOn = true
          }
          root.powerOnSupported = powerOn
          var modes = []
          for (var k = 0; k < root.allModes.length; k++)
            if (!unsupported[root.allModes[k].cmd])
              modes.push({ value: root.allModes[k].value, label: root.allModes[k].label })
          root.trackModes = modes
        } catch (e) {
          root.trackModes = []
          root.powerOnSupported = false
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

        Text {
          width: parent.width
          visible: root.actionError !== ""
          text: root.actionError
          color: Color.accent
          wrapMode: Text.WordWrap
          font.pixelSize: Style.font.caption
        }

        // --- tabs: Camera | Gimbal | Image ---
        Row {
          id: tabRow
          visible: root.haveCam
          width: parent.width
          readonly property var names: ["Camera", "Gimbal", "Image"]
          Repeater {
            model: tabRow.names
            delegate: Item {
              id: tab
              required property int index
              required property string modelData
              readonly property bool active: root.currentTab === tab.index
              width: tabRow.width / tabRow.names.length
              implicitHeight: tabLabel.implicitHeight + Style.space(14)
              Text {
                id: tabLabel
                anchors.centerIn: parent
                text: tab.modelData
                color: tab.active ? Color.accent : root.fg
                opacity: tab.active ? 1 : 0.7
                font.family: root.fam
                font.pixelSize: Style.font.subtitle
                font.bold: tab.active
              }
              Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Style.space(tab.active ? 3 : 1)
                color: tab.active ? Color.accent : Qt.darker(root.fg, 2.2)
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.currentTab = tab.index
              }
            }
          }
        }

        // Camera tab
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.haveCam && root.currentTab === 0
          Text {
            width: parent.width
            visible: root.haveCam
            text: "Power: " + root.powerPolicy + (root.guardActive ? " · guard active" : " · guard not running")
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

          // Make a preset the camera's power-on state (like OBSBOT Center's "As
          // Initial State"): position plus its Additional settings.
          Dropdown {
            width: parent.width
            visible: root.haveCam && root.powerOnSupported && root.presets.length > 0
            enabled: root.stateValid && !root.busy
            label: "Power-on preset"
            value: String(root.powerOnSlot)
            options: {
              var o = root.powerOnSlot === 0 ? [{ value: "0", label: "Not one of the presets" }] : []
              for (var i = 0; i < root.presets.length; i++) {
                var p = root.presets[i]
                o.push({ value: String(p.slot), label: "Preset " + p.slot + (p.name !== "" ? " · " + p.name : "") })
              }
              return o
            }
            onChanged: function(v) {
              if (v !== "0" && v !== String(root.powerOnSlot)) {
                root.powerOnSlot = parseInt(v)
                root.act(["preset", "power-on", v])
                presetRefresh.restart()
              }
            }
          }
          Timer { id: presetRefresh; interval: 3000; onTriggered: root.refreshCameraInfo() }

          PanelSeparator { foreground: root.fg; visible: root.haveCam }

          // Applies to all cameras: notifications from the OBSBOT remote
          // (tiny-remote). Off by default.
          SwitchRow {
            width: parent.width
            visible: root.haveCam
            label: "Remote notifications"
            sub: "OBSBOT remote: modes, presets, errors"
            value: root.remoteNotifications
            fg: root.fg
            fam: root.fam
            onSwitched: root.setRemoteNotifications(!root.remoteNotifications)
          }

          Button {
            width: parent.width
            visible: root.haveCam
            foreground: root.fg
            text: "Wake automatically for calls"
            enabled: !root.busy
            onClicked: root.act(["auto"])
          }

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

        // Gimbal tab
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.haveCam && root.currentTab === 1
          Text {
            width: parent.width
            visible: root.haveCam
            color: root.fg
            font.family: root.fam
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            text: "Gimbal · pan " + Math.round(root.panDeg) + "°, tilt " + Math.round(root.tiltDeg)
                  + "°, zoom " + root.zoomVal
                  + (root.tracking_on ? "\nAI tracking is steering — turn it off (or use Desk mode) to move manually" : "")
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
              PadButton { width: pad.cell; height: pad.cellH; glyph: "▲"; enabled: pad.can; onClicked: root.nudgeTilt(1) }
              Item { width: pad.cell; height: pad.cellH }
              PadButton { width: pad.cell; height: pad.cellH; glyph: "◀"; enabled: pad.can; onClicked: root.nudgePan(1) }
              PadButton { width: pad.cell; height: pad.cellH; glyph: "⌖"; enabled: pad.can; onClicked: root.act(["recenter"]) }
              PadButton { width: pad.cell; height: pad.cellH; glyph: "▶"; enabled: pad.can; onClicked: root.nudgePan(-1) }
              Item { width: pad.cell; height: pad.cellH }
              PadButton { width: pad.cell; height: pad.cellH; glyph: "▼"; enabled: pad.can; onClicked: root.nudgeTilt(-1) }
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
            onSwitched: root.setUi("fine_control", !root.fineControl)
          }
          SwitchRow {
            width: parent.width
            visible: root.haveCam
            label: "Swap left/right"
            sub: root.swapPan ? "◀ ▶ inverted" : ""
            value: root.swapPan
            fg: root.fg
            fam: root.fam
            onSwitched: root.setUi("swap_pan", !root.swapPan)
          }
          SwitchRow {
            width: parent.width
            visible: root.haveCam
            label: "Swap up/down"
            sub: root.swapTilt ? "▲ ▼ inverted" : ""
            value: root.swapTilt
            fg: root.fg
            fam: root.fam
            onSwitched: root.setUi("swap_tilt", !root.swapTilt)
          }
        }

        // Image tab: the camera's hue / contrast / saturation / sharpness.
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.haveCam && root.currentTab === 2
          Repeater {
            model: [
              { key: "hue", label: "Hue" },
              { key: "contrast", label: "Contrast" },
              { key: "saturation", label: "Saturation" },
              { key: "sharpness", label: "Sharpness" }
            ]
            delegate: Item {
              id: imgRow
              required property var modelData
              readonly property var ctl: root.imageCtl[imgRow.modelData.key]
              readonly property bool can: root.stateValid && !root.busy && imgRow.ctl !== undefined
              visible: imgRow.ctl !== undefined
              width: parent ? parent.width : root.rowW
              implicitHeight: Math.max(imgLabel.implicitHeight, imgButtons.implicitHeight) + Style.space(6)
              Column {
                id: imgLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  text: imgRow.modelData.label
                  color: root.fg
                  font.family: root.fam
                  font.pixelSize: Style.font.subtitle
                }
                Text {
                  text: imgRow.ctl ? (imgRow.ctl.value + "   (default " + imgRow.ctl["default"] + ")") : ""
                  color: Qt.darker(root.fg, 1.4)
                  font.family: root.fam
                  font.pixelSize: Style.font.caption
                }
              }
              Row {
                id: imgButtons
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)
                PadButton { width: Style.space(52); height: Style.space(40); glyph: "−"; enabled: imgRow.can; onClicked: root.nudgeImage(imgRow.modelData.key, -1) }
                PadButton { width: Style.space(52); height: Style.space(40); glyph: "+"; enabled: imgRow.can; onClicked: root.nudgeImage(imgRow.modelData.key, 1) }
              }
            }
          }
          SwitchRow {
            width: parent.width
            label: "Fine control"
            sub: root.imageFine ? "steps of 1" : "steps of 5"
            value: root.imageFine
            fg: root.fg
            fam: root.fam
            onSwitched: root.imageFine = !root.imageFine
          }
          Button {
            width: parent.width
            foreground: root.fg
            text: "Reset to camera defaults"
            enabled: root.stateValid && !root.busy
            onClicked: root.act(["image", "reset"])
          }
        }
      }
    }
  }
}
