import AppKit
import ApplicationServices
import Foundation

// Native AX navigation through application elements and actions.
enum ControlFailure: Error { case blocked(String) }
let started = ProcessInfo.processInfo.systemUptime
let deadline = started + 8.0
var visits = 0
var actions: [[String: Any]] = []
let composerLabels = ["메시지 입력", "Message", "Type a message", "Enter a message"]

func check() throws {
    guard visits < 20_000, ProcessInfo.processInfo.systemUptime < deadline else {
        throw ControlFailure.blocked("accessibility_control_limit")
    }
}
func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
}
func string(_ el: AXUIElement, _ name: String) -> String {
    if let s = attr(el, name) as? String { return s }
    if let s = attr(el, name) as? NSAttributedString { return s.string }
    return ""
}
func elements(_ el: AXUIElement, _ name: String = "AXChildren") -> [AXUIElement] {
    return attr(el, name) as? [AXUIElement] ?? []
}
func composerText(_ el: AXUIElement) throws -> String {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(el, "AXValue" as CFString, &value)
    if result == .noValue { return "" }
    guard result == .success else { throw ControlFailure.blocked("composer_value_unavailable") }
    if let text = value as? String { return text }
    if let text = value as? NSAttributedString { return text.string }
    throw ControlFailure.blocked("composer_value_unavailable")
}
func names(_ el: AXUIElement) -> [String] {
    var value: CFArray?
    _ = AXUIElementCopyActionNames(el, &value)
    return value as? [String] ?? []
}
func settable(_ el: AXUIElement, _ name: String) -> Bool {
    var result = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(el, name as CFString, &result) == .success && result.boolValue
}
func act(_ el: AXUIElement, _ name: String) throws {
    try check()
    let result = AXUIElementPerformAction(el, name as CFString)
    actions.append(["action": name, "result": Int(result.rawValue)])
}
func setValue(_ el: AXUIElement, _ value: String) throws {
    try check()
    guard ["AXTextField", "AXSearchField"].contains(string(el, "AXRole")) else {
        throw ControlFailure.blocked("only_search_text_fields_may_be_edited")
    }
    // AXValue changes the displayed string but Kakao's room-search delegate does not
    // observe it. AXSelectedText performs an actual accessibility text edit instead.
    if settable(el, "AXFocused") {
        let result = AXUIElementSetAttributeValue(el, "AXFocused" as CFString, kCFBooleanTrue)
        actions.append(["action": "AXFocused(search)", "result": Int(result.rawValue)])
    }
    if settable(el, "AXSelectedText"), settable(el, "AXSelectedTextRange") {
        var range = CFRange(location: 0, length: string(el, "AXValue").utf16.count)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { throw ControlFailure.blocked("search_selection_unavailable") }
        let selected = AXUIElementSetAttributeValue(el, "AXSelectedTextRange" as CFString, rangeValue)
        actions.append(["action": "AXSelectedTextRange(search)", "result": Int(selected.rawValue)])
        guard selected == .success else { throw ControlFailure.blocked("search_selection_failed") }
        let edited = AXUIElementSetAttributeValue(el, "AXSelectedText" as CFString, value as CFString)
        actions.append(["action": "AXSelectedText(search)", "result": Int(edited.rawValue)])
        guard edited == .success, string(el, "AXValue") == value else { throw ControlFailure.blocked("search_text_edit_failed") }
        return
    }
    throw ControlFailure.blocked("search_text_edit_not_supported")
}
func nodes(_ el: AXUIElement, tables: Bool = false, depth: Int = 0) throws -> [AXUIElement] {
    visits += 1
    try check()
    guard depth < 20 else { throw ControlFailure.blocked("accessibility_tree_depth") }
    let role = string(el, "AXRole")
    if ["AXSheet", "AXDialog"].contains(role) { throw ControlFailure.blocked("modal_dialog_present") }
    var result = [el]
    if !tables && ["AXTable", "AXRow", "AXCell"].contains(role) { return result }
    if ["AXTextArea", "AXTextField", "AXSearchField"].contains(role) { return result }
    for child in elements(el) { result += try nodes(child, tables: tables, depth: depth + 1) }
    return result
}
func chatControls(_ window: AXUIElement) throws -> [AXUIElement] {
    guard elements(window, "AXSheets").isEmpty else { throw ControlFailure.blocked("modal_dialog_present") }
    let found = try nodes(window)
    guard found.filter({ string($0, "AXRole") == "AXTextArea" && composerLabels.contains(string($0, "AXDescription")) }).count == 1 else {
        throw ControlFailure.blocked("chat_composer_not_unique")
    }
    return found
}
func window(_ application: AXUIElement, _ title: String) throws -> AXUIElement {
    let matches = elements(application, "AXWindows").filter { string($0, "AXTitle") == title }
    guard matches.count == 1 else {
        throw ControlFailure.blocked(matches.isEmpty ? "target_room_window_not_open" : "target_room_window_ambiguous")
    }
    guard string(matches[0], "AXIdentifier") != "Main Window" else { throw ControlFailure.blocked("main_window_is_not_a_chat") }
    _ = try chatControls(matches[0])
    return matches[0]
}
func mainWindow(_ application: AXUIElement) throws -> AXUIElement {
    let found = elements(application, "AXWindows").filter { string($0, "AXIdentifier") == "Main Window" }
    guard found.count == 1 else { throw ControlFailure.blocked("main_window_not_unique") }
    return found[0]
}
func ensureChats(_ application: AXUIElement) throws -> AXUIElement {
    let main = try mainWindow(application)
    // Older builds title the chats pane with a static text. KakaoTalk 26.9 replaced it
    // with a "채팅 | 오픈채팅" toggle, exposed as a top-level button described "채팅".
    func isChats() -> Bool {
        elements(main).contains {
            let role = string($0, "AXRole")
            return (role == "AXStaticText" && ["채팅", "Chats"].contains(string($0, "AXValue")))
                || (role == "AXButton" && ["채팅", "Chats"].contains(string($0, "AXDescription")))
        }
    }
    if isChats() { return main }
    guard let bar = attr(application, "AXMenuBar") else { throw ControlFailure.blocked("chats_menu_unavailable") }
    let top = elements(bar as! AXUIElement).filter { ["창", "Window"].contains(string($0, "AXTitle")) }
    let menus = top.flatMap { elements($0) }
    let items = menus.flatMap { elements($0) }.filter { string($0, "AXRole") == "AXMenuItem" && ["채팅", "Chats"].contains(string($0, "AXTitle")) }
    guard items.count == 1 else { throw ControlFailure.blocked("chats_menu_not_unique") }
    try act(items[0], "AXPress")
    let until = min(deadline, ProcessInfo.processInfo.systemUptime + 1.5)
    while !isChats() && ProcessInfo.processInfo.systemUptime < until { Thread.sleep(forTimeInterval: 0.05) }
    guard isChats() else { throw ControlFailure.blocked("chats_pane_not_observed") }
    return main
}
func roomEntries(_ main: AXUIElement, namesOnly: Bool = false) throws -> (entries: [(cell: AXUIElement, info: [String: Any])], reported: Int, source: String) {
    let tables = try nodes(main).filter { string($0, "AXRole") == "AXTable" }
    guard tables.count == 1 else { throw ControlFailure.blocked("room_list_not_unique") }
    let table = tables[0]
    // Offscreen rows are virtualized. Fetching every reported row can spend the
    // entire control deadline instantiating empty cells in a large account.
    let visible = attr(table, "AXVisibleRows") as? [AXUIElement]
    let rows = visible ?? elements(table).filter { string($0, "AXRole") == "AXRow" }
    var reported: CFIndex = 0
    if AXUIElementGetAttributeValueCount(table, "AXRows" as CFString, &reported) != .success { reported = rows.count }
    guard rows.count <= 1000 else { throw ControlFailure.blocked("room_list_limit") }
    var result: [(AXUIElement, [String: Any])] = []
    for (index, row) in rows.enumerated() {
        try check()
        let cells = elements(row).filter { string($0, "AXRole") == "AXCell" }
        guard cells.count == 1 else { continue }
        let children = elements(cells[0])
        let labelElements = children.filter { string($0, "AXRole") == "AXStaticText" }
        guard let nameElement = labelElements.first else { continue }
        let name = string(nameElement, "AXValue")
        guard !name.isEmpty else { continue }
        // Opening an ordinary room needs its exact name, not its preview or badges.
        if namesOnly {
            result.append((cells[0], ["name": name]))
            continue
        }
        let labels = labelElements.map { string($0, "AXValue") }.filter { !$0.isEmpty }
        let descendants = try nodes(cells[0], tables: true)
        let previews = descendants.filter { string($0, "AXRole") == "AXTextArea" }.map { string($0, "AXValue") }
        let own = descendants.contains { string($0, "AXRole") == "AXImage" && string($0, "AXDescription") == "badge me" }
        result.append((cells[0], ["name": name, "isSelf": own, "rowIndex": (attr(row, "AXIndex") as? NSNumber)?.intValue ?? index,
                                 "labels": labels, "preview": previews.first as Any? ?? NSNull()]))
    }
    return (result, reported, visible == nil ? "AXChildren" : "AXVisibleRows")
}
func searchField(_ container: AXUIElement, open: Bool) throws -> AXUIElement {
    func fields() throws -> [AXUIElement] {
        try nodes(container).filter { ["AXTextField", "AXSearchField"].contains(string($0, "AXRole")) }
    }
    var found = try fields()
    if found.isEmpty && open {
        let buttons = try nodes(container).filter { string($0, "AXRole") == "AXButton" && ["검색", "Search"].contains(string($0, "AXDescription")) }
        guard buttons.count == 1 else { throw ControlFailure.blocked("search_button_not_unique") }
        try act(buttons[0], "AXPress")
        let until = min(deadline, ProcessInfo.processInfo.systemUptime + 1.0)
        while found.isEmpty && ProcessInfo.processInfo.systemUptime < until {
            Thread.sleep(forTimeInterval: 0.05); found = try fields()
        }
    }
    guard found.count == 1 else { throw ControlFailure.blocked("search_field_not_unique") }
    return found[0]
}

