import QtQuick
import qs.Commons as Commons
import "providers"

Item {
    id: root
    visible: false

    property var settings: ({})
    property string unknownModelLabel: "Unknown"

    Cline {
        id: clineProvider
    }

    readonly property var provider: clineProvider
    readonly property bool refreshing: clineProvider.refreshing
    readonly property int refreshIntervalSec: Math.max(30, Number(root.setting("refreshIntervalSec", 900)))

    // The first tick waits for the cache file to load, so a fresh cache costs
    // no Python process at shell start. A stale one is scanned once; every
    // later tick skips when another instance already wrote a fresh snapshot.
    Timer {
        id: startupRefresh
        // Stagger instances so one monitor's scan lands in the cache before
        // the next one decides it needs a scan of its own.
        interval: 1000 + Math.floor(Math.random() * 4000)
        repeat: false
        running: true
        onTriggered: {
            root.refreshIfStale(root.refreshIntervalSec * 0.9)
            refreshTimer.start()
        }
    }

    Timer {
        id: refreshTimer
        interval: root.refreshIntervalSec * 1000
        repeat: true
        running: false
        onTriggered: root.refreshIfStale(root.refreshIntervalSec * 0.9)
    }

    // A failed scan asks for a sooner try instead of waiting out the full
    // interval. The delay backs off to five minutes so a database that stays
    // locked does not turn into a 30-second treadmill; success stops it.
    property int retryDelaySec: 30

    Timer {
        id: retryTimer
        interval: root.retryDelaySec * 1000
        repeat: true
        running: false
        onTriggered: {
            if (!clineProvider.retryAdvised) return
            clineProvider.refresh(true)
            root.retryDelaySec = Math.min(300, root.retryDelaySec * 2)
        }
    }

    Connections {
        target: clineProvider
        function onRetryAdvisedChanged() {
            if (clineProvider.retryAdvised) {
                root.retryDelaySec = 30
                retryTimer.restart()
            } else {
                retryTimer.stop()
                root.retryDelaySec = 30
            }
        }
    }

    Component.onCompleted: if (clineProvider.retryAdvised) retryTimer.restart()

    function setting(name, fallback) {
        var value = settings ? settings[name] : undefined
        return value === undefined || value === null ? fallback : value
    }

    function refreshAll(force) {
        clineProvider.refresh(force === true)
    }

    function refreshIfStale(maxAgeSec) {
        clineProvider.refreshIfStale(maxAgeSec)
    }

    function formatTokenCount(n) {
        if (n === undefined || n === null) return Commons.I18n.formatNumber(0)
        if (n >= 1e9) return Commons.I18n.formatNumber(n / 1e9, 1) + "B"
        if (n >= 1e6) return Commons.I18n.formatNumber(n / 1e6, 1) + "M"
        if (n >= 1e3) return Commons.I18n.formatNumber(n / 1e3, 1) + "K"
        return Commons.I18n.formatNumber(n)
    }

    function modelWordCase(word) {
        var lower = String(word || "").toLowerCase()
        if (lower === "gpt") return "GPT"
        if (lower === "glm") return "GLM"
        if (lower === "deepseek") return "DeepSeek"
        if (lower === "nvidia") return "NVIDIA"
        if (lower === "minimax") return "MiniMax"
        if (lower === "opencode") return "OpenCode"
        if (lower === "gguf") return "GGUF"
        return word.charAt(0).toUpperCase() + word.slice(1)
    }

    // Vendors that appear before the slash in catalogue ids such as
    // `z-ai/glm-5.3-flash` or `cline-pass/deepseek-v4-flash`.
    function vendorWordCase(value) {
        var lower = String(value || "").toLowerCase()
        if (lower === "z-ai" || lower === "zai") return "Z.AI"
        if (lower === "cline-pass") return "Cline Pass"
        if (lower === "cline-free") return "Cline Free"
        if (lower === "opencode-go") return "OpenCode Go"
        if (lower === "inclusionai") return "InclusionAI"
        if (lower === "unsloth") return "Unsloth"
        return root.modelWordCase(value)
    }

    // Model ids arrive in two shapes: native hyphenated ids
    // (`claude-sonnet-4-5`, `gpt-5.1-codex`) and vendor-prefixed catalogue
    // ids (`z-ai/glm-5.3-flash`, `cline-pass/deepseek-v4-flash`). Rejoin the
    // numeric run into one version, title-case the words around it, keep a
    // context suffix (`1m`) out of the version, and keep the provider suffix
    // the scanner appends.
    function friendlyModelName(id) {
        if (!id) return root.unknownModelLabel
        var value = String(id)
        var suffix = ""
        var suffixMatch = value.match(/^(.*?)(\s+\([^)]*\))$/)
        if (suffixMatch) {
            value = suffixMatch[1]
            suffix = suffixMatch[2]
        }

        // Cache files written before the scanner normalized the id.
        if (value.charAt(0) === "{") {
            try {
                var parsed = JSON.parse(value)
                var modelId = String(parsed.id || "")
                var provider = String(parsed.providerID || "")
                if (modelId && provider) {
                    value = modelId
                    suffix = " (" + provider + ")"
                } else if (modelId) {
                    value = modelId
                }
            } catch (e) {}
        }

        var vendor = ""
        var slash = value.indexOf("/")
        if (slash > 0) {
            vendor = value.substring(0, slash)
            value = value.substring(slash + 1)
        }
        value = value.replace(/:/g, "-")

        var name = value.replace(/^claude-/, "").replace(/-\d{8}$/, "")
        var parts = name.split("-")
        var words = []
        var version = []
        for (var i = 0; i < parts.length; i++) {
            var part = parts[i]
            if (part === "") continue
            if (/^\d/.test(part)) {
                // `1m` / `200k` is context size, not another version segment.
                if (/^\d+[mk]$/i.test(part) && version.length > 0) {
                    words.push(version.join("."))
                    version = []
                    words.push(part.toUpperCase())
                    continue
                }
                version.push(part)
                continue
            }
            if (version.length > 0) {
                words.push(version.join("."))
                version = []
            }
            words.push(root.modelWordCase(part))
        }
        if (version.length > 0) words.push(version.join("."))

        var modelLabel = words.length > 0 ? words.join(" ") : root.unknownModelLabel
        var vendorLabel = vendor !== "" ? root.vendorWordCase(vendor) : ""
        if (vendorLabel !== "" && modelLabel.toLowerCase().indexOf(vendorLabel.toLowerCase()) === 0)
            vendorLabel = ""
        return (vendorLabel !== "" ? vendorLabel + " · " : "") + modelLabel + suffix
    }
}
