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

    // Configuration properties
    property int cfg_refreshInterval: plasmoid.configuration.refreshInterval
    property bool cfg_showWeeklyInTray: plasmoid.configuration.showWeeklyInTray
    property int cfg_warningThreshold: plasmoid.configuration.warningThreshold
    property int cfg_criticalThreshold: plasmoid.configuration.criticalThreshold
    property string cfg_manualSessionKey: plasmoid.configuration.manualSessionKey

    // ============================================================
    // Data Source for executing Python script
    // ============================================================

    PlasmaCore.DataSource {
        id: executableSource
        engine: "executable"

        onNewData: function(sourceName, data) {
            isLoading = false

            if (data["exit code"] !== 0) {
                lastError = data.stderr || "Script execution failed"
                usageData = null
                return
            }

            try {
                var result = JSON.parse(data.stdout)
                if (result.success) {
                    usageData = result
                    lastError = ""
                    lastUpdated = new Date()
                } else {
                    lastError = result.error || "Unknown error"
                    usageData = null
                }
            } catch (e) {
                lastError = "Failed to parse response"
                usageData = null
            }
        }
    }

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

    // ============================================================
    // Functions
    // ============================================================

    function fetchUsage() {
        if (isLoading) return

        isLoading = true
        lastError = ""

        var scriptPath = Qt.resolvedUrl("../code/claude-usage.py")
        var cmd = "python3 " + scriptPath

        if (cfg_manualSessionKey && cfg_manualSessionKey.length > 0) {
            cmd += " --manual-key '" + cfg_manualSessionKey + "'"
        }

        cmd += " --browser auto"

        executableSource.connectSource(cmd)
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

        if (lastError) return "!"

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
        if (lastError || !usageData) {
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

    // ============================================================
    // ToolTip
    // ============================================================

    Plasmoid.toolTipMainText: "Claude Code Usage"
    Plasmoid.toolTipSubText: {
        if (lastError) return lastError
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
                onClicked: fetchUsage()
                enabled: !isLoading
                PlasmaComponents.ToolTip.text: "Refresh"
                PlasmaComponents.ToolTip.visible: hovered
            }
        }

        // Error state
        PlasmaComponents.Label {
            visible: lastError !== ""
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

                    // Custom color based on usage
                    property color progressColor: usageData && usageData.session
                        ? getUsageColor(usageData.session.used)
                        : Kirigami.Theme.highlightColor
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
        fetchUsage()
    }
}
