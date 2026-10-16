import BrowserTesting
import Foundation
import Testing

/// Netflix and other DRM sites: a page asking for a DRM key system moves to a WebKit tab (FairPlay), and its site's
/// next pages open there directly. Chromium engine only (WebKit is the fallback it hosts).
@Suite(.serialized, .enabled(if: AppDriver.executableFromEnvironment != nil, "set BROWSER_E2E_APP (./forkctl test --e2e)"))
struct ProtectedMediaTests {
    static let pages = [
        "/drm": """
        <!doctype html><title>DRM</title><script>
        navigator.requestMediaKeySystemAccess('com.widevine.alpha', [{ initDataTypes: ['cenc'],
          videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.42E01E"' }] }]).then(() => {}, () => {});
        </script>
        """,
        "/plain": "<!doctype html><title>Plain</title><body>plain</body>",
    ]

    /// Only WebKit has Apple's legacy key API: which engine runs the selected page.
    func inWebKit(_ app: AppDriver) throws -> Bool { try app.eval("typeof WebKitMediaKeys") as? String == "function" }

    @Test func protectedMediaPlaysInWebKit() throws {
        let server = try TestHTTPServer(pages: Self.pages)
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-drm-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: data) }
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!, extraEnvironment: ["BROWSER_DATA_DIR": data.path])
        guard try app.state()["engine"] as? String == "cef-chrome" else { try app.quit(); return }

        try app.open(server.url("/plain"))
        try app.waitUntil(timeout: 15) { try app.tabs().contains { $0.title == "Plain" } }
        #expect(try !inWebKit(app))

        try app.open(server.url("/drm"))
        try app.waitUntil(timeout: 20) { try inWebKit(app) && app.eval("document.title") as? String == "DRM" }
        let fairPlay = "navigator.requestMediaKeySystemAccess('com.apple.fps', [{ initDataTypes: ['skd'], videoCapabilities: [{ contentType: 'application/vnd.apple.mpegurl' }] }]).then(() => document.title = 'fps', () => document.title = 'no fps'); 1"
        _ = try app.eval(fairPlay)
        try app.waitUntil(timeout: 10) { try app.eval("document.title") as? String == "fps" }
        #expect(try app.eval("navigator.userAgent") as? String ?? "" ~= "Safari/")

        // The site is remembered: its next page opens in WebKit at once.
        try app.open(server.url("/plain?again"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "Plain" }
        #expect(try inWebKit(app))
        #expect(try app.tabs().count == 3)
        try app.quit()
    }
}

extension ProtectedMediaTests {
    /// A page moving to WebKit stays signed in: the site's Chromium cookies, HttpOnly ones included, go with it.
    @Test func signInCarriesOverToWebKit() throws {
        let server = try TestHTTPServer(pages: [:], responders: [
            "/login": { _ in (["Set-Cookie: session=s3cret; Path=/; HttpOnly"], "<!doctype html><title>Signed in</title>") },
            "/account": { request in
                let cookie = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("cookie:") }?.dropFirst(7)
                    .trimmingCharacters(in: .whitespaces) ?? "none"
                return ([], "<!doctype html><title>Account \(cookie)</title><script>"
                    + "navigator.requestMediaKeySystemAccess('com.widevine.alpha', [{ initDataTypes: ['cenc'], "
                    + "videoCapabilities: [{ contentType: 'video/mp4; codecs=\"avc1.42E01E\"' }] }]).then(() => {}, () => {});</script>")
            },
        ])
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-drm-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: data) }
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!, extraEnvironment: ["BROWSER_DATA_DIR": data.path])
        guard try app.state()["engine"] as? String == "cef-chrome" else { try app.quit(); return }

        try app.open(server.url("/login"))
        try app.waitUntil(timeout: 15) { try app.tabs().contains { $0.title == "Signed in" } }
        #expect(try !inWebKit(app))
        try app.open(server.url("/account"))
        try app.waitUntil(timeout: 20) { try inWebKit(app) }
        try app.waitUntil(timeout: 10) { try app.eval("document.title") as? String == "Account session=s3cret" }
        try app.quit()
    }
}

/// Netflix's way of playing, end to end without Netflix: MediaSource segments (fMP4, cbcs) with the modern EME API
/// (`com.apple.fps`), licensed by EZDRM's public FairPlay demo (Shaka's "Big Buck Bunny (FairPlay)"). The page asks for
/// FairPlay in Chromium, moves to WebKit, and plays. Reaches the internet: opt-in with BROWSER_E2E_NETWORK=1.
@Suite(.serialized, .enabled(if: AppDriver.executableFromEnvironment != nil && ProcessInfo.processInfo.environment["BROWSER_E2E_NETWORK"] != nil,
                             "set BROWSER_E2E_APP and BROWSER_E2E_NETWORK=1"))
