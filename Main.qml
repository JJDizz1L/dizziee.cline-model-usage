import QtQuick
import Quickshell
import "providers"

Item {
    id: root
    visible: false

    property var settings: ({})

    Cline {
        id: clineProvider
        enabled: true
    }

    property var providers: [clineProvider]
    property var enabledProviders: {
        var result = []
        if (clineProvider.enabled) result.push(displayProvider(clineProvider))
        return result
    }

    property bool refreshing: clineProvider.refreshing
    property int refreshIntervalSec: Math.max(30, Number(root.setting("refreshIntervalSec", 300)))

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

    function displayProvider(provider) {
        return {
            providerId: provider.providerId,
            providerName: provider.providerName,
            providerIcon: provider.providerIcon,
            enabled: provider.enabled,
            ready: provider.ready,
            refreshing: provider.refreshing,
            lastRefreshedAtMs: provider.lastRefreshedAtMs,
            usageStatusText: provider.usageStatusText,
            authHelpText: provider.authHelpText,
            todaySessions: provider.todaySessions,
            todayTotalTokens: provider.todayTotalTokens,
            todayTokensByModel: provider.todayTokensByModel,
            recentDays: provider.recentDays,
            totalSessions: provider.totalSessions,
            modelUsage: provider.modelUsage,
            hasLocalStats: provider.hasLocalStats
        }
    }

    function refreshAll(force) {
        clineProvider.refresh(force === true)
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
