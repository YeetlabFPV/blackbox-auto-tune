"""Windows front end for the shared Blackbox analysis engine."""
import argparse
import contextlib
import io
import json
import os
import queue
import sys
import threading
import uuid
from pathlib import Path
from tkinter import Canvas, StringVar, Tk, filedialog, messagebox, ttk

if not getattr(sys, "frozen", False):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "outputs"))
import bb_tune

ROOT = Path(getattr(sys, "_MEIPASS", Path(__file__).parent))
DECODER = ROOT / "blackbox_decode.exe"
STATUSES = {
    "CLI-Vorschlag zur Flugprüfung": "CLI suggestion for flight testing",
    "Slider-Schritt zur Flugprüfung": "Slider change for flight testing",
    "Keine Änderung abgeleitet": "No change recommended",
    "Keine klare Verschlechterung": "No clear degradation",
    "Kein klarer Nutzen": "No clear benefit",
    "Verbesserung im Vergleich": "Improvement observed",
    "Slider-Rücknahme empfohlen": "Restore the previous slider setting",
    "Slider-Vergleich offen": "Slider comparison pending",
    "Vergleich offen": "Comparison pending",
    "Rücknahme prüfen": "Review rollback",
    "Starke Vibration prüfen": "Investigate strong vibration",
    "Diagnose · Vorab-Firmware": "Diagnostics · Prerelease firmware",
}


def analyze(logs, dump, previous, report):
    if not DECODER.is_file():
        raise ValueError("The bundled Blackbox decoder is missing. Extract the whole ZIP first.")
    args = argparse.Namespace(log=logs[0], additional_log=logs[1:], dump=dump, previous=previous,
                              report=report, decoder=str(DECODER), index=None, allow_filter_opening=False)
    with contextlib.redirect_stdout(io.StringIO()):
        bb_tune.run(args)
    return json.loads(report.read_text(encoding="utf-8"))


def slider_text(value):
    for source, target in ((" erhöhen", " increase"), (" senken", " decrease"),
                           (" zurückstellen", " undo"), (" um ", " · ")):
        value = value.replace(source, target)
    return value