struct FairPlayNetworkTests {
    static let page = #"""
<!doctype html><title>start</title><video id="v" width="640" height="360" muted playsinline></video>
<script>
// Netflix's way of playing, without Netflix: MediaSource segments (fMP4, cbcs) and the modern EME API (com.apple.fps),
// against EZDRM's public FairPlay demo (Shaka's "Big Buck Bunny (FairPlay)").
const base = 'https://na-fps.ezdrm.com/demo/ezdrm/';
const licenseURL = 'https://fps.ezdrm.com/api/licenses/b99ed9e5-c641-49d1-bfa8-43692b686ddb';
const certURL = 'https://fps.ezdrm.com/demo/video/eleisure.cer';
const say = s => { document.title = s; };
const v = document.getElementById('v');
async function range(u, length, offset) {
  const r = await fetch(u, { headers: { Range: 'bytes=' + offset + '-' + (offset + length - 1) } });
  return new Uint8Array(await r.arrayBuffer());
}
(async () => {
  try {
    const cert = new Uint8Array(await (await fetch(certURL)).arrayBuffer());
    const access = await navigator.requestMediaKeySystemAccess('com.apple.fps', [{ initDataTypes: ['sinf', 'skd'],
      videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.64001f"', robustness: '' }] }]);
    const keys = await access.createMediaKeys();
    await keys.setServerCertificate(cert);
    await v.setMediaKeys(keys);
    v.addEventListener('encrypted', async e => {
      say('encrypted ' + e.initDataType);
      const session = keys.createSession();
      session.addEventListener('message', async m => {
        const r = await fetch(licenseURL, { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: m.message });
        const ckc = new Uint8Array(await r.arrayBuffer());
        say('license ' + r.status + ' ' + ckc.length);
        try { await session.update(ckc); say('keyed'); } catch (err) { say('update error ' + err.name + ' ' + err.message); }
      });
      await session.generateRequest(e.initDataType, e.initData);
    }, { once: true });
    v.addEventListener('error', () => say('media error ' + (v.error && v.error.code) + ' ' + (v.error && v.error.message)));

    const lines = (await (await fetch(base + 'stream_1.m3u8')).text()).split('\n');
    const map = lines.find(l => l.startsWith('#EXT-X-MAP')).match(/URI="([^"]+)",BYTERANGE="(\d+)@(\d+)"/);
    const file = base + map[1];
    const segments = []; let next = 0;
    for (const l of lines) {
      const m = l.match(/^#EXT-X-BYTERANGE:(\d+)(?:@(\d+))?/);
      if (!m) continue;
      const offset = m[2] !== undefined ? +m[2] : next;
      segments.push([+m[1], offset]); next = offset + +m[1];
      if (segments.length === 3) break;
    }
    const ms = new MediaSource(); v.src = URL.createObjectURL(ms);
    await new Promise(r => ms.addEventListener('sourceopen', r, { once: true }));
    const sb = ms.addSourceBuffer('video/mp4; codecs="avc1.64001f"');
    const append = d => new Promise((res, rej) => { sb.addEventListener('updateend', res, { once: true }); sb.addEventListener('error', rej, { once: true }); sb.appendBuffer(d); });
    await append(await range(file, +map[2], +map[3]));
    v.play().catch(() => {});
    setInterval(() => {
      const q = v.getVideoPlaybackQuality();
      if (v.currentTime > 2) say('playing t=' + v.currentTime.toFixed(1) + ' frames=' + q.totalVideoFrames + ' dropped=' + q.droppedVideoFrames + ' ' + v.videoWidth + 'x' + v.videoHeight);
    }, 500);
    for (const [length, offset] of segments) await append(await range(file, length, offset));
  } catch (e) { say('error ' + (e && e.name) + ': ' + (e && e.message)); }
})();
</script>
"""#

    @Test func fairPlayPlaysThroughMediaSource() throws {
        let server = try TestHTTPServer(pages: ["/fairplay": Self.page])
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-fps-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: data) }
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!, extraEnvironment: ["BROWSER_DATA_DIR": data.path])
        guard try app.state()["engine"] as? String == "cef-chrome" else { try app.quit(); return }
        try app.open(server.url("/fairplay"))
        var title = ""
        try app.waitUntil(timeout: 60) {
            title = try app.eval("document.title") as? String ?? ""
            return title.hasPrefix("playing") || title.hasPrefix("error") || title.contains("error")
        }
        #expect(title.hasPrefix("playing"), "page reported: \(title)")
        #expect(title.contains("dropped=0"))
        try app.quit()
    }
}

private func ~= (string: String, part: String) -> Bool { string.contains(part) }
