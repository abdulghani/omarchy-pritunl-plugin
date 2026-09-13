import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Pritunl VPN profiles in the bar: a status icon, and a popup that connects,
// disconnects, imports profiles, and asks for whatever sign-in the selected
// profile needs. Everything goes through the pritunl-client CLI, which drives
// pritunl-client-service; the widget keeps no state beyond what is being typed.
Panel {
  id: root
  moduleName: "abdulghani.pritunl"

  readonly property string scriptPath: Qt.resolvedUrl("profiles.sh").toString().replace(/^file:\/\//, "")
  readonly property string importScriptPath: Qt.resolvedUrl("add-profile.sh").toString().replace(/^file:\/\//, "")
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string vpnGlyph: "󰖂"   // nf-md-vpn

  property bool sampled: false
  property bool installed: true
  property var profiles: []
  property string listError: ""
  property string selectedId: ""
  // When the reading in flight started, so an import only trusts a reading
  // taken after it finished.
  property real listStartedAt: 0

  // Sign-in fields for the selected profile. Codes are cleared the moment a
  // connection starts; the username is kept, since it is not a secret.
  property string usernameText: ""
  property string firstFieldText: ""
  property string secondFieldText: ""

  // "connect" or "disconnect" from the click until the client gets there,
  // "" otherwise. A connect that shows activity and then falls back to
  // disconnected, or never shows any before the timeout, has failed.
  property string pendingAction: ""
  property string pendingId: ""
  property bool attemptSawActivity: false
  property string actionError: ""
  property string failureText: ""
  property string failureDetail: ""

  // Profile import. The ids from before an import tell a new profile apart
  // from one the client updated in place.
  property string importText: ""
  property string importMessage: ""
  property bool importFailed: false
  property var idsBeforeImport: []
  property real importFinishedAt: 0
  property bool awaitingImportedList: false
  // The file chooser opens with the popup closed, so it is not buried under
  // it; the popup comes back to show how the import went.
  property bool reopenAfterImport: false
  readonly property bool importing: pickProc.running || importProc.running

  readonly property var selectedProfile: profileById(selectedId) || (profiles.length > 0 ? profiles[0] : null)
  readonly property var connectedProfile: {
    for (var i = 0; i < profiles.length; i++) if (profiles[i].connected) return profiles[i]
    return null
  }
  readonly property string selectedPhase: Model.phase(selectedProfile)
  readonly property bool anyConnected: connectedProfile !== null
  readonly property bool anyBusy: {
    if (pendingAction !== "") return true
    for (var i = 0; i < profiles.length; i++) if (Model.busyPhase(Model.phase(profiles[i]))) return true
    return false
  }

  readonly property var credentials: selectedProfile
    ? Model.credentials(selectedProfile.passwordMode)
    : ({ username: false, fields: [] })
  readonly property var fieldValues: {
    var v = {}
    if (credentials.fields.length > 0) v[credentials.fields[0].key] = firstFieldText
    if (credentials.fields.length > 1) v[credentials.fields[1].key] = secondFieldText
    return v
  }
  readonly property bool showSignIn: selectedProfile !== null && selectedPhase === "off" && pendingAction === ""
  readonly property bool canConnect: showSignIn
    && Model.ready(selectedProfile.passwordMode, fieldValues, usernameText)

  readonly property string heroMeta: {
    if (!installed) return "Pritunl client not installed"
    if (listError !== "") return "Pritunl client unavailable"
    if (!selectedProfile) return sampled ? "No profiles" : "Checking…"
    if (pendingAction === "connect" && selectedPhase === "off") return "Connecting…"
    if (pendingAction === "disconnect" && selectedPhase !== "off") return "Disconnecting…"
    var label = Model.phaseLabel(selectedPhase)
    return selectedPhase === "connected" ? label + " · " + Model.duration(selectedProfile.uptime) : label
  }

  function profileById(id) {
    for (var i = 0; i < profiles.length; i++) if (profiles[i].id === id) return profiles[i]
    return null
  }

  function sample() {
    if (!listProc.running) listProc.running = true
  }

  function applySample(text) {
    var s = Model.parse(text)
    // Keep the last good reading if this one was not JSON.
    if (!s) return

    root.installed = s.installed
    root.listError = s.error
    root.profiles = s.profiles
    root.sampled = true

    // Stay on the chosen profile while it exists; otherwise follow whichever
    // one is up, else the first.
    if (!root.profileById(root.selectedId)) {
      var up = root.connectedProfile
      root.selectedId = up ? up.id : (s.profiles.length > 0 ? s.profiles[0].id : "")
    }

    if (root.awaitingImportedList && root.listStartedAt >= root.importFinishedAt) root.reportImport(s.profiles)
    root.trackAttempt()
  }

  function selectProfile(id) {
    if (id === root.selectedId) return
    root.selectedId = id
    root.firstFieldText = ""
    root.secondFieldText = ""
    root.failureText = ""
    root.failureDetail = ""
    root.actionError = ""
    root.focusSignIn()
  }

  function connect() {
    if (!root.canConnect) return
    var p = root.selectedProfile
    var args = ["start", p.id]
    if (root.credentials.username) args.push("--username", root.usernameText.trim())
    var password = Model.password(p.passwordMode, root.fieldValues)
    if (password !== "") args.push("--password", password)
    root.startAction("connect", p.id, args)
    root.firstFieldText = ""
    root.secondFieldText = ""
  }

  function disconnect(profile) {
    var p = profile || root.connectedProfile || root.selectedProfile
    if (!p || root.pendingAction !== "") return
    root.startAction("disconnect", p.id, ["stop", p.id])
  }

  // The header switch: connect when the sign-in is filled in, otherwise send
  // the cursor to the field that still needs something.
  function toggleSelected() {
    if (root.pendingAction !== "" || !root.selectedProfile) return
    if (root.selectedPhase !== "off") root.disconnect(root.selectedProfile)
    else if (root.canConnect) root.connect()
    else root.focusSignIn()
  }

  function startAction(kind, id, args) {
    root.actionError = ""
    root.failureText = ""
    root.failureDetail = ""
    root.pendingAction = kind
    root.pendingId = id
    root.attemptSawActivity = false
    // One stream with the exit status on the last line, so the result is
    // read in a single place rather than raced between signals.
    actionProc.command = ["sh", "-c", "pritunl-client \"$@\" 2>&1; echo \"__exit $?\"", "sh"].concat(args)
    actionProc.running = true
    attemptTimeout.restart()
  }

  function finishAction(output) {
    var result = Model.commandResult(output)
    if (result.status !== 0) {
      root.actionError = result.message !== "" ? result.message : "pritunl-client exited with status " + result.status
      root.endAttempt()
    }
    root.sample()
  }

  function trackAttempt() {
    if (root.pendingAction === "" || actionProc.running) return
    var phase = Model.phase(root.profileById(root.pendingId))
    if (root.pendingAction === "connect") {
      if (phase === "connected") root.endAttempt()
      else if (phase !== "off") root.attemptSawActivity = true
      else if (root.attemptSawActivity) root.failAttempt()
    } else if (phase === "off") {
      root.endAttempt()
    }
  }

  function endAttempt() {
    root.pendingAction = ""
    root.pendingId = ""
    root.attemptSawActivity = false
    attemptTimeout.stop()
  }

  function failAttempt() {
    var id = root.pendingId
    root.endAttempt()
    root.failureText = "Didn't connect. Check the code and try again."
    if (id !== "" && !logsProc.running) {
      logsProc.command = ["sh", "-c",
        "pritunl-client logs \"$1\" 2>/dev/null | grep -iE 'auth|fail|error|denied|invalid' | tail -n 1", "sh", id]
      logsProc.running = true
    }
    root.focusSignIn()
  }

  function focusSignIn() {
    focusTimer.restart()
  }

  // ---- Import --------------------------------------------------------------

  function importSource(source) {
    var s = String(source || "").trim()
    if (s === "" || importProc.running) return
    root.importMessage = ""
    root.importFailed = false
    root.idsBeforeImport = root.profiles.map(function (p) { return p.id })
    importProc.command = ["sh", "-c", "\"$0\" \"$1\" 2>&1; echo \"__exit $?\"", root.importScriptPath, s]
    importProc.running = true
  }

  function pickProfileFile() {
    if (root.importing) return
    root.importMessage = ""
    root.importFailed = false
    root.reopenAfterImport = true
    root.close()
    pickProc.running = true
  }

  function finishImport(output) {
    var result = Model.commandResult(output)
    if (result.status !== 0) {
      root.importFailed = true
      root.importMessage = result.message !== "" ? result.message : "Import failed."
      root.showImportResult()
      return
    }
    root.importText = ""
    root.importFinishedAt = Date.now()
    root.awaitingImportedList = true
    root.sample()
  }

  function reportImport(profiles) {
    root.awaitingImportedList = false
    var added = profiles.filter(function (p) { return root.idsBeforeImport.indexOf(p.id) < 0 })
    root.importFailed = false
    if (added.length > 0) {
      root.selectProfile(added[0].id)
      root.importMessage = added.length === 1 ? "Added " + added[0].name + "." : "Added " + added.length + " profiles."
    } else {
      root.importMessage = "That profile was already here, so it was updated."
    }
    root.showImportResult()
  }

  function showImportResult() {
    if (!root.reopenAfterImport) return
    root.reopenAfterImport = false
    root.open()
  }

  onOpenedChanged: {
    if (!opened) return
    sample()
    if (showSignIn) focusSignIn()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: listProc
    command: [root.scriptPath]
    onStarted: root.listStartedAt = Date.now()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySample(text)
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishAction(text)
    }
  }

  Process {
    id: logsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.failureDetail = text.trim().slice(0, 240)
    }
  }

  // Exits 1 with nothing printed when the chooser is cancelled, which needs
  // no message; a chooser that could not open says why on stderr.
  Process {
    id: pickProc
    command: ["omarchy-file-select", "--title", "Import Pritunl profile", "--extensions", "ovpn tar zip"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var path = text.split("\n")[0].trim()
        if (path !== "") root.importSource(path)
        else if (!root.importFailed) root.reopenAfterImport = false
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text.trim() === "") return
        root.importFailed = true
        root.importMessage = text.trim()
        root.showImportResult()
      }
    }
  }

  Process {
    id: importProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishImport(text)
    }
  }

  // Poll fast only while something is changing; the popup being open is the
  // next reason to look, and the bar icon alone needs little.
  Timer {
    interval: root.anyBusy ? 1000 : (root.opened ? 3000 : 15000)
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.sample()
  }

  Timer {
    id: attemptTimeout
    interval: 30000
    onTriggered: {
      if (root.pendingAction === "connect" && Model.phase(root.profileById(root.pendingId)) !== "connected")
        root.failAttempt()
      else
        root.endAttempt()
    }
  }

  // The panel hands focus to its key catcher as it opens, so the field takes
  // it a moment later rather than losing it straight back.
  Timer {
    id: focusTimer
    interval: 80
    onTriggered: {
      if (!root.showSignIn) return
      if (usernameField.visible && usernameField.text === "") usernameField.forceActiveFocus()
      else if (firstField.visible) firstField.forceActiveFocus()
    }
  }

  // ---- Bar button ----------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        OpticalGlyph {
          anchors.fill: parent
          text: root.vpnGlyph
          fontFamily: root.fontFamily
          fontSize: Style.bar.iconFont
          color: root.anyConnected ? root.foreground : root.dim
          opacity: root.anyBusy && !root.anyConnected ? 0.75 : 1.0
        }
      }
    }
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton && root.anyConnected) root.disconnect(root.connectedProfile)
      else if (buttonCode === Qt.MiddleButton) root.sample()
      else root.toggle()
    }
  }

  // ---- Popup ---------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Header ----------
        Item {
          id: header
          width: parent.width
          implicitHeight: hero.implicitHeight

          // Read by the hero's trailingControl, which reaches panel state
          // through `header` the way Omarchy's Tailscale panel does.
          readonly property bool switchVisible: root.selectedProfile !== null
          readonly property bool switchChecked: root.pendingAction === "connect"
            || (root.pendingAction !== "disconnect" && root.selectedPhase !== "off")
          readonly property bool switchBusy: root.pendingAction !== "" || Model.busyPhase(root.selectedPhase)
          function toggle() { root.toggleSelected() }

          PanelHero {
            id: hero
            width: parent.width
            title: root.selectedProfile ? root.selectedProfile.name : "Pritunl VPN"
            meta: root.heroMeta
            detail: root.selectedPhase === "connected" && root.selectedProfile ? root.selectedProfile.clientAddress : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.selectedPhase === "connected" ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.vpnGlyph
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                visible: header.switchVisible
                checked: header.switchChecked
                busy: header.switchBusy
                foreground: hero.foreground
                onToggled: header.toggle()
              }
            }
          }
        }

        Text {
          visible: text !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.actionError !== "" ? root.actionError : root.failureText
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          visible: text !== ""
          width: parent.width
          wrapMode: Text.WrapAnywhere
          maximumLineCount: 3
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: root.failureDetail
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // Nothing to connect: say why rather than showing an empty panel.
        Text {
          visible: root.sampled && text !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: !root.installed
            ? "Install pritunl-client-electron from the AUR, then add a profile here."
            : root.listError !== "" ? root.listError
            : root.profiles.length === 0 ? "No profiles yet. Add one below with a pritunl:// link or a profile file." : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // ---------- Profiles ----------
        PanelSeparator { foreground: root.foreground; visible: root.profiles.length > 1 }

        PanelSectionHeader {
          text: "PROFILES"
          foreground: root.foreground
          visible: root.profiles.length > 1
        }

        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.profiles.length > 1

          Repeater {
            model: root.profiles

            Button {
              required property var modelData
              width: parent.width
              leftAlign: true
              selected: root.selectedProfile !== null && modelData.id === root.selectedProfile.id
              text: modelData.name + "   ·   " + Model.phaseLabel(Model.phase(modelData))
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.selectProfile(modelData.id)
            }
          }
        }

        // ---------- Sign in ----------
        PanelSeparator { foreground: root.foreground; visible: root.showSignIn }

        PanelSectionHeader {
          text: "SIGN IN"
          foreground: root.foreground
          visible: root.showSignIn
        }

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.showSignIn

          TextField {
            id: usernameField
            visible: root.credentials.username
            width: parent.width
            placeholderText: "Username"
            foreground: root.foreground
            text: root.usernameText
            onTextChanged: if (text !== root.usernameText) root.usernameText = text
            onAccepted: firstField.visible ? firstField.forceActiveFocus() : root.connect()
            Keys.onEscapePressed: root.close()
          }

          TextField {
            id: firstField
            visible: root.credentials.fields.length > 0
            width: parent.width
            placeholderText: visible ? root.credentials.fields[0].label : ""
            password: visible && root.credentials.fields[0].secret
            foreground: root.foreground
            text: root.firstFieldText
            onTextChanged: if (text !== root.firstFieldText) root.firstFieldText = text
            onAccepted: secondField.visible ? secondField.forceActiveFocus() : root.connect()
            Keys.onEscapePressed: root.close()
          }

          TextField {
            id: secondField
            visible: root.credentials.fields.length > 1
            width: parent.width
            placeholderText: visible ? root.credentials.fields[1].label : ""
            password: visible && root.credentials.fields[1].secret
            foreground: root.foreground
            text: root.secondFieldText
            onTextChanged: if (text !== root.secondFieldText) root.secondFieldText = text
            onAccepted: root.connect()
            Keys.onEscapePressed: root.close()
          }

          Item {
            width: parent.width
            implicitHeight: connectButton.implicitHeight

            Button {
              id: connectButton
              anchors.right: parent.right
              text: "Connect"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.canConnect
              opacity: root.canConnect ? 1.0 : 0.5
              onClicked: root.connect()
            }
          }
        }

        // ---------- Add profile ----------
        PanelSeparator { foreground: root.foreground; visible: root.installed }

        PanelSectionHeader {
          text: "ADD PROFILE"
          foreground: root.foreground
          visible: root.installed
        }

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.installed

          TextField {
            id: importField
            width: parent.width
            placeholderText: "Paste a pritunl:// link or a file path"
            foreground: root.foreground
            enabled: !root.importing
            text: root.importText
            onTextChanged: if (text !== root.importText) root.importText = text
            onAccepted: root.importSource(root.importText)
            Keys.onEscapePressed: root.close()
          }

          Item {
            width: parent.width
            implicitHeight: Math.max(importFileButton.implicitHeight, addButton.implicitHeight)

            Button {
              id: importFileButton
              anchors.left: parent.left
              text: "Import file…"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.importing
              opacity: enabled ? 1.0 : 0.5
              onClicked: root.pickProfileFile()
            }

            Button {
              id: addButton
              anchors.right: parent.right
              text: root.importing ? "Importing…" : "Add"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.importing && root.importText.trim() !== ""
              opacity: enabled ? 1.0 : 0.5
              onClicked: root.importSource(root.importText)
            }
          }

          Text {
            visible: root.importMessage !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.importMessage
            color: root.importFailed ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          textFormat: Text.PlainText
          text: root.anyConnected ? "Right-click the bar to disconnect" : "Middle-click the bar to refresh"
          color: Qt.darker(root.foreground, 1.8)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          width: parent.width
          horizontalAlignment: Text.AlignRight
        }
      }
    }
  }
}
