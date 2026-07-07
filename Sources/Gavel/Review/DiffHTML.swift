import Foundation

/// Everything the review page needs, assembled at approval time.
struct ReviewContent {
    let repoName: String
    let commitMessage: String?
    let files: [DiffFile]
    let includesUnstaged: Bool
    let truncated: Bool
}

/// Server-side renderer for the mobile review page. Fully self-contained:
/// inline CSS/JS, no external fetches (the page is served over the tailnet
/// and must work without any CDN).
enum DiffHTML {

    static func page(content: ReviewContent) -> String {
        let adds = content.files.reduce(0) { $0 + $1.additions }
        let dels = content.files.reduce(0) { $0 + $1.deletions }

        var banners = ""
        if content.includesUnstaged {
            banners += banner("Commit uses -a: includes unstaged changes to tracked files.")
        }
        if content.truncated {
            banners += banner("Diff truncated at \(GavelConstants.reviewDiffMaxBytes / (1024 * 1024)) MB — review the tail at the desk.")
        }

        let body: String
        if content.files.isEmpty {
            body = "<p class=\"empty\">No changes captured — nothing staged?</p>"
        } else {
            body = content.files.map { fileSection($0) }.joined()
        }

        let title = esc("Review — \(content.repoName)")
        let commitLine = content.commitMessage.map {
            "<p class=\"msg\">\(esc($0))</p>"
        } ?? ""

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>\(css)</style>
        </head>
        <body>
        <header>
        <h1>\(esc(content.repoName))</h1>
        \(commitLine)
        <p class="stats">\(content.files.count) file\(content.files.count == 1 ? "" : "s") · <span class="add">+\(adds)</span> <span class="del">−\(dels)</span></p>
        </header>
        \(banners)
        <main>\(body)</main>
        <footer id="bar">
        <textarea id="note" placeholder="Overall note (optional)"></textarea>
        <div class="btns">
        <button class="reject" onclick="submitVerdict('request_changes')">Request changes</button>
        <button class="approve" onclick="submitVerdict('approve')">Approve</button>
        </div>
        </footer>
        <script>\(js)</script>
        </body>
        </html>
        """
    }

    static func resolvedPage(by source: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Review resolved</title><style>\(css)</style></head>
        <body><header><h1>Already resolved</h1>
        <p class="msg">This approval was resolved via \(esc(source)).</p></header></body></html>
        """
    }

    // MARK: - Sections

    private static func fileSection(_ file: DiffFile) -> String {
        var label = esc(file.displayPath)
        if file.isRename { label = "\(esc(file.oldPath)) → \(esc(file.newPath))" }
        var tag = ""
        if file.isNew { tag = "<span class=\"tag new\">new</span>" }
        if file.isDeleted { tag = "<span class=\"tag del\">deleted</span>" }
        if file.isBinary { tag += "<span class=\"tag bin\">binary</span>" }

        let inner: String
        if file.isBinary {
            inner = "<div class=\"withheld\">Binary file — not rendered.</div>"
        } else if file.hunks.isEmpty {
            inner = "<div class=\"withheld\">No content changes (mode/rename only).</div>"
        } else {
            inner = file.hunks.map { hunkSection($0, file: file) }.joined()
        }

        return """
        <details open class="file">
        <summary>\(label) \(tag) <span class="fstats"><span class="add">+\(file.additions)</span> <span class="del">−\(file.deletions)</span></span></summary>
        \(inner)
        </details>
        """
    }

    private static func hunkSection(_ hunk: DiffHunk, file: DiffFile) -> String {
        // Credential gate for content leaving the machine: same philosophy as
        // CredentialGate withholding commands from Telegram. Known-secret
        // patterns only — the entropy heuristic would flag every lockfile hash.
        if let label = SecretRedactor.firstMatchLabel(in: hunk.rawText) {
            return """
            <div class="hunk">
            <div class="hheader">\(esc(hunk.header))</div>
            <div class="withheld">Hunk withheld — possible \(esc(label)). Review at the desk.</div>
            </div>
            """
        }

        let rows = hunk.lines.map { line -> String in
            let cls: String
            switch line.kind {
            case .addition: cls = "add"
            case .deletion: cls = "del"
            case .context: cls = "ctx"
            case .meta: cls = "meta"
            }
            let num = line.newNumber ?? line.oldNumber
            let numText = num.map(String.init) ?? ""
            return "<div class=\"ln \(cls)\"><span class=\"no\">\(numText)</span><span class=\"code\">\(esc(line.raw))</span></div>"
        }.joined()

        return """
        <div class="hunk">
        <div class="hheader">\(esc(hunk.header))</div>
        <div class="lines">\(rows)</div>
        <button class="cbtn" onclick="toggleComment(this)">💬 Comment</button>
        <textarea class="hc hidden" data-file="\(escAttr(file.displayPath))" data-line="\(hunk.newStart)" placeholder="Comment on this hunk"></textarea>
        </div>
        """
    }

    private static func banner(_ text: String) -> String {
        "<div class=\"banner\">\(esc(text))</div>"
    }

    // MARK: - Escaping

