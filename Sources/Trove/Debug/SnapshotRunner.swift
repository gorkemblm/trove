#if SNAPSHOTS
import AppKit
import SwiftUI

/// Renders the panel offscreen with sample data, writes PNG files and runs layout stability checks.
/// A stability check renders two states that differ only in numbers or labels and asserts that
/// the changed pixels stay inside the area that is allowed to change.
@MainActor
enum SnapshotRunner {
    private static let size = PanelController.size

    static func run(outputDirectory: URL) -> Int32 {
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            var failures = 0

            // MARK: Scenes for visual review
            let (app, model, clips) = try makeScene(manyItems: false)
            _ = app
            for (name, clip) in clips where clip.kind != .secret {
                model.selectedID = clip.id
                try write(render(model), to: outputDirectory.appendingPathComponent("panel-\(name).png"))
            }
            model.selectedID = clips["text"]?.id
            model.focusSidebar()
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-sidebar-focus.png"))
            model.category = .ips
            model.selectedID = clips["ip"]?.id
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-ips-group.png"))
            model.category = .all
            model.focusList()
            model.category = .files
            model.query = "nothing-matches-this"
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-no-results.png"))
            model.query = ""
            model.category = .all

            model.category = .hidden
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-hidden-locked.png"))
            model.unlockForSnapshots()
            model.selectedID = clips["secret"]?.id
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-hidden-unlocked.png"))
            model.lockHidden()
            model.category = .all
            model.focusList() // The empty Hidden group moved the arrows to the sidebar.

            model.selectedID = clips["text"]?.id
            model.requestHideToggle()
            model.naming?.name = "Meeting note"
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-naming.png"))
            model.cancelNaming()

            model.selectedID = clips["text"]?.id
            model.requestDelete()
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-delete-confirmation.png"))
            model.cancelDelete()

            // Lock screen and paused recording, for visual review.
            model.setPanelLocked(true)
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-locked.png"))
            model.setPanelLocked(false)
            app.pauseRecording(minutes: 10)
            model.selectedID = clips["text"]?.id
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-paused.png"))
            app.resumeRecording()

            // Light appearance, for visual review.
            for name in ["text", "image", "color"] {
                model.selectedID = clips[name]?.id
                try write(render(model, dark: false), to: outputDirectory.appendingPathComponent("panel-\(name)-light.png"))
            }
            model.selectedID = clips["text"]?.id
            model.requestDelete()
            try write(render(model, dark: false), to: outputDirectory.appendingPathComponent("panel-delete-confirmation-light.png"))
            model.cancelDelete()

            // Select mode: several items picked, then the group delete confirmation.
            model.selectedID = clips["image"]?.id
            for name in ["screenshot", "json", "link"] {
                if let clip = clips[name] { model.togglePick(clip) }
            }
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-group.png"))
            model.requestDelete()
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-group-delete.png"))
            model.cancelDelete()
            model.endSelecting()

            // "/" group suggestions, and the chip after a group is chosen.
            model.query = "/"
            model.moveGroupPick(8)
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-groups-slash.png"))
            model.query = "/co"
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-groups-typed.png"))
            model.query = "/images "
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-group-chip.png"))
            model.category = .all

            // "@" app suggestions, and the app chip next to a group chip.
            model.query = "@"
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-apps-at.png"))
            model.query = "/text "
            model.query = "@tel "
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-app-chip.png"))
            model.clearAppFilter()
            model.category = .all

            // Text in images: a search that matches the text in the screenshot, the boxes on it,
            // the list line, and the large preview with the text next to the image.
            model.query = "invoice"
            model.selectedID = clips["screenshot"]?.id
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-image-text-search.png"))
            model.query = ""
            model.selectedID = clips["screenshot"]?.id
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-image-text.png"))
            if let shot = clips["screenshot"], let image = model.image(for: shot) {
                try write(renderView(LargePreviewView(clip: shot, image: image, terms: ["paid"], copy: {}), size: NSSize(width: 900, height: 640)),
                          to: outputDirectory.appendingPathComponent("large-preview-image-text.png"))
            }

            // Snippets: the naming card, then the group with one snippet.
            model.selectedID = clips["email"]?.id
            model.requestSaveSnippet()
            model.naming?.name = "Work email"
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-snippet-naming.png"))
            model.confirmNaming()
            model.category = .snippets
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-snippets.png"))
            if let id = clips["email"]?.id { try? app.store?.removeSnippet(id: id) }
            model.category = .all

            // The editor (⌘E) on a JSON item, after "Format JSON".
            model.selectedID = clips["json"]?.id
            model.requestEdit()
            model.apply(.jsonPretty)
            let editorImage = render(model)
            try write(editorImage, to: outputDirectory.appendingPathComponent("panel-editor.png"))
            // The sidebar must stay where it is: a wider editor would push the whole panel.
            model.cancelEdit()
            let sidebarArea = CGRect(x: 0, y: 56, width: 196, height: 400)
            let withoutEditor = render(model)
            failures += check("Editor: the panel keeps its layout", diff(withoutEditor, editorImage, in: sidebarArea), maxWidth: 0.5)
            model.requestEdit()
            model.apply(.jsonPretty)
            model.toggleActions()
            model.actionFilter = "case"
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-editor-actions.png"))
            model.closeActions()
            model.cancelEdit()

            // The actions menu (⌘K) for a screenshot, and filtered.
            model.selectedID = clips["screenshot"]?.id
            model.toggleActions()
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-actions.png"))
            model.actionFilter = "pin"
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-actions-filtered.png"))
            model.closeActions()

            // Copy confirmation pill, light and dark.
            for dark in [true, false] {
                try write(renderView(CopyToastView(message: "Copied to Clipboard").background(.regularMaterial, in: Capsule()),
                                     size: NSSize(width: 240, height: 60), dark: dark),
                          to: outputDirectory.appendingPathComponent("toast\(dark ? "-dark" : "").png"))
            }

            // Settings pages, light and dark.
            for tab in SettingsTab.allCases {
                for dark in [false, true] {
                    let view = SettingsView(app: app, settings: app.settings, tab: tab)
                    try write(renderView(view, size: SettingsView.size, dark: dark),
                              to: outputDirectory.appendingPathComponent("settings-\(tab.rawValue)\(dark ? "-dark" : "").png"))
                }
            }
            // General, whole page without scrolling: the lower sections are not in the window snapshot.
            let general = GeneralSettings(app: app, settings: app.settings).padding(.bottom, 12)
            let fullHeight = NSHostingView(rootView: general.frame(width: SettingsView.size.width)).fittingSize.height
            try write(renderView(general, size: NSSize(width: SettingsView.size.width, height: fullHeight), dark: false),
                      to: outputDirectory.appendingPathComponent("settings-general-full.png"))

            // The import window, step by step (a sample plan like a Raycast export).
            let flow = ImportFlow(app: app)
            let record = Store.ImportRecord(content: ClipClassifier.textContent("sample", rtf: nil), source: ClipSource(),
                                            firstCopiedAt: Date(), lastCopiedAt: Date(), timesCopied: 1, pinned: false)
            let plan = ImportPlan(source: .raycast, records: Array(repeating: record, count: 3799), secrets: [],
                                  kinds: [.text: 3351, .link: 418, .file: 30], earliest: Date(timeIntervalSinceNow: -720 * 86_400),
                                  latest: Date(), alreadyHave: 120, skippedImages: 13, secretsToHidden: true,
                                  removedByRetention: 2410, removedByItemLimit: 0)
            let steps: [(String, ImportFlow.Step, String?)] = [
                ("choose", .choose, nil),
                ("password", .password(.raycast, URL(fileURLWithPath: "/Users/me/Downloads/Raycast 2026-11-26 6.13.44 pm.rayconfig")),
                 L("The password is not correct.")),
                ("reading", .reading(.raycast, String(localized: "Checking \(3812.formatted()) items…")), nil),
                ("summary", .summary(plan), nil),
                ("importing", .importing(plan, 0.64), nil),
                ("done", .done(.raycast, ImportResult(added: 3679, merged: 120, hidden: 0)), nil),
            ]
            for (name, step, problem) in steps {
                flow.preview(step, problem: problem)
                try write(renderView(ImportView(flow: flow, close: {}), size: ImportView.size),
                          to: outputDirectory.appendingPathComponent("import-\(name).png"))
            }

            // Onboarding steps, for visual review of the fixed-size window.
            for step in 0..<5 {
                let view = OnboardingView(app: app, settings: app.settings, step: step)
                try write(renderView(view, size: OnboardingView.size),
                          to: outputDirectory.appendingPathComponent("onboarding-\(step).png"))
            }

            // MARK: Check 1: information values change, labels and rows stay
            let infoRegion = CGRect(x: 527, y: 240, width: size.width - 527, height: 275) // Below the preview, which ends at y 238.
            model.selectedID = clips["text"]?.id
            let infoA = render(model)
            model.selectedID = clips["textOther"]?.id
            let infoB = render(model)
            failures += check(
                "Information: only values change between two text items",
                diff(infoA, infoB, in: infoRegion),
                allowedMinX: 527 + 18 + 120
            )

            // MARK: Check 2: footer, Pin and Unpin keep the other buttons in place
            let footerRegion = CGRect(x: 0, y: size.height - 44, width: size.width, height: 44)
            model.selectedID = clips["text"]?.id
            let footerA = render(model)
            model.selectedID = clips["pinned"]?.id
            let footerB = render(model)
            failures += check(
                "Footer: pinning changes nothing",
                diff(footerA, footerB, in: footerRegion),
                // The longest pair is Turkish (Sabitle / Sabitlemeyi Kaldır). If Delete moved too,
                // the changed area would be over 200 pt wide.
                maxWidth: 130
            )

            // MARK: Check 2b: Show in Finder takes the Plain Text slot; Pin and Delete stay put
            model.selectedID = clips["text"]?.id
            let slotA = render(model)
            model.selectedID = clips["screenshot"]?.id
            failures += check(
                "Footer: Show in Finder replaces Plain Text; the right side stays",
                diff(slotA, render(model), in: footerRegion),
                allowedMaxX: 560 // The item's own action is on the left; Paste and Actions on the right never move.
            )

            model.selectedID = clips["link"]?.id
            failures += check(
                "Footer: Open in Browser replaces Plain Text; the right side stays",
                diff(slotA, render(model), in: footerRegion),
                allowedMaxX: 560
            )
            model.selectedID = clips["json"]?.id
            failures += check(
                "Footer: Copy Formatted replaces Plain Text; the right side stays",
                diff(slotA, render(model), in: footerRegion),
                allowedMaxX: 560
            )
            model.selectedID = clips["email"]?.id
            failures += check(
                "Footer: Compose Email replaces Plain Text; the right side stays",
                diff(slotA, render(model), in: footerRegion),
                allowedMaxX: 560
            )

            // MARK: Check 2c: every sidebar group fits, so the panel never grows
            let sidebarHeight = NSHostingView(rootView: SidebarView(model: model).frame(width: 196)).fittingSize.height
            let available = size.height - 54 - 44 - 2
            if sidebarHeight <= available {
                print("PASS  Sidebar fits the panel — \(Int(sidebarHeight)) of \(Int(available)) pt")
            } else {
                print("FAIL  Sidebar fits the panel — needs \(Int(sidebarHeight)) pt, has \(Int(available)) pt")
                failures += 1
            }

            // MARK: Check 3: sidebar counts change, titles stay
            let sidebarRegion = CGRect(x: 0, y: 56, width: 196, height: 280)
            let (_, manyModel, manyClips) = try makeScene(manyItems: true)
            manyModel.selectedID = manyClips["text"]?.id
            model.selectedID = clips["text"]?.id
            failures += check(
                "Sidebar: counts change, category names stay",
                diff(render(model), render(manyModel), in: sidebarRegion),
                allowedMinX: 120
            )

            // MARK: Check 4: the Information header and the first two labels stay put for every kind
            let headerRegion = CGRect(x: 540, y: 240, width: 130, height: 78) // Below the preview, which ends at y 238.
            model.selectedID = clips["text"]?.id
            let reference = render(model)
            for name in ["textOther", "link", "linkOther", "image", "file", "color", "email", "phone", "ip", "code", "screenshot", "json", "yaml", "csv"] {
                model.selectedID = clips[name]?.id
                failures += check(
                    "Detail: Information header and labels stay put (text → \(name))",
                    diff(reference, render(model), in: headerRegion),
                    allowedMinX: .infinity
                )
            }

            // MARK: Check 4b: nothing moves sideways, whatever is selected. A view that wants more
            // width than it has (a long name, a wide image bar) pushes the whole panel; then the
            // sidebar and the search bar move too.
            let steadyRegion = CGRect(x: 0, y: 0, width: 196, height: size.height - 44)
            model.selectedID = clips["text"]?.id
            let steady = render(model)
            for name in clips.keys.sorted() where name != "secret" {
                model.selectedID = clips[name]?.id
                failures += check("Panel: nothing moves sideways (\(name))", diff(steady, render(model), in: steadyRegion), maxWidth: 0.5)
            }
            for (name, query) in [("screenshot", "invoice"), ("photoFile", "holiday")] {
                model.query = query
                model.selectedID = clips[name]?.id
                failures += check("Panel: nothing moves sideways (\(name), search “\(query)”)",
                                  diff(steady, render(model), in: CGRect(x: 0, y: 56, width: 196, height: 400)), maxWidth: 0.5)
            }
            model.query = ""
            model.selectedID = clips["photoFile"]?.id
            try write(render(model), to: outputDirectory.appendingPathComponent("panel-photo-file.png"))

            // MARK: Check 5: list rows keep their height and title position when times change
            let rowRegion = CGRect(x: 197, y: 56, width: 330, height: 459)
            model.selectedID = clips["text"]?.id
            let listA = render(model)
            model.selectedID = clips["textOther"]?.id
            failures += check(
                "List: only the selection highlight moves",
                diff(listA, render(model), in: rowRegion),
                maxWidth: 320
            )

            // MARK: Check 7: the large preview takes the keyboard while Clipboard is not the active
            // app. An ordinary window could not, and stayed behind the panel (25 Nov 2026 bug).
            // (Whether the app becomes active here says nothing: with no other active app, macOS
            // activates whichever app shows a key window. In real use another app is active.)
            //
            // This check shows a real window, so it runs only with `--window-checks` (make
            // window-check), never in `make layout`: a window appearing on screen while the user
            // works is a bug of its own. The window opens off screen, and the app is not deactivated.
            let preview = PreviewWindowController()
            if CommandLine.arguments.contains("--window-checks"), let clip = clips["json"] {
                preview.show(clip: clip, image: nil, appearance: .dark, near: NSRect(x: -20_000, y: -20_000, width: 1, height: 1),
                             actionTitle: "Copy") {}
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                if preview.isOpen && preview.isKey {
                    print("PASS  Large preview opens in front with the keyboard")
                } else {
                    print("FAIL  Large preview opens in front with the keyboard — open: \(preview.isOpen), key: \(preview.isKey)")
                    failures += 1
                }
                preview.close()
            }

            print(failures == 0 ? "All layout checks passed." : "\(failures) layout check(s) failed.")
            print("Snapshots: \(outputDirectory.path)")
            return failures == 0 ? 0 : 1
        } catch {
            print("Snapshot failed: \(error)")
            return 2
        }
    }

    // MARK: - Sample data

    static func makeScene(manyItems: Bool) throws -> (AppModel, PanelModel, [String: Clip]) {
        let app = AppModel()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-snapshot-\(UUID().uuidString)")
        let store = try Store.inMemory(imagesDirectory: dir.appendingPathComponent("Images"))
        let hiddenKey = SoftwareHiddenKey()
        app.installStoreForSnapshots(store, hiddenKey: hiddenKey)
        var clips: [String: Clip] = [:]
        let now = Date()

        func clip(_ kind: ClipKind, _ text: String?, app name: String, bundle: String, minutesAgo: Double,
                  times: Int = 1, url: String? = nil, pinned: Bool = false, firstDaysAgo: Double = 0) -> Clip {
            let last = now.addingTimeInterval(-minutesAgo * 60)
            return Clip(
                id: nil, kind: kind, text: text, rtf: nil, imageFile: nil, imageWidth: nil, imageHeight: nil,
                fileSize: nil, byteSize: text?.utf8.count ?? 0, contentHash: UUID().uuidString,
                sourceBundleID: bundle, sourceAppName: name, sourceURL: url, pinned: pinned, timesCopied: times,
                firstCopiedAt: last.addingTimeInterval(-firstDaysAgo * 86_400), lastCopiedAt: last
            )
        }

        let telegram = String(repeating: "The meeting starts Thursday at 2 pm, the agenda is attached. ", count: 5)
        clips["text"] = try store.insert(clip(.text, telegram, app: "Telegram", bundle: "ru.keepcoder.Telegram", minutesAgo: 2))
        clips["textOther"] = try store.insert(clip(.text, String(repeating: "deploy notes 8 ", count: 82) + "\nline two\nline three",
                                                   app: "Telegram", bundle: "ru.keepcoder.Telegram", minutesAgo: 600, times: 128, firstDaysAgo: 9))
        clips["link"] = try store.insert(clip(.link, "https://github.com/groue/GRDB.swift", app: "Arc", bundle: "company.thebrowser.Browser",
                                              minutesAgo: 14, url: "https://github.com/groue/GRDB.swift"))
        clips["linkOther"] = try store.insert(clip(.link, "https://developer.apple.com/documentation/appkit/nspanel", app: "Safari",
                                                   bundle: "com.apple.Safari", minutesAgo: 1440 * 3, times: 7))
        clips["color"] = try store.insert(clip(.color, "#D97757", app: "Figma", bundle: "com.figma.Desktop", minutesAgo: 90))
        clips["pinned"] = try store.insert(clip(.text, telegram, app: "Telegram", bundle: "ru.keepcoder.Telegram",
                                                minutesAgo: 2, pinned: true).withHash("pinned"))
        var file = clip(.file, "/Users/me/Documents/PLAN.md\n/Users/me/Documents/architecture.png", app: "Finder",
                        bundle: "com.apple.finder", minutesAgo: 1500)
        file.fileSize = 412_000
        clips["file"] = try store.insert(file)

        let image = NSImage(size: NSSize(width: 640, height: 360), flipped: false) { rect in
            NSColor(calibratedRed: 0.2, green: 0.3, blue: 0.5, alpha: 1).setFill()
            rect.fill()
            NSColor.white.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 120, dy: 90), xRadius: 16, yRadius: 16).fill()
            return true
        }
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let content = CapturedContent(kind: .image, imageData: png, imageWidth: 640, imageHeight: 360,
                                          byteSize: png.count, hash: ClipClassifier.hash("image", png))
            clips["image"] = try store.ingest(content, source: ClipSource(bundleID: "com.apple.Preview", appName: "Preview", url: nil),
                                              at: now.addingTimeInterval(-3600))
            // The screenshot is of a document with text, so Vision has something to read.
            let page = NSImage(size: NSSize(width: 960, height: 540), flipped: true) { rect in
                NSColor.white.setFill(); rect.fill()
                let lines = [("Invoice 2026-114", 46.0, NSFont.Weight.bold), ("Customer: Jane Miller", 30, .regular),
                             ("Amount due: $1,250.00", 30, .regular), ("Due date: 30 November 2026", 30, .regular),
                             ("Status: paid", 30, .medium)]
                var y = 60.0
                for (text, size, weight) in lines {
                    (text as NSString).draw(at: NSPoint(x: 70, y: y), withAttributes: [
                        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor.black])
                    y += size + 36
                }
                return true
            }
            var shot = page.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
                .flatMap { ClipClassifier.imageContent(data: $0, maxBytes: 10_000_000) } ?? content
            shot.hash = "screenshot"
            shot.text = "/Users/me/Desktop/Screenshots/Screenshot 2026-11-25 at 22.15.45.png"
            clips["screenshot"] = try store.ingest(shot, source: ClipSource(bundleID: "com.apple.screenshot.launcher", appName: "Screenshot", url: nil),
                                                   at: now.addingTimeInterval(-3700))
            // A photo copied in Finder: a file item with a preview, in Images and Files.
            var photo = CapturedContent(kind: .file, text: "/Users/me/Pictures/Holiday photo with a rather long file name.jpg",
                                        byteSize: 60, hash: "photo-file")
            photo.format = Clip.imageFilesFormat
            photo.imageData = shot.imageData
            photo.imageWidth = shot.imageWidth
            photo.imageHeight = shot.imageHeight
            photo.fileSize = 2_400_000
            clips["photoFile"] = try store.ingest(photo, source: ClipSource(bundleID: "com.apple.finder", appName: "Finder", url: nil),
                                                  at: now.addingTimeInterval(-3800))
        }

        for (name, text, app, bundle, minutes) in [
            ("email", "jane.miller@example.com", "Mail", "com.apple.mail", 30.0),
            ("phone", "+1 415 555 0132", "Messages", "com.apple.MobileSMS", 40.0),
            ("ip", "192.168.1.24/24", "Terminal", "com.apple.Terminal", 45.0),
            ("code", "func greet(name: String) -> String {\n    return \"Hello, \\(name)\"\n}", "Code", "com.microsoft.VSCode", 50.0),
            ("json", #"{"name":"Clipboard","version":"0.1.0","features":["search","hidden","screenshots"],"limits":{"items":5000,"days":30},"encrypted":true}"#,
             "Terminal", "com.apple.Terminal", 55.0),
            ("yaml", "apiVersion: v1\nkind: Pod\nmetadata:\n  name: web # front end\n  labels:\n    app: web\nspec:\n  replicas: 3", "Code", "com.microsoft.VSCode", 56.0),
            ("csv", "Item\tQty\tPrice\tTotal\nPen\t3\t2.50\t7.50\nNotebook\t1\t8.00\t8.00\nEraser\t2\t1.00\t2.00", "Numbers", "com.apple.iWork.Numbers", 57.0),
        ] {
            clips[name] = try store.ingest(ClipClassifier.textContent(text, rtf: nil),
                                           source: ClipSource(bundleID: bundle, appName: app, url: nil),
                                           at: now.addingTimeInterval(-minutes * 60))
        }

        let secret = "ghp_" + String(repeating: "x7Kq", count: 9)
        if let finding = SensitiveDetector.detect(secret) {
            clips["secret"] = try store.ingestSecret(
                sealed: try SealedSecret.seal(Data(secret.utf8), to: hiddenKey.publicKey), finding: finding,
                characters: secret.count, source: ClipSource(bundleID: "com.microsoft.VSCode", appName: "Code", url: nil),
                at: now.addingTimeInterval(-300), expiresAt: nil)
            if let id = clips["secret"]?.id { try store.renameSecret(id: id, name: "Work GitHub token") }
        }
        // The screenshot has text in it (the "Text" badge in the detail).
        if let id = clips["screenshot"]?.id {
            let full = try store.clip(id: id)
            try store.setRecognizedText(id: id, full.flatMap(store.imageData(for:)).flatMap(TextRecognizer.recognize))
            clips["screenshot"] = try store.clip(id: id)
        }

        if manyItems {
            for i in 0..<1234 {
                try store.insert(clip(.text, "filler \(i)", app: "Notes", bundle: "com.apple.Notes", minutesAgo: Double(5000 + i)))
            }
        }

        let model = app.panelModel
        model.willShow()
        return (app, model, clips)
    }

    // MARK: - Rendering

    static func render(_ model: PanelModel, dark: Bool = true, overlay: AnyView? = nil) -> NSBitmapImageRep {
        let root = ZStack {
            Color(white: dark ? 0.11 : 0.90)
            PanelView(model: model)
            if let overlay { overlay }
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, dark ? .dark : .light)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private static func renderView(_ view: some View, size: NSSize, dark: Bool = true) -> NSBitmapImageRep {
        let root = view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) throws {
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: - Pixel diff

    /// Bounding box, in points with a top-left origin, of pixels that differ inside `region`.
    private static func diff(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in region: CGRect) -> CGRect? {
        let scale = CGFloat(a.pixelsWide) / size.width
        let x0 = Int(region.minX * scale), x1 = min(Int(region.maxX * scale), a.pixelsWide)
        let y0 = Int(region.minY * scale), y1 = min(Int(region.maxY * scale), a.pixelsHigh)
        var box: CGRect?
        for y in y0..<y1 {
            for x in x0..<x1 {
                guard let ca = a.colorAt(x: x, y: y), let cb = b.colorAt(x: x, y: y) else { continue }
                let delta = abs(ca.redComponent - cb.redComponent) + abs(ca.greenComponent - cb.greenComponent)
                    + abs(ca.blueComponent - cb.blueComponent)
                if delta > 0.06 {
                    let point = CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: 1 / scale, height: 1 / scale)
                    box = box?.union(point) ?? point
                }
            }
        }
        return box
    }

    private static func check(_ name: String, _ box: CGRect?, allowedMinX: CGFloat? = nil, allowedMaxX: CGFloat? = nil,
                              maxWidth: CGFloat? = nil) -> Int {
        guard let box else {
            print("PASS  \(name) (no change)")
            return 0
        }
        var ok = true
        if let allowedMinX, box.minX < allowedMinX { ok = false }
        if let allowedMaxX, box.maxX > allowedMaxX { ok = false }
        if let maxWidth, box.width > maxWidth { ok = false }
        let detail = String(format: "changed x %.0f–%.0f, y %.0f–%.0f", box.minX, box.maxX, box.minY, box.maxY)
        print("\(ok ? "PASS" : "FAIL")  \(name) — \(detail)")
        return ok ? 0 : 1
    }
}

private extension Clip {
    func withHash(_ hash: String) -> Clip {
        var copy = self
        copy.contentHash = hash
        return copy
    }
}
#endif
