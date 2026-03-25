import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as Plasma5Support
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
    property string cfg_sessionKey: plasmoid.configuration.sessionKey
    property int cfg_refreshInterval: plasmoid.configuration.refreshInterval
    property int cfg_warningThreshold: plasmoid.configuration.warningThreshold
    property int cfg_criticalThreshold: plasmoid.configuration.criticalThreshold

    // ============================================================
    // Timer for periodic refresh
    // ============================================================

    Timer {
        id: refreshTimer
        interval: cfg_refreshInterval * 1000
        running: cfg_sessionKey !== ""
        repeat: true
        onTriggered: fetchUsage()
    }

    // ============================================================
    // HTTP requests via curl (QML XMLHttpRequest strips Cookie headers)
    // ============================================================

    Plasma5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        onNewData: function(sourceName, data) {
            var handler = requestHandlers[sourceName]
            if (handler) {
                delete requestHandlers[sourceName]

                var exitCode = data["exit code"]
                var stdout = (data["stdout"] || "").trim()

                if (exitCode !== 0) {
                    handler({ error: exitCode === 28 ? "Request timed out" : "Network error" })
                } else {
                    var lastNewline = stdout.lastIndexOf('\n')
                    var statusCode = parseInt(lastNewline >= 0 ? stdout.substring(lastNewline + 1) : stdout)
                    var body = lastNewline >= 0 ? stdout.substring(0, lastNewline) : ""

                    handler({ status: statusCode, body: body })
                }
            }
            disconnectSource(sourceName)
        }
    }

    property var requestHandlers: ({})

    function shellEscape(str) {
        return "'" + str.replace(/'/g, "'\\''") + "'"
    }

    function curlRequest(url, handler) {
        var cmd = "curl -s --max-time 15"
            + " --cookie " + shellEscape("sessionKey=" + cfg_sessionKey)
            + " -H 'Accept: application/json'"
            + " -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'"
            + " -H 'Referer: https://claude.ai/'"
            + " -H 'Origin: https://claude.ai'"
            + " -w '\\n%{http_code}'"
            + " " + shellEscape(url)

        requestHandlers[cmd] = handler
        executable.connectSource(cmd)
    }

    // ============================================================
    // Functions
    // ============================================================

    function fetchUsage() {
        if (isLoading || !cfg_sessionKey) return

        isLoading = true
        lastError = ""

        curlRequest("https://claude.ai/api/organizations", function(response) {
            if (response.error) {
                isLoading = false
                lastError = response.error
                return
            }

            if (response.status === 401 || response.status === 403) {
                isLoading = false
                lastError = "Session expired - update cookie in config"
                return
            }

            if (response.status !== 200) {
                isLoading = false
                lastError = "Failed to fetch organizations: " + response.status
                return
            }

            try {
                var orgs = JSON.parse(response.body)
                var orgId = null

                // Find org with chat capability
                for (var i = 0; i < orgs.length; i++) {
                    if (orgs[i].capabilities && orgs[i].capabilities.indexOf("chat") >= 0) {
                        orgId = orgs[i].uuid
                        break
                    }
                }

                if (!orgId && orgs.length > 0) {
                    orgId = orgs[0].uuid
                }

                if (orgId) {
                    fetchUsageData(orgId)
                } else {
                    isLoading = false
                    lastError = "No organization found"
                }
            } catch (e) {
                isLoading = false
                lastError = "Failed to parse organizations"
            }
        })
    }

    function fetchUsageData(orgId) {
        curlRequest("https://claude.ai/api/organizations/" + orgId + "/usage", function(response) {
            if (response.error) {
                isLoading = false
                lastError = response.error
                return
            }

            if (response.status !== 200) {
                isLoading = false
                lastError = "Failed to fetch usage: " + response.status
                return
            }

            try {
                var data = JSON.parse(response.body)
                processUsageData(data)
                fetchExtraUsage(orgId)
            } catch (e) {
                isLoading = false
                lastError = "Failed to parse usage data"
            }
        })
    }

    function fetchExtraUsage(orgId) {
        curlRequest("https://claude.ai/api/organizations/" + orgId + "/overage_spend_limit", function(response) {
            isLoading = false

            if (!response.error && response.status === 200) {
                try {
                    var extraData = JSON.parse(response.body)

                    if (usageData && extraData.is_enabled) {
                        usageData.extra_usage = {
                            used: extraData.used_credits / 100.0,
                            limit: extraData.monthly_credit_limit / 100.0,
                            currency: extraData.currency || "USD",
                            enabled: true
                        }
                        usageData = usageData
                    }
                } catch (e) {}
            }

            lastUpdated = new Date()
        })
    }

    function processUsageData(data) {
        usageData = {}

        // Session (5-hour window)
        if (data.five_hour && data.five_hour.utilization !== undefined) {
            usageData.session = {
                used: data.five_hour.utilization,
                resets_at: data.five_hour.resets_at,
                resets_in: formatTimeRemaining(parseISODate(data.five_hour.resets_at))
            }
        }

        // Weekly (7-day window)
        if (data.seven_day && data.seven_day.utilization !== undefined) {
            usageData.weekly = {
                used: data.seven_day.utilization,
                resets_at: data.seven_day.resets_at,
                resets_in: formatTimeRemaining(parseISODate(data.seven_day.resets_at)),
                resets_date: formatResetDate(parseISODate(data.seven_day.resets_at))
            }
        }

        usageData.extra_usage = null
        lastError = ""
    }

    function parseISODate(dateStr) {
        if (!dateStr) return null
        return new Date(dateStr)
    }

    function formatTimeRemaining(resetsAt) {
        if (!resetsAt) return ""

        var now = new Date()
        var diff = resetsAt - now

        if (diff <= 0) return "Resets soon"

        var totalSeconds = Math.floor(diff / 1000)
        var hours = Math.floor(totalSeconds / 3600)
        var minutes = Math.floor((totalSeconds % 3600) / 60)
        var days = Math.floor(hours / 24)

        if (days > 0) {
            var remainingHours = hours % 24
            if (remainingHours > 0) return "Resets in " + days + "d " + remainingHours + "h"
            return "Resets in " + days + " days"
        }

        if (hours > 0) return "Resets in " + hours + "h " + minutes + "m"

        return "Resets in " + minutes + "m"
    }

    function formatResetDate(resetsAt) {
        if (!resetsAt) return ""

        var now = new Date()
        var diff = resetsAt - now

        if (diff <= 0) return "Now"

        if (diff < 86400000) { // < 24 hours
            return resetsAt.toLocaleTimeString(Qt.locale(), "h:mm AP")
        } else if (diff < 604800000) { // < 7 days
            return resetsAt.toLocaleDateString(Qt.locale(), "MMM d, h:mm AP")
        } else {
            return resetsAt.toLocaleDateString(Qt.locale(), "MMM d")
        }
    }

    function getUsageColor(percentage) {
        if (percentage >= cfg_criticalThreshold) {
            return Kirigami.Theme.negativeTextColor
        } else if (percentage >= cfg_warningThreshold) {
            return Kirigami.Theme.neutralTextColor
        }
        return Kirigami.Theme.positiveTextColor
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
    // Tooltip
    // ============================================================

    toolTipMainText: "Claude Code Usage"
    toolTipSubText: {
        if (!cfg_sessionKey) return "Session key not configured"
        if (lastError) return lastError
        if (!usageData) return "Loading..."

        var text = ""

        if (usageData.session) {
            text += "Session: " + Math.round(usageData.session.used) + "% - " + usageData.session.resets_in
        }

        if (usageData.weekly) {
            if (text) text += "\n"
            text += "Weekly: " + Math.round(usageData.weekly.used) + "% - " + usageData.weekly.resets_in
        }

        return text
    }

    // Watch for session key changes
    onCfg_sessionKeyChanged: {
        usageData = null
        if (cfg_sessionKey) {
            fetchUsage()
        }
    }

    // ============================================================
    // Compact Representation (System Tray)
    // ============================================================

    compactRepresentation: PlasmaComponents.AbstractButton {
        id: compactRep

        implicitWidth: Kirigami.Units.gridUnit * 3
        implicitHeight: Kirigami.Units.gridUnit * 2

        onClicked: root.expanded = !root.expanded

        PlasmaComponents.BusyIndicator {
            anchors.centerIn: parent
            running: isLoading
            visible: isLoading
            implicitWidth: Kirigami.Units.gridUnit
            implicitHeight: Kirigami.Units.gridUnit
        }

        Column {
            anchors.centerIn: parent
            visible: !isLoading

            // Session usage (top line)
            PlasmaComponents.Label {
                anchors.horizontalCenter: parent.horizontalCenter
                text: {
                    if (!cfg_sessionKey) return "?"
                    if (lastError && !usageData) return "!"
                    if (usageData && usageData.session) return Math.round(usageData.session.used) + "%"
                    return "?"
                }
                color: {
                    if (!cfg_sessionKey) return Kirigami.Theme.disabledTextColor
                    if (lastError && !usageData) return Kirigami.Theme.negativeTextColor
                    if (usageData && usageData.session) return getUsageColor(usageData.session.used)
                    return Kirigami.Theme.textColor
                }
                font.bold: true
                font.pixelSize: Kirigami.Units.gridUnit * 0.7
            }

            // Weekly usage (bottom line)
            PlasmaComponents.Label {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: usageData != null
                text: usageData && usageData.weekly ? Math.round(usageData.weekly.used) + "%" : "?"
                color: usageData && usageData.weekly ? getUsageColor(usageData.weekly.used) : Kirigami.Theme.disabledTextColor
                font.pixelSize: Kirigami.Units.gridUnit * 0.6
            }
        }
    }

    // ============================================================
    // Full Representation (Popup)
    // ============================================================

    fullRepresentation: ColumnLayout {
        id: fullRep

        implicitWidth: Kirigami.Units.gridUnit * 18
        implicitHeight: Kirigami.Units.gridUnit * 14
        spacing: Kirigami.Units.smallSpacing

        // Header
        RowLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: Kirigami.Units.smallSpacing

            PlasmaComponents.Label {
                text: "Claude Code Usage"
                font.bold: true
                font.pixelSize: Kirigami.Units.gridUnit * 1.1
                Layout.fillWidth: true
            }

            PlasmaComponents.ToolButton {
                icon.name: "view-refresh"
                display: PlasmaComponents.AbstractButton.IconOnly
                onClicked: fetchUsage()
                enabled: !isLoading && cfg_sessionKey !== ""
                PlasmaComponents.ToolTip.text: "Refresh"
                PlasmaComponents.ToolTip.visible: hovered
            }

            PlasmaComponents.ToolButton {
                icon.name: "configure"
                display: PlasmaComponents.AbstractButton.IconOnly
                onClicked: plasmoid.internalAction("configure").trigger()
                PlasmaComponents.ToolTip.text: "Configure"
                PlasmaComponents.ToolTip.visible: hovered
            }
        }

        // No session key configured
        ColumnLayout {
            visible: !cfg_sessionKey
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Kirigami.Units.smallSpacing

            Item { Layout.fillHeight: true }

            Kirigami.Icon {
                source: "dialog-information"
                implicitWidth: Kirigami.Units.gridUnit * 3
                implicitHeight: Kirigami.Units.gridUnit * 3
                Layout.alignment: Qt.AlignHCenter
            }

            PlasmaComponents.Label {
                text: "Configure your session key"
                font.bold: true
                Layout.alignment: Qt.AlignHCenter
            }

            PlasmaComponents.Label {
                text: "1. Go to claude.ai and login\n2. Open DevTools (F12)\n3. Application → Cookies\n4. Copy 'sessionKey' value\n5. Click configure button above"
                font.pixelSize: Kirigami.Units.gridUnit * 0.8
                color: Kirigami.Theme.disabledTextColor
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.gridUnit
                Layout.rightMargin: Kirigami.Units.gridUnit
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            Item { Layout.fillHeight: true }
        }

        // Error state
        PlasmaComponents.Label {
            visible: cfg_sessionKey && lastError !== "" && !usageData
            text: lastError
            color: Kirigami.Theme.negativeTextColor
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            Layout.topMargin: Kirigami.Units.largeSpacing
            Layout.bottomMargin: Kirigami.Units.largeSpacing
        }

        // Session usage
        ColumnLayout {
            visible: usageData && usageData.session
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents.Label {
                text: "Session (5h window)"
                font.pixelSize: Kirigami.Units.gridUnit * 0.9
                color: Kirigami.Theme.disabledTextColor
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                // Custom Progress Bar
                Rectangle {
                    id: sessionProgress
                    Layout.fillWidth: true
                    implicitHeight: Kirigami.Units.gridUnit * 0.4
                    radius: height / 2
                    color: Kirigami.Theme.alternateBackgroundColor

                    property real progressValue: usageData && usageData.session ? usageData.session.used : 0
                    property color progressColor: usageData && usageData.session
                        ? getUsageColor(usageData.session.used)
                        : Kirigami.Theme.highlightColor

                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: parent.width * (Math.min(Math.max(parent.progressValue, 0), 100) / 100)
                        radius: parent.radius
                        color: parent.progressColor

                        Behavior on width {
                            NumberAnimation { duration: 200 }
                        }
                    }
                }

                PlasmaComponents.Label {
                    text: usageData && usageData.session
                        ? Math.round(usageData.session.used) + "%"
                        : "0%"
                    font.bold: true
                    color: usageData && usageData.session
                        ? getUsageColor(usageData.session.used)
                        : Kirigami.Theme.textColor
                    Layout.minimumWidth: Kirigami.Units.gridUnit * 2
                    horizontalAlignment: Text.AlignRight
                }
            }

            PlasmaComponents.Label {
                text: usageData && usageData.session ? usageData.session.resets_in : ""
                font.pixelSize: Kirigami.Units.gridUnit * 0.8
                color: Kirigami.Theme.disabledTextColor
            }
        }

        // Weekly usage
        ColumnLayout {
            visible: usageData && usageData.weekly
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            Layout.topMargin: Kirigami.Units.smallSpacing

            PlasmaComponents.Label {
                text: "Weekly (7 day window)"
                font.pixelSize: Kirigami.Units.gridUnit * 0.9
                color: Kirigami.Theme.disabledTextColor
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                // Custom Progress Bar
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: Kirigami.Units.gridUnit * 0.4
                    radius: height / 2
                    color: Kirigami.Theme.alternateBackgroundColor

                    property real progressValue: usageData && usageData.weekly ? usageData.weekly.used : 0

                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: parent.width * (Math.min(Math.max(parent.progressValue, 0), 100) / 100)
                        radius: parent.radius
                        color: usageData && usageData.weekly
                            ? getUsageColor(usageData.weekly.used)
                            : Kirigami.Theme.highlightColor

                        Behavior on width {
                            NumberAnimation { duration: 200 }
                        }
                    }
                }

                PlasmaComponents.Label {
                    text: usageData && usageData.weekly
                        ? Math.round(usageData.weekly.used) + "%"
                        : "0%"
                    font.bold: true
                    color: usageData && usageData.weekly
                        ? getUsageColor(usageData.weekly.used)
                        : Kirigami.Theme.textColor
                    Layout.minimumWidth: Kirigami.Units.gridUnit * 2
                    horizontalAlignment: Text.AlignRight
                }
            }

            PlasmaComponents.Label {
                text: usageData && usageData.weekly ? usageData.weekly.resets_date : ""
                font.pixelSize: Kirigami.Units.gridUnit * 0.8
                color: Kirigami.Theme.disabledTextColor
            }
        }

        // Extra usage (only shown when enabled)
        ColumnLayout {
            visible: usageData && usageData.extra_usage && usageData.extra_usage.enabled
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            Layout.topMargin: Kirigami.Units.smallSpacing

            PlasmaComponents.Label {
                text: "Extra Usage (Monthly)"
                font.pixelSize: Kirigami.Units.gridUnit * 0.9
                color: Kirigami.Theme.disabledTextColor
            }

            PlasmaComponents.Label {
                text: {
                    if (!usageData || !usageData.extra_usage) return ""

                    var used = usageData.extra_usage.used.toFixed(2)
                    var limit = usageData.extra_usage.limit.toFixed(2)

                    return "$" + used + " / $" + limit + " used"
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
            text: cfg_sessionKey ? "Updated: " + formatTimeSince(lastUpdated) : ""
            font.pixelSize: Kirigami.Units.gridUnit * 0.7
            color: Kirigami.Theme.disabledTextColor
            horizontalAlignment: Text.AlignRight
        }
    }

    // ============================================================
    // Initialization
    // ============================================================

    Component.onCompleted: {
        if (cfg_sessionKey) {
            fetchUsage()
        }
    }
}
