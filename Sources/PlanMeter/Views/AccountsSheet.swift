import SwiftUI
import PlanMeterCore

struct AccountsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Accounts").font(.title2.weight(.semibold))
            Text("PlanMeter reads the login stored in each provider home. If T3 Code is installed, its provider instances supply additional homes, names, and colors. Assign each account to Personal or Work; the suggestion comes from the account name, email domain, or plan type.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(model.accounts) { account in
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(model.color(for: account))
                            .frame(width: 10, height: 10)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(account.displayName).font(.body.weight(.medium))
                                Text(account.provider.displayName).font(.caption).foregroundStyle(.secondary)
                                if let plan = account.planLabel {
                                    Text(plan).font(.caption).foregroundStyle(.secondary)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                }
                            }
                            if let email = account.email {
                                Text(email).font(.caption).foregroundStyle(.secondary)
                            }
                            if let org = account.organization {
                                Text(org).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(account.sourceDescription).font(.caption2).foregroundStyle(.tertiary).lineLimit(2).truncationMode(.middle)
                        }
                        Spacer()
                        Picker("Group", selection: Binding(
                            get: { model.group(for: account) },
                            set: { model.setGroup($0, for: account) }
                        )) {
                            ForEach(PlanGroup.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 240)

            HStack {
                Button("Use suggestions") {
                    for account in model.accounts { model.setGroup(nil, for: account) }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 520)
    }
}
