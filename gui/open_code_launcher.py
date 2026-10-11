#!/usr/bin/env python3

"""PyQt5 selector for the local profile-only OpenCode launcher."""

import argparse
import json
import os
import sys
from pathlib import Path

from PyQt5.QtCore import QCoreApplication, Qt
from PyQt5.QtGui import QFont
from PyQt5.QtWidgets import (
    QAction,
    QApplication,
    QComboBox,
    QFileDialog,
    QFormLayout,
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QVBoxLayout,
    QWidget,
)


CANCEL_EXIT_CODE = 10
EFFORT_LABELS = {"low": "Low", "medium": "Medium", "high": "High"}
EFFORT_TOOLTIPS = {
    "low": "Faster responses with a smaller reasoning budget.",
    "medium": "Balances reasoning depth and response time.",
    "high": "Uses the profile's largest reasoning budget for difficult work.",
}


def load_catalog(path):
    with open(path, "r", encoding="utf-8") as handle:
        catalog = json.load(handle)
    if not isinstance(catalog, dict) or set(catalog) != {"profiles", "rejected"}:
        raise ValueError("catalog must contain only profiles and rejected")
    if not isinstance(catalog["profiles"], list) or not catalog["profiles"]:
        raise ValueError("catalog contains no valid profiles")
    if not isinstance(catalog["rejected"], list):
        raise ValueError("catalog rejected field must be a list")
    required = {
        "profile_id", "model", "family", "gguf", "size_bytes", "source_url",
        "context", "output", "default_effort", "reasoning_efforts",
    }
    seen = set()
    for profile in catalog["profiles"]:
        if not isinstance(profile, dict) or set(profile) != required:
            raise ValueError("catalog profile has an invalid shape")
        profile_id = profile["profile_id"]
        if not isinstance(profile_id, str) or not profile_id or profile_id in seen:
            raise ValueError(f"invalid or duplicate profile ID: {profile_id}")
        seen.add(profile_id)
        efforts = profile["reasoning_efforts"]
        if efforts != ["low", "medium", "high"] or profile["default_effort"] not in efforts:
            raise ValueError(f"invalid reasoning policy: {profile_id}")
        if not isinstance(profile["source_url"], str) or not profile["source_url"].startswith("https://"):
            raise ValueError(f"invalid model source URL: {profile_id}")
    return catalog


