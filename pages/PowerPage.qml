import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Core"

// Power page (placeholder).
// Injected by the host: `sys` (Core/Sys.qml) and `app` (Settings.qml).
// `activated()` runs every time the page becomes visible — refresh live
// state there.
ColumnLayout {
  id: page

  property var sys: null
  property var app: null

  spacing: Style.spacing.huge

  function activated() {
  }

  SettingsSection {
    title: "Coming soon"
    SettingsRow {
      label: "This page is not built yet"
      description: "Placeholder"
    }
  }
}
