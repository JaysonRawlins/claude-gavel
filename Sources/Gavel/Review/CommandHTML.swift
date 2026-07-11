import Foundation

/// Everything the full-command review page needs, assembled at approval time.
///
/// This page exists so the FULL, unredacted command never has to transit
/// Telegram: the inline card stays redacted/truncated, and fidelity lives
/// here — served loopback-only, reachable exclusively over the tailnet
/// (same security model as the diff review page).
struct CommandContent {
    let sessionLabel: String
    let toolName: String
    let cwd: String?
    /// The primary text (Bash command / file path), when the tool has one.
    let command: String?
    /// Remaining tool args rendered as name → value rows (MCP calls live here).
    let args: [(name: String, value: String)]
    let triggerReason: String?
    /// True when the credential gate withheld the command from the Telegram
    /// card — the page shows it anyway (tailnet-only), with a banner saying why.
    let withheldInline: Bool
}

/// Server-side renderer for the mobile full-command page. Fully
/// self-contained (inline CSS/JS, no external fetches), same as DiffHTML.
enum CommandHTML {

    static func page(content: CommandContent) -> String {
        var banners = ""
        if content.withheldInline {
            banners += banner("Withheld from Telegram — possible credential in the command. This page never leaves your tailnet.")
        }
        if let reason = content.triggerReason, !reason.isEmpty {
            banners += banner(DiffHTML.esc(reason))
        }

        var metaRows = ""
        if let cwd = content.cwd, !cwd.isEmpty {
            metaRows += metaRow("cwd", cwd)
        }

        var body = ""
        if let command = content.command, !command.isEmpty {
            body += "<section class=\"block\"><h2>Command</h2><pre>\(DiffHTML.esc(command))</pre></section>"
        }
        if !content.args.isEmpty {
            let rows = content.args.map { arg in
                "<div class=\"arg\"><div class=\"aname\">\(DiffHTML.esc(arg.name))</div><pre>\(DiffHTML.esc(arg.value))</pre></div>"
            }.joined()
            body += "<section class=\"block\"><h2>Arguments</h2>\(rows)</section>"
        }
        if body.isEmpty {
            body = "<p class=\"empty\">No command text or arguments on this call.</p>"
        }

        let title = DiffHTML.esc("Approval — \(content.toolName)")
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
        <h1>\(DiffHTML.esc(content.toolName))</h1>
        <p class="msg">\(DiffHTML.esc(content.sessionLabel))</p>
        \(metaRows)
        </header>
        \(banners)
        <main>\(body)</main>
        <footer id="bar">
        <textarea id="note" placeholder="Note to Claude (optional)"></textarea>
        <div class="btns">
        <button class="reject" onclick="submitVerdict('deny')">Deny</button>
        <button class="approve" onclick="submitVerdict('allow')">Allow once</button>
        </div>
        </footer>
        <script>\(js)</script>
        </body>
        </html>
        """
    }

    private static func banner(_ escapedText: String) -> String {
        "<div class=\"banner\">\(escapedText)</div>"
    }

    private static func metaRow(_ label: String, _ value: String) -> String {
        "<p class=\"meta\"><span class=\"mlabel\">\(DiffHTML.esc(label))</span> \(DiffHTML.esc(value))</p>"
    }

    private static let css = """
    :root { color-scheme: light dark; }
    * { box-sizing: border-box; margin: 0; }
    body { font-family: -apple-system, system-ui, sans-serif; font-size: 15px;
           background: #f5f5f7; color: #1d1d1f; padding-bottom: 170px; }
    header { padding: 14px 16px 8px; }
    h1 { font-size: 17px; font-family: ui-monospace, monospace; word-break: break-all; }
    h2 { font-size: 12px; text-transform: uppercase; letter-spacing: .04em;
         opacity: .6; padding: 10px 12px 4px; }
    .msg { font-style: italic; opacity: .8; margin-top: 4px; }
    .meta { font-size: 13px; opacity: .75; margin-top: 4px; word-break: break-all; }
    .mlabel { font-weight: 600; opacity: .8; margin-right: 4px; }
    .banner { background: #fff8c5; border: 1px solid #d4a72c66; margin: 6px 12px;
              padding: 8px 12px; border-radius: 8px; font-size: 13px; }
    .block { background: #fff; margin: 8px 8px; border-radius: 10px; overflow: hidden;
             border: 1px solid #0000001a; }
    pre { font-family: ui-monospace, monospace; font-size: 12.5px; line-height: 1.5;
          padding: 8px 12px 12px; overflow-x: auto; white-space: pre-wrap;
          word-break: break-word; }
    .arg { border-top: 1px solid #0000000d; }
    .arg:first-of-type { border-top: none; }
    .aname { font-family: ui-monospace, monospace; font-size: 11px; font-weight: 700;
             opacity: .65; padding: 8px 12px 0; }
    .empty { padding: 24px; text-align: center; opacity: .7; }
    footer { position: fixed; bottom: 0; left: 0; right: 0; background: #fffffff2;
             backdrop-filter: blur(10px); border-top: 1px solid #0002; padding: 10px 0
             calc(10px + env(safe-area-inset-bottom)); }
    textarea { width: calc(100% - 24px); margin: 0 12px 8px; padding: 8px;
               border-radius: 8px; border: 1px solid #0003; font-size: 15px;
               font-family: inherit; min-height: 44px; background: inherit; color: inherit; }
    .btns { display: flex; gap: 10px; padding: 0 12px; }
    .btns button { flex: 1; padding: 12px; border-radius: 10px; border: none;
                   font-size: 16px; font-weight: 600; }
    .approve { background: #1a7f37; color: #fff; }
    .reject { background: #cf222e; color: #fff; }
    button:disabled { opacity: .5; }
    @media (prefers-color-scheme: dark) {
      body { background: #161618; color: #f5f5f7; }
      .block { background: #1e1e20; border-color: #ffffff1a; }
      .banner { background: #3a3117; border-color: #d4a72c44; }
      footer { background: #161618f2; border-color: #fff2; }
      textarea { border-color: #fff3; }
    }
    """

    private static let js = """
    function submitVerdict(verdict) {
      const note = document.getElementById('note').value.trim();
      document.querySelectorAll('.btns button').forEach(function (b) { b.disabled = true; });
      fetch(location.pathname + '/verdict', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ verdict: verdict, note: note || null })
      }).then(function (r) {
        if (r.ok) {
          finish(verdict === 'allow' ? '✅ Allowed — command proceeding.' : '🛑 Denied.');
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
