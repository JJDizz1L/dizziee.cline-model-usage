import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "dizziee.cline-model-usage"

  property bool popupOpen: false
  property bool settingsMode: false
  property var draftSettings: ({})
  property string settingsStatusText: ""
  property bool refreshFlash: false

  // Countdowns and "updated Nm ago" read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open. The timer only runs
  // while the panel is open.
  property double nowMs: Date.now()

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color background: Commons.Color.popups.background
  readonly property color border: Commons.Color.popups.border
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color card: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.055)
  readonly property color track: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.24)
  readonly property string fontFamily: bar ? bar.fontFamily : "JetBrainsMono Nerd Font"

  readonly property var provider: usageMain.provider

  // Every visible string comes from i18n/<language>.json, falling back to
  // English. The component watches the catalogs, so a language switch under
  // Setup re-renders the panel without a shell restart.
  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  function close() {
    popupOpen = false
    settingsMode = false
  }

  function triggerPress(button) {
    if (button === Qt.RightButton) {
      openSettings()
      return
    }
    if (button === Qt.MiddleButton) {
      triggerRefresh()
      return
    }

    popupOpen = !popupOpen
  }

  function triggerRefresh() {
    refreshFlash = true
    refreshFlashTimer.restart()
    usageMain.refreshAll()
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function cloneObject(value, fallback) {
    if (value === undefined || value === null) return fallback
    try { return JSON.parse(JSON.stringify(value)) }
    catch (e) { return fallback }
  }

  function defaultSettings() {
    return { refreshIntervalSec: 900 }
  }

  function normalizedSettings(source) {
    var next = cloneObject(source, {}) || {}
    var refresh = Number(next.refreshIntervalSec === undefined || next.refreshIntervalSec === null ? 900 : next.refreshIntervalSec)
    next.refreshIntervalSec = Math.round(clamp(isFinite(refresh) ? refresh : 900, 30, 3600))
    return next
  }

  function openSettings() {
    draftSettings = normalizedSettings(settings)
    settingsStatusText = ""
    settingsMode = true
    popupOpen = true
    panel.ensureContent()
    Qt.callLater(root.focusKeys)
  }

  function showUsage() {
    settingsMode = false
    settingsStatusText = ""
    Qt.callLater(root.focusKeys)
  }

  function focusKeys() {
    if (panel.loadedContent) panel.loadedContent.forceActiveFocus()
  }

  function canPersistSettings() {
    return !!(bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
  }

  function saveSettings() {
    var next = normalizedSettings(draftSettings)
    draftSettings = next
    root.settings = next
    if (canPersistSettings()) {
      bar.shell.updateEntryInline(root.moduleName, next)
      settingsStatusText = strings.t("cline.savedToShell")
    } else {
      settingsStatusText = strings.t("cline.savedForSession")
    }
    usageMain.refreshAll()
  }

  function iconSource() {
    return Qt.resolvedUrl("assets/cline.svg")
  }

  function chipLabel() {
    var toks = provider ? (provider.todayTotalTokens || 0) : 0
    if (toks <= 0) return ""
    return usageMain.formatTokenCount(toks)
  }

  function tooltipText() {
    if (!provider) return strings.t("cline.title")
    var count = usageMain.formatTokenCount(provider.todayTotalTokens || 0)
    if (provider.stale)
      return strings.t("cline.chipTooltipStale").arg(provider.providerName).arg(count)
    if (provider.scannedAtMs > 0) {
      var seconds = Math.max(0, Math.floor((Date.now() - provider.scannedAtMs) / 1000))
      if (seconds >= 60)
        return strings.t("cline.chipTooltipAge").arg(provider.providerName).arg(count)
          .arg(Commons.I18n.formatNumber(Math.floor(seconds / 60)))
    }
    return strings.t("cline.chipTooltip").arg(provider.providerName).arg(count)
  }

  function todayKey() {
    var d = new Date(root.nowMs)
    return d.getFullYear()
      + "-" + String(d.getMonth() + 1).padStart(2, "0")
      + "-" + String(d.getDate()).padStart(2, "0")
  }

  function dayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return Qt.locale(Commons.I18n.formatLocale).dayName([7, 1, 2, 3, 4, 5, 6][parsed.getDay()], Locale.ShortFormat)
  }

  function dayLabel(date) {
    if (String(date || "") === root.todayKey()) return strings.t("cline.today")
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return root.dayName(date) + " " + Commons.I18n.formatNumber(parsed.getMonth() + 1) + "/" + Commons.I18n.formatNumber(parsed.getDate())
  }

  function dayTooltip(day) {
    if (!day) return ""
    return strings.t("cline.dayTooltip").arg(root.dayLabel(day.date))
      .arg(usageMain.formatTokenCount(Number(day.totalTokens || 0)))
  }

  function tokenTotal(bucket) {
    if (!bucket) return 0
    return Number(bucket.inputTokens || 0) + Number(bucket.outputTokens || 0)
      + Number(bucket.cacheReadInputTokens || 0) + Number(bucket.cacheCreationInputTokens || 0)
  }

  function todayRows(limit) {
    var source = provider ? (provider.todayTokensByModel || ({})) : ({})
    var rows = []
    for (var id in source) rows.push({ modelId: id, count: Number(source[id] || 0) })
    rows.sort(function(a, b) { return b.count - a.count })
    return limit > 0 ? rows.slice(0, limit) : rows
  }

  function allTimeRows(limit) {
    var source = provider ? (provider.modelUsage || ({})) : ({})
    var rows = []
    for (var id in source) {
      var bucket = source[id] || ({})
      rows.push({ modelId: id, data: bucket, total: root.tokenTotal(bucket) })
    }
    rows.sort(function(a, b) { return b.total - a.total })
    return limit > 0 ? rows.slice(0, limit) : rows
  }

  function modelTooltip(row) {
    if (!row) return ""
    var data = row.data || ({})
    return strings.t("cline.modelTooltip")
      .arg(usageMain.friendlyModelName(row.modelId))
      .arg(usageMain.formatTokenCount(data.inputTokens || 0))
      .arg(usageMain.formatTokenCount(data.outputTokens || 0))
      .arg(usageMain.formatTokenCount(data.cacheReadInputTokens || 0))
      .arg(usageMain.formatTokenCount(data.cacheCreationInputTokens || 0))
  }

  function footerStatus() {
    if (!provider || !provider.ready) return ""
    if (provider.stale) return strings.t("cline.stale")
    if (!(provider.scannedAtMs > 0)) return ""
    var seconds = Math.max(0, Math.floor((root.nowMs - provider.scannedAtMs) / 1000))
    if (seconds < 60) return strings.t("cline.updatedJustNow")
    if (seconds < 3600) return strings.t("cline.updatedMinutes").arg(Commons.I18n.formatNumber(Math.floor(seconds / 60)))
    if (seconds < 86400) return strings.t("cline.updatedHours").arg(Commons.I18n.formatNumber(Math.floor(seconds / 3600)))
    return strings.t("cline.updatedDays").arg(Commons.I18n.formatNumber(Math.floor(seconds / 86400)))
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onPopupOpenChanged: {
    if (popupOpen) {
      nowMs = Date.now()
      if (panel.loadedContent && panel.loadedContent.panelFlick)
        panel.loadedContent.panelFlick.contentY = 0
      // The background scan keeps the bar chip current. Opening the panel only
      // asks for a scan when the cache is old; a fresh one costs nothing.
      usageMain.refreshIfStale(30)
      Qt.callLater(root.focusKeys)
    }
  }

  Main {
    id: usageMain
    settings: root.settings
    unknownModelLabel: strings.t("cline.unknownModel")
  }

  // Only while the panel is open: it keeps "Updated 2m ago" honest without
  // waking a closed panel every minute.
  Timer {
    id: panelClock
    interval: 60000
    running: root.popupOpen
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    id: refreshFlashTimer
    interval: 900
    repeat: false
    onTriggered: root.refreshFlash = false
  }

  IpcHandler {
    target: "dizziee.cline-model-usage"
    function open(): string { root.showUsage(); root.popupOpen = true; return "ok" }
    function close(): string { root.close(); return "ok" }
    function toggle(): string {
      if (root.popupOpen) root.close()
      else { root.showUsage(); root.popupOpen = true }
      return "ok"
    }
    function refresh(): string { root.triggerRefresh(); return "ok" }
    function settings(): string { root.openSettings(); return "ok" }
    function openSettings(): string { root.openSettings(); return "ok" }
  }

  component UsageChip: Item {
    id: chip

    readonly property bool compact: root.vertical

    width: compact ? root.barSize : chipRow.implicitWidth
    height: compact ? Math.max(root.barSize, chipColumn.implicitHeight + Style.space(2)) : root.barSize

    Row {
      id: chipRow
      visible: !chip.compact
      anchors.centerIn: parent
      spacing: 4

      Image {
        source: root.iconSource()
        width: 13
        height: 13
        sourceSize.width: 13
        sourceSize.height: 13
        fillMode: Image.PreserveAspectFit
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: root.chipLabel()
        color: root.provider && root.provider.stale ? urgent : foreground
        font.family: fontFamily
        font.pixelSize: 10
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
        visible: text !== ""
      }
    }

    Column {
      id: chipColumn
      visible: chip.compact
      anchors.centerIn: parent
      spacing: 1

      Image {
        source: root.iconSource()
        width: 13
        height: 13
        sourceSize.width: 13
        sourceSize.height: 13
        fillMode: Image.PreserveAspectFit
        anchors.horizontalCenter: parent.horizontalCenter
      }

    }

    property var registeredBar: null

    function triggerPress(button) {
      root.triggerPress(button)
    }

    function syncClickRegistration() {
      if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(chip)
      registeredBar = root.bar
      if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(chip)
    }

    Component.onCompleted: syncClickRegistration()
    Component.onDestruction: if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(chip)

    Connections {
      target: root
      function onBarChanged() { chip.syncClickRegistration() }
    }

    MouseArea {
      id: mouseArea
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: if (root.bar) root.bar.showTooltip(chip, root.tooltipText())
      onExited: if (root.bar) root.bar.hideTooltip(chip)
      onClicked: function(mouse) { root.triggerPress(mouse.button) }
    }
  }

  component EmptyUsageChip: Item {
    id: emptyChip
    visible: !provider
    width: root.vertical ? root.barSize : emptyLabel.implicitWidth
    height: root.barSize

    property var registeredBar: null

    function triggerPress(button) { root.triggerPress(button) }

    function syncClickRegistration() {
      if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(emptyChip)
      registeredBar = root.bar
      if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(emptyChip)
    }

    Component.onCompleted: syncClickRegistration()
    Component.onDestruction: if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(emptyChip)

    Connections {
      target: root
      function onBarChanged() { emptyChip.syncClickRegistration() }
    }

    Text {
      textFormat: Text.PlainText
      id: emptyLabel
      anchors.centerIn: parent
      text: strings.t("cline.emptyChip")
      color: dim
      font.family: fontFamily
      font.pixelSize: 10
      font.bold: true
    }

    MouseArea {
      id: emptyMouse
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: if (root.bar) root.bar.showTooltip(emptyChip, strings.t("cline.title"))
      onExited: if (root.bar) root.bar.hideTooltip(emptyChip)
      onClicked: function(mouse) { root.triggerPress(mouse.button) }
    }
  }

  Item {
    id: button
    anchors.fill: parent
    implicitWidth: root.vertical ? root.barSize : barRow.implicitWidth + Style.space(10)
    implicitHeight: root.vertical ? barColumn.implicitHeight : root.barSize

    Row {
      id: barRow
      visible: !root.vertical
      anchors.centerIn: parent
      spacing: Style.space(8)
      UsageChip { visible: !root.vertical }
      EmptyUsageChip { visible: !root.vertical && (!provider || !provider.hasLocalStats) }
    }

    Column {
      id: barColumn
      visible: root.vertical
      anchors.centerIn: parent
      spacing: Style.space(2)
      UsageChip { visible: root.vertical }
      EmptyUsageChip { visible: root.vertical && (!provider || !provider.hasLocalStats) }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.popupOpen
    // The card is built the first time the panel opens, not on every monitor
    // at shell startup. Ids inside it are reached through panel.loadedContent.
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(370))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(560))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias panelFlick: flick
      property alias contentColumn: contentColumn
      anchors.fill: parent
      implicitHeight: contentColumn.implicitHeight
      blocked: settingsMode && settingsContent.editorActive

      // The card is built after the panel opens, so focus it here as well as
      // from the open handler; otherwise the first key goes to the app behind.
      Component.onCompleted: if (root.popupOpen) Qt.callLater(keyCatcher.forceActiveFocus)

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) flick.contentY = root.clamp(flick.contentY + dy * 56, 0, Math.max(0, flick.contentHeight - flick.height))
      }
      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.triggerRefresh()
        if (t === "s" || t === "S") root.settingsMode ? root.saveSettings() : root.openSettings()
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: 10

        Header {
          visible: !root.settingsMode && !!root.provider
          provider: root.provider
        }

        SettingsHeader { visible: root.settingsMode }

        PanelSeparator {
          Layout.fillWidth: true
          foreground: root.foreground
        }

        Flickable {
          id: flick
          Layout.fillWidth: true
          Layout.fillHeight: true
          contentWidth: width
          contentHeight: contentColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          ColumnLayout {
            id: contentColumn
            width: flick.width
            spacing: 10

            Text {
              textFormat: Text.PlainText
              visible: !root.settingsMode && (!root.provider || !root.provider.hasLocalStats)
              Layout.fillWidth: true
              Layout.topMargin: 24
              text: strings.t("cline.noData")
              color: dim
              font.family: fontFamily
              font.pixelSize: 11
              horizontalAlignment: Text.AlignHCenter
            }

            StatusCard { provider: root.settingsMode ? null : root.provider }
            TodayCard { provider: root.settingsMode ? null : root.provider }
            WeekCard { provider: root.settingsMode ? null : root.provider }
            AllTimeCard { provider: root.settingsMode ? null : root.provider }

            UsageFooter { visible: !root.settingsMode }
            SettingsContent {
              id: settingsContent
              visible: root.settingsMode
            }
          }
        }
      }
    }
  }

  component SettingsHeader: RowLayout {
    Layout.fillWidth: true
    spacing: 8

    Text {
      textFormat: Text.PlainText
      text: strings.t("cline.settingsTitle")
      color: foreground
      font.family: fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
    }

    Button {
      text: strings.t("cline.usage")
      foreground: root.foreground
      tooltipText: strings.t("cline.backToUsage")
      tooltipBackground: root.background
      tooltipForeground: root.foreground
      fontFamily: root.fontFamily
      fontSize: 10
      horizontalPadding: 8
      verticalPadding: 4
      onClicked: root.showUsage()
    }

    Button {
      text: strings.t("cline.save")
      foreground: root.foreground
      tooltipText: strings.t("cline.saveSettings")
      tooltipBackground: root.background
      tooltipForeground: root.foreground
      fontFamily: root.fontFamily
      fontSize: 10
      horizontalPadding: 8
      verticalPadding: 4
      active: true
      onClicked: root.saveSettings()
    }
  }

  component UsageFooter: RowLayout {
    Layout.fillWidth: true
    spacing: 8

    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      text: strings.t("cline.panelKeys")
      color: dim
      font.family: fontFamily
      font.pixelSize: 10
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }
  }

  component SettingsContent: ColumnLayout {
    id: settingsRoot
    Layout.fillWidth: true
    spacing: 10

    readonly property bool editorActive: refreshIntervalField.field.activeFocus

    SectionCard {
      title: strings.t("cline.refreshSection")

      ColumnLayout {
        width: parent.width
        spacing: 8

        NumberField {
          id: refreshIntervalField
          label: strings.t("cline.refreshInterval")
          value: Number(root.draftValue("refreshIntervalSec", 900))
          from: 30
          to: 3600
          stepSize: 30
          fieldWidth: parent.width
          foreground: root.foreground
          accent: Commons.Color.accent
          fontFamily: root.fontFamily
          onModified: function(value) { root.setDraftValue("refreshIntervalSec", value) }
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: strings.t("cline.refreshHelp")
          color: dim
          font.family: fontFamily
          font.pixelSize: 10
          wrapMode: Text.WordWrap
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: root.settingsStatusText !== ""
      Layout.fillWidth: true
      text: root.settingsStatusText
      color: dim
      font.family: fontFamily
      font.pixelSize: 10
      horizontalAlignment: Text.AlignHCenter
    }

    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      text: strings.t("cline.settingsKeys")
      color: dim
      font.family: fontFamily
      font.pixelSize: 10
      horizontalAlignment: Text.AlignHCenter
    }
  }

  function draftValue(name, fallback) {
    var value = draftSettings ? draftSettings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function setDraftValue(name, value) {
    var next = normalizedSettings(draftSettings)
    next[name] = value
    draftSettings = next
  }

  component Header: RowLayout {
    property var provider: null
    visible: !!provider
    Layout.fillWidth: true
    spacing: 8

    Image {
      source: root.iconSource()
      Layout.preferredWidth: 16
      Layout.preferredHeight: 16
      sourceSize.width: 16
      sourceSize.height: 16
      fillMode: Image.PreserveAspectFit
      Layout.alignment: Qt.AlignVCenter
    }

    ColumnLayout {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      spacing: 0

      Text {
        textFormat: Text.PlainText
        text: strings.t("cline.title")
        color: foreground
        font.family: fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        Layout.fillWidth: true
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        visible: text !== ""
        text: root.footerStatus()
        color: provider && provider.stale ? urgent : dim
        font.family: fontFamily
        font.pixelSize: Style.font.caption
        Layout.fillWidth: true
        elide: Text.ElideRight
      }
    }

    Button {
      text: (root.refreshFlash || usageMain.refreshing)
        ? strings.t("cline.refreshing") : strings.t("cline.refresh")
      foreground: root.foreground
      tooltipText: (root.refreshFlash || usageMain.refreshing)
        ? strings.t("cline.refreshingTooltip") : strings.t("cline.refreshTooltip")
      tooltipBackground: root.background
      tooltipForeground: root.foreground
      fontFamily: root.fontFamily
      fontSize: 10
      horizontalPadding: 8
      verticalPadding: 4
      active: root.refreshFlash || usageMain.refreshing
      onClicked: {
        root.triggerRefresh()
        keyCatcher.forceActiveFocus()
      }
    }
  }

  component StatusCard: SectionCard {
    property var provider: null
    readonly property bool failed: !!provider && provider.scanFailed === true
    visible: failed || (!!provider && String(provider.usageStatusText || "") !== "")
    titleColor: urgent
    title: failed ? strings.t("cline.scanFailed") : (provider ? provider.usageStatusText : "")
    subtitle: {
      if (!provider) return ""
      if (!failed) return provider.authHelpText
      var detail = ""
      if (provider.scanErrorKind === "cache")
        detail = strings.t("cline.cacheTooLarge")
      else if (provider.scanErrorKind === "parse")
        detail = strings.t("cline.parseFailedDetail").arg(provider.errorText || "")
      else
        detail = strings.t("cline.scanFailedDetail").arg(provider.errorText || "")
      if (provider.stale) detail += " " + strings.t("cline.showingLastGood")
      return detail
    }
  }

  component TodayCard: SectionCard {
    id: todayCard
    property var provider: null
    visible: !!provider && provider.ready && provider.hasLocalStats
    title: strings.t("cline.today")

    // Rendering is gated on the panel being open: a closed panel keeps no
    // model rows in memory. Five is enough to answer "what did I use today".
    readonly property var rows: root.popupOpen ? root.todayRows(5) : []
    readonly property int hiddenModels: root.popupOpen
      ? Math.max(0, Object.keys(provider ? (provider.todayTokensByModel || ({})) : ({})).length - 5)
      : 0

    ColumnLayout {
      width: parent.width
      spacing: 8
      RowLayout {
        Layout.fillWidth: true
        spacing: 20
        StatBlock { value: provider ? Commons.I18n.formatNumber(provider.todaySessions || 0) : Commons.I18n.formatNumber(0); label: strings.t("cline.sessions") }
        StatBlock { value: provider ? usageMain.formatTokenCount(provider.todayTotalTokens || 0) : "0"; label: strings.t("cline.tokens") }
      }
      Repeater {
        model: todayCard.rows
        delegate: RowLayout {
          required property var modelData
          Layout.fillWidth: true
          Text {
            textFormat: Text.PlainText
            text: usageMain.friendlyModelName(modelData.modelId)
            color: dim
            font.family: fontFamily
            font.pixelSize: 11
            elide: Text.ElideRight
            Layout.fillWidth: true
          }
          Text {
            textFormat: Text.PlainText
            text: usageMain.formatTokenCount(modelData.count)
            color: foreground
            font.family: fontFamily
            font.pixelSize: 11
            font.bold: true
          }
        }
      }
      Text {
        textFormat: Text.PlainText
        visible: todayCard.hiddenModels > 0
        Layout.fillWidth: true
        text: strings.tn("cline.moreModels", todayCard.hiddenModels)
          .arg(Commons.I18n.formatNumber(todayCard.hiddenModels))
        color: dim
        font.family: fontFamily
        font.pixelSize: 10
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }

  component WeekCard: SectionCard {
    id: weekCard
    property var provider: null
    visible: !!provider && provider.recentDays && provider.recentDays.length > 0
               && provider.recentDays.some(function(d) { return Number(d.totalTokens || 0) > 0 })
    title: strings.t("cline.last7Days")

    // One peak for all rows, not one per delegate.
    readonly property real maxCount: {
      var days = provider ? (provider.recentDays || []) : []
      var max = 1
      for (var i = 0; i < days.length; i++)
        if (Number(days[i].totalTokens || 0) > max) max = Number(days[i].totalTokens || 0)
      return max
    }

    ColumnLayout {
      width: parent.width
      spacing: 6
      Repeater {
        model: root.popupOpen && provider ? provider.recentDays : []
        delegate: Item {
          id: dayItem
          required property var modelData
          Layout.fillWidth: true
          Layout.preferredHeight: dayRow.implicitHeight

          RowLayout {
            id: dayRow
            anchors.fill: parent
            spacing: 8
            readonly property real count: dayItem.modelData ? Number(dayItem.modelData.totalTokens || 0) : 0
            readonly property bool today: !!dayItem.modelData && String(dayItem.modelData.date || "") === root.todayKey()

            Text {
              textFormat: Text.PlainText
              text: root.dayLabel(dayItem.modelData ? dayItem.modelData.date : "")
              color: dayRow.today ? foreground : dim
              font.family: fontFamily
              font.pixelSize: 10
              font.bold: dayRow.today
              Layout.preferredWidth: 54
            }
            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: 10
              color: track
              radius: Math.max(1, Style.cornerRadius / 3)
              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: parent.width * (dayRow.count / weekCard.maxCount)
                color: dayRow.today ? foreground : root.alpha(foreground, 0.55)
                radius: Math.max(1, Style.cornerRadius / 3)
                Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
              }
            }
            Text {
              textFormat: Text.PlainText
              text: usageMain.formatTokenCount(dayRow.count)
              color: dayRow.today ? foreground : dim
              font.family: fontFamily
              font.pixelSize: 10
              font.bold: true
              horizontalAlignment: Text.AlignRight
              Layout.preferredWidth: 48
            }
          }

          MouseArea {
            id: dayHover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
          }
          PanelToolTip {
            visible: dayHover.containsMouse
            text: root.dayTooltip(dayItem.modelData)
            fontFamily: root.fontFamily
          }
        }
      }
    }
  }

  component AllTimeCard: SectionCard {
    id: allTimeCard
    property var provider: null
    visible: !!provider && Object.keys(provider.modelUsage || ({})).length > 0
    title: strings.t("cline.allTime")

    readonly property int totalModels: {
      var usage = provider ? (provider.modelUsage || {}) : ({})
      return Object.keys(usage).length
    }
    readonly property var rows: root.popupOpen ? root.allTimeRows(6) : []
    readonly property int hiddenModels: root.popupOpen ? Math.max(0, totalModels - 6) : 0

    ColumnLayout {
      width: parent.width
      spacing: 8
      RowLayout {
        Layout.fillWidth: true
        spacing: 20
        StatBlock { value: provider ? Commons.I18n.formatNumber(provider.totalSessions || 0) : Commons.I18n.formatNumber(0); label: strings.t("cline.sessions") }
      }
      PanelSeparator { Layout.fillWidth: true; foreground: root.foreground; strength: 0.18 }

      Repeater {
        model: allTimeCard.rows
        delegate: Item {
          id: modelRow
          required property var modelData
          required property int index
          Layout.fillWidth: true
          Layout.preferredHeight: modelName.implicitHeight + 12
          readonly property real share: allTimeCard.rows.length > 0
            ? Number(modelData.total || 0) / Math.max(1, Number(allTimeCard.rows[0].total || 0))
            : 0

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: root.alpha(foreground, 0.05)
          }
          Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width * root.clamp(modelRow.share, 0, 1)
            radius: Style.cornerRadius
            color: root.alpha(foreground, 0.14)
            Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
          }
          Text {
            id: modelName
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.right: modelTokens.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: usageMain.friendlyModelName(modelData.modelId)
            color: foreground
            font.family: fontFamily
            font.pixelSize: 11
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            id: modelTokens
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: usageMain.formatTokenCount(modelData.total || 0)
            color: dim
            font.family: fontFamily
            font.pixelSize: 10
            font.bold: true
          }

          MouseArea {
            id: modelHover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
          }
          PanelToolTip {
            visible: modelHover.containsMouse
            text: root.modelTooltip(modelData)
            fontFamily: root.fontFamily
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: allTimeCard.hiddenModels > 0
        Layout.fillWidth: true
        text: strings.tn("cline.moreModels", allTimeCard.hiddenModels)
          .arg(Commons.I18n.formatNumber(allTimeCard.hiddenModels))
        color: dim
        font.family: fontFamily
        font.pixelSize: 10
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }

  component SectionCard: BorderSurface {
    id: section
    property string title: ""
    property string subtitle: ""
    property color titleColor: foreground
    default property alias content: body.data

    Layout.fillWidth: true
    color: card
    borderSpec: Border.flat(Qt.rgba(foreground.r, foreground.g, foreground.b, 0.05), 1)
    padding: 12
    radius: Style.cornerRadius
    implicitHeight: body.implicitHeight + contentTopInset + contentBottomInset

    ColumnLayout {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: section.contentTopInset
      anchors.rightMargin: section.contentRightInset
      anchors.bottomMargin: section.contentBottomInset
      anchors.leftMargin: section.contentLeftInset
      spacing: 8

      PanelSectionHeader {
        visible: section.title !== ""
        Layout.fillWidth: true
        text: section.title
        foreground: section.titleColor
        fontFamily: root.fontFamily
        fontSize: 11
      }
      Text {
        textFormat: Text.PlainText
        visible: section.subtitle !== ""
        Layout.fillWidth: true
        text: section.subtitle
        color: dim
        font.family: fontFamily
        font.pixelSize: 10
        wrapMode: Text.WordWrap
      }
    }
  }

  component StatBlock: ColumnLayout {
    property string value: "0"
    property string label: ""
    spacing: 2
    Text { textFormat: Text.PlainText; text: value; color: foreground; font.family: fontFamily; font.pixelSize: 18; font.bold: true }
    Text { textFormat: Text.PlainText; text: label; color: dim; font.family: fontFamily; font.pixelSize: 10 }
  }

}
