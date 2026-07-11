import Foundation

/// Everything the full-command review page needs, assembled at approval time.
///
/// This page exists so the FULL, unredacted command never has to transit
/// Telegram: the inline card stays redacted/truncated, and fidelity lives
/// here — served loopback-only, reachable exclusively over the tailnet
/// (same security model as the diff review page).
struct CommandArg {
    let name: String
    let value: String
    /// Scalar args of an MCP call can anchor a scoped Always Allow row.
    let scopable: Bool
}

struct CommandContent {
    let sessionLabel: String
    let toolName: String
    let cwd: String?
    /// The primary text (Bash command / file path), when the tool has one.
    let command: String?
    /// Remaining tool args rendered as name → value rows (MCP calls live here).
    let args: [CommandArg]
    let triggerReason: String?
    /// True when the credential gate withheld the command from the Telegram
    /// card — the page shows it anyway (tailnet-only), with a banner saying why.
    let withheldInline: Bool
    /// True when this approval may author a scoped Always Allow from the page
    /// (MCP call with scalar args, not Allow-once-only). Must match whether a
    /// createScopedAllow callback was registered with the server.
    let offersScopedAllow: Bool

    init(sessionLabel: String, toolName: String, cwd: String?, command: String?,
         args: [CommandArg], triggerReason: String?, withheldInline: Bool,
         offersScopedAllow: Bool = false) {
        self.sessionLabel = sessionLabel
        self.toolName = toolName
        self.cwd = cwd
        self.command = command
        self.args = args
        self.triggerReason = triggerReason
        self.withheldInline = withheldInline
        self.offersScopedAllow = offersScopedAllow
    }
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
        if content.offersScopedAllow {
            body += scopedAllowSection(content)
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

    /// Scoped Always Allow authoring — the phone twin of the Mac panel's
    /// per-arg rows. Checked args become argConditions on a persistent allow
    /// rule (regex, full match, absent arg fails closed), prefilled with the
    /// escaped literal value of THIS call.
    private static func scopedAllowSection(_ content: CommandContent) -> String {
        let rows = content.args.filter(\.scopable).map { arg in
            let escaped = DiffHTML.escAttr(NSRegularExpression.escapedPattern(for: arg.value))
            return """
            <div class="scoperow">
            <label><input type="checkbox" class="scopecheck" data-arg="\(DiffHTML.escAttr(arg.name))" onchange="scopeChanged()"> \(DiffHTML.esc(arg.name))</label>
            <input class="pat" id="pat-\(DiffHTML.escAttr(arg.name))" value="\(escaped)" autocapitalize="off" autocorrect="off">
            </div>
            """
        }.joined()
        return """
        <section class="block">
        <h2>Always allow, scoped to</h2>
        <p class="scopehint">Creates an allow rule for \(DiffHTML.esc(content.toolName)) limited to args fully matching these regexes. Absent args never match — future calls outside the scope still prompt. Session rules expire when the session ends; Always rules persist.</p>
        \(rows)
        <div class="scopedbtns">
        <button id="scopedsessionbtn" class="scoped session" disabled onclick="submitScoped('allow_session_scoped')">Allow for session (scoped)</button>
        <button id="scopedbtn" class="scoped" disabled onclick="submitScoped('allow_scoped')">Always Allow (scoped)</button>
        </div>
        </section>
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
    .scopehint { font-size: 12px; opacity: .7; padding: 0 12px 6px; }
    .scoperow { display: flex; align-items: center; gap: 8px; padding: 4px 12px; }
    .scoperow label { flex: 0 0 34%; font-family: ui-monospace, monospace;
                      font-size: 12.5px; word-break: break-all; }
    .scoperow .pat { flex: 1; font-family: ui-monospace, monospace; font-size: 12.5px;
                     padding: 6px 8px; border-radius: 8px; border: 1px solid #0003;
                     background: inherit; color: inherit; min-width: 0; }
    .scopedbtns { display: flex; gap: 10px; margin: 10px 12px 12px; }
    .scoped { flex: 1; padding: 12px; border-radius: 10px; border: none; font-size: 14px;
              font-weight: 600; background: #0969da; color: #fff; }
    .scoped.session { background: #6639ba; }
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
      .scoperow .pat { border-color: #fff3; }
    }
    """

    private static let js = """
    function scopeChanged() {
      const any = document.querySelectorAll('.scopecheck:checked').length > 0;
      document.querySelectorAll('.scoped').forEach(function (b) { b.disabled = !any; });
    }
    function submitScoped(verdict) {
      const conditions = {};
      document.querySelectorAll('.scopecheck:checked').forEach(function (c) {
        const pat = document.getElementById('pat-' + c.dataset.arg);
        if (pat && pat.value.trim()) conditions[c.dataset.arg] = pat.value.trim();
      });
      if (Object.keys(conditions).length === 0) { alert('Tick at least one argument to scope the rule.'); return; }
      post({ verdict: verdict, note: noteValue(), conditions: conditions },
           verdict === 'allow_session_scoped'
             ? '✅ Scoped session allow created (expires with the session) — command proceeding.'
             : '✅ Scoped allow rule created — command proceeding.');
    }
    function submitVerdict(verdict) {
      post({ verdict: verdict, note: noteValue() },
           verdict === 'allow' ? '✅ Allowed — command proceeding.' : '🛑 Denied.');
    }
    function noteValue() {
      return document.getElementById('note').value.trim() || null;
    }
    function post(payload, doneMsg) {
      document.querySelectorAll('.btns button, .scoped').forEach(function (b) { b.disabled = true; });
      fetch(location.pathname + '/verdict', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      }).then(function (r) {
        if (r.ok) {
          finish(doneMsg);
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
      document.querySelectorAll('.btns button, .scoped').forEach(function (b) { b.disabled = false; });
      scopeChanged();
      alert(msg);
    }
    """
}
