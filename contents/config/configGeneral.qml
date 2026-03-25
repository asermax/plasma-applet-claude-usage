import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kquickcontrols as KQC
import org.kde.plasma.components as PlasmaComponents

Kirigami.FormLayout {
    id: configPage

    property alias cfg_refreshInterval: refreshIntervalSpinBox.value
    property alias cfg_showWeeklyInTray: showWeeklyInTrayCheckBox.checked
    property alias cfg_warningThreshold: warningThresholdSpinBox.value
    property alias cfg_criticalThreshold: criticalThresholdSpinBox.value
    property alias cfg_manualSessionKey: manualSessionKeyField.text
    property alias cfg_browserType: browserTypeComboBox.currentIndex

    // Refresh interval
    SpinBox {
        id: refreshIntervalSpinBox
        Kirigami.FormData.label: i18n("Refresh interval (seconds):")
        from: 60
        to: 3600
        stepSize: 60
        editable: true
    }

    Item {
        Layout.fillHeight: true
    }

    Kirigami.Separator {
        Kirigami.FormData.isSection: true
        Kirigami.FormData.label: i18n("Display Options")
    }

    // Show weekly in tray
    CheckBox {
        id: showWeeklyInTrayCheckBox
        Kirigami.FormData.label: i18n("Show weekly in tray:")
        text: i18n("Display weekly usage instead of session")
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

    Item {
        Layout.fillHeight: true
    }

    Kirigami.Separator {
        Kirigami.FormData.isSection: true
        Kirigami.FormData.label: i18n("Authentication")
    }

    // Browser type
    ComboBox {
        id: browserTypeComboBox
        Kirigami.FormData.label: i18n("Browser for cookies:")
        model: [
            { text: i18n("Auto-detect"), value: "auto" },
            { text: i18n("Chrome/Chromium"), value: "chrome" },
            { text: i18n("Firefox"), value: "firefox" }
        ]
        textRole: "text"

        property string selectedValue: model[currentIndex]?.value ?? "auto"
    }

    // Manual session key
    TextField {
        id: manualSessionKeyField
        Kirigami.FormData.label: i18n("Manual session key:")
        placeholderText: i18n("Optional: Override browser cookie extraction")
        echoMode: TextInput.Password
        Layout.fillWidth: true

        PlasmaComponents.Label {
            anchors.top: parent.bottom
            anchors.topMargin: Kirigami.Units.smallSpacing
            text: i18n("Leave empty to use browser cookies")
            font: Kirigami.Theme.smallFont
            color: Kirigami.Theme.disabledTextColor
        }
    }
}
