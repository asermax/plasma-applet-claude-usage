import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    id: configPage

    property alias cfg_sessionKey: sessionKeyField.text
    property alias cfg_refreshInterval: refreshIntervalSpinBox.value
    property alias cfg_showWeeklyInTray: showWeeklyInTrayCheckBox.checked
    property alias cfg_warningThreshold: warningThresholdSpinBox.value
    property alias cfg_criticalThreshold: criticalThresholdSpinBox.value

    // Session Key
    ColumnLayout {
        Kirigami.FormData.label: i18n("Session Key:")
        spacing: Kirigami.Units.smallSpacing

        TextField {
            id: sessionKeyField
            placeholderText: i18n("sk-ant-...")
            echoMode: TextInput.Password
            Layout.fillWidth: true
            Layout.minimumWidth: Kirigami.Units.gridUnit * 20
        }

        RowLayout {
            spacing: Kirigami.Units.smallSpacing

            Label {
                text: i18n("How to get:")
                font: Kirigami.Theme.smallFont
                color: Kirigami.Theme.disabledTextColor
            }

            Label {
                text: "<a href='#'>claude.ai → DevTools → Application → Cookies → sessionKey</a>"
                font: Kirigami.Theme.smallFont
                color: Kirigami.Theme.disabledTextColor
                textFormat: Text.RichText
                onLinkActivated: Qt.openUrlExternally("https://claude.ai")
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor
                }
            }
        }
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

    // Show weekly in tray
    CheckBox {
        id: showWeeklyInTrayCheckBox
        Kirigami.FormData.label: i18n("Tray display:")
        text: i18n("Show weekly usage instead of session")
    }

    Kirigami.Separator {
        Kirigami.FormData.isSection: true
        Kirigami.FormData.label: i18n("Color Thresholds")
    }

    // Warning threshold
    SpinBox {
        id: warningThresholdSpinBox
        Kirigami.FormData.label: i18n("Warning color (%):")
        from: 0
        to: 100
        stepSize: 5
        editable: true
    }

    // Critical threshold
    SpinBox {
        id: criticalThresholdSpinBox
        Kirigami.FormData.label: i18n("Critical color (%):")
        from: 0
        to: 100
        stepSize: 5
        editable: true
    }

    Item {
        Layout.fillHeight: true
    }
}
