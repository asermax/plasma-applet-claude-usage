import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

Kirigami.FormLayout {
    id: configPage

    property alias cfg_sessionKey: sessionKeyField.text
    property alias cfg_glmToken: glmTokenField.text
    property alias cfg_refreshInterval: refreshIntervalSpinBox.value
    property alias cfg_warningThreshold: warningThresholdSpinBox.value
    property alias cfg_criticalThreshold: criticalThresholdSpinBox.value

    Kirigami.Separator {
        Kirigami.FormData.isSection: true
        Kirigami.FormData.label: i18n("Claude Authentication")
    }

    TextField {
        id: sessionKeyField
        Kirigami.FormData.label: i18n("Session Key:")
        placeholderText: i18n("Paste your claude.ai sessionKey cookie here")
        echoMode: TextInput.Password
        Layout.fillWidth: true
    }

    PlasmaComponents.Label {
        Layout.fillWidth: true
        text: i18n("To get your session key:\n1. Go to claude.ai in your browser and login\n2. Open DevTools (F12) → Application → Cookies\n3. Copy the 'sessionKey' value")
        font: Kirigami.Theme.smallFont
        color: Kirigami.Theme.disabledTextColor
        wrapMode: Text.WordWrap
        Layout.topMargin: Kirigami.Units.smallSpacing
    }

    Kirigami.Separator {
        Kirigami.FormData.isSection: true
        Kirigami.FormData.label: i18n("GLM Authentication")
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
