import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

Kirigami.FormLayout {
    id: configPage

    property alias cfg_sessionKey: sessionKeyField.text
    property alias cfg_refreshInterval: refreshIntervalSpinBox.value
    property alias cfg_warningThreshold: warningThresholdSpinBox.value
    property alias cfg_criticalThreshold: criticalThresholdSpinBox.value

    Kirigami.Separator {
        Kirigami.FormData.isSection: true
        Kirigami.FormData.label: i18n("Authentication")
    }

    // Session key
    TextField {
        id: sessionKeyField
        Kirigami.FormData.label: i18n("Session Key:")
        placeholderText: i18n("Paste your claude.ai sessionKey cookie here")
        echoMode: TextInput.Password
        Layout.fillWidth: true
    }

    PlasmaComponents.Label {
        Layout.fillWidth: true
        text: i18n("To get your session key:\n1. Go to claude.ai and your browser and login\n2. Open DevTools (F12) → Application → Cookies\n3. Copy the 'sessionKey' value")
        font: Kirigami.Theme.smallFont
        color: Kirigami.Theme.disabledTextColor
        wrapMode: Text.WordWrap
        Layout.topMargin: Kirigami.Units.smallSpacing
    }

    Kirigami.Separator {
        Kirigami.FormData.isSection: true
        Kirigami.FormData.label: i18n("Display Options")
    }

    // Refresh interval
    SpinBox {
        id: refreshIntervalSpinBox
        Kirigami.FormData.label: i18n("Refresh interval (seconds):")
        from: 60
        to: 3600
        stepSize: 60
        editable: true
    }

    // Warning threshold
    SpinBox {
        id: warningThresholdSpinBox
        Kirigami.FormData.label: i18n("Warning threshold (%):")
        from: 0
        to: 100
        stepSize: 5
        editable: true
    }

    // Critical threshold
    SpinBox {
        id: criticalThresholdSpinBox
        Kirigami.FormData.label: i18n("Critical threshold (%):")
        from: 0
        to: 100
        stepSize: 5
        editable: true
    }
}
