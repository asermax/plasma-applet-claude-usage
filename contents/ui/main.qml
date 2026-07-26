import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // ============================================================
    // Properties
    // ============================================================

    // Claude
    property var usageData: null
    property string lastError: ""

    // GLM
    property var glmUsageData: null
    property string glmError: ""

    // Codex (OpenAI)
    property var codexUsageData: null
    property string codexError: ""
    property string resolvedCodexToken: ""  // loaded from auth.json or config
    property bool codexAuthLoading: false

    // Shared
    property bool isLoading: false
    property var lastUpdated: null

    // Configuration properties
    property bool cfg_claudeEnabled: plasmoid.configuration.claudeEnabled
    property bool cfg_glmEnabled: plasmoid.configuration.glmEnabled
    property bool cfg_codexEnabled: plasmoid.configuration.codexEnabled
    property string cfg_sessionKey: plasmoid.configuration.sessionKey
    property string cfg_glmToken: plasmoid.configuration.glmToken
    property string cfg_codexToken: plasmoid.configuration.codexToken
    property int cfg_refreshInterval: plasmoid.configuration.refreshInterval
    property int cfg_warningThreshold: plasmoid.configuration.warningThreshold
    property int cfg_criticalThreshold: plasmoid.configuration.criticalThreshold

    // Derived
    property bool hasClaudeConfig: cfg_claudeEnabled && cfg_sessionKey !== ""
    property bool hasGlmConfig: cfg_glmEnabled && cfg_glmToken !== ""
    property bool hasCodexConfig: cfg_codexEnabled && resolvedCodexToken !== ""
    property bool hasAnyConfig: hasClaudeConfig || hasGlmConfig || hasCodexConfig

    // ============================================================
    // Timer for periodic refresh
    // ============================================================

    Timer {
        id: refreshTimer
        interval: cfg_refreshInterval * 1000
        running: hasAnyConfig
        repeat: true
        onTriggered: refreshAll()
    }

    // Ticks every minute to keep "Updated: Xm ago" text fresh
    property int timeTick: 0

    Timer {
        interval: 60000
        running: lastUpdated != null
        repeat: true
        onTriggered: timeTick++
    }

    // ============================================================
    // HTTP requests via curl (QML XMLHttpRequest strips Cookie headers)
    // ============================================================

    Plasma5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        onNewData: function(sourceName, data) {
            var handler = requestHandlers[sourceName]
            if (handler) {
                delete requestHandlers[sourceName]

                var exitCode = data["exit code"]
                var stdout = (data["stdout"] || "").trim()

                if (exitCode !== 0) {
                    handler({ error: exitCode === 28 ? "Request timed out" : "Network error" })
                } else {
                    var lastNewline = stdout.lastIndexOf('\n')
                    var statusCode = parseInt(lastNewline >= 0 ? stdout.substring(lastNewline + 1) : stdout)
                    var body = lastNewline >= 0 ? stdout.substring(0, lastNewline) : ""

                    handler({ status: statusCode, body: body })
                }
            }
            disconnectSource(sourceName)
        }
    }

    property var requestHandlers: ({})

    // Expanded by the shell at run time: the executable data engine runs commands via
    // KProcess::setShellCommand, so $HOME resolves and the source name stays constant.
    readonly property string cacheDirExpr: "\"$HOME/.cache/plasma-claude-usage\""

    function shellEscape(str) {
        return "'" + str.replace(/'/g, "'\\''") + "'"
    }

    function cookieJarExpr(name) {
        return "\"$HOME/.cache/plasma-claude-usage/cookies-" + name + ".txt\""
    }

    // Cloudflare serves an HTML interstitial under a 403/503 to clients it has not vetted.
    // That is not an authentication failure and must not be reported as an expired session.
    function isCloudflareChallenge(response) {
        return (response.status === 403 || response.status === 503)
            && /just a moment|challenge-platform|cf-browser-verification|cf_chl/i.test(response.body || "")
    }

    function scheduleRetry(delayMs, callback) {
        var timer = Qt.createQmlObject('import QtQuick; Timer { repeat: false }', root)
        timer.interval = delayMs
        timer.triggered.connect(function() {
            timer.destroy()
            callback()
        })
        timer.start()
    }

    function curlRequest(url, handler, opts) {
        opts = opts || {}

        var maxAttempts = opts.maxAttempts || 3
        var retryDelayMs = opts.retryDelayMs || 2000

        var cmd = "curl -s --max-time 15 --compressed"

        if (opts.bearerToken) {
            cmd += " -H 'Authorization: Bearer " + opts.bearerToken + "'"
        }

        if (opts.cookie) {
            cmd += " --cookie " + shellEscape(opts.cookie)
        }

        // Cloudflare hands out a __cf_bm bot-management cookie on every response. Unless it
        // is stored and replayed, each request looks like a brand-new unvetted client and
        // roughly one in six comes back as a 403 challenge page instead of data.
        if (opts.cookieJar) {
            cmd += " -b " + cookieJarExpr(opts.cookieJar) + " -c " + cookieJarExpr(opts.cookieJar)
        }

        cmd += " -H 'Accept: application/json'"
        cmd += " -H 'Accept-Language: en-US,en;q=0.9'"
        cmd += " -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'"
        cmd += " -H 'Sec-Fetch-Site: same-origin'"
        cmd += " -H 'Sec-Fetch-Mode: cors'"
        cmd += " -H 'Sec-Fetch-Dest: empty'"

        if (opts.headers) {
            for (var i = 0; i < opts.headers.length; i++) {
                cmd += " -H " + shellEscape(opts.headers[i])
            }
        }

        cmd += " -w '\\n%{http_code}'"
        cmd += " " + shellEscape(url)

        if (opts.cookieJar) {
            cmd = "mkdir -p " + cacheDirExpr + " && " + cmd
        }

        function attempt(n) {
            requestHandlers[cmd] = function(response) {
                response.challenge = isCloudflareChallenge(response)

                // A challenge is transient: the response that carries it also sets the
                // __cf_bm cookie, so the retry usually goes through.
                var isRetryable = response.error || response.status >= 500 || response.challenge

                if (isRetryable && n < maxAttempts) {
                    scheduleRetry(retryDelayMs, function() { attempt(n + 1) })
                    return
                }

                handler(response)
            }
            executable.connectSource(cmd)
        }

        attempt(1)
    }

    // ============================================================
    // Codex token loading from ~/.codex/auth.json
    // ============================================================

    function resolveCodexToken() {
        if (!cfg_codexEnabled) return

        // If user set a manual token in config, use it
        if (cfg_codexToken !== "") {
            resolvedCodexToken = cfg_codexToken
            return
        }

        // Try to load from ~/.codex/auth.json using python3 to extract the token.
        // The executable handler expects the last line of stdout to be a numeric
        // status code (curl -w pattern). Python prints token then status line.
        codexAuthLoading = true

        var script = "import json,os; p=os.path.expanduser('~/.codex/auth.json'); d=json.load(open(p)); t=d.get('OPENAI_API_KEY','') or d.get('tokens',{}).get('access_token','') or d.get('tokens',{}).get('accessToken',''); print(t); print(0)"
        var cmd = "python3 -c " + shellEscape(script) + " 2>/dev/null"

        requestHandlers[cmd] = function(response) {
            codexAuthLoading = false

            if (response.error) {
                return
            }

            if (response.status !== undefined && response.status === 0) {
                var token = (response.body || "").trim()
                if (token) {
                    resolvedCodexToken = token
                    fetchCodexUsage()
                }
            }
        }
        executable.connectSource(cmd)
    }

    // ============================================================
    // Claude data fetching
    // ============================================================

    function fetchUsage() {
        if (!cfg_claudeEnabled || !cfg_sessionKey) return

        isLoading = true
        lastError = ""

        curlRequest("https://claude.ai/api/organizations", function(response) {
            if (response.error) {
                isLoading = false
                lastError = response.error
                return
            }

            if (response.challenge) {
                isLoading = false
                lastError = "Cloudflare challenge - will retry"
                return
            }

            if (response.status === 401 || response.status === 403) {
                isLoading = false
                lastError = "Session expired - update cookie in config"
                return
            }

            if (response.status !== 200) {
                isLoading = false
                lastError = "Failed to fetch organizations: " + response.status
                return
            }

            try {
                var orgs = JSON.parse(response.body)
                var orgId = null
                var fallbackOrgId = null

                // Prefer orgs with a paid subscription
                for (var i = 0; i < orgs.length; i++) {
                    var org = orgs[i]
                    var hasChat = org.capabilities && org.capabilities.indexOf("chat") >= 0

                    if (!hasChat) continue

                    if (org.billing_type && org.billing_type !== "none") {
                        orgId = org.uuid
                        break
                    }

                    if (!fallbackOrgId) {
                        fallbackOrgId = org.uuid
                    }
                }

                orgId = orgId || fallbackOrgId || (orgs.length > 0 ? orgs[0].uuid : null)

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
        }, {
            cookie: "sessionKey=" + cfg_sessionKey,
            cookieJar: "claude",
            headers: ["Referer: https://claude.ai/", "Origin: https://claude.ai"],
        })
    }

    function fetchUsageData(orgId) {
        curlRequest("https://claude.ai/api/organizations/" + orgId + "/usage", function(response) {
            isLoading = false

            if (response.error) {
                lastError = response.error
                return
            }

            if (response.challenge) {
                lastError = "Cloudflare challenge - will retry"
                return
            }

            if (response.status !== 200) {
                lastError = "Failed to fetch usage: " + response.status
                return
            }

            try {
                var data = JSON.parse(response.body)
                processUsageData(data)
                lastUpdated = new Date()
            } catch (e) {
                lastError = "Failed to parse usage data"
            }
        }, {
            cookie: "sessionKey=" + cfg_sessionKey,
            cookieJar: "claude",
            headers: ["Referer: https://claude.ai/", "Origin: https://claude.ai"],
        })
    }

    function processUsageData(data) {
        var newData = {}

        // Session (5-hour window)
        if (data.five_hour && data.five_hour.utilization !== undefined) {
            newData.session = {
                used: data.five_hour.utilization,
                resets_at: data.five_hour.resets_at,
                resets_in: formatTimeRemaining(parseISODate(data.five_hour.resets_at)),
            }
        }

        // Weekly (7-day window)
        if (data.seven_day && data.seven_day.utilization !== undefined) {
            newData.weekly = {
                used: data.seven_day.utilization,
                resets_at: data.seven_day.resets_at,
                resets_in: formatTimeRemaining(parseISODate(data.seven_day.resets_at)),
            }
        }

        usageData = newData
        lastError = ""
    }

    // ============================================================
    // GLM data fetching
    // ============================================================

    function fetchGlmUsage() {
        if (!cfg_glmEnabled || !cfg_glmToken) return

        isLoading = true
        glmError = ""

        curlRequest("https://api.z.ai/api/monitor/usage/quota/limit", function(response) {
            isLoading = false

            if (response.error) {
                glmError = response.error
                return
            }

            if (response.challenge) {
                glmError = "Cloudflare challenge - will retry"
                return
            }

            if (response.status === 401 || response.status === 403) {
                glmError = "GLM token expired - update in config"
                return
            }

            if (response.status !== 200) {
                glmError = "Failed to fetch GLM limits: " + response.status
                return
            }

            try {
                var data = JSON.parse(response.body)
                processGlmData(data)
                lastUpdated = new Date()
            } catch (e) {
                glmError = "Failed to parse GLM data"
            }
        }, {
            bearerToken: cfg_glmToken,
            cookieJar: "glm",
        })
    }

    function processGlmData(response) {
        if (!response.data || !response.data.limits) {
            glmError = "No limits data found"
            return
        }

        var newData = { level: response.data.level || "unknown" }

        for (var i = 0; i < response.data.limits.length; i++) {
            var limit = response.data.limits[i]

            if (limit.type === "TIME_LIMIT") {
                newData.timeLimit = {
                    usage: limit.usage,
                    currentValue: limit.currentValue,
                    remaining: limit.remaining,
                    percentage: limit.percentage,
                    resetsAt: new Date(limit.nextResetTime),
                    resetsIn: formatTimeRemaining(new Date(limit.nextResetTime)),
                    usageDetails: limit.usageDetails || [],
                }
            }

            if (limit.type === "TOKENS_LIMIT") {
                newData.tokensLimit = {
                    percentage: limit.percentage,
                    unit: limit.unit,
                    number: limit.number,
                    resetsAt: new Date(limit.nextResetTime),
                    resetsIn: formatTimeRemaining(new Date(limit.nextResetTime)),
                }
            }
        }

        glmUsageData = newData
        glmError = ""
    }

    // ============================================================
    // Codex (OpenAI) data fetching
    // ============================================================

    function fetchCodexUsage() {
        if (!cfg_codexEnabled || !resolvedCodexToken) return

        isLoading = true
        codexError = ""

        curlRequest("https://chatgpt.com/backend-api/wham/usage", function(response) {
            isLoading = false

            if (response.error) {
                codexError = response.error
                return
            }

            if (response.challenge) {
                codexError = "Cloudflare challenge - will retry"
                return
            }

            if (response.status === 401 || response.status === 403) {
                codexError = "Codex token expired - run 'codex' to re-authenticate"
                return
            }

            if (response.status !== 200) {
                codexError = "Failed to fetch Codex usage: " + response.status
                return
            }

            try {
                var data = JSON.parse(response.body)
                processCodexData(data)
                lastUpdated = new Date()
            } catch (e) {
                codexError = "Failed to parse Codex data"
            }
        }, {
            bearerToken: resolvedCodexToken,
            cookieJar: "codex",
        })
    }

    function processCodexData(data) {
        var newData = {}

        if (data.rate_limit) {
            // Primary window (5-hour session)
            if (data.rate_limit.primary_window) {
                var pw = data.rate_limit.primary_window
                newData.session = {
                    used: pw.used_percent !== undefined ? pw.used_percent : 0,
                    resets_at: pw.reset_at ? new Date(pw.reset_at * 1000) : null,
                    resets_in: pw.reset_at ? formatTimeRemaining(new Date(pw.reset_at * 1000)) : "",
                }
            }

            // Secondary window (7-day weekly)
            if (data.rate_limit.secondary_window) {
                var sw = data.rate_limit.secondary_window
                newData.weekly = {
                    used: sw.used_percent !== undefined ? sw.used_percent : 0,
                    resets_at: sw.reset_at ? new Date(sw.reset_at * 1000) : null,
                    resets_in: sw.reset_at ? formatTimeRemaining(new Date(sw.reset_at * 1000)) : "",
                }
            }
        }

        // Credits (optional)
        if (data.credits) {
            newData.credits = {
                hasCredits: data.credits.has_credits || false,
                unlimited: data.credits.unlimited || false,
                balance: data.credits.balance !== undefined ? data.credits.balance : null,
            }
        }

        codexUsageData = newData
        codexError = ""
    }

    // ============================================================
    // Shared utilities
    // ============================================================

    function refreshAll() {
        if (isLoading) return

        if (hasClaudeConfig) fetchUsage()
        if (hasGlmConfig) fetchGlmUsage()
        if (hasCodexConfig) fetchCodexUsage()
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
            return "Resets on " + resetsAt.toLocaleString(Qt.locale(), "ddd MMM d") + " at " + resetsAt.toLocaleTimeString(Qt.locale(), "HH:mm")
        }

        if (hours > 0) return "Resets in " + hours + "h " + minutes + "m"

        return "Resets in " + minutes + "m"
    }

    function getUsageColor(percentage) {
        if (percentage >= cfg_criticalThreshold) {
            return Kirigami.Theme.negativeTextColor
        } else if (percentage >= cfg_warningThreshold) {
            return Kirigami.Theme.neutralTextColor
        }
        return Kirigami.Theme.highlightColor
    }

    function formatTimeSince(date, _tick) {
        if (!date) return "Never"

        var now = new Date()
        var diff = Math.floor((now - date) / 1000)

        if (diff < 60) return "Just now"
        if (diff < 3600) return Math.floor(diff / 60) + "m ago"
        if (diff < 86400) return Math.floor(diff / 3600) + "h ago"

        return Math.floor(diff / 86400) + "d ago"
    }

    function formatToolName(code) {
        var names = {
            "search-prime": "Web Search",
            "web-reader": "Web Reader",
            "zread": "ZRead",
        }
        return names[code] || code
    }

    // ============================================================
    // Tooltip
    // ============================================================

    toolTipMainText: "Subscription Usage"
    toolTipSubText: {
        var parts = []

        if (hasClaudeConfig && usageData) {
            if (usageData.session) {
                var text = "Claude Session: " + Math.round(usageData.session.used) + "%"
                if (usageData.session.resets_in) text += " - " + usageData.session.resets_in
                parts.push(text)
            }

            if (usageData.weekly) {
                var text = "Claude Weekly: " + Math.round(usageData.weekly.used) + "%"
                if (usageData.weekly.resets_in) text += " - " + usageData.weekly.resets_in
                parts.push(text)
            }
        }

        if (hasGlmConfig && glmUsageData) {
            if (glmUsageData.tokensLimit) {
                var text = "GLM Session: " + Math.round(glmUsageData.tokensLimit.percentage) + "%"
                if (glmUsageData.tokensLimit.resetsIn) text += " - " + glmUsageData.tokensLimit.resetsIn
                parts.push(text)
            }

            if (glmUsageData.timeLimit) {
                var text = "GLM Tools: " + Math.round(glmUsageData.timeLimit.percentage) + "%"
                if (glmUsageData.timeLimit.resetsIn) text += " - " + glmUsageData.timeLimit.resetsIn
                parts.push(text)
            }
        }

        if (hasCodexConfig && codexUsageData) {
            if (codexUsageData.session) {
                var text = "Codex Session: " + Math.round(codexUsageData.session.used) + "%"
                if (codexUsageData.session.resets_in) text += " - " + codexUsageData.session.resets_in
                parts.push(text)
            }

            if (codexUsageData.weekly) {
                var text = "Codex Weekly: " + Math.round(codexUsageData.weekly.used) + "%"
                if (codexUsageData.weekly.resets_in) text += " - " + codexUsageData.weekly.resets_in
                parts.push(text)
            }
        }

        if (parts.length === 0) {
            if (!hasAnyConfig) return "No service configured"
            if (lastError) return lastError
            if (glmError) return glmError
            if (codexError) return codexError
            return "Loading..."
        }

        return parts.join("\n")
    }

    // Watch for configuration changes
    onCfg_claudeEnabledChanged: {
        if (cfg_claudeEnabled) fetchUsage()
        else usageData = null
    }

    onCfg_glmEnabledChanged: {
        if (cfg_glmEnabled) fetchGlmUsage()
        else glmUsageData = null
    }

    onCfg_codexEnabledChanged: {
        if (cfg_codexEnabled) resolveCodexToken()
        else codexUsageData = null
    }

    onCfg_sessionKeyChanged: {
        usageData = null
        if (cfg_sessionKey) {
            fetchUsage()
        }
    }

    onCfg_glmTokenChanged: {
        glmUsageData = null
        if (cfg_glmToken) {
            fetchGlmUsage()
        }
    }

    onCfg_codexTokenChanged: {
        codexUsageData = null
        resolvedCodexToken = ""
        if (cfg_codexToken) {
            resolvedCodexToken = cfg_codexToken
            fetchCodexUsage()
        } else {
            resolveCodexToken()
        }
    }

    // ============================================================
    // Compact Representation (System Tray)
    // ============================================================

    compactRepresentation: PlasmaComponents.AbstractButton {
        id: compactRep

        readonly property int ringCount: {
            var rings = 0
            if (hasClaudeConfig) rings++
            if (hasGlmConfig) rings++
            if (hasCodexConfig) rings++
            return Math.max(rings, 1)
        }

        Layout.minimumWidth: Kirigami.Units.gridUnit * 1.6 * ringCount
        Layout.preferredWidth: Kirigami.Units.gridUnit * 1.6 * ringCount
        Layout.maximumWidth: Kirigami.Units.gridUnit * 1.6 * ringCount
        Layout.minimumHeight: Kirigami.Units.gridUnit * 2
        Layout.preferredHeight: Kirigami.Units.gridUnit * 2

        onClicked: root.expanded = !root.expanded

        PlasmaComponents.BusyIndicator {
            anchors.centerIn: parent
            running: isLoading && !usageData && !glmUsageData && !codexUsageData
            visible: isLoading && !usageData && !glmUsageData && !codexUsageData
            implicitWidth: Kirigami.Units.gridUnit
            implicitHeight: Kirigami.Units.gridUnit
        }

        RowLayout {
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing

            // Claude ring
            Item {
                id: claudeRingContainer
                visible: hasClaudeConfig && (!isLoading || usageData)

                property real ringSize: Math.min(compactRep.height, compactRep.width / Math.max(1, (hasClaudeConfig ? 1 : 0) + (hasGlmConfig ? 1 : 0) + (hasCodexConfig ? 1 : 0))) - Kirigami.Units.smallSpacing

                width: ringSize
                height: ringSize

                Shape {
                    id: claudeRing
                    anchors.fill: parent
                    layer.enabled: true
                    layer.samples: 8

                    property real ringWidth: claudeRingContainer.ringSize * 0.15
                    property real ringRadius: (claudeRingContainer.ringSize - ringWidth) / 2
                    property real centerXY: claudeRingContainer.ringSize / 2

                    property bool hasError: lastError && !usageData
                    property bool hasData: usageData && usageData.session
                    property real sessionUsed: hasData ? usageData.session.used : 0

                    property real sweepAngle: {
                        if (hasError) return 360
                        if (hasData) return (Math.min(Math.max(sessionUsed, 0), 100) / 100) * 360
                        return 0
                    }

                    property color arcColor: {
                        if (hasError) return Kirigami.Theme.negativeTextColor
                        if (hasData) return getUsageColor(sessionUsed)
                        return Kirigami.Theme.disabledTextColor
                    }

                    // Background track
                    ShapePath {
                        fillColor: "transparent"
                        strokeColor: Qt.rgba(
                            Kirigami.Theme.textColor.r,
                            Kirigami.Theme.textColor.g,
                            Kirigami.Theme.textColor.b,
                            0.15
                        )
                        strokeWidth: claudeRing.ringWidth
                        capStyle: ShapePath.RoundCap

                        PathAngleArc {
                            centerX: claudeRing.centerXY
                            centerY: claudeRing.centerXY
                            radiusX: claudeRing.ringRadius
                            radiusY: claudeRing.ringRadius
                            startAngle: -90
                            sweepAngle: 360
                        }
                    }

                    // Foreground progress arc
                    ShapePath {
                        fillColor: "transparent"
                        strokeColor: claudeRing.arcColor
                        strokeWidth: claudeRing.ringWidth
                        capStyle: ShapePath.RoundCap

                        PathAngleArc {
                            centerX: claudeRing.centerXY
                            centerY: claudeRing.centerXY
                            radiusX: claudeRing.ringRadius
                            radiusY: claudeRing.ringRadius
                            startAngle: -90
                            sweepAngle: claudeRing.sweepAngle
                        }
                    }
                }

                PlasmaComponents.Label {
                    anchors.centerIn: parent
                    text: "C"
                    font.pixelSize: claudeRingContainer.ringSize * 0.45
                    font.bold: true
                    color: "white"
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            // GLM ring
            Item {
                id: glmRingContainer
                visible: hasGlmConfig && (!isLoading || glmUsageData)

                property real ringSize: Math.min(compactRep.height, compactRep.width / Math.max(1, (hasClaudeConfig ? 1 : 0) + (hasGlmConfig ? 1 : 0) + (hasCodexConfig ? 1 : 0))) - Kirigami.Units.smallSpacing

                width: ringSize
                height: ringSize

                Shape {
                    id: glmRing
                    anchors.fill: parent
                    layer.enabled: true
                    layer.samples: 8

                    property real ringWidth: glmRingContainer.ringSize * 0.15
                    property real ringRadius: (glmRingContainer.ringSize - ringWidth) / 2
                    property real centerXY: glmRingContainer.ringSize / 2

                    property bool hasError: glmError && !glmUsageData
                    property bool hasData: glmUsageData && glmUsageData.tokensLimit
                    property real usedPercentage: hasData ? glmUsageData.tokensLimit.percentage : 0

                    property real sweepAngle: {
                        if (hasError) return 360
                        if (hasData) return (Math.min(Math.max(usedPercentage, 0), 100) / 100) * 360
                        return 0
                    }

                    property color arcColor: {
                        if (hasError) return Kirigami.Theme.negativeTextColor
                        if (hasData) return getUsageColor(usedPercentage)
                        return Kirigami.Theme.disabledTextColor
                    }

                    // Background track
                    ShapePath {
                        fillColor: "transparent"
                        strokeColor: Qt.rgba(
                            Kirigami.Theme.textColor.r,
                            Kirigami.Theme.textColor.g,
                            Kirigami.Theme.textColor.b,
                            0.15
                        )
                        strokeWidth: glmRing.ringWidth
                        capStyle: ShapePath.RoundCap

                        PathAngleArc {
                            centerX: glmRing.centerXY
                            centerY: glmRing.centerXY
                            radiusX: glmRing.ringRadius
                            radiusY: glmRing.ringRadius
                            startAngle: -90
                            sweepAngle: 360
                        }
                    }

                    // Foreground progress arc
                    ShapePath {
                        fillColor: "transparent"
                        strokeColor: glmRing.arcColor
                        strokeWidth: glmRing.ringWidth
                        capStyle: ShapePath.RoundCap

                        PathAngleArc {
                            centerX: glmRing.centerXY
                            centerY: glmRing.centerXY
                            radiusX: glmRing.ringRadius
                            radiusY: glmRing.ringRadius
                            startAngle: -90
                            sweepAngle: glmRing.sweepAngle
                        }
                    }
                }

                PlasmaComponents.Label {
                    anchors.centerIn: parent
                    text: "G"
                    font.pixelSize: glmRingContainer.ringSize * 0.45
                    font.bold: true
                    color: "white"
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }

            // Codex (OpenAI) ring
            Item {
                id: codexRingContainer
                visible: hasCodexConfig && (!isLoading || codexUsageData)

                property real ringSize: Math.min(compactRep.height, compactRep.width / Math.max(1, (hasClaudeConfig ? 1 : 0) + (hasGlmConfig ? 1 : 0) + (hasCodexConfig ? 1 : 0))) - Kirigami.Units.smallSpacing

                width: ringSize
                height: ringSize

                Shape {
                    id: codexRing
                    anchors.fill: parent
                    layer.enabled: true
                    layer.samples: 8

                    property real ringWidth: codexRingContainer.ringSize * 0.15
                    property real ringRadius: (codexRingContainer.ringSize - ringWidth) / 2
                    property real centerXY: codexRingContainer.ringSize / 2

                    property bool hasError: codexError && !codexUsageData
                    property bool hasData: codexUsageData && codexUsageData.session
                    property real sessionUsed: hasData ? codexUsageData.session.used : 0

                    property real sweepAngle: {
                        if (hasError) return 360
                        if (hasData) return (Math.min(Math.max(sessionUsed, 0), 100) / 100) * 360
                        return 0
                    }

                    property color arcColor: {
                        if (hasError) return Kirigami.Theme.negativeTextColor
                        if (hasData) return getUsageColor(sessionUsed)
                        return Kirigami.Theme.disabledTextColor
                    }

                    // Background track
                    ShapePath {
                        fillColor: "transparent"
                        strokeColor: Qt.rgba(
                            Kirigami.Theme.textColor.r,
                            Kirigami.Theme.textColor.g,
                            Kirigami.Theme.textColor.b,
                            0.15
                        )
                        strokeWidth: codexRing.ringWidth
                        capStyle: ShapePath.RoundCap

                        PathAngleArc {
                            centerX: codexRing.centerXY
                            centerY: codexRing.centerXY
                            radiusX: codexRing.ringRadius
                            radiusY: codexRing.ringRadius
                            startAngle: -90
                            sweepAngle: 360
                        }
                    }

                    // Foreground progress arc
                    ShapePath {
                        fillColor: "transparent"
                        strokeColor: codexRing.arcColor
                        strokeWidth: codexRing.ringWidth
                        capStyle: ShapePath.RoundCap

                        PathAngleArc {
                            centerX: codexRing.centerXY
                            centerY: codexRing.centerXY
                            radiusX: codexRing.ringRadius
                            radiusY: codexRing.ringRadius
                            startAngle: -90
                            sweepAngle: codexRing.sweepAngle
                        }
                    }
                }

                PlasmaComponents.Label {
                    anchors.centerIn: parent
                    text: "O"
                    font.pixelSize: codexRingContainer.ringSize * 0.45
                    font.bold: true
                    color: "white"
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }

    // ============================================================
    // Full Representation (Popup)
    // ============================================================

    fullRepresentation: ColumnLayout {
        id: fullRep

        Layout.preferredWidth: Kirigami.Units.gridUnit * 18
        spacing: 0

        // Header
        RowLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: Kirigami.Units.smallSpacing

            PlasmaComponents.Label {
                text: "Subscription Usage"
                font.bold: true
                font.pixelSize: Kirigami.Units.gridUnit * 1.1
                Layout.fillWidth: true
            }

            PlasmaComponents.ToolButton {
                icon.name: "view-refresh"
                display: PlasmaComponents.AbstractButton.IconOnly
                onClicked: refreshAll()
                enabled: !isLoading && hasAnyConfig
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

        // Neither configured message
        ColumnLayout {
            visible: !hasAnyConfig
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Kirigami.Units.smallSpacing

            Item { Layout.fillHeight: true }

            Kirigami.Icon {
                source: "dialog-information"
                implicitWidth: Kirigami.Units.gridUnit * 3
                implicitHeight: Kirigami.Units.gridUnit * 3
                Layout.alignment: Qt.AlignHCenter
            }

            PlasmaComponents.Label {
                text: "Configure at least one service"
                font.bold: true
                Layout.alignment: Qt.AlignHCenter
            }

            PlasmaComponents.Label {
                text: "Click the configure button to add\nyour Claude session key or GLM token"
                font.pixelSize: Kirigami.Units.gridUnit * 0.8
                color: Kirigami.Theme.disabledTextColor
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.gridUnit
                Layout.rightMargin: Kirigami.Units.gridUnit
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            Item { Layout.fillHeight: true }
        }

        // ============================================================
        // Claude section
        // ============================================================

        ColumnLayout {
            visible: hasClaudeConfig
            Layout.fillWidth: true
            spacing: 0

            // Section title
            PlasmaComponents.Label {
                text: "Claude"
                font.bold: true
                font.pixelSize: Kirigami.Units.gridUnit * 0.9
                Layout.leftMargin: Kirigami.Units.smallSpacing
            }

            // Unconfigured
            ColumnLayout {
                visible: !hasClaudeConfig
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Label {
                    text: "Configure your session key in settings"
                    font.pixelSize: Kirigami.Units.gridUnit * 0.8
                    color: Kirigami.Theme.disabledTextColor
                    Layout.alignment: Qt.AlignHCenter
                }
            }

            // Error state
            PlasmaComponents.Label {
                visible: hasClaudeConfig && lastError !== "" && !usageData
                text: lastError
                color: Kirigami.Theme.negativeTextColor
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                Layout.topMargin: Kirigami.Units.smallSpacing
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
            }

            // Session usage
            ColumnLayout {
                visible: usageData && usageData.session
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                Layout.topMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Label {
                    text: "Session (5h window)"
                    font.pixelSize: Kirigami.Units.gridUnit * 0.9
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: Kirigami.Units.gridUnit * 0.4
                        radius: height / 2
                        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.15)

                        property real progressValue: usageData && usageData.session ? usageData.session.used : 0

                        Rectangle {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: parent.width * (Math.min(Math.max(parent.progressValue, 0), 100) / 100)
                            radius: parent.radius
                            color: usageData && usageData.session
                                ? getUsageColor(usageData.session.used)
                                : Kirigami.Theme.highlightColor

                            Behavior on width {
                                NumberAnimation { duration: 200 }
                            }
                        }
                    }

                    PlasmaComponents.Label {
                        text: usageData && usageData.session
                            ? Math.round(usageData.session.used) + "%"
                            : "0%"
                        font.bold: true
                        Layout.minimumWidth: Kirigami.Units.gridUnit * 2
                        horizontalAlignment: Text.AlignRight
                    }
                }

                PlasmaComponents.Label {
                    text: usageData && usageData.session ? usageData.session.resets_in : ""
                    font.pixelSize: Kirigami.Units.gridUnit * 0.8
                    color: Kirigami.Theme.disabledTextColor
                }
            }

            // Weekly usage
            ColumnLayout {
                visible: usageData && usageData.weekly
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                Layout.topMargin: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Label {
                    text: "Weekly (7 day window)"
                    font.pixelSize: Kirigami.Units.gridUnit * 0.9
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: Kirigami.Units.gridUnit * 0.4
                        radius: height / 2
                        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.15)

                        property real progressValue: usageData && usageData.weekly ? usageData.weekly.used : 0

                        Rectangle {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: parent.width * (Math.min(Math.max(parent.progressValue, 0), 100) / 100)
                            radius: parent.radius
                            color: usageData && usageData.weekly
                                ? getUsageColor(usageData.weekly.used)
                                : Kirigami.Theme.highlightColor

                            Behavior on width {
                                NumberAnimation { duration: 200 }
                            }
                        }
                    }

                    PlasmaComponents.Label {
                        text: usageData && usageData.weekly
                            ? Math.round(usageData.weekly.used) + "%"
                            : "0%"
                        font.bold: true
                        Layout.minimumWidth: Kirigami.Units.gridUnit * 2
                        horizontalAlignment: Text.AlignRight
                    }
                }

                PlasmaComponents.Label {
                    text: usageData && usageData.weekly ? usageData.weekly.resets_in : ""
                    font.pixelSize: Kirigami.Units.gridUnit * 0.8
                    color: Kirigami.Theme.disabledTextColor
                }
            }
        }

        // Separator between sections
        Kirigami.Separator {
            visible: hasClaudeConfig && hasGlmConfig
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.largeSpacing
            Layout.bottomMargin: Kirigami.Units.largeSpacing
        }

        // ============================================================
        // GLM section
        // ============================================================

        ColumnLayout {
            visible: hasGlmConfig
            Layout.fillWidth: true
            spacing: 0

            // Section title
            PlasmaComponents.Label {
                text: "GLM"
                font.bold: true
                font.pixelSize: Kirigami.Units.gridUnit * 0.9
                Layout.leftMargin: Kirigami.Units.smallSpacing
            }

            // Error state
            PlasmaComponents.Label {
                visible: hasGlmConfig && glmError !== "" && !glmUsageData
                text: glmError
                color: Kirigami.Theme.negativeTextColor
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                Layout.topMargin: Kirigami.Units.smallSpacing
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
            }

            // Session (5h window) - progress bar
            ColumnLayout {
                visible: glmUsageData && glmUsageData.tokensLimit
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                Layout.topMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Label {
                    text: "Session (5h window)"
                    font.pixelSize: Kirigami.Units.gridUnit * 0.9
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: Kirigami.Units.gridUnit * 0.4
                        radius: height / 2
                        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.15)

                        property real progressValue: glmUsageData && glmUsageData.tokensLimit ? glmUsageData.tokensLimit.percentage : 0

                        Rectangle {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: parent.width * (Math.min(Math.max(parent.progressValue, 0), 100) / 100)
                            radius: parent.radius
                            color: glmUsageData && glmUsageData.tokensLimit
                                ? getUsageColor(glmUsageData.tokensLimit.percentage)
                                : Kirigami.Theme.highlightColor

                            Behavior on width {
                                NumberAnimation { duration: 200 }
                            }
                        }
                    }

                    PlasmaComponents.Label {
                        text: glmUsageData && glmUsageData.tokensLimit
                            ? Math.round(glmUsageData.tokensLimit.percentage) + "%"
                            : "0%"
                        font.bold: true
                        Layout.minimumWidth: Kirigami.Units.gridUnit * 2
                        horizontalAlignment: Text.AlignRight
                    }
                }

                PlasmaComponents.Label {
                    text: glmUsageData && glmUsageData.tokensLimit ? glmUsageData.tokensLimit.resetsIn : ""
                    font.pixelSize: Kirigami.Units.gridUnit * 0.8
                    color: Kirigami.Theme.disabledTextColor
                }
            }

            // Tools (Monthly window) - progress bar
            ColumnLayout {
                visible: glmUsageData && glmUsageData.timeLimit
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                Layout.topMargin: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Label {
                    text: "Tools (Monthly window)"
                    font.pixelSize: Kirigami.Units.gridUnit * 0.9
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: Kirigami.Units.gridUnit * 0.4
                        radius: height / 2
                        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.15)

                        property real progressValue: glmUsageData && glmUsageData.timeLimit ? glmUsageData.timeLimit.percentage : 0

                        Rectangle {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: parent.width * (Math.min(Math.max(parent.progressValue, 0), 100) / 100)
                            radius: parent.radius
                            color: glmUsageData && glmUsageData.timeLimit
                                ? getUsageColor(glmUsageData.timeLimit.percentage)
                                : Kirigami.Theme.highlightColor

                            Behavior on width {
                                NumberAnimation { duration: 200 }
                            }
                        }
                    }

                    PlasmaComponents.Label {
                        text: glmUsageData && glmUsageData.timeLimit
                            ? Math.round(glmUsageData.timeLimit.percentage) + "%"
                            : "0%"
                        font.bold: true
                        Layout.minimumWidth: Kirigami.Units.gridUnit * 2
                        horizontalAlignment: Text.AlignRight
                    }
                }

                PlasmaComponents.Label {
                    text: glmUsageData && glmUsageData.timeLimit ? glmUsageData.timeLimit.resetsIn : ""
                    font.pixelSize: Kirigami.Units.gridUnit * 0.8
                    color: Kirigami.Theme.disabledTextColor
                }
            }
        }

        // Separator between GLM and Codex
        Kirigami.Separator {
            visible: hasCodexConfig && (hasClaudeConfig || hasGlmConfig)
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.largeSpacing
            Layout.bottomMargin: Kirigami.Units.largeSpacing
        }

        // ============================================================
        // Codex (OpenAI) section
        // ============================================================

        ColumnLayout {
            visible: hasCodexConfig
            Layout.fillWidth: true
            spacing: 0

            // Section title
            PlasmaComponents.Label {
                text: "Codex (OpenAI)"
                font.bold: true
                font.pixelSize: Kirigami.Units.gridUnit * 0.9
                Layout.leftMargin: Kirigami.Units.smallSpacing
            }

            // Error state
            PlasmaComponents.Label {
                visible: hasCodexConfig && codexError !== "" && !codexUsageData
                text: codexError
                color: Kirigami.Theme.negativeTextColor
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                Layout.topMargin: Kirigami.Units.smallSpacing
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
            }

            // Session usage (primary window - 5h)
            ColumnLayout {
                visible: codexUsageData && codexUsageData.session
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                Layout.topMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Label {
                    text: "Session (5h window)"
                    font.pixelSize: Kirigami.Units.gridUnit * 0.9
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: Kirigami.Units.gridUnit * 0.4
                        radius: height / 2
                        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.15)

                        property real progressValue: codexUsageData && codexUsageData.session ? codexUsageData.session.used : 0

                        Rectangle {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: parent.width * (Math.min(Math.max(parent.progressValue, 0), 100) / 100)
                            radius: parent.radius
                            color: codexUsageData && codexUsageData.session
                                ? getUsageColor(codexUsageData.session.used)
                                : Kirigami.Theme.highlightColor

                            Behavior on width {
                                NumberAnimation { duration: 200 }
                            }
                        }
                    }

                    PlasmaComponents.Label {
                        text: codexUsageData && codexUsageData.session
                            ? Math.round(codexUsageData.session.used) + "%"
                            : "0%"
                        font.bold: true
                        Layout.minimumWidth: Kirigami.Units.gridUnit * 2
                        horizontalAlignment: Text.AlignRight
                    }
                }

                PlasmaComponents.Label {
                    text: codexUsageData && codexUsageData.session ? codexUsageData.session.resets_in : ""
                    font.pixelSize: Kirigami.Units.gridUnit * 0.8
                    color: Kirigami.Theme.disabledTextColor
                }
            }

            // Weekly usage (secondary window - 7d)
            ColumnLayout {
                visible: codexUsageData && codexUsageData.weekly
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                Layout.topMargin: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Label {
                    text: "Weekly (7 day window)"
                    font.pixelSize: Kirigami.Units.gridUnit * 0.9
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: Kirigami.Units.gridUnit * 0.4
                        radius: height / 2
                        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.15)

                        property real progressValue: codexUsageData && codexUsageData.weekly ? codexUsageData.weekly.used : 0

                        Rectangle {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: parent.width * (Math.min(Math.max(parent.progressValue, 0), 100) / 100)
                            radius: parent.radius
                            color: codexUsageData && codexUsageData.weekly
                                ? getUsageColor(codexUsageData.weekly.used)
                                : Kirigami.Theme.highlightColor

                            Behavior on width {
                                NumberAnimation { duration: 200 }
                            }
                        }
                    }

                    PlasmaComponents.Label {
                        text: codexUsageData && codexUsageData.weekly
                            ? Math.round(codexUsageData.weekly.used) + "%"
                            : "0%"
                        font.bold: true
                        Layout.minimumWidth: Kirigami.Units.gridUnit * 2
                        horizontalAlignment: Text.AlignRight
                    }
                }

                PlasmaComponents.Label {
                    text: codexUsageData && codexUsageData.weekly ? codexUsageData.weekly.resets_in : ""
                    font.pixelSize: Kirigami.Units.gridUnit * 0.8
                    color: Kirigami.Theme.disabledTextColor
                }
            }

            // Credits balance (optional)
            ColumnLayout {
                visible: codexUsageData && codexUsageData.credits && codexUsageData.credits.hasCredits && !codexUsageData.credits.unlimited
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                Layout.topMargin: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Label {
                    text: "Credits Balance"
                    font.pixelSize: Kirigami.Units.gridUnit * 0.9
                }

                PlasmaComponents.Label {
                    text: codexUsageData && codexUsageData.credits && codexUsageData.credits.balance !== null
                        ? "$" + codexUsageData.credits.balance.toFixed(2)
                        : "—"
                    font.bold: true
                    font.pixelSize: Kirigami.Units.gridUnit * 1.1
                }
            }
        }

        // Footer with last updated time
        PlasmaComponents.Label {
            Layout.fillWidth: true
            Layout.leftMargin: Kirigami.Units.smallSpacing
            Layout.rightMargin: Kirigami.Units.smallSpacing
            Layout.topMargin: Kirigami.Units.largeSpacing
            text: hasAnyConfig ? "Updated: " + formatTimeSince(lastUpdated, timeTick) : ""
            font.pixelSize: Kirigami.Units.gridUnit * 0.7
            color: Kirigami.Theme.disabledTextColor
            horizontalAlignment: Text.AlignRight
        }
    }

    // ============================================================
    // Initialization
    // ============================================================

    Component.onCompleted: {
        if (hasClaudeConfig) fetchUsage()
        if (hasGlmConfig) fetchGlmUsage()
        resolveCodexToken()
    }
}
