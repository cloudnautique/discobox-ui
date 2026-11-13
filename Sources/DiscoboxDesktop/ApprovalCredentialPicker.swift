import SwiftUI
import DiscoboxCore

/// Creation is a local picker action, never a credential ID sent to Discobox.
struct ApprovalCredentialPicker: View {
    @Binding var secretID: String
    @Binding var creating: Bool
    let secrets: [JSONValue]
    var placeholder = "Choose an existing credential…"
    var canCreate = true

    private var selection: Binding<String> {
        Binding(get: { creating ? "@new" : secretID }, set: { value in
            if value == "@new" { creating = true }
            else { secretID = value; creating = false }
        })
    }
    var body: some View {
        StudioMenuField(title: "Credential", selection: selection, options:
            [.init(id: "@new", title: "+ New credential…", enabled: canCreate), .init(id: "", title: placeholder)]
            + secrets.sorted { $0["name"].string.localizedStandardCompare($1["name"].string) == .orderedAscending }
                .map { .init(id: $0["id"].string, title: $0["name"].string) })
            .accessibilityIdentifier("approval.credential")
    }
}

struct InlineTokenCredentialForm<Restrictions: View>: View {
    @Binding var name: String
    @Binding var value: String
    var destinationHost: Binding<String>? = nil
    let canSave: Bool
    let save: () -> Void
    let cancel: () -> Void
    @ViewBuilder var restrictions: Restrictions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("New token credential").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("approval.newName")
            SecureField("Token", text: $value).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("approval.newToken")
            if let destinationHost {
                TextField("Allowed destination host", text: destinationHost).textFieldStyle(.roundedBorder)
            }
            Text("Saving stores a credential. It does not approve this request.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Save credential", action: save).disabled(!canSave)
                    .accessibilityIdentifier("approval.saveCredential")
            }
            restrictions
        }.onSubmit { if canSave { save() } }
    }
}
