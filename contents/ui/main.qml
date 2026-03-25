import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
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

    // Ticks every minute to keep "Updated: Xm ago" text fresh
    property int timeTick: 0

    Timer {
        interval: 60000
        running: lastUpdated != null
        repeat: true
        onTriggered: timeTick++
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
                var fallbackOrgId = null

                // Prefer orgs with a paid subscription
                for (var i = 0; i < orgs.length; i++) {
                    var org = orgs[i]
                    var hasChat = org.capabilities && org.capabilities.indexOf("chat") >= 0

                    if (!hasChat) continue

                    if (org.billing_type && org.billing_type !== "none") {
                        orgId = org.uuid
                        break
                    }

                    if (!fallbackOrgId) {
                        fallbackOrgId = org.uuid
                    }
                }

                orgId = orgId || fallbackOrgId || (orgs.length > 0 ? orgs[0].uuid : null)

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
            isLoading = false

            if (response.error) {
                lastError = response.error
                return
            }

            if (response.status !== 200) {
                lastError = "Failed to fetch usage: " + response.status
                return
            }

            try {
                var data = JSON.parse(response.body)
                processUsageData(data)
                lastUpdated = new Date()
            } catch (e) {
                lastError = "Failed to parse usage data"
            }
        })
    }

    function processUsageData(data) {
        var newData = {}

        // Session (5-hour window)
        if (data.five_hour && data.five_hour.utilization !== undefined) {
            newData.session = {
                used: data.five_hour.utilization,
                resets_at: data.five_hour.resets_at,
                resets_in: formatTimeRemaining(parseISODate(data.five_hour.resets_at))
            }
        }

        // Weekly (7-day window)
        if (data.seven_day && data.seven_day.utilization !== undefined) {
            newData.weekly = {
                used: data.seven_day.utilization,
                resets_at: data.seven_day.resets_at,
                resets_in: formatTimeRemaining(parseISODate(data.seven_day.resets_at))
            }
        }

        usageData = newData
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
            return "Resets on " + resetsAt.toLocaleString(Qt.locale(), "MMM d") + " at " + resetsAt.toLocaleTimeString(Qt.locale(), "HH:mm")
        }

        if (hours > 0) return "Resets in " + hours + "h " + minutes + "m"

        return "Resets in " + minutes + "m"
    }

    function getUsageColor(percentage) {
        if (percentage >= cfg_criticalThreshold) {
            return Kirigami.Theme.negativeTextColor
        } else if (percentage >= cfg_warningThreshold) {
            return Kirigami.Theme.neutralTextColor
        }
        return Kirigami.Theme.highlightColor
    }

    function formatTimeSince(date, _tick) {
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
            text += "Session: " + Math.round(usageData.session.used) + "%"
            if (usageData.session.resets_in) text += " - " + usageData.session.resets_in
        }

        if (usageData.weekly) {
            if (text) text += "\n"
            text += "Weekly: " + Math.round(usageData.weekly.used) + "%"
            if (usageData.weekly.resets_in) text += " - " + usageData.weekly.resets_in
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

        implicitWidth: Kirigami.Units.gridUnit * 2
        implicitHeight: Kirigami.Units.gridUnit * 2

        onClicked: root.expanded = !root.expanded

        PlasmaComponents.BusyIndicator {
            anchors.centerIn: parent
            running: isLoading
            visible: isLoading
            implicitWidth: Kirigami.Units.gridUnit
            implicitHeight: Kirigami.Units.gridUnit
        }

        // Circular progress ring
        Shape {
            id: progressRing

            property real ringSize: Math.min(parent.width, parent.height) - Kirigami.Units.smallSpacing * 2
            property real ringWidth: ringSize * 0.15
            property real ringRadius: (ringSize - ringWidth) / 2
            property real centerXY: ringSize / 2

            property bool hasError: lastError && !usageData
            property bool isUnconfigured: !cfg_sessionKey
            property bool hasData: usageData && usageData.session
            property real sessionUsed: hasData ? usageData.session.used : 0

            property real sweepAngle: {
                if (isUnconfigured || hasError) return 360
                if (hasData) return (Math.min(Math.max(sessionUsed, 0), 100) / 100) * 360
                return 0
            }

            property color arcColor: {
                if (isUnconfigured) return Kirigami.Theme.disabledTextColor
                if (hasError) return Kirigami.Theme.negativeTextColor
                if (hasData) return getUsageColor(sessionUsed)
                return Kirigami.Theme.disabledTextColor
            }

            anchors.centerIn: parent
            width: ringSize
            height: ringSize
            visible: !isLoading

            // Background track
            ShapePath {
                fillColor: "transparent"
                strokeColor: Qt.rgba(
                    Kirigami.Theme.textColor.r,
                    Kirigami.Theme.textColor.g,
                    Kirigami.Theme.textColor.b,
                    0.15
                )
                strokeWidth: progressRing.ringWidth
                capStyle: ShapePath.RoundCap

                PathAngleArc {
                    centerX: progressRing.centerXY
                    centerY: progressRing.centerXY
                    radiusX: progressRing.ringRadius
                    radiusY: progressRing.ringRadius
                    startAngle: -90
                    sweepAngle: 360
                }
            }

            // Foreground progress arc
            ShapePath {
                fillColor: "transparent"
                strokeColor: progressRing.arcColor
                strokeWidth: progressRing.ringWidth
                capStyle: ShapePath.RoundCap

                PathAngleArc {
                    centerX: progressRing.centerXY
                    centerY: progressRing.centerXY
                    radiusX: progressRing.ringRadius
                    radiusY: progressRing.ringRadius
                    startAngle: -90
                    sweepAngle: progressRing.sweepAngle
                }
            }
        }
    }

    // ============================================================
    // Full Representation (Popup)
    // ============================================================

    fullRepresentation: ColumnLayout {
        id: fullRep

        Layout.preferredWidth: Kirigami.Units.gridUnit * 18
        spacing: 0

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
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            Layout.topMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents.Label {
                text: "Session (5h window)"
                font.pixelSize: Kirigami.Units.gridUnit * 0.9
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: Kirigami.Units.gridUnit * 0.4
                    radius: height / 2
                    color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.15)

                    property real progressValue: usageData && usageData.session ? usageData.session.used : 0

                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: parent.width * (Math.min(Math.max(parent.progressValue, 0), 100) / 100)
                        radius: parent.radius
                        color: usageData && usageData.session
                            ? getUsageColor(usageData.session.used)
                            : Kirigami.Theme.highlightColor

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
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            Layout.topMargin: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents.Label {
                text: "Weekly (7 day window)"
                font.pixelSize: Kirigami.Units.gridUnit * 0.9
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: Kirigami.Units.gridUnit * 0.4
                    radius: height / 2
                    color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.15)

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
                    Layout.minimumWidth: Kirigami.Units.gridUnit * 2
                    horizontalAlignment: Text.AlignRight
                }
            }

            PlasmaComponents.Label {
                text: usageData && usageData.weekly ? usageData.weekly.resets_in : ""
                font.pixelSize: Kirigami.Units.gridUnit * 0.8
                color: Kirigami.Theme.disabledTextColor
            }
        }

        // Footer with last updated time
        PlasmaComponents.Label {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            Layout.topMargin: Kirigami.Units.largeSpacing
            text: cfg_sessionKey ? "Updated: " + formatTimeSince(lastUpdated, timeTick) : ""
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
