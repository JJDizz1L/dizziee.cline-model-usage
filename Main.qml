import QtQuick
import "providers"

Item {
    id: root
    visible: false

    property var settings: ({})

    Cline {
        id: clineProvider
    }

    readonly property var provider: clineProvider
    readonly property bool refreshing: clineProvider.refreshing
    readonly property int refreshIntervalSec: Math.max(30, Number(root.setting("refreshIntervalSec", 300)))

    // Background refresh keeps the bar chip current. Each scan is a read-only
    // query of about 50 ms, so the interval is the only steady-state cost.
    Timer {
        interval: root.refreshIntervalSec * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refreshAll()
    }

    function setting(name, fallback) {
        var value = settings ? settings[name] : undefined
        return value === undefined || value === null ? fallback : value
    }

    function refreshAll() {
        clineProvider.refresh()
    }

    function formatTokenCount(n) {
        if (n === undefined || n === null) return "0"
        if (n >= 1e9) return (n / 1e9).toFixed(1) + "B"
        if (n >= 1e6) return (n / 1e6).toFixed(1) + "M"
        if (n >= 1e3) return (n / 1e3).toFixed(1) + "K"
        return String(n)
    }

    function friendlyModelName(id) {
        if (!id) return "Unknown"
        return String(id)
    }
}
