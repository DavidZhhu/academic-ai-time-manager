import SwiftUI
import AuthenticationServices
import AcademicCore

@MainActor
final class MicrosoftBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow() }
    func authenticate(_ authorization: MicrosoftAuthorization) async throws -> URL {
        defer { session = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authorization.url, callbackURLScheme: "msauth.org.example.AcademicTimeManager") { url, _ in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: OutlookError.cancelled) }
            }
            self.session = session
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            if !session.start() { self.session = nil; continuation.resume(throwing: OutlookError.cancelled) }
        }
    }
}

@MainActor
@Observable
final class OutlookViewModel {
    var state = OutlookState()
    var busy = false
    var status = "Add an Entra client ID to enable Microsoft sign-in. Analysis runs on this Mac."
    var error = false
    var selected = Set<String>()
    var showHistory = false
    var disconnectID: String?
    var accountErrors: [String: String] = [:]
    var sourceURLs: [String: URL] = [:]
    private var database: LocalDatabase?
    private let store = MicrosoftKeychainStore()
    private let browser = MicrosoftBrowser()
    private var lastAttempt: [String: Date] = [:]
    var available: Bool { database != nil }
    func attach(_ database: LocalDatabase?) {
        guard self.database == nil, let database else { return }
        self.database = database
        do { state = try database.outlookState(); loadSourceURLs() }
        catch { report(error) }
    }
    func saveSettings() {
        guard let database else { return }
        do {
            let old = try database.outlookState().settings
            guard TimeZone(identifier: state.settings.timeZoneIdentifier) != nil else { throw OutlookError.configuration }
            if old.keywords != state.settings.keywords || old.allowedSenders != state.settings.allowedSenders || old.analyzeAttachments != state.settings.analyzeAttachments || old.timeZoneIdentifier != state.settings.timeZoneIdentifier {
                for i in state.accounts.indices { state.accounts[i].deltaLink = nil; state.accounts[i].initialSince = Date().addingTimeInterval(-30*86400) }
            }
            try database.save(state); error = false
            status = "Microsoft settings saved. Classification changes are applied to the last 30 days at the next sync."
        } catch { report(error) }
    }
    func connect() async {
        guard let database, !busy else { return }
        busy = true; error = false; defer { busy = false }
        do {
            let authorization = try MicrosoftAuthorization(clientID: state.settings.clientID.trimmingCharacters(in: .whitespacesAndNewlines))
            status = "Waiting for Microsoft sign-in and read-only consent…"
            let callback = try await browser.authenticate(authorization)
            let credentials = try await MicrosoftOAuthClient().exchange(authorization, callback: callback)
            let graph = MicrosoftGraphClient(token: { _ in credentials.accessToken })
            let profile = try await graph.profile()
            let account = OutlookAccount(profileID: profile.id, clientID: authorization.clientID,
                label: profile.displayName ?? "Microsoft account", address: profile.mail ?? profile.userPrincipalName ?? "Microsoft account")
            let oldCredentials = try store.read(accountID: account.id)
            try store.save(credentials, accountID: account.id)
            var updated = state
            if let i = updated.accounts.firstIndex(where: { $0.id == account.id }) {
                updated.accounts[i].connected = true; updated.accounts[i].label = account.label; updated.accounts[i].address = account.address
            } else { updated.accounts.append(account) }
            do { try database.save(updated) }
            catch {
                if let oldCredentials { try? store.save(oldCredentials, accountID: account.id) } else { try? store.remove(accountID: account.id) }
                throw error
            }
            state = updated; accountErrors[account.id] = nil
            status = "Account connected. Choose Synchronise now to read its Inbox. No messages have been imported yet by this sign-in."
        } catch { report(error) }
    }
    func test(_ account: OutlookAccount) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let session = MicrosoftSession(account: account)
            let profile = try await MicrosoftGraphClient(token: { try await session.accessToken(forceRefresh: $0) }).profile()
            guard profile.id == account.profileID else { throw OutlookError.reconnect }
            accountErrors[account.id] = nil; error = false; status = "Connection verified for \(account.address)."
        } catch { report(error); accountErrors[account.id] = status }
    }
    func sync(_ account: OutlookAccount) async -> Bool {
        guard let database, !busy, account.connected else { return false }
        busy = true; error = false; lastAttempt[account.id] = Date(); defer { busy = false }
        status = "Reading Inbox changes for \(account.address)…"
        do {
            let session = MicrosoftSession(account: account)
            let graph = MicrosoftGraphClient(token: { try await session.accessToken(forceRefresh: $0) })
            let batch = try await graph.synchronize(account: account, previous: database.outlookState())
            try database.importOutlook(batch)
            state = try database.outlookState(); loadSourceURLs(); accountErrors[account.id] = nil
            status = "Sync complete for \(account.address): \(batch.messages.count) message changes, \(batch.proposals.count) review proposals. " + batch.notices.joined(separator: " ")
            return true
        } catch { report(error); accountErrors[account.id] = status; return false }
    }
    func poll() async -> Bool {
        guard !busy, let persisted = try? database?.outlookState() else { return false }
        var changed = false
        for account in persisted.accounts where account.pollingDue(settings: persisted.settings, now: Date()) {
            guard Date().timeIntervalSince(lastAttempt[account.id] ?? .distantPast) >= persisted.settings.pollInterval else { continue }
            if await sync(account) { changed = true }
        }
        return changed
    }
    func disconnect(_ id: String) {
        guard let database, !busy, let index = state.accounts.firstIndex(where: { $0.id == id }) else { return }
        do {
            // Disable polling first; if Keychain removal fails, the UI keeps a retryable disconnect action.
            state.accounts[index].connected = false
            try database.save(state)
            try store.remove(accountID: id)
            accountErrors[id] = nil; error = false; status = "Disconnected locally. Cached sources, reviewed events, and progress are preserved. Revoke consent in Microsoft account settings if desired."
        } catch { report(error) }
    }
    func decide(_ decision: ReviewDecision) {
        guard let database, !busy else { return }
        do {
            try database.decideOutlook(ids: selected, decision: decision)
            state = try database.outlookState(); selected = []; error = false
            status = "Batch review saved locally. Nothing was written to Microsoft or Apple Calendar."
        } catch { report(error) }
    }
    func edit(_ proposal: EmailProposal, date: Date?, duration: Int) {
        guard let database, !busy, let i = state.proposals.firstIndex(where: { $0.id == proposal.id }), proposal.decision == .pending else { return }
        var updated = state; updated.proposals[i].date = date; updated.proposals[i].durationMinutes = duration
        do {
            updated.proposals = EmailReviewRules.annotated(updated.proposals,
                existing: AcademicDataset(items: try database.items(), sources: try database.sourceRecords()).items)
            try database.save(updated); state = updated
        } catch { report(error) }
    }
    private func loadSourceURLs() {
        guard let records = try? database?.sourceRecords() else { return }
        sourceURLs = Dictionary(uniqueKeysWithValues: records.filter { $0.provider == "Outlook" }.compactMap { record in
            guard let uri = record.sourceURI, let url = URL(string: uri), url.scheme == "https", url.user == nil, url.password == nil,
                  ["outlook.office.com", "outlook.office365.com", "outlook.live.com"].contains(url.host ?? "") else { return nil }
            return (record.id, url)
        })
    }
    private func report(_ failure: Error) {
        error = true
        if failure is OutlookError || failure is CanvasKeychainError { status = failure.localizedDescription }
        else { status = "Microsoft operation could not be completed. Check local storage and try again." }
    }
}

