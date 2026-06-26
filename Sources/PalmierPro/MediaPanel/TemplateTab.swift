import SwiftUI

struct TemplateTab: View {
    private var store: TemplateStore { TemplateStore.shared }
    @State private var renamingId: String?
    @State private var draftName: String = ""
    @State private var pendingDeleteId: String?

    var body: some View {
        Group {
            if store.templates.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: AppTheme.Spacing.xs) {
                        ForEach(store.templates) { template in
                            row(template)
                        }
                    }
                    .padding(AppTheme.Spacing.sm)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.Background.surfaceColor)
        .alert("Rename Template", isPresented: renameBinding) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) { renamingId = nil }
            Button("Save") {
                let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = renamingId, !trimmed.isEmpty {
                    try? store.rename(id: id, to: trimmed)
                }
                renamingId = nil
            }
        }
        .alert("Delete Template?", isPresented: deleteBinding) {
            Button("Cancel", role: .cancel) { pendingDeleteId = nil }
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteId { try? store.delete(id: id) }
                pendingDeleteId = nil
            }
        } message: {
            Text("This removes the template from your library. This cannot be undone.")
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingId != nil }, set: { if !$0 { renamingId = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDeleteId != nil }, set: { if !$0 { pendingDeleteId = nil } })
    }

    private func row(_ template: EditTemplate) -> some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: AppTheme.FontSize.smMd))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(template.name)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                if !template.summary.isEmpty {
                    Text(template.summary)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .fill(AppTheme.Background.raisedColor)
        )
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous))
        .draggable(TemplateDragPayload.string(forTemplateId: template.id)) {
            dragPreview(template)
        }
        .contextMenu {
            Button("Rename") { draftName = template.name; renamingId = template.id }
            Button("Delete", role: .destructive) { pendingDeleteId = template.id }
        }
    }

    private func dragPreview(_ template: EditTemplate) -> some View {
        Text(template.name)
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(AppTheme.Background.prominentColor)
            )
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: AppTheme.FontSize.xl))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text("No templates yet")
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text("Ask the agent to create one, or save a clip's motion.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .multilineTextAlignment(.center)
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
