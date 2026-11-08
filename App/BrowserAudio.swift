import Foundation
import WebKit

/// A per-tab media output gate, installed before page scripts in every frame.
/// WebKit's playback-suspension API also stops video, so sound is controlled at
/// HTML media elements and the final Web Audio output instead.
@MainActor
final class BrowserAudioController: NSObject, WKScriptMessageHandler {
    static let scriptMarker = "/* TrendingTab media output */"
    private let channel = "trendingAudio" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let command = "trendingAudio" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private weak var webView: WKWebView?
    private var frames: [String: (info: WKFrameInfo, playing: Bool, seen: Date)] = [:]
    private var expiryTask: Task<Void, Never>?
    private(set) var muted = true
    private var playing = false
    var onPlaybackChange: ((Bool) -> Void)?

    private final class MessageHandler: NSObject, WKScriptMessageHandler {
        weak var target: BrowserAudioController?
        init(_ target: BrowserAudioController) { self.target = target }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(userContentController, didReceive: message)
        }
    }

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        webView.configuration.userContentController.add(MessageHandler(self), contentWorld: .page, name: channel)
        installScript()
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.updatePlaying()
            }
        }
    }

    deinit { expiryTask?.cancel() }

    func setMuted(_ value: Bool) {
        muted = value
        installScript()
        for frame in frames.values { apply(to: frame.info) }
    }

    func navigationStarted() {
        frames.removeAll()
        updatePlaying()
    }

    private func installScript() {
        guard let controller = webView?.configuration.userContentController else { return }
        let others = controller.userScripts.filter { !$0.source.hasPrefix(Self.scriptMarker) }
        controller.removeAllUserScripts()
        for script in others { controller.addUserScript(script) }
        controller.addUserScript(WKUserScript(source: Self.script(channel: channel, command: command, muted: muted),
                                             injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    }

    private func apply(to frame: WKFrameInfo) {
        webView?.callAsyncJavaScript("window[command]?.(muted)", arguments: ["command": command, "muted": muted],
                                    in: frame, in: .page, completionHandler: { _ in })
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView, let body = message.body as? [String: Any],
              let id = body["id"] as? String, id.count < 100,
              let active = body["playing"] as? Bool else { return }
        if body["gone"] as? Bool == true { frames.removeValue(forKey: id) }
        else {
            frames[id] = (message.frameInfo, active, Date())
            if body["ready"] as? Bool == true || body["muted"] as? Bool != muted { apply(to: message.frameInfo) }
        }
        updatePlaying()
    }

    private func updatePlaying() {
        let now = Date()
        // A detached iframe or terminated page must not leave an audio hint behind.
        // Retain frame references for sound changes while a background page's
        // JavaScript timer is throttled; only the visual activity expires.
        let active = frames.values.contains { $0.playing && now.timeIntervalSince($0.seen) < 2 }
        guard active != playing else { return }
        playing = active
        onPlaybackChange?(active)
    }

    private static func script(channel: String, command: String, muted: Bool) -> String {
        #"""
        /* TrendingTab media output */
        (() => {
            const command = "\#(command)";
            if (window[command]) return;
            let muted = \#(muted ? "true" : "false");
            const id = crypto.randomUUID?.() || (Date.now().toString(36) + Math.random().toString(36));
            const post = window.webkit.messageHandlers["\#(channel)"].postMessage.bind(window.webkit.messageHandlers["\#(channel)"]);
            const elements = new Set();
            const requestedMute = new WeakMap();
            const descriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'muted');
            const nativePlay = HTMLMediaElement.prototype.play;
            const nativeConnect = window.AudioNode?.prototype.connect;
            const nativeDisconnect = window.AudioNode?.prototype.disconnect;
            const outputs = new Map();
            let lastPlaying = false;
            let lastReport = 0;
            let reporting = false;

            function applyMute(media) {
                const value = muted || requestedMute.get(media);
                if (descriptor.get.call(media) !== value) descriptor.set.call(media, value);
            }
            function track(media) {
                if (!requestedMute.has(media)) requestedMute.set(media, descriptor.get.call(media));
                elements.add(media);
                applyMute(media);
            }
            Object.defineProperty(HTMLMediaElement.prototype, 'muted', {
                ...descriptor,
                set(value) {
                    requestedMute.set(this, Boolean(value));
                    elements.add(this);
                    applyMute(this);
                }
            });
            HTMLMediaElement.prototype.play = function(...args) { track(this); return nativePlay.apply(this, args); };

            function output(context) {
                if (outputs.has(context)) return outputs.get(context);
                const analyser = context.createAnalyser();
                analyser.fftSize = 256;
                const gain = context.createGain();
                gain.gain.value = muted ? 0 : 1;
                nativeConnect.call(analyser, gain);
                nativeConnect.call(gain, context.destination);
                const result = { analyser, gain, samples: new Float32Array(256) };
                outputs.set(context, result);
                return result;
            }
            if (nativeConnect) {
                AudioNode.prototype.connect = function(destination, ...ports) {
                    if (destination === this.context.destination && !(this.context instanceof OfflineAudioContext)) {
                        nativeConnect.call(this, output(this.context).analyser, ...ports);
                        return destination;
                    }
                    return nativeConnect.call(this, destination, ...ports);
                };
                AudioNode.prototype.disconnect = function(...args) {
                    if (args[0] === this.context.destination && outputs.has(this.context)) args[0] = outputs.get(this.context).analyser;
                    return nativeDisconnect.apply(this, args);
                };
            }

            function scan(root) {
                if (root instanceof HTMLMediaElement) track(root);
                for (const media of root.querySelectorAll?.('audio,video') || []) track(media);
            }
            new MutationObserver(records => {
                for (const record of records) for (const node of record.addedNodes) scan(node);
            }).observe(document, { childList: true, subtree: true });
            // Players also create video inside shadow roots or while detached.
            const attachShadow = Element.prototype.attachShadow;
            Element.prototype.attachShadow = function(...args) {
                const root = attachShadow.apply(this, args);
                new MutationObserver(records => {
                    for (const record of records) for (const node of record.addedNodes) scan(node);
                }).observe(root, { childList: true, subtree: true });
                return root;
            };

            function report(ready = false, gone = false) {
                if (reporting) return;
                reporting = true;
                let playing = false;
                for (const media of elements) {
                    if (!media.isConnected && media.paused) { elements.delete(media); continue; }
                    // A site's own mute and volume choices remain independent of the tab gate.
                    if (muted && !descriptor.get.call(media)) descriptor.set.call(media, true);
                    const hasAudio = media instanceof HTMLAudioElement || (media.audioTracks
                        ? media.audioTracks.length > 0 : media.webkitAudioDecodedByteCount > 0);
                    if (hasAudio && !media.paused && !media.ended && media.readyState >= 2 && media.volume > 0 && !requestedMute.get(media)) playing = true;
                }
                for (const [context, gate] of outputs) {
                    if (context.state === 'closed') { outputs.delete(context); continue; }
                    if (context.state !== 'running') continue;
                    gate.analyser.getFloatTimeDomainData(gate.samples);
                    if (gate.samples.some(value => Math.abs(value) > 0.0001)) playing = true;
                }
                const now = performance.now();
                if (ready || gone || playing !== lastPlaying || now - lastReport >= 500) {
                    post({ id, muted, playing: gone ? false : playing, ready, gone });
                    lastPlaying = playing; lastReport = now;
                }
                reporting = false;
            }
            Object.defineProperty(window, command, { value(value) {
                muted = Boolean(value);
                for (const media of elements) applyMute(media);
                for (const [context, gate] of outputs) if (context.state !== 'closed') gate.gain.gain.setValueAtTime(muted ? 0 : 1, context.currentTime);
                report();
            }});
            for (const event of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied']) {
                document.addEventListener(event, e => { if (e.target instanceof HTMLMediaElement) { track(e.target); report(); } }, true);
            }
            addEventListener('pageshow', () => report(true));
            addEventListener('pagehide', () => report(false, true));
            scan(document);
            setInterval(report, 250);
            report(true);
        })();
        """#
    }
}