struct OutlookConnectionsView: View {
    @Bindable var model: OutlookViewModel
    let changed: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Microsoft Outlook accounts", systemImage: "envelope").font(.title2.bold())
            Text("Connect Oxford Microsoft 365 and personal Outlook/Hotmail separately. Read-only Inbox access; review proposals before adding them to your local calendar.")
            TextField("Microsoft Entra application (client) ID", text: $model.state.settings.clientID).textFieldStyle(.roundedBorder)
            Text("Register organisational + personal accounts and the desktop redirect: \(MicrosoftAuthorization.redirectURI)")
                .font(.caption).textSelection(.enabled)
            Button("Add Microsoft account") { Task { await model.connect() } }
                .disabled(!model.available || model.busy || UUID(uuidString: model.state.settings.clientID.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
            Text(model.status).foregroundStyle(model.error ? .orange : .secondary).fixedSize(horizontal: false, vertical: true)
            if model.busy { ProgressView().controlSize(.small) }
            ForEach(model.state.accounts) { account in
                VStack(alignment: .leading, spacing: 8) {
                    Text(account.label + " · " + account.address).font(.headline)
                    Text(account.connected ? "Connection saved" : "Disconnected locally").font(.caption)
                    if let failure = model.accountErrors[account.id] { Text(failure).font(.caption).foregroundStyle(.orange) }
                    Text(account.lastSuccessfulSync.map { "Last successful sync: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Not synchronised yet").font(.caption)
                    HStack {
                        Button("Test connection") { Task { await model.test(account) } }.disabled(!account.connected)
                        Button("Synchronise now") { Task { if await model.sync(account) { changed() } } }.disabled(!account.connected)
                        Button("Disconnect", role: .destructive) { model.disconnectID = account.id }
                    }.disabled(model.busy)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            DisclosureGroup("Shared classification and privacy settings") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Keywords (comma separated)", text: $model.state.settings.keywords)
                    TextField("Allowed sender addresses or domains (empty = all)", text: $model.state.settings.allowedSenders)
                    TextField("Time zone for dates without an offset", text: $model.state.settings.timeZoneIdentifier)
                    Toggle("Analyse relevant PDF and DOCX attachments locally", isOn: $model.state.settings.analyzeAttachments)
                    Toggle("Poll connected Inboxes while this app is running", isOn: $model.state.settings.pollingEnabled)
                    Stepper("Polling interval: \(model.state.settings.pollingMinutes) minutes", value: $model.state.settings.pollingMinutes, in: 5...1440, step: 5)
                    Text("Same rules for all accounts. No cloud AI transmission. Full message bodies and attachment files are not saved; review excerpts and source references are saved locally. Limits: 5 MB per file, 3 supported attachments per relevant email, 50 PDF pages; DOCX macros, embedded files and external relationships are rejected.").font(.caption)
                    Button("Save Microsoft settings") { model.saveSettings() }
                }.padding(.top, 8).textFieldStyle(.roundedBorder).disabled(model.busy || !model.available)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 10))
        .confirmationDialog("Disconnect this Microsoft account?", isPresented: Binding(get: { model.disconnectID != nil }, set: { if !$0 { model.disconnectID = nil } })) {
            Button("Disconnect", role: .destructive) { if let id = model.disconnectID { model.disconnect(id) }; model.disconnectID = nil }
            Button("Cancel", role: .cancel) { model.disconnectID = nil }
        } message: { Text("Removes this account's credentials from Keychain and stops polling. Cached data and approved commitments are preserved.") }
    }
}

struct OutlookReviewView: View {
    @Bindable var model: OutlookViewModel
    let changed: () -> Void
    private var proposals: [EmailProposal] { model.state.proposals.filter { model.showHistory || ($0.decision == .pending && !$0.withdrawn) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Email proposals").font(.title2.bold())
            Text("Approval adds dated events to the local Timeline only. Cancellation and rescheduling notices are advisory; approval records your review and does not alter an existing commitment.").font(.callout).foregroundStyle(.secondary)
            Text(model.status).font(.caption).foregroundStyle(model.error ? .orange : .secondary)
            HStack {
                Button("Select pending") { model.selected = Set(proposals.filter { $0.decision == .pending && !$0.withdrawn }.map(\.id)) }
                Button("Clear selection") { model.selected = [] }
                Button("Approve selected") { model.decide(.accepted); changed() }
                    .disabled(model.selected.isEmpty || model.state.proposals.filter { model.selected.contains($0.id) }.contains { !$0.canApprove })
                Button("Reject selected") { model.decide(.rejected); changed() }.disabled(model.selected.isEmpty)
            }.disabled(model.busy)
            Toggle("Show reviewed and withdrawn proposals", isOn: $model.showHistory)
            if proposals.isEmpty { Text("No email proposals to review.").foregroundStyle(.secondary) }
            ForEach(proposals) { proposal in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("Select", isOn: Binding(get: { model.selected.contains(proposal.id) }, set: { if $0 { model.selected.insert(proposal.id) } else { model.selected.remove(proposal.id) } }))
                            .toggleStyle(.checkbox).disabled(proposal.decision != .pending || proposal.withdrawn)
                        Text(proposal.title).font(.headline)
                    }
                    Text("\(proposal.kind.rawValue.capitalized) · \(Int(proposal.confidence * 100))% confidence · \(proposal.decision.rawValue.capitalized)\(proposal.withdrawn ? " · Source withdrawn" : "")").font(.caption)
                    Text("Account: " + (model.state.accounts.first { $0.id == proposal.accountID }?.address ?? proposal.accountID)).font(.caption)
                    Text(proposal.evidence).textSelection(.enabled)
                    if let attachment = proposal.attachmentName { Text("Attachment: \(attachment)").font(.caption) }
                    if let note = proposal.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    if proposal.duplicateOf != nil { Label("Possible duplicate; identical approved events are merged locally.", systemImage: "doc.on.doc").font(.caption) }
                    if !proposal.conflictsWith.isEmpty { Label("Conflicts with another proposed or existing commitment. Check before approving.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    if proposal.decision == .pending && !proposal.withdrawn {
                        if let date = proposal.date {
                            DatePicker("Confirm date and time", selection: Binding(get: { date }, set: { model.edit(proposal, date: $0, duration: proposal.durationMinutes) }))
                                .environment(\.timeZone, TimeZone(identifier: model.state.settings.timeZoneIdentifier) ?? .current)
                        } else { Button("Set date and time…") { model.edit(proposal, date: Date(), duration: proposal.durationMinutes) } }
                        if proposal.kind == .meeting || proposal.kind == .tutorial {
                            Stepper("Duration: \(proposal.durationMinutes) minutes", value: Binding(get: { proposal.durationMinutes }, set: { model.edit(proposal, date: proposal.date, duration: $0) }), in: 5...1440, step: 5)
                        }
                    }
                    if let url = model.sourceURLs[proposal.sourceID] { Link("Open original email", destination: url) }
                    Text("Source reference: \(proposal.messageID)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 8)).disabled(model.busy)
            }
        }
    }
}
