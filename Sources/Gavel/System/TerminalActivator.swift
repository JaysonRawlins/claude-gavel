import Cocoa

enum TerminalActivator {

    /// Bring the Ghostty tab whose title encodes `pid` to the front.
    /// Returns true if a matching tab was found and activated.
    @discardableResult
    static func focusGhosttyTab(pid: Int) -> Bool {
        let script = """
        on stripPrefix(s)
            set i to 1
            repeat while i ≤ length of s
                set ch to character i of s
                if ch is in "0123456789" then exit repeat
                set i to i + 1
            end repeat
            if i > length of s then return ""
            return text i thru -1 of s
        end stripPrefix

        on isMatch(itemName, pidStr)
            set tail to my stripPrefix(itemName)
            if tail is "" then return false
            if tail is pidStr then return true
            if tail starts with (pidStr & " ") then return true
            if tail starts with (pidStr & "-") then return true
            return false
        end isMatch

        tell application "System Events"
            if not (exists process "Ghostty") then return false
            tell process "Ghostty"
                try
                    repeat with mi in menu bar 1's menu bar item "Window"'s menu 1's menu items
                        try
                            set n to name of mi as string
                            if my isMatch(n, "\(pid)") then
                                click mi
                                return true
                            end if
                        end try
                    end repeat
                end try
            end tell
        end tell
        return false
        """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return false }
        let result = appleScript.executeAndReturnError(&error)
        if let error = error {
            gavelLog("[terminal] focus pid=\(pid) error=\(error)")
            return false
        }
        return result.booleanValue
    }
}