class Window:
    def __init__(self):
        self.root = Tk()
        self.root.title("Blackbox Auto-Tune")
        self.root.geometry("930x730")
        self.root.minsize(700, 545)
        self.path = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "Blackbox Auto-Tune" / "Reports"
        self.logs, self.dump, self.previous, self.report_path, self.report = [], None, None, None, None
        self.result_queue = queue.Queue()
        self.cli = ""
        frame = ttk.Frame(self.root, padding=18)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="Blackbox Auto-Tune", font=("Segoe UI", 20, "bold")).pack(anchor="w")
        bar = ttk.Frame(frame)
        bar.pack(fill="x", pady=12)
        self.selectors = []
        for caption, command in (("Select logs", self.pick_logs), ("Optional CLI dump", self.pick_dump),
                                 ("Previous report", self.pick_previous), ("New session", self.clear)):
            button = ttk.Button(bar, text=caption, command=command)
            button.pack(side="left", padx=(0, 6))
            self.selectors.append(button)
        self.go = ttk.Button(bar, text="Analyze", command=self.start, state="disabled")
        self.go.pack(side="right")
        self.inputs = StringVar(value="Select one or more Blackbox logs flown with the same settings.")
        ttk.Label(frame, textvariable=self.inputs, wraplength=840).pack(anchor="w")
        self.status = StringVar(value="Ready")
        ttk.Label(frame, textvariable=self.status, font=("Segoe UI", 12, "bold")).pack(anchor="w", pady=10)
        tabs = ttk.Notebook(frame)
        tabs.pack(fill="both", expand=True)
        self.summary, self.chirp = ttk.Frame(tabs, padding=10), ttk.Frame(tabs, padding=10)
        tabs.add(self.summary, text="Tune overview")
        tabs.add(self.chirp, text="Chirp response")
        self.table = ttk.Treeview(self.summary, columns=("value",), show="tree headings", height=11)
        self.table.heading("#0", text="Measurement")
        self.table.heading("value", text="Result")
        self.table.column("#0", width=260)
        self.table.pack(fill="both", expand=True)
        self.action = StringVar()
        ttk.Label(self.summary, textvariable=self.action, wraplength=810, justify="left").pack(anchor="w", pady=12)
        self.sweeps = ttk.Combobox(self.chirp, state="readonly")
        self.sweeps.pack(fill="x")
        self.sweeps.bind("<<ComboboxSelected>>", self.plot)
        self.chart = Canvas(self.chirp, background="#111720", highlightthickness=0)
        self.chart.pack(fill="both", expand=True, pady=(8, 0))
        self.chart.bind("<Configure>", self.plot)
        footer = ttk.Frame(frame)
        footer.pack(fill="x", pady=(12, 0))
        self.copy = ttk.Button(footer, text="Copy CLI", command=self.copy_cli, state="disabled")
        self.copy.pack(side="left")
        self.next = ttk.Button(footer, text="Prepare next round", command=self.follow_up, state="disabled")
        self.next.pack(side="right")
        ttk.Button(footer, text="Open reports folder", command=self.open_reports).pack(side="left", padx=8)
        self.sweep_data = []

    def pick_logs(self):
        paths = filedialog.askopenfilenames(filetypes=[("Blackbox logs", "*.bbl *.bfl"), ("All files", "*.*")])
        if paths:
            self.logs = list(map(Path, paths))
            self.show_inputs()

    def pick_dump(self):
        selected = filedialog.askopenfilename(filetypes=[("CLI dump", "*.txt"), ("All files", "*.*")])
        if selected:
            self.dump = Path(selected)
            self.show_inputs()

    def pick_previous(self):
        selected = filedialog.askopenfilename(filetypes=[("Flight report", "*.json")], initialdir=self.path)
        if selected:
            self.previous = Path(selected)
            self.show_inputs()

    def show_inputs(self):
        self.inputs.set(f"{len(self.logs)} log(s) · Dump: {self.dump.name if self.dump else 'None'} · "
                        f"Previous report: {self.previous.name if self.previous else 'None'}")
        self.go.configure(state="normal" if self.logs else "disabled")

    def clear(self):
        self.logs, self.dump, self.previous = [], None, None
        self.show_inputs()
        self.status.set("Ready")

    def start(self):
        self.path.mkdir(parents=True, exist_ok=True)
        self.report_path = self.path / f"Flight-{uuid.uuid4().hex[:10]}.json"
        self.status.set("Analyzing logs…")
        for button in [*self.selectors, self.go, self.copy, self.next]:
            button.configure(state="disabled")

        def worker():
            try:
                result = analyze(self.logs, self.dump, self.previous, self.report_path)
                self.result_queue.put((result, None))
            except Exception as exc:
                self.result_queue.put((None, str(exc)))

        threading.Thread(target=worker, daemon=True).start()
        self.root.after(100, self.poll)

    def poll(self):
        try:
            result, error = self.result_queue.get_nowait()
        except queue.Empty:
            self.root.after(100, self.poll)
            return
        for button in self.selectors:
            button.configure(state="normal")
        self.show_inputs()
        if error:
            self.status.set("Analysis could not finish")
            messagebox.showerror("Analysis", error)
            return
        self.display(result)

    def display(self, report):
        self.report = report
        self.status.set(f"Round {report['stage']} · {STATUSES.get(report['status'], report['status'])}")
        self.table.delete(*self.table.get_children())
        self.table.insert("", "end", text="Firmware", values=(report["firmware"],))
        metrics = report["metrics"]
        for axis, values in metrics["axes"].items():
            overshoot = values.get("overshoot")
            detail = f"{overshoot:.0%} overshoot" if overshoot is not None else "More comparable inputs needed"
            self.table.insert("", "end", text=f"{axis.title()} · P/D damping", values=(detail,))
        for key, band in (("low", "20–40%"), ("mid", "40–65%")):
            values = metrics["noise"].get(key)
            detail = (f"Filtered gyro {max(values[:2]):.2f} °/s RMS · D-term {max(values[4:6]):.2f} RMS"
                      if values else "More steady throttle data needed")
            self.table.insert("", "end", text=f"Filter · {band} throttle", values=(detail,))
        self.sweep_data = [(log["file"], sweep) for log in report.get("logs", ())
                           for sweep in log["metrics"].get("chirp_response", ())]
        self.sweeps["values"] = [f"{s['axis'].title()} · {s['seconds']:.1f} s · {name}" for name, s in self.sweep_data]
        if self.sweep_data:
            self.sweeps.current(0)
        else:
            detected = any(log["metrics"].get("chirp_seconds", 0) > 0 for log in report.get("logs", ()))
            self.sweeps.set("Chirp detected, but too few valid frequency points" if detected else "No marked sweep available")
        self.plot()
        self.cli = bb_tune.cli_block(report["profile"], report["changes"])
        relative = report.get("relative_slider") or {}
        action = self.cli or slider_text(relative.get("instruction", ""))
        if self.cli:
            original = bb_tune.cli_block(report["profile"], {key: report["config"][key] for key in report["changes"]})
            action += f"\nOriginal values\n{original}"
        if relative:
            action += "\nChange only this slider and repeat similar maneuvers.\n" + slider_text(relative["undo"])
        if report.get("slider_comparison"):
            action += "\n" + slider_text(report["slider_comparison"])
        self.action.set(action.strip())
        self.copy.configure(state="normal" if self.cli else "disabled")
        self.next.configure(state="normal" if report["stage"] < 3 and not report["blocked"] else "disabled")

    def plot(self, _event=None):
        self.chart.delete("all")
        index = self.sweeps.current()
        if index < 0:
            return
        sweep = self.sweep_data[index][1]
        frequencies = sweep["frequency_hz"]
        width, height = self.chart.winfo_width(), self.chart.winfo_height()
        if width < 130 or height < 150:
            return
        x0, x1 = 62, width - 22
        for row, (key, label) in enumerate((("gain_db", "Gain (dB)"), ("phase_deg", "Phase (°)"))):
            y0, y1 = 30 + row * (height / 2), (row + 1) * (height / 2) - 28
            values = sweep[key]
            lo, hi = min(values), max(values)
            self.chart.create_text(x0, y0 - 12, text=label, anchor="w", fill="#e2e8f1")
            self.chart.create_text(x0 - 6, y0, text=f"{hi:.1f}", anchor="e", fill="#a6b1bf")
            self.chart.create_text(x0 - 6, y1, text=f"{lo:.1f}", anchor="e", fill="#a6b1bf")
            self.chart.create_line(x0, y0, x0, y1, x1, y1, fill="#506176")
            self.chart.create_text(x0, y1+12, text=f"{frequencies[0]:.0f} Hz", anchor="w", fill="#a6b1bf")
            self.chart.create_text(x1, y1+12, text=f"{frequencies[-1]:.0f} Hz", anchor="e", fill="#a6b1bf")
            for frequency, value in zip(frequencies, values):
                x = x0 + (frequency-frequencies[0])/(frequencies[-1]-frequencies[0])*(x1-x0)
                y = (y0+y1)/2 if hi == lo else y1-(value-lo)/(hi-lo)*(y1-y0)
                self.chart.create_oval(x-2, y-2, x+2, y+2, fill="#75dfb8", outline="")

    def copy_cli(self):
        self.root.clipboard_clear()
        self.root.clipboard_append(self.cli)

    def follow_up(self):
        self.previous, self.logs, self.dump = self.report_path, [], None
        self.show_inputs()
        self.next.configure(state="disabled")
        self.status.set("Select the follow-up flight logs")

    def open_reports(self):
        self.path.mkdir(parents=True, exist_ok=True)
        os.startfile(self.path)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--smoke-test":
        result = analyze([Path(sys.argv[2])], None, None, Path(sys.argv[3]))
        assert result["logs"][0]["metrics"]["chirp_response"][0]["axis"] == "roll"
        assert not result["changes"]
    else:
        Window().root.mainloop()
