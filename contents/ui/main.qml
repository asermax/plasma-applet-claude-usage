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
    property string cfg_sessionKey: plasmoid.configuration.sessionKey
    property int cfg_refreshInterval: plasmoid.configuration.refreshInterval
    property bool cfg_showWeeklyInTray: plasmoid.configuration.showWeeklyInTray
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
    // Functions
    // ============================================================

    function fetchUsage() {
        if (isLoading || !cfg_sessionKey) return

        isLoading = true
        lastError = ""

        // First get organization
        var orgXhr = new XMLHttpRequest()
        orgXhr.open("GET", "https://claude.ai/api/organizations", true)
        orgXhr.setRequestHeader("Cookie", "sessionKey=" + cfg_sessionKey)
        orgXhr.setRequestHeader("Accept", "application/json")
        orgXhr.timeout = 15000

        orgXhr.onreadystatechange = function() {
            if (orgXhr.readyState === XMLHttpRequest.DONE) {
                if (orgXhr.status === 200) {
                    try {
                        var orgs = JSON.parse(orgXhr.responseText)
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
                } else if (orgXhr.status === 401 || orgXhr.status === 403) {
                    isLoading = false
                    lastError = "Session expired - update cookie in config"
                } else {
                    isLoading = false
                    lastError = "Failed to fetch organizations: " + orgXhr.status
                }
            }
        }

        orgXhr.onerror = function() {
            isLoading = false
            lastError = "Network error"
        }

        orgXhr.ontimeout = function() {
            isLoading = false
            lastError = "Request timed out"
        }

        orgXhr.send()
    }

    function fetchUsageData(orgId) {
        var usageXhr = new XMLHttpRequest()
        usageXhr.open("GET", "https://claude.ai/api/organizations/" + orgId + "/usage", true)
        usageXhr.setRequestHeader("Cookie", "sessionKey=" + cfg_sessionKey)
        usageXhr.setRequestHeader("Accept", "application/json")
        usageXhr.timeout = 15000

        usageXhr.onreadystatechange = function() {
            if (usageXhr.readyState === XMLHttpRequest.DONE) {
                if (usageXhr.status === 200) {
                    try {
                        var data = JSON.parse(usageXhr.responseText)
                        processUsageData(data)
                        fetchExtraUsage(orgId)
                    } catch (e) {
                        isLoading = false
                        lastError = "Failed to parse usage data"
                    }
                } else {
                    isLoading = false
                    lastError = "Failed to fetch usage: " + usageXhr.status
                }
            }
        }

        usageXhr.onerror = function() {
            isLoading = false
            lastError = "Network error"
        }

        usageXhr.send()
    }

    function fetchExtraUsage(orgId) {
        var extraXhr = new XMLHttpRequest()
        extraXhr.open("GET", "https://claude.ai/api/organizations/" + orgId + "/overage_spend_limit", true)
        extraXhr.setRequestHeader("Cookie", "sessionKey=" + cfg_sessionKey)
        extraXhr.setRequestHeader("Accept", "application/json")
        extraXhr.timeout = 10000

        extraXhr.onreadystatechange = function() {
            if (extraXhr.readyState === XMLHttpRequest.DONE) {
                isLoading = false
                if (extraXhr.status === 200) {
                    try {
                        var extraData = JSON.parse(extraXhr.responseText)
                        if (usageData && extraData.is_enabled) {
                            usageData.extra_usage = {
                                used: extraData.used_credits / 100.0,
                                limit: extraData.monthly_credit_limit / 100.0,
                                currency: extraData.currency || "USD",
                                enabled: true
                            }
                        }
                    } catch (e) {}
                }
                lastUpdated = new Date()
            }
        }

        extraXhr.onerror = function() {
            isLoading = false
            lastUpdated = new Date()
        }

        extraXhr.send()
    }

    function processUsageData(data) {
        usageData = {}

        // Session (5-hour window)
        if (data.five_hour && data.five_hour.utilization !== undefined) {
            var sessionResets = parseISODate(data.five_hour.resets_at)
            usageData.session = {
                used: data.five_hour.utilization,
                resets_at: data.five_hour.resets_at,
                resets_in: formatTimeRemaining(sessionResets),
                resets_date: formatResetDate(sessionResets)
            }
        }

        // Weekly (7-day window)
        if (data.seven_day && data.seven_day.utilization !== undefined) {
            var weeklyResets = parseISODate(data.seven_day.resets_at)
            usageData.weekly = {
                used: data.seven_day.utilization,
                resets_at: data.seven_day.resets_at,
                resets_in: formatTimeRemaining(weeklyResets),
                resets_date: formatResetDate(weeklyResets)
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

    function getTrayText() {
        if (!cfg_sessionKey) return "?"

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
        if (!cfg_sessionKey) {
            return Kirigami.Theme.disabledTextColor
        }

        if (lastError && !usageData) {
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

    // Watch for session key changes
    onCfg_sessionKeyChanged: {
        usageData = null
        if (cfg_sessionKey) {
            fetchUsage()
        }
    }

    // ============================================================
    // ToolTip
    // ============================================================

    Plasmoid.toolTipMainText: "Claude Code Usage"
    Plasmoid.toolTipSubText: {
        if (!cfg_sessionKey) return "Configure session key"

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
        implicitHeight: PlasmaCore.Units.gridUnit * 14
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
            spacing: PlasmaCore.Units.smallSpacing

            Kirigami.Icon {
                source: "dialog-information"
                implicitWidth: PlasmaCore.Units.gridUnit * 3
                implicitHeight: PlasmaCore.Units.gridUnit * 3
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: PlasmaCore.Units.gridUnit
            }

            PlasmaComponents.Label {
                text: "Configure your session key"
                font.bold: true
                Layout.alignment: Qt.AlignHCenter
            }

            PlasmaComponents.Label {
                text: "1. Go to claude.ai and login\n2. Open browser DevTools (F12)\n3. Go to Application → Cookies\n4. Copy the 'sessionKey' value\n5. Click configure button above"
                font.pixelSize: PlasmaCore.Units.gridUnit * 0.8
                color: Kirigami.Theme.disabledTextColor
                Layout.alignment: Qt.AlignHCenter
                Layout.leftMargin: PlasmaCore.Units.gridUnit
                Layout.rightMargin: PlasmaCore.Units.gridUnit
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }
        }

        // Error state
        PlasmaComponents.Label {
            visible: cfg_sessionKey && lastError !== "" && !usageData
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

                    return "$" + used + " / $" + limit + " used"
                }
                font.bold: true
            }
        }

        // Spacer
        Item {
            Layout.fillHeight: true
        }

        // Footer
        PlasmaComponents.Label {
            Layout.fillWidth: true
            text: cfg_sessionKey ? "Updated: " + formatTimeSince(lastUpdated) : ""
            font.pixelSize: PlasmaCore.Units.gridUnit * 0.7
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