// Kakao's search toolbar has no accessible labels on its navigation buttons.
// Resolve the observed sibling layout, fail closed if a future app changes it.
func searchButtons(_ field: AXUIElement) throws -> [AXUIElement] {
    guard let parent = attr(field, "AXParent") else { throw ControlFailure.blocked("search_toolbar_unavailable") }
    let siblings = elements(parent as! AXUIElement)
    guard let index = siblings.firstIndex(where: { CFEqual($0, field) }) else { throw ControlFailure.blocked("search_field_missing") }
    let buttons = Array(siblings.dropFirst(index + 1).prefix(5))
    guard buttons.count == 5, buttons.allSatisfy({ string($0, "AXRole") == "AXButton" }),
          buttons.map({ string($0, "AXIdentifier") }) == ["_NS:10", "_NS:30", "_NS:43", "_NS:56", "_NS:80"] else {
        throw ControlFailure.blocked("search_toolbar_layout_unknown")
    }
    return buttons
}
func searchState(_ target: AXUIElement, _ field: AXUIElement, _ query: String) throws -> [String: Any] {
    let buttons = try searchButtons(field)
    let tables = try nodes(target).filter { string($0, "AXRole") == "AXTable" }
    guard tables.count == 1 else { throw ControlFailure.blocked("chat_transcript_not_unique") }
    let visible = elements(tables[0], "AXVisibleRows")
    var rows: [[String: Any]] = []
    var matches = 0
    for row in visible {
        let parts = try nodes(row, tables: true)
        let bodies = parts.filter { string($0, "AXRole") == "AXTextArea" }.map { string($0, "AXValue") }
        matches += bodies.filter { $0.range(of: query, options: .caseInsensitive) != nil }.count
        rows.append(["index": (attr(row, "AXIndex") as? NSNumber)?.intValue ?? -1,
                     "bodies": bodies,
                     "labels": parts.filter { string($0, "AXRole") == "AXStaticText" }.map { string($0, "AXValue") }])
    }
    guard let previous = attr(buttons[0], "AXEnabled") as? NSNumber,
          let next = attr(buttons[1], "AXEnabled") as? NSNumber else {
        throw ControlFailure.blocked("search_navigation_state_unavailable")
    }
    return ["query": string(field, "AXValue"), "visibleRows": rows, "visibleMatchCount": matches,
            "previousEnabled": previous.boolValue, "nextEnabled": next.boolValue]
}
func stateKey(_ state: [String: Any]) -> Data {
    return (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])) ?? Data()
}

