import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.components as PlasmaComponents

PlasmaComponents.ScrollView {
    id: scrollView

    contentWidth: availableWidth
    padding: Kirigami.Units.gridUnit

    property bool claudeAvailable: false
    property bool antigravityAvailable: false

    // Plasma only scans the config page's ROOT item for cfg_* properties, so
    // every alias has to live here rather than on the inner FormLayout.
    property alias cfg_claudeEnabled: claudeEnabledSwitch.checked
    property alias cfg_glmEnabled: glmEnabledSwitch.checked
    property alias cfg_codexEnabled: codexEnabledSwitch.checked
    property alias cfg_antigravityEnabled: antigravityEnabledSwitch.checked
    property alias cfg_glmToken: glmTokenField.text
    property alias cfg_codexToken: codexTokenField.text
    property alias cfg_refreshInterval: refreshIntervalSpinBox.value
    property alias cfg_warningThreshold: warningThresholdSpinBox.value
    property alias cfg_criticalThreshold: criticalThresholdSpinBox.value

    Kirigami.FormLayout {
        id: configPage

        width: scrollView.availableWidth

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Claude (Claude Code CLI)")
        }

        Switch {
            id: claudeEnabledSwitch
            Kirigami.FormData.label: i18n("Enabled:")
            enabled: scrollView.claudeAvailable
        }

        PlasmaComponents.Label {
            Layout.fillWidth: true
            text: scrollView.claudeAvailable
                ? i18n("Usage is read from the Claude Code CLI with 'claude -p \"/usage\"', so no session key is needed.\nRun 'claude' once to log in if the widget reports an auth error.")
                : i18n("The Claude Code CLI ('claude') was not found in PATH, so this cannot be enabled.\nInstall the claude-code package to track Claude usage.")
            font: Kirigami.Theme.smallFont
            color: scrollView.claudeAvailable ? Kirigami.Theme.disabledTextColor : Kirigami.Theme.negativeTextColor
            wrapMode: Text.WordWrap
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("GLM Authentication")
        }

        Switch {
            id: glmEnabledSwitch
            Kirigami.FormData.label: i18n("Enabled:")
        }

        TextField {
            id: glmTokenField
            Kirigami.FormData.label: i18n("GLM Token:")
            placeholderText: i18n("Paste your z.ai open platform token here")
            echoMode: TextInput.Password
            Layout.fillWidth: true
        }

        PlasmaComponents.Label {
            Layout.fillWidth: true
            text: i18n("To get your GLM token:\n1. Go to z.ai in your browser and login\n2. Open DevTools (F12) → Application → Local Storage\n3. Select z.ai → Copy 'z-ai-open-platform-token-production' value")
            font: Kirigami.Theme.smallFont
            color: Kirigami.Theme.disabledTextColor
            wrapMode: Text.WordWrap
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Codex Authentication (OpenAI)")
        }

        Switch {
            id: codexEnabledSwitch
            Kirigami.FormData.label: i18n("Enabled:")
        }

        TextField {
            id: codexTokenField
            Kirigami.FormData.label: i18n("Codex Token (optional):")
            placeholderText: i18n("Leave empty to auto-detect from ~/.codex/auth.json")
            echoMode: TextInput.Password
            Layout.fillWidth: true
        }

        PlasmaComponents.Label {
            Layout.fillWidth: true
            text: i18n("The Codex token is loaded automatically from ~/.codex/auth.json\nif you have the Codex CLI installed and are logged in.\nRun 'codex' in your terminal to set up authentication.\n\nTo manually override, paste your Codex OAuth access token above.\nFind it in ~/.codex/auth.json → tokens.access_token")
            font: Kirigami.Theme.smallFont
            color: Kirigami.Theme.disabledTextColor
            wrapMode: Text.WordWrap
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Antigravity")
        }

        Switch {
            id: antigravityEnabledSwitch
            Kirigami.FormData.label: i18n("Enabled:")
            enabled: scrollView.antigravityAvailable
        }

        PlasmaComponents.Label {
            Layout.fillWidth: true
            text: scrollView.antigravityAvailable
                ? i18n("Quota is read from the Antigravity CLI with 'agy -p \"/quota\"', so no token is needed.\nRun 'agy' once to log in if the widget reports an auth error.")
                : i18n("The Antigravity CLI ('agy') was not found in PATH, so this cannot be enabled.\nInstall the antigravity-cli package to track Antigravity quota.")
            font: Kirigami.Theme.smallFont
            color: scrollView.antigravityAvailable ? Kirigami.Theme.disabledTextColor : Kirigami.Theme.negativeTextColor
            wrapMode: Text.WordWrap
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Display Options")
        }

        SpinBox {
            id: refreshIntervalSpinBox
            Kirigami.FormData.label: i18n("Refresh interval (seconds):")
            from: 60
            to: 3600
            stepSize: 60
            editable: true
        }

        SpinBox {
            id: warningThresholdSpinBox
            Kirigami.FormData.label: i18n("Warning threshold (%):")
            from: 0
            to: 100
            stepSize: 5
            editable: true
        }

        SpinBox {
            id: criticalThresholdSpinBox
            Kirigami.FormData.label: i18n("Critical threshold (%):")
            from: 0
            to: 100
            stepSize: 5
            editable: true
        }
    }

    Plasma5Support.DataSource {
        id: toolProbe
        engine: "executable"
        connectedSources: []

        onNewData: function(sourceName, data) {
            var available = data["exit code"] === 0

            if (sourceName === "command -v claude") scrollView.claudeAvailable = available
            if (sourceName === "command -v agy") scrollView.antigravityAvailable = available

            disconnectSource(sourceName)
        }
    }

    Component.onCompleted: {
        toolProbe.connectSource("command -v claude")
        toolProbe.connectSource("command -v agy")
    }
}
