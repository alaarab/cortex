import PhrenKit
import SwiftUI
import WebKit

/// The 3D memory graph, rendered by the same `browser/graph` bundle the web
/// memory UI and the VS Code webview use.
///
/// The app is serverless, so unlike those two hosts there is no `/api/graph`
/// to fetch: `GraphBuilder` builds the payload on-device from synced markdown
/// and it is injected into the page. Edits travel the other way over
/// `WKScriptMessageHandler` and become ordinary `PendingOp`s, so a graph edit
/// syncs and conflicts exactly like one made in the findings list.
struct GraphView: View {
    @Environment(AppModel.self) private var model
    /// nil renders every project; a value focuses one (and lifts the CLI's
    /// per-project node caps, matching `?project=` on the web).
    var focusProject: String?

    @State private var payloadJSON: String?
    @State private var buildError: String?
    @State private var selection: GraphNodeRef?
    @State private var actionError: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            if let payloadJSON {
                GraphWebView(
                    payloadJSON: payloadJSON,
                    onSelect: { selection = $0 },
                    onAction: handle(action:items:),
                    onError: { buildError = $0 }
                )
                .ignoresSafeArea()
            } else if buildError == nil {
                ProgressView("Building graph…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let buildError {
                PhrenEmptyState(title: "Graph unavailable", message: buildError)
            }

            if let selection {
                GraphSelectionBar(node: selection) {
                    self.selection = nil
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selection)
        .navigationTitle(focusProject ?? "Graph")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.indexGeneration) { await rebuild() }
        .alert("Could not apply that edit", isPresented: .constant(actionError != nil)) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private func rebuild() async {
        do {
            payloadJSON = try await model.graphPayloadJSON(focusProject: focusProject)
            buildError = nil
        } catch {
            buildError = error.localizedDescription
        }
    }

    /// Maps a renderer action onto a pending op. Only the two single-item
    /// actions are wired: `merge` and `delete-batch` are desktop bulk
    /// affordances with no phone equivalent, and silently half-applying them
    /// would be worse than ignoring them.
    private func handle(action: String, items: [GraphNodeRef]) {
        guard let node = items.first else { return }
        Task {
            do {
                switch action {
                case "save-inline":
                    guard let edited = node.editedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !edited.isEmpty else { return }
                    try await model.applyGraphEdit(node: node, newText: edited)
                case "delete":
                    try await model.applyGraphDelete(node: node)
                default:
                    return
                }
                await rebuild()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

/// The subset of a renderer node the app acts on, decoded from the page.
struct GraphNodeRef: Codable, Equatable, Identifiable {
    var id: String
    var kind: String?
    var group: String?
    var project: String?
    var label: String?
    var fullLabel: String?
    var text: String?
    var scoreKey: String?
    var editedText: String?
    var editedSection: String?
    var editedPriority: String?

    /// The renderer groups tasks as `task-active` / `task-queue`; findings get
    /// a `topic:` group. `kind` is the renderer's own classification and is
    /// preferred when present.
    var isTask: Bool { kind == "task" || (group?.hasPrefix("task-") ?? false) }
    var isFinding: Bool { kind == "finding" || (group?.hasPrefix("topic:") ?? false) }

    /// The markdown text this node was minted from.
    var sourceText: String? { fullLabel ?? text }
}

private struct GraphSelectionBar: View {
    let node: GraphNodeRef
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let project = node.project {
                    Text(project.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(node.sourceText ?? node.label ?? node.id)
                    .font(.callout)
                    .lineLimit(4)
            }
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - WKWebView host

private struct GraphWebView: UIViewRepresentable {
    let payloadJSON: String
    let onSelect: (GraphNodeRef?) -> Void
    let onAction: (String, [GraphNodeRef]) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onAction: onAction, onError: onError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        for name in ["graphReady", "graphSelect", "graphAction", "graphError"] {
            controller.add(context.coordinator, name: name)
        }
        config.userContentController = controller
        // The bundle is local and the page makes no network requests; keeping
        // it non-persistent means nothing from the graph outlives the view.
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = webView

        guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "graph") else {
            // The bundle step was skipped — say so plainly rather than
            // rendering an empty black screen.
            onError("Graph renderer is missing from the app bundle. Run scripts/bundle-graph.mjs and rebuild.")
            return webView
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.pendingPayload = payloadJSON
        context.coordinator.renderIfReady()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var pendingPayload: String?
        private var isReady = false
        private var lastRendered: String?

        private let onSelect: (GraphNodeRef?) -> Void
        private let onAction: (String, [GraphNodeRef]) -> Void
        private let onError: (String) -> Void

        init(onSelect: @escaping (GraphNodeRef?) -> Void,
             onAction: @escaping (String, [GraphNodeRef]) -> Void,
             onError: @escaping (String) -> Void) {
            self.onSelect = onSelect
            self.onAction = onAction
            self.onError = onError
        }

        func renderIfReady() {
            guard isReady, let payload = pendingPayload, payload != lastRendered, let webView else { return }
            lastRendered = payload
            // The payload is JSON from JSONEncoder, so it is already a valid
            // JS expression — no string interpolation into source, nothing to
            // escape.
            webView.evaluateJavaScript("window.phrenHost.render(\(payload));") { [weak self] _, error in
                if let error { self?.onError(error.localizedDescription) }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "graphReady":
                isReady = true
                renderIfReady()

            case "graphSelect":
                onSelect(decode(GraphNodeRef.self, from: message.body))

            case "graphAction":
                guard let body = message.body as? [String: Any],
                      let action = body["action"] as? String else { return }
                let items = (body["items"] as? [Any])?.compactMap { decode(GraphNodeRef.self, from: $0) } ?? []
                onAction(action, items)

            case "graphError":
                let body = message.body as? [String: Any]
                onError(body?["message"] as? String ?? "The graph renderer reported an error.")

            default:
                break
            }
        }

        /// Round-trips a JS object through JSONSerialization. `message.body`
        /// is untrusted page data, so a shape that does not decode is dropped
        /// rather than force-unwrapped.
        private func decode<T: Decodable>(_ type: T.Type, from body: Any) -> T? {
            guard JSONSerialization.isValidJSONObject(body),
                  let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
    }
}
