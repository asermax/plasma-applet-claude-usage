import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // ============================================================
    // Properties
    // ============================================================

    property var usageData: null
    property string lastError: ""
    property bool isLoading: false
    property var lastUpdated: null
    property bool serverRunning: false

    // Configuration properties
    property int cfg_refreshInterval: plasmoid.configuration.refreshInterval
    property bool cfg_showWeeklyInTray: plasmoid.configuration.showWeeklyInTray
    property int cfg_warningThreshold: plasmoid.configuration.warningThreshold
    property int cfg_criticalThreshold: plasmoid.configuration.criticalThreshold
    property string cfg_manualSessionKey: plasmoid.configuration.manualSessionKey
    property string cfg_browserType: plasmoid.configuration.browserType

    // Server URL
    readonly property string serverUrl: "http://127.0.0.1:17432"

    // ============================================================
    // Timer for periodic refresh
    // ============================================================

    Timer {
        id: refreshTimer
        interval: cfg_refreshInterval * 1000
        running: true
        repeat: true
        onTriggered: fetchUsage()
    }

    // Timer to start server if not running
    Timer {
        id: serverCheckTimer
        interval: 5000
        running: true
        repeat: true
        onTriggered: checkServer()
    }

    // ============================================================
    // Functions
    // ============================================================

    function checkServer() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", serverUrl + "/health", true)
        xhr.timeout = 2000
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                var wasRunning = serverRunning
                serverRunning = xhr.status === 200

                if (!serverRunning && !wasRunning) {
                    // Server not running, try to start it
                    startServer()
                }
            }
        }
        xhr.onerror = function() {
            serverRunning = false
        }
        xhr.send()
    }

    function startServer() {
        // The server needs to be started externally or via systemd
        // For now, we'll show an error if it's not running
        if (!serverRunning) {
            lastError = "Server not running. Start with: python3 " + getScriptPath() + " --server &"
        }
    }

    function getScriptPath() {
        return Qt.resolvedUrl("../code/claude-usage.py").toString().replace("file://", "")
    }

    function fetchUsage() {
        if (isLoading) return

        isLoading = true

        var xhr = new XMLHttpRequest()
        xhr.open("GET", serverUrl + "/usage", true)
        xhr.timeout = 15000

        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                isLoading = false

                if (xhr.status === 200) {
                    try {
                        var result = JSON.parse(xhr.responseText)
                        usageData = result
                        lastError = result.error || ""
                        lastUpdated = new Date()
                        serverRunning = true
                    } catch (e) {
                        lastError = "Failed to parse response"
                        usageData = null
                    }
                } else {
                    lastError = "Server error: " + xhr.status
                    serverRunning = false
                }
            }
        }

        xhr.onerror = function() {
            isLoading = false
            lastError = "Connection failed"
            serverRunning = false
        }

        xhr.ontimeout = function() {
            isLoading = false
            lastError = "Request timed out"
        }

        xhr.send()
    }

    function updateConfig() {
        var xhr = new XMLHttpRequest()
        xhr.open("POST", serverUrl + "/config", true)
        xhr.setRequestHeader("Content-Type", "application/json")

        var config = {
            manual_key: cfg_manualSessionKey,
            browser: cfg_browserType || "auto"
        }

        xhr.send(JSON.stringify(config))
    }

    function forceRefresh() {
        isLoading = true

        var xhr = new XMLHttpRequest()
        xhr.open("POST", serverUrl + "/refresh", true)
        xhr.timeout = 15000

        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                isLoading = false

                if (xhr.status === 200) {
                    try {
                        var result = JSON.parse(xhr.responseText)
                        usageData = result
                        lastError = result.error || ""
                        lastUpdated = new Date()
                    } catch (e) {
                        lastError = "Failed to parse response"
                    }
                }
            }
        }

        xhr.send()
    }

    function getUsageColor(percentage) {
        if (percentage >= cfg_criticalThreshold) {
            return Kirigami.Theme.negativeTextColor
        } else if (percentage >= cfg_warningThreshold) {
            return Kirigami.Theme.neutralTextColor
        }
        return Kirigami.Theme.positiveTextColor
    }

    function getTrayText() {
        if (isLoading) return "..."

        if (!serverRunning) return "!"

        if (lastError && !usageData) return "!"

        if (!usageData) return "?"

        if (cfg_showWeeklyInTray && usageData.weekly) {
            return Math.round(usageData.weekly.used) + "%"
        }

        if (usageData.session) {
            return Math.round(usageData.session.used) + "%"
        }

        return "?"
    }

    function getTrayColor() {
        if (!serverRunning || (lastError && !usageData)) {
            return Kirigami.Theme.negativeTextColor
        }

        if (!usageData) {
            return Kirigami.Theme.textColor
        }

        var percentage = cfg_showWeeklyInTray && usageData.weekly
            ? usageData.weekly.used
            : (usageData.session ? usageData.session.used : 0)

        return getUsageColor(percentage)
    }

    function formatTimeSince(date) {
        if (!date) return "Never"

        var now = new Date()
        var diff = Math.floor((now - date) / 1000)

        if (diff < 60) return "Just now"
        if (diff < 3600) return Math.floor(diff / 60) + "m ago"
        if (diff < 86400) return Math.floor(diff / 3600) + "h ago"

        return Math.floor(diff / 86400) + "d ago"
    }

    // Watch for config changes
    onCfg_manualSessionKeyChanged: updateConfig()
    onCfg_browserTypeChanged: updateConfig()

    // ============================================================
    // ToolTip
    // ============================================================

    Plasmoid.toolTipMainText: "Claude Code Usage"
    Plasmoid.toolTipSubText: {
        if (!serverRunning) return "Server not running"

        if (lastError && !usageData) return lastError

        if (!usageData) return "No data"

        var session = usageData.session ? Math.round(usageData.session.used) + "%" : "?"
        var weekly = usageData.weekly ? Math.round(usageData.weekly.used) + "%" : "?"

        return "Session: " + session + " | Weekly: " + weekly
    }

    // ============================================================
    // Compact Representation (System Tray)
    // ============================================================

    compactRepresentation: PlasmaComponents.AbstractButton {
        id: compactRep

        implicitWidth: PlasmaCore.Units.gridUnit * 2.5
        implicitHeight: PlasmaCore.Units.gridUnit

        onClicked: root.expanded = !root.expanded

        PlasmaComponents.Label {
            anchors.centerIn: parent
            text: getTrayText()
            color: getTrayColor()
            font.bold: true
            font.pixelSize: PlasmaCore.Units.gridUnit * 0.8
        }

        // Loading animation
        PlasmaComponents.BusyIndicator {
            anchors.centerIn: parent
            running: isLoading
            visible: isLoading
            implicitWidth: PlasmaCore.Units.gridUnit
            implicitHeight: PlasmaCore.Units.gridUnit
        }
    }

    // ============================================================
    // Full Representation (Popup)
    // ============================================================

    fullRepresentation: ColumnLayout {
        id: fullRep

        implicitWidth: PlasmaCore.Units.gridUnit * 18
        implicitHeight: PlasmaCore.Units.gridUnit * 16
        spacing: PlasmaCore.Units.smallSpacing

        // Header
        RowLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: PlasmaCore.Units.smallSpacing

            PlasmaComponents.Label {
                text: "Claude Code Usage"
                font.bold: true
                font.pixelSize: PlasmaCore.Units.gridUnit * 1.1
                Layout.fillWidth: true
            }

            PlasmaComponents.ToolButton {
                icon.name: "view-refresh"
                text: "Refresh"
                display: PlasmaComponents.AbstractButton.IconOnly
                onClicked: forceRefresh()
                enabled: !isLoading && serverRunning
                PlasmaComponents.ToolTip.text: "Refresh"
                PlasmaComponents.ToolTip.visible: hovered
            }
        }

        // Server status
        PlasmaComponents.Label {
            visible: !serverRunning
            text: "⚠ Server not running. Start with:\npython3 ~/.local/share/plasma/plasmoids/com.github.claude-usage/contents/code/claude-usage.py --server &"
            color: Kirigami.Theme.negativeTextColor
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            font.pixelSize: PlasmaCore.Units.gridUnit * 0.8
        }

        // Error state
        PlasmaComponents.Label {
            visible: serverRunning && lastError !== "" && !usageData
            text: lastError
            color: Kirigami.Theme.negativeTextColor
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            Layout.topMargin: PlasmaCore.Units.largeSpacing
            Layout.bottomMargin: PlasmaCore.Units.largeSpacing
        }

        // Session usage
        ColumnLayout {
            visible: usageData && usageData.session
            Layout.fillWidth: true
            spacing: PlasmaCore.Units.smallSpacing

            PlasmaComponents.Label {
                text: "Session (5h window)"
                font.pixelSize: PlasmaCore.Units.gridUnit * 0.9
                color: Kirigami.Theme.disabledTextColor
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: PlasmaCore.Units.smallSpacing

                Kirigami.ProgressBar {
                    id: sessionProgress
                    Layout.fillWidth: true
                    from: 0
                    to: 100
                    value: usageData && usageData.session ? usageData.session.used : 0
                }

                PlasmaComponents.Label {
                    text: usageData && usageData.session
                        ? Math.round(usageData.session.used) + "%"
                        : "0%"
                    font.bold: true
                    color: usageData && usageData.session
                        ? getUsageColor(usageData.session.used)
                        : Kirigami.Theme.textColor
                    Layout.minimumWidth: PlasmaCore.Units.gridUnit * 2
                    horizontalAlignment: Text.AlignRight
                }
            }

            PlasmaComponents.Label {
                text: usageData && usageData.session ? usageData.session.resets_in : ""
                font.pixelSize: PlasmaCore.Units.gridUnit * 0.8
                color: Kirigami.Theme.disabledTextColor
            }
        }

        // Weekly usage
        ColumnLayout {
            visible: usageData && usageData.weekly
            Layout.fillWidth: true
            spacing: PlasmaCore.Units.smallSpacing
            Layout.topMargin: PlasmaCore.Units.smallSpacing

            PlasmaComponents.Label {
                text: "Weekly (7 day window)"
                font.pixelSize: PlasmaCore.Units.gridUnit * 0.9
                color: Kirigami.Theme.disabledTextColor
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: PlasmaCore.Units.smallSpacing

                Kirigami.ProgressBar {
                    Layout.fillWidth: true
                    from: 0
                    to: 100
                    value: usageData && usageData.weekly ? usageData.weekly.used : 0
                }

                PlasmaComponents.Label {
                    text: usageData && usageData.weekly
                        ? Math.round(usageData.weekly.used) + "%"
                        : "0%"
                    font.bold: true
                    color: usageData && usageData.weekly
                        ? getUsageColor(usageData.weekly.used)
                        : Kirigami.Theme.textColor
                    Layout.minimumWidth: PlasmaCore.Units.gridUnit * 2
                    horizontalAlignment: Text.AlignRight
                }
            }

            PlasmaComponents.Label {
                text: usageData && usageData.weekly ? usageData.weekly.resets_date : ""
                font.pixelSize: PlasmaCore.Units.gridUnit * 0.8
                color: Kirigami.Theme.disabledTextColor
            }
        }

        // Extra usage (only shown when enabled)
        ColumnLayout {
            visible: usageData && usageData.extra_usage && usageData.extra_usage.enabled
            Layout.fillWidth: true
            spacing: PlasmaCore.Units.smallSpacing
            Layout.topMargin: PlasmaCore.Units.smallSpacing

            PlasmaComponents.Label {
                text: "Extra Usage (Monthly)"
                font.pixelSize: PlasmaCore.Units.gridUnit * 0.9
                color: Kirigami.Theme.disabledTextColor
            }

            PlasmaComponents.Label {
                text: {
                    if (!usageData || !usageData.extra_usage) return ""

                    var used = usageData.extra_usage.used.toFixed(2)
                    var limit = usageData.extra_usage.limit.toFixed(2)
                    var currency = usageData.extra_usage.currency || "USD"

                    return currency + "$" + used + " / $" + limit + " used"
                }
                font.bold: true
            }
        }

        // Spacer
        Item {
            Layout.fillHeight: true
        }

        // Footer with last updated time
        PlasmaComponents.Label {
            Layout.fillWidth: true
            text: "Updated: " + formatTimeSince(lastUpdated)
            font.pixelSize: PlasmaCore.Units.gridUnit * 0.7
            color: Kirigami.Theme.disabledTextColor
            horizontalAlignment: Text.AlignRight
        }
    }

    // ============================================================
    // Initialization
    // ============================================================

    Component.onCompleted: {
        checkServer()
    }
}