def load_initial_selection(path):
    if not path or not os.path.isfile(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            selection = json.load(handle)
    except (OSError, ValueError):
        return {}
    return selection if isinstance(selection, dict) else {}


def format_tokens(value):
    return f"{value // 1024}K" if value % 1024 == 0 else f"{value:,}"


def format_size(value):
    return f"{value / (1024 ** 3):.1f} GiB"


class LauncherWindow(QMainWindow):
    def __init__(self, catalog, result_path, initial_workspace, default_profile, initial_selection):
        super().__init__()
        self.catalog = catalog
        self.result_path = result_path
        self.profiles = {profile["profile_id"]: profile for profile in catalog["profiles"]}
        self.launch_selected = False
        self.setWindowTitle("Local OpenCode Launcher")
        self.setMinimumSize(680, 430)
        self._build_menu()
        self._build_ui()
        self._apply_initial_selection(initial_workspace, default_profile, initial_selection)
        self._apply_style()
        self._size_to_screen()
        self._validate()

    def _build_menu(self):
        file_menu = self.menuBar().addMenu("&File")
        quit_action = QAction("&Quit", self)
        quit_action.setShortcut("Ctrl+Q")
        quit_action.triggered.connect(self.cancel)
        file_menu.addAction(quit_action)
        help_menu = self.menuBar().addMenu("&Help")
        help_action = QAction("Launcher &Help", self)
        help_action.triggered.connect(self.show_help)
        help_menu.addAction(help_action)
        about_action = QAction("&About", self)
        about_action.triggered.connect(self.show_about)
        help_menu.addAction(about_action)

    def _build_ui(self):
        central = QWidget(self)
        outer = QVBoxLayout(central)
        outer.setContentsMargins(20, 16, 20, 16)
        outer.setSpacing(12)

        title = QLabel("Launch OpenCode locally")
        title.setObjectName("title")
        title.setFont(QFont(title.font().family(), 16, QFont.DemiBold))
        subtitle = QLabel(
            "Choose a validated RTX 3090 profile and workspace. The interactive OpenCode session continues in this terminal."
        )
        subtitle.setWordWrap(True)
        subtitle.setObjectName("subtitle")
        outer.addWidget(title)
        outer.addWidget(subtitle)

        if self.catalog["rejected"]:
            names = ", ".join(item.get("file", "unknown") for item in self.catalog["rejected"])
            warning = QLabel(f"Unavailable invalid profile/config entries: {names}")
            warning.setObjectName("warning")
            warning.setWordWrap(True)
            warning.setToolTip("\n\n".join(
                f"{item.get('file', 'unknown')}: {item.get('error', 'validation failed')}"
                for item in self.catalog["rejected"]
            ))
            outer.addWidget(warning)

        form = QFormLayout()
        form.setFieldGrowthPolicy(QFormLayout.AllNonFixedFieldsGrow)
        form.setHorizontalSpacing(16)
        form.setVerticalSpacing(10)

        self.profile_combo = QComboBox()
        for profile in sorted(self.profiles.values(), key=lambda item: item["profile_id"]):
            self.profile_combo.addItem(f"{profile['model']} — {profile['profile_id']}", profile["profile_id"])
        self.profile_combo.currentIndexChanged.connect(self._profile_changed)
        form.addRow("Profile", self.profile_combo)

        workspace_row = QWidget()
        workspace_layout = QHBoxLayout(workspace_row)
        workspace_layout.setContentsMargins(0, 0, 0, 0)
        workspace_layout.setSpacing(8)
        self.workspace_edit = QLineEdit()
        self.workspace_edit.setPlaceholderText("/absolute/path/to/workspace")
        self.workspace_edit.textChanged.connect(self._validate)
        browse_button = QPushButton("Browse…")
        browse_button.clicked.connect(self._browse_workspace)
        workspace_layout.addWidget(self.workspace_edit, 1)
        workspace_layout.addWidget(browse_button)
        form.addRow("Workspace", workspace_row)

        self.reasoning_combo = QComboBox()
        self.reasoning_combo.currentIndexChanged.connect(self._validate)
        form.addRow("Reasoning effort", self.reasoning_combo)
        outer.addLayout(form)

        details_frame = QFrame()
        details_frame.setObjectName("detailsCard")
        details = QGridLayout(details_frame)
        details.setContentsMargins(14, 12, 14, 12)
        details.setHorizontalSpacing(18)
        details.setVerticalSpacing(6)
        self.detail_values = {}
        for row, (label, key) in enumerate((
            ("Model", "model"), ("GGUF", "gguf"), ("Limits", "limits"), ("Source", "source")
        )):
            name = QLabel(label)
            name.setObjectName("detailLabel")
            value = QLabel("—")
            value.setWordWrap(True)
            value.setTextInteractionFlags(Qt.TextSelectableByMouse)
            details.addWidget(name, row, 0, Qt.AlignTop)
            details.addWidget(value, row, 1)
            self.detail_values[key] = value
        details.setColumnStretch(1, 1)
        outer.addWidget(details_frame)
        outer.addStretch(1)

        footer = QHBoxLayout()
        self.status_label = QLabel()
        self.status_label.setObjectName("status")
        self.status_label.setWordWrap(True)
        cancel_button = QPushButton("Cancel")
        cancel_button.clicked.connect(self.cancel)
        self.launch_button = QPushButton("Launch OpenCode")
        self.launch_button.setObjectName("primaryButton")
        self.launch_button.setDefault(True)
        self.launch_button.clicked.connect(self.launch)
        footer.addWidget(self.status_label, 1)
        footer.addWidget(cancel_button)
        footer.addWidget(self.launch_button)
        outer.addLayout(footer)
        self.setCentralWidget(central)

    def _apply_initial_selection(self, initial_workspace, default_profile, selection):
        profile_id = selection.get("profile_id")
        if profile_id not in self.profiles:
            profile_id = default_profile if default_profile in self.profiles else sorted(self.profiles)[0]
        profile_index = self.profile_combo.findData(profile_id)
        self.profile_combo.setCurrentIndex(profile_index)

        workspace = selection.get("workspace")
        if not isinstance(workspace, str) or self._workspace_error(workspace):
            workspace = initial_workspace
        self.workspace_edit.setText(workspace)

        effort = selection.get("reasoning_effort")
        profile = self.profiles[profile_id]
        if effort not in profile["reasoning_efforts"]:
            effort = profile["default_effort"]
        effort_index = self.reasoning_combo.findData(effort)
        self.reasoning_combo.setCurrentIndex(effort_index)

    def _profile_changed(self):
        profile = self.profiles.get(self.profile_combo.currentData())
        self.reasoning_combo.blockSignals(True)
        self.reasoning_combo.clear()
        if profile is not None:
            for effort in profile["reasoning_efforts"]:
                label = EFFORT_LABELS[effort]
                if effort == profile["default_effort"]:
                    label += " (profile default)"
                self.reasoning_combo.addItem(label, effort)
                self.reasoning_combo.setItemData(
                    self.reasoning_combo.count() - 1, EFFORT_TOOLTIPS[effort], Qt.ToolTipRole
                )
            self.reasoning_combo.setCurrentIndex(
                profile["reasoning_efforts"].index(profile["default_effort"])
            )
            self.detail_values["model"].setText(profile["model"])
            self.detail_values["gguf"].setText(
                f"{profile['gguf']} ({format_size(profile['size_bytes'])})"
            )
            self.detail_values["limits"].setText(
                f"{format_tokens(profile['context'])} context · {format_tokens(profile['output'])} maximum output"
            )
            self.detail_values["source"].setText(profile["source_url"])
            self.detail_values["source"].setToolTip(profile["source_url"])
        self.reasoning_combo.blockSignals(False)
        self._validate()

    def _browse_workspace(self):
        start = self.workspace_edit.text().strip()
        if not os.path.isdir(start):
            start = str(Path.home())
        selected = QFileDialog.getExistingDirectory(self, "Choose OpenCode Workspace", start)
        if selected:
            self.workspace_edit.setText(selected)

    @staticmethod
    def _workspace_error(path):
        path = path.strip()
        if not path:
            return "Choose a workspace."
        if not path.startswith("/") or "\n" in path or "\r" in path:
            return "Workspace must be an absolute path without line breaks."
        if not os.path.isdir(path):
            return "Workspace must be an existing directory."
        return None

    def _validate(self):
        error = None
        profile = self.profiles.get(self.profile_combo.currentData())
        if profile is None:
            error = "Select a valid profile."
        else:
            error = self._workspace_error(self.workspace_edit.text())
            if error is None and self.reasoning_combo.currentData() not in profile["reasoning_efforts"]:
                error = "Select a valid reasoning effort."
        self.launch_button.setEnabled(error is None)
        self.status_label.setText(error or "Ready to launch in the calling terminal.")
        return error is None

    def launch(self):
        if not self._validate():
            return
        selection = {
            "profile_id": self.profile_combo.currentData(),
            "reasoning_effort": self.reasoning_combo.currentData(),
            "workspace": self.workspace_edit.text().strip(),
        }
        try:
            self._write_result(selection)
        except OSError as error:
            QMessageBox.critical(self, "Could not save selection", str(error))
            return
        self.launch_selected = True
        QCoreApplication.exit(0)

    def _write_result(self, selection):
        result = Path(self.result_path)
        temporary = result.with_name(f".{result.name}.tmp.{os.getpid()}")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(selection, handle, separators=(",", ":"), sort_keys=True)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, result)
            os.chmod(result, 0o600)
        except Exception:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise

    def cancel(self):
        self.launch_selected = False
        QCoreApplication.exit(CANCEL_EXIT_CODE)

    def closeEvent(self, event):
        if self.launch_selected:
            event.accept()
        else:
            event.ignore()
            self.cancel()

    def keyPressEvent(self, event):
        if event.key() == Qt.Key_Escape:
            event.accept()
            self.cancel()
            return
        super().keyPressEvent(event)

    def show_help(self):
        QMessageBox.information(
            self,
            "Launcher Help",
            "Choose one of the validated local RTX 3090 profiles, an existing workspace, and a reasoning effort.\n\n"
            "After Launch, this window closes and the existing command-line launcher starts authenticated llama-server and OpenCode in the calling terminal. "
            "Closing or cancelling this window starts nothing and does not replace the last saved selection.",
        )

    def show_about(self):
        from PyQt5.QtCore import PYQT_VERSION_STR, QT_VERSION_STR
        QMessageBox.about(
            self,
            "About Local OpenCode Launcher",
            f"Local OpenCode Launcher\nPyQt {PYQT_VERSION_STR} · Qt {QT_VERSION_STR}",
        )

    def _apply_style(self):
        self.setStyleSheet("""
            QLabel#subtitle, QLabel#status { color: palette(mid); }
            QLabel#warning { background: #fff3cd; color: #664d03; border: 1px solid #ffecb5; border-radius: 4px; padding: 7px; }
            QFrame#detailsCard { background: palette(base); border: 1px solid palette(midlight); border-radius: 6px; }
            QLabel#detailLabel { color: palette(mid); font-weight: 600; min-width: 72px; }
            QPushButton { min-height: 28px; padding: 2px 12px; }
            QPushButton#primaryButton { font-weight: 600; }
            QComboBox, QLineEdit { min-height: 28px; }
        """)

    def _size_to_screen(self):
        available = QApplication.primaryScreen().availableGeometry()
        self.resize(min(860, int(available.width() * 0.9)), min(560, int(available.height() * 0.9)))
        frame = self.frameGeometry()
        frame.moveCenter(available.center())
        self.move(frame.topLeft())


def run_smoke_test(app, window):
    window.show()
    app.processEvents()
    if window.profile_combo.count() < 1 or window.profile_combo.currentData() is None:
        raise RuntimeError("profile selector is empty")
    if window.reasoning_combo.currentData() not in {"low", "medium", "high"}:
        raise RuntimeError("reasoning selector is invalid")
    if not window._validate():
        raise RuntimeError("default selection is invalid")
    window.workspace_edit.setText("relative/path")
    if window._validate():
        raise RuntimeError("relative workspace is accepted")
    return 0


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--result", required=True)
    parser.add_argument("--initial-workspace", required=True)
    parser.add_argument("--default-profile")
    parser.add_argument("--initial-selection")
    parser.add_argument("--smoke-test", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    catalog = load_catalog(args.catalog)
    selection = load_initial_selection(args.initial_selection)
    app = QApplication(sys.argv[:1])
    window = LauncherWindow(
        catalog, args.result, args.initial_workspace, args.default_profile, selection
    )
    if args.smoke_test:
        return run_smoke_test(app, window)
    window.show()
    return app.exec_()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