func run() throws -> [String: Any] {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 16_384, let request = try JSONSerialization.jsonObject(with: input) as? [String: Any],
          let command = request["action"] as? String,
          ["rooms", "open", "close", "load_older", "search_open", "search_query", "search_previous", "search_close", "search_rooms"].contains(command) else {
        throw ControlFailure.blocked("invalid_control_request")
    }
    guard AXIsProcessTrusted() else { throw ControlFailure.blocked("accessibility_permission_required") }
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.kakao.KakaoTalkMac" }) else {
        throw ControlFailure.blocked("app_not_running")
    }
    let application = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.2)
    let title = request["windowTitle"] as? String ?? ""
    if ["rooms", "open", "search_rooms"].contains(command) {
        let main = try ensureChats(application)
        if command == "search_rooms" {
            guard let query = request["query"] as? String, query.utf8.count <= 4096 else { throw ControlFailure.blocked("invalid_query") }
            let field = try searchField(main, open: true)
            try setValue(field, query)
            if names(field).contains("AXConfirm") { try act(field, "AXConfirm") }
            // Kakao debounces search edits; returning immediately would expose the previous query's rows.
            Thread.sleep(forTimeInterval: 0.65)
        }
        let listing = try roomEntries(main, namesOnly: command == "open" && (request["requireSelf"] as? Bool != true))
        let entries = listing.entries
        if command != "open" {
            let fields = try nodes(main).filter { ["AXTextField", "AXSearchField"].contains(string($0, "AXRole")) }
            return ["status": "ok", "items": entries.map { $0.info }, "scope": "currently_visible_room_list",
                    "reportedRowCount": listing.reported, "rowsSource": listing.source,
                    "visibleItemsReturned": entries.count, "historyComplete": false,
                    "searchQuery": fields.count == 1 ? string(fields[0], "AXValue") : ""]
        }
        guard !title.isEmpty else { throw ControlFailure.blocked("exact_window_title_required") }
        let matching = entries.filter { $0.info["name"] as? String == title }
        guard matching.count <= 1 else { throw ControlFailure.blocked("target_room_name_ambiguous") }
        if request["requireSelf"] as? Bool == true {
            guard matching.count == 1 else { throw ControlFailure.blocked("room_not_in_exposed_list") }
            guard matching[0].info["isSelf"] as? Bool == true else { throw ControlFailure.blocked("self_room_not_verified") }
        }
        let opened = elements(application, "AXWindows").filter { string($0, "AXTitle") == title }
        if !opened.isEmpty {
            _ = try window(application, title)
            return ["status": "ok", "windowTitle": title, "alreadyOpen": true]
        }
        guard matching.count == 1 else { throw ControlFailure.blocked("room_not_in_exposed_list") }
        let cell = matching[0].cell
        guard !elements(cell).contains(where: { string($0, "AXRole") == "AXMenu" }) else { throw ControlFailure.blocked("existing_menu_preserved") }
        try act(cell, "AXShowMenu")
        var openItems: [AXUIElement] = []
        let menuDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 1.0)
        repeat {
            let menus = elements(cell).filter { string($0, "AXRole") == "AXMenu" }
            // The command identifier is stable across localized menu titles.
            openItems = menus.flatMap { elements($0) }.filter {
                string($0, "AXRole") == "AXMenuItem" && string($0, "AXIdentifier") == "openChatRoom:" &&
                attr($0, "AXEnabled") as? Bool == true
            }
            if openItems.count == 1 { break }
            Thread.sleep(forTimeInterval: 0.03)
        } while ProcessInfo.processInfo.systemUptime < menuDeadline
        guard openItems.count == 1 else { throw ControlFailure.blocked("open_menu_item_not_unique") }
        try act(openItems[0], "AXPress")
        let until = min(deadline, ProcessInfo.processInfo.systemUptime + 2.0)
        while ProcessInfo.processInfo.systemUptime < until {
            if let _ = try? window(application, title) { return ["status": "ok", "windowTitle": title, "alreadyOpen": false] }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw ControlFailure.blocked("opened_window_not_observed")
    }
    guard !title.isEmpty else { throw ControlFailure.blocked("exact_window_title_required") }
    if command == "close", !elements(application, "AXWindows").contains(where: { string($0, "AXTitle") == title }) {
        return ["status": "ok", "windowTitle": title, "alreadyClosed": true]
    }
    let target = try window(application, title)
    let controls = try chatControls(target)
    if command == "search_close" {
        let fields = controls.filter { ["AXTextField", "AXSearchField"].contains(string($0, "AXRole")) }
        if fields.isEmpty { return ["status": "ok", "alreadyClosed": true, "windowTitle": title] }
        let buttons = controls.filter { string($0, "AXRole") == "AXButton" && ["검색", "Search"].contains(string($0, "AXDescription")) }
        guard buttons.count == 1 else { throw ControlFailure.blocked("search_button_not_unique") }
        try act(buttons[0], "AXPress")
        let until = min(deadline, ProcessInfo.processInfo.systemUptime + 1.0)
        while ProcessInfo.processInfo.systemUptime < until {
            let current = try nodes(target).filter { ["AXTextField", "AXSearchField"].contains(string($0, "AXRole")) }
            if current.isEmpty { return ["status": "ok", "alreadyClosed": false, "windowTitle": title] }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw ControlFailure.blocked("search_close_not_observed")
    }
    if command == "close" {
        let composers = controls.filter { string($0, "AXRole") == "AXTextArea" && composerLabels.contains(string($0, "AXDescription")) }
        guard composers.count == 1 else { throw ControlFailure.blocked("chat_composer_not_unique") }
        guard try composerText(composers[0]).isEmpty else { throw ControlFailure.blocked("existing_draft_preserved") }
        guard let close = attr(target, "AXCloseButton") else { throw ControlFailure.blocked("close_button_unavailable") }
        try act(close as! AXUIElement, "AXPress")
        let until = min(deadline, ProcessInfo.processInfo.systemUptime + 1.5)
        while ProcessInfo.processInfo.systemUptime < until {
            if !elements(application, "AXWindows").contains(where: { string($0, "AXTitle") == title }) {
                return ["status": "ok", "windowTitle": title, "alreadyClosed": false]
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw ControlFailure.blocked("closed_window_not_observed")
    }
    if ["search_open", "search_query", "search_previous"].contains(command) {
        let field = try searchField(target, open: command != "search_previous")
        if command == "search_open" { return ["status": "ok", "windowTitle": title] }
        guard let query = request["query"] as? String, !query.isEmpty, query.utf8.count <= 4096 else { throw ControlFailure.blocked("invalid_query") }
        let before = try searchState(target, field, query)
        if command == "search_previous" {
            guard string(field, "AXValue") == query else { throw ControlFailure.blocked("search_query_changed") }
            if before["previousEnabled"] as? Bool == false {
                return ["status": "ok", "searchVerified": true, "searchOutcome": "navigation_exhausted", "searchState": before]
            }
            try act(try searchButtons(field)[0], "AXPress")
        } else {
            try setValue(field, query)
            guard names(field).contains("AXConfirm") else { throw ControlFailure.blocked("search_confirm_unavailable") }
            try act(field, "AXConfirm")
        }
        let verificationStarted = ProcessInfo.processInfo.systemUptime
        let until = min(deadline - 0.2, verificationStarted + 3.0)
        var last = Data(), stableSamples = 0
        var observed = before
        while ProcessInfo.processInfo.systemUptime < until {
            Thread.sleep(forTimeInterval: 0.15)
            observed = try searchState(target, field, query)
            let key = stateKey(observed)
            stableSamples = key == last ? stableSamples + 1 : 0
            last = key
            let moved = command != "search_previous" || key != stateKey(before)
            if ProcessInfo.processInfo.systemUptime - verificationStarted >= 0.65,
               stableSamples >= 1, moved, observed["query"] as? String == query,
               (observed["visibleMatchCount"] as? Int ?? 0) > 0 {
                return ["status": "ok", "windowTitle": title, "query": query,
                        "searchVerified": true, "searchOutcome": "visible_match_observed", "searchState": observed]
            }
        }
        return ["status": "partial", "reason": "search_result_not_observed", "windowTitle": title,
                "query": query, "searchVerified": false, "searchOutcome": "unverified", "searchState": observed]
    }
    let tables = controls.filter { string($0, "AXRole") == "AXTable" }
    guard tables.count == 1 else { throw ControlFailure.blocked("chat_transcript_not_unique") }
    let scrolls = controls.filter { element in
        string(element, "AXRole") == "AXScrollArea" && elements(element).contains(where: { CFEqual($0, tables[0]) })
    }
    guard scrolls.count == 1, names(scrolls[0]).contains("AXScrollUpByPage") else { throw ControlFailure.blocked("history_scroll_not_supported") }
    let before = elements(tables[0], "AXRows").count
    var bar = attr(scrolls[0], "AXVerticalScrollBar")
    if bar == nil { bar = elements(scrolls[0]).first(where: { string($0, "AXRole") == "AXScrollBar" }) }
    var method = "AXScrollUpByPage"
    if let value = bar {
        let scrollbar = value as! AXUIElement
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(scrollbar, "AXValue" as CFString, &settable) == .success && settable.boolValue {
            let minimum = attr(scrollbar, "AXMinValue") as? NSNumber ?? NSNumber(value: 0)
            let result = AXUIElementSetAttributeValue(scrollbar, "AXValue" as CFString, minimum)
            actions.append(["action": "AXValue(scrollbar_minimum)", "result": Int(result.rawValue)])
            guard result == .success else { throw ControlFailure.blocked("history_scrollbar_set_failed") }
            method = "AXValue(scrollbar_minimum)"
        } else {
            let previous = elements(scrollbar).filter { ["AXDecrementPage", "AXDecrementArrow"].contains(string($0, "AXSubrole")) }
            if previous.count == 1 { try act(previous[0], "AXPress"); method = "AXPress(scrollbar_previous)" }
            else { try act(scrolls[0], "AXScrollUpByPage") }
        }
    } else { try act(scrolls[0], "AXScrollUpByPage") }
    Thread.sleep(forTimeInterval: 0.25)
    let after = elements(tables[0], "AXRows").count
    let actionSucceeded = actions.last?["result"] as? Int == 0
    return ["status": "ok", "windowTitle": title, "exposedRowsBefore": before, "exposedRowsAfter": after,
            "method": method, "scrollActionSucceeded": actionSucceeded,
            "loadStatus": actionSucceeded ? "history_requested" : "no_scroll_effect_observed",
            "historyComplete": false, "endOfHistory": NSNull()]
}
var result: [String: Any]
do { result = try run() }
catch ControlFailure.blocked(let reason) { result = ["status": "blocked", "reason": reason] }
catch { result = ["status": "bridge_error"] }
result["source"] = "macos_accessibility"
result["databaseCalls"] = 0
result["dispatchAttempted"] = false
result["uiActions"] = actions.count
result["actions"] = actions
result["elapsedMs"] = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
