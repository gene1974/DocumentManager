import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = FileBrowserViewModel()

    @State private var selectedRowIDs = Set<FileEntry.ID>()
    @State private var renamingRow: FileEntry?
    @State private var renameInput = ""
    @State private var pendingDeleteRows: [FileEntry] = []
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 10) {
            controlBar
            headerRow

            List(viewModel.rows, selection: $selectedRowIDs) { row in
                rowView(row)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        viewModel.open(row)
                    }
                    .contextMenu {
                        Button("重命名") {
                            beginRename(row)
                        }
                        .disabled(!viewModel.isEditModeEnabled)

                        Button("移到废纸篓", role: .destructive) {
                            pendingDeleteRows = [row]
                            showingDeleteConfirmation = true
                        }
                        .disabled(!viewModel.isEditModeEnabled)
                    }
            }
            .listStyle(.plain)
        }
        .padding(12)
        .frame(minWidth: 980, minHeight: 560)
        .alert(
            "读取失败",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { newValue in
                    if !newValue {
                        viewModel.errorMessage = nil
                    }
                }
            )
        ) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .confirmationDialog(
            "确认移到废纸篓",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) {
                confirmDelete()
            }

            Button("取消", role: .cancel) {
                pendingDeleteRows = []
            }
        } message: {
            if pendingDeleteRows.count == 1, let row = pendingDeleteRows.first {
                Text("将把“\(row.name)”移到废纸篓，可在系统废纸篓恢复。")
            } else if !pendingDeleteRows.isEmpty {
                Text("将把选中的 \(pendingDeleteRows.count) 个项目移到废纸篓，可在系统废纸篓恢复。")
            }
        }
        .sheet(item: $renamingRow) { row in
            VStack(alignment: .leading, spacing: 12) {
                Text("重命名")
                    .font(.headline)

                Text("当前：\(row.name)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("新名称", text: $renameInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        applyRename(for: row)
                    }

                HStack {
                    Spacer()
                    Button("取消") {
                        renamingRow = nil
                    }
                    Button("保存") {
                        applyRename(for: row)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 420)
            .onAppear {
                renameInput = row.name
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            Button("主页") {
                viewModel.navigateHome()
            }

            Button("上一级") {
                viewModel.navigateUp()
            }

            Button("选择文件夹") {
                viewModel.chooseFolder()
            }

            Button("刷新") {
                viewModel.refresh()
            }

            TextField("输入路径后回车", text: $viewModel.pathInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    viewModel.navigateToPathInput()
                }

            Toggle("显示隐藏文件", isOn: $viewModel.showHiddenFiles)

            Divider()
                .frame(height: 18)

            Toggle("编辑模式", isOn: editModeBinding)
                .help("开启后允许重命名和移到废纸篓，120 秒后自动关闭")

            Text(viewModel.isEditModeEnabled ? "可编辑（120 秒后自动关闭）" : "只读")
                .font(.caption)
                .foregroundStyle(viewModel.isEditModeEnabled ? .orange : .secondary)

            Button("移到废纸篓（选中）", role: .destructive) {
                pendingDeleteRows = selectedRows
                showingDeleteConfirmation = true
            }
            .disabled(!viewModel.isEditModeEnabled || selectedRows.isEmpty)

            Picker("排序", selection: $viewModel.sortField) {
                ForEach(FileBrowserViewModel.SortField.allCases) { field in
                    Text(field.rawValue).tag(field)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)

            Button {
                viewModel.toggleSortDirection()
            } label: {
                Image(systemName: viewModel.sortAscending ? "arrow.up" : "arrow.down")
                    .frame(width: 16)
            }
            .help(viewModel.sortAscending ? "升序" : "降序")
        }
    }

    private var headerRow: some View {
        HStack {
            headerButton(title: "名称", field: .name)
                .frame(maxWidth: .infinity, alignment: .leading)

            headerButton(title: "类型", field: .type)
                .frame(width: 90, alignment: .leading)

            headerButton(title: "大小", field: .size)
                .frame(width: 120, alignment: .trailing)

            headerButton(title: "修改时间", field: .modifiedDate)
                .frame(width: 180, alignment: .leading)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    private var editModeBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isEditModeEnabled },
            set: { newValue in
                viewModel.isEditModeEnabled = newValue
                if !newValue {
                    selectedRowIDs.removeAll()
                }
            }
        )
    }

    private var selectedRows: [FileEntry] {
        viewModel.rows.filter { selectedRowIDs.contains($0.id) }
    }

    private func headerButton(title: String, field: FileBrowserViewModel.SortField) -> some View {
        Button {
            viewModel.setSortField(field)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if viewModel.sortField == field {
                    Image(systemName: viewModel.sortAscending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func rowView(_ row: FileEntry) -> some View {
        HStack(spacing: 8) {
            Label {
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: row.iconName)
                    .foregroundStyle(row.isDirectory ? .yellow : .blue)
                    .frame(width: 16)
            }
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.kindText)
                .frame(width: 90, alignment: .leading)

            Text(row.sizeText)
                .monospacedDigit()
                .frame(width: 120, alignment: .trailing)

            Text(row.modifiedText)
                .frame(width: 180, alignment: .leading)
        }
        .font(.system(size: 13))
    }

    private func beginRename(_ row: FileEntry) {
        guard viewModel.isEditModeEnabled else { return }
        renamingRow = row
    }

    private func applyRename(for row: FileEntry) {
        do {
            try viewModel.rename(row, to: renameInput)
            renamingRow = nil
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func confirmDelete() {
        guard !pendingDeleteRows.isEmpty else { return }

        do {
            if pendingDeleteRows.count == 1, let row = pendingDeleteRows.first {
                try viewModel.moveToTrash(row)
            } else {
                try viewModel.moveToTrash(rows: pendingDeleteRows)
            }
            selectedRowIDs.subtract(pendingDeleteRows.map(\.id))
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }

        pendingDeleteRows = []
    }
}