    static func esc(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escAttr(_ text: String) -> String {
        esc(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - Assets

    private static let css = """
    :root { color-scheme: light dark; }
    * { box-sizing: border-box; margin: 0; }
    body { font-family: -apple-system, system-ui, sans-serif; font-size: 15px;
           background: #f5f5f7; color: #1d1d1f; padding-bottom: 170px; }
    header { padding: 14px 16px 8px; }
    h1 { font-size: 17px; }
    .msg { font-style: italic; opacity: .8; margin-top: 4px; }
    .stats, .fstats { font-size: 13px; opacity: .75; margin-top: 4px; }
    .add { color: #1a7f37; } .del { color: #cf222e; }
    .banner { background: #fff8c5; border: 1px solid #d4a72c66; margin: 6px 12px;
              padding: 8px 12px; border-radius: 8px; font-size: 13px; }
    .file { background: #fff; margin: 8px 8px; border-radius: 10px; overflow: hidden;
            border: 1px solid #0000001a; }
    summary { padding: 10px 12px; font-weight: 600; font-size: 13px;
              font-family: ui-monospace, monospace; word-break: break-all; cursor: pointer; }
    .tag { font-size: 11px; padding: 1px 6px; border-radius: 6px; margin-left: 4px;
           background: #ddf4ff; color: #0969da; font-family: -apple-system, system-ui; }
    .tag.del { background: #ffebe9; color: #cf222e; }
    .hunk { border-top: 1px solid #0000000d; }
    .hheader { font-family: ui-monospace, monospace; font-size: 11px; opacity: .6;
               padding: 6px 12px; background: #f0f4f8; }
    .lines { overflow-x: auto; font-family: ui-monospace, monospace; font-size: 12px;
             line-height: 1.5; }
    .ln { display: flex; white-space: pre; }
    .ln .no { flex: 0 0 38px; text-align: right; padding-right: 8px; opacity: .4;
              user-select: none; font-size: 10px; line-height: 1.8; }
    .ln .code { padding-right: 12px; }
    .ln.add { background: #dafbe1; } .ln.add .code { color: #116329; }
    .ln.del { background: #ffebe9; } .ln.del .code { color: #82071e; }
    .ln.meta { opacity: .5; font-style: italic; }
    .withheld { padding: 12px; font-size: 13px; background: #fff1e5; color: #953800; }
    .cbtn { margin: 8px 12px; font-size: 12px; padding: 4px 10px; border-radius: 8px;
            border: 1px solid #0002; background: transparent; }
    textarea { width: calc(100% - 24px); margin: 0 12px 10px; padding: 8px;
               border-radius: 8px; border: 1px solid #0003; font-size: 15px;
               font-family: inherit; min-height: 60px; background: inherit; color: inherit; }
    .hidden { display: none; }
    .empty { padding: 24px; text-align: center; opacity: .7; }
    footer { position: fixed; bottom: 0; left: 0; right: 0; background: #fffffff2;
             backdrop-filter: blur(10px); border-top: 1px solid #0002; padding: 10px 0
             calc(10px + env(safe-area-inset-bottom)); }
    footer textarea { min-height: 44px; margin-bottom: 8px; }
    .btns { display: flex; gap: 10px; padding: 0 12px; }
    .btns button { flex: 1; padding: 12px; border-radius: 10px; border: none;
                   font-size: 16px; font-weight: 600; }
    .approve { background: #1a7f37; color: #fff; }
    .reject { background: #cf222e; color: #fff; }
    button:disabled { opacity: .5; }
    @media (prefers-color-scheme: dark) {
      body { background: #161618; color: #f5f5f7; }
      .file { background: #1e1e20; border-color: #ffffff1a; }
      .hheader { background: #26262a; }
      .banner { background: #3a3117; border-color: #d4a72c44; }
      .ln.add { background: #12261e; } .ln.add .code { color: #3fb950; }
      .ln.del { background: #2d1215; } .ln.del .code { color: #f85149; }
      .withheld { background: #341a00; color: #e3b341; }
      footer { background: #161618f2; border-color: #fff2; }
      .cbtn { border-color: #fff3; color: #f5f5f7; }
      textarea { border-color: #fff3; }
    }
    """

    private static let js = """
    function toggleComment(btn) {
      const ta = btn.nextElementSibling;
      ta.classList.toggle('hidden');
      if (!ta.classList.contains('hidden')) ta.focus();
    }
    function submitVerdict(verdict) {
      const comments = [];
      document.querySelectorAll('textarea.hc').forEach(function (t) {
        if (t.value.trim()) {
          comments.push({ file: t.dataset.file, line: parseInt(t.dataset.line, 10), text: t.value.trim() });
        }
      });
      const note = document.getElementById('note').value.trim();
      document.querySelectorAll('.btns button').forEach(function (b) { b.disabled = true; });
      fetch(location.pathname + '/verdict', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ verdict: verdict, note: note || null, comments: comments })
      }).then(function (r) {
        if (r.ok) {
          finish(verdict === 'approve' ? '✅ Approved — commit proceeding.'
                                       : '📝 Changes requested — comments sent to Claude.');
        } else if (r.status === 409) {
          finish('Already resolved elsewhere (Mac panel or Telegram).');
        } else {
          fail('Submit failed: HTTP ' + r.status);
        }
      }).catch(function (e) { fail('Submit failed: ' + e); });
    }
    function finish(msg) {
      document.body.innerHTML = '<header><h1>' + msg + '</h1><p class="msg">You can close this tab.</p></header>';
    }
    function fail(msg) {
      document.querySelectorAll('.btns button').forEach(function (b) { b.disabled = false; });
      alert(msg);
    }
    """
}
