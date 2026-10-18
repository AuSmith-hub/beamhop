import AppKit
import ApplicationServices
import Foundation
import BeamhopCore

/// Kimi Work (Kimi desktop) delivery, mechanism verified by probe 2026-10-18:
///   - App element ACCEPTS AXManualAccessibility (opt-in succeeds — unlike ChatGPT 26.x).
///   - Exactly one AXTextArea/AXTextField in the window tree; AXEditable not exposed
///     (kAXErrorNoValue) — the shared AXComposerFinder two-pass logic handles it.
///   - kAXValueAttribute set-value returns success but does NOT take effect on Kimi's editor
///     (empty composer keeps exposing its placeholder as the AX value; injection appends to a
///     phantom node). So injection = FOCUS the composer, then clipboard-paste (⌘V) — the same
///     §12.3 clipboard-safe protocol, verified clean: pasted text lands exactly, placeholder
///     stays visual-only.
///   - auto_submit = false — user reviews and sends manually (consistent with ChatGPT §7.5 ⑥).
enum KimiDelivery {
    static let bundleIDs = ["com.moonshot.kimichat"]

    /// Returns nil on success, or a user-facing failure reason (caller falls back to clipboard).
    static func deliver(_ capture: Capture, userNote: String?) -> String? {
        guard let (app, bundleID) = runningApp() else {
            return "Kimi Work 未运行(先打开它,或改用剪贴板)"
        }
        guard AppActivator.focus(app, bundleID: bundleID) else { return "无法把 Kimi Work 切到前台" }

        AXHelper.enableManualAX(pid: app.processIdentifier)
        usleep(150_000)   // let Chromium rebuild the tree

        guard AXComposerFinder.waitForWindow(pid: app.processIdentifier) else {
            return "Kimi Work 窗口未打开(点开它的窗口再试)"
        }

        // Deliver into a FRESH conversation (context hygiene): press the sidebar "新建会话"
        // button via AXPress (measured 2026-10-18, desc="新建会话"). Best-effort — if the button
        // can't be found in a future layout we degrade to pasting into the current composer.
        if let newChat = findNewChatButton(pid: app.processIdentifier) {
            AXUIElementPerformAction(newChat, kAXPressAction as CFString)
            usleep(600_000)   // let the new conversation's composer render
        }

        guard let composer = AXComposerFinder.findComposer(pid: app.processIdentifier) else {
            return "未找到 Kimi 输入框(AXTextArea)——版本可能已变化,请用剪贴板"
        }
        guard AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString,
                                           kCFBooleanTrue) == .success else {
            return "无法聚焦 Kimi 输入框"
        }
        usleep(150_000)   // focus settle before the paste lands

        // Kimi has no MCP channel: paste the FULL self-contained markdown (§7.5 pattern).
        let md = PromptRenderer.fullMarkdown(capture, userNote: userNote)
        do {
            try ClipboardService.safePasteOnly(md)
        } catch {
            return "剪贴板无法保护,已放弃自动粘贴(请手动粘贴)"
        }
        Notifier.info("已粘贴到 Kimi Work", "请检查内容后手动发送(不自动回车)")
        return nil
    }

    /// Sidebar "新建会话" button (desc-identified; title is empty on this build).
    /// ⚠️ BFS must start from the WINDOW element — Electron 43's app element only exposes
    /// menu bars; the window subtree is reachable via AXFocusedWindow/AXMainWindow only.
    private static func findNewChatButton(pid: pid_t) -> AXUIElement? {
        guard let root = AXComposerFinder.resolveWindow(pid: pid) else { return nil }
        var queue: [(el: AXUIElement, depth: Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 4000 {
            let (el, depth) = queue.removeFirst()
            visited += 1
            if let role = axString(el, kAXRoleAttribute as String), role == (kAXButtonRole as String) {
                let desc = axString(el, kAXDescriptionAttribute as String) ?? ""
                let title = axString(el, kAXTitleAttribute as String) ?? ""
                if desc == "新建会话" || title == "新建会话" || desc == "New chat" { return el }
            }
            guard depth < 40 else { continue }
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let childrenRef, CFGetTypeID(childrenRef) == CFArrayGetTypeID() else { continue }
            for child in (childrenRef as! CFArray as NSArray) {
                queue.append((child as! AXUIElement, depth + 1))
            }
        }
        return nil
    }

    private static func axString(_ el: AXUIElement, _ key: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success,
              let v, CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
        return v as! CFString as String
    }

    private static func runningApp() -> (NSRunningApplication, String)? {
        for bid in bundleIDs {
            if let app = AppActivator.runningApp(bundleID: bid) { return (app, bid) }
        }
        return nil
    }
}
