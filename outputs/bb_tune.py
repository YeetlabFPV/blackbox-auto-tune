#!/usr/bin/env python3
"""Local Betaflight Blackbox analysis and staged CLI proposals."""
import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path

import numpy as np

AXES = ("roll", "pitch", "yaw")
MARKER = b"H Product:Blackbox flight data recorder by Nicholas Sherlock\n"
DYNL = "dterm_lpf1_dyn_min_hz"
DYNH = "dterm_lpf1_dyn_max_hz"
STATIC = "dterm_lpf1_static_hz"
GYRO_LPF1 = "gyro_lpf1_static_hz"
RPM_FIELDS = [f"eRPM[{motor}]" for motor in range(4)]
CONTROL_TERMS = [f"axis{term}[{axis}]" for axis in range(2) for term in ("P", "I", "F")]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def decode_columns(segment, decoder, select_fields):
    headers = {}
    for line in segment.split(b"\n"):
        if not line.startswith(b"H "):
            break
        key, sep, value = line[2:].decode("ascii", errors="replace").partition(":")
        if sep:
            headers[key] = value.strip()
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "flight.bbl"
        source.write_bytes(MARKER + segment)
        subprocess.run([decoder, str(source)], cwd=directory, capture_output=True,
                       check=True, timeout=120)
        result = list(Path(directory).glob("flight.[0-9][0-9].csv"))
        require(len(result) == 1, "Decoder hat kein eindeutiges Flug-CSV erzeugt.")
        with result[0].open() as file:
            columns = [name.strip().split(" (")[0] for name in file.readline().split(",")]
            fields = select_fields(headers, columns)
            missing = set(fields) - set(columns)
            require(not missing, "Fehlende Logfelder: " + ", ".join(sorted(missing)))
            require("motor[4]" not in columns, "Diese Auswertung erwartet einen Quad mit vier Motoren.")
            body = file.tell()
            has_frames = bool(file.readline().strip())
            file.seek(body)
            data = (np.loadtxt(file, delimiter=",", usecols=[columns.index(k) for k in fields], ndmin=2)
                    if has_frames else np.empty((0, len(fields))))
    return headers, data, hashlib.sha256(segment).hexdigest()


def modern_fields(headers, columns):
    return (["time", "setpoint[3]"]
            + [f"{name}[{axis}]" for axis in range(3)
               for name in ("setpoint", "gyroADC", "gyroUnfilt")]
            + [f"axisD[{axis}]" for axis in range(2)]
            + [f"motor[{motor}]" for motor in range(4)]
            + (CONTROL_TERMS if set(CONTROL_TERMS) <= set(columns) else [])
            + (RPM_FIELDS if set(RPM_FIELDS) <= set(columns) else []))


def decode_segment(segment, decoder):
    return decode_columns(segment, decoder, modern_fields)


def read_dump(path):
    require(path.suffix.lower() not in {".bbl", ".bfl"},
            f"{path.name} ist ein Blackbox-Log. Wähle unter CLI-Dump die Betaflight-Ausgabe von `dump` (.txt).")
    try:
        dump = path.read_text(encoding="utf-8-sig")
    except UnicodeDecodeError as exc:
        raise ValueError(f"{path.name} ist keine UTF-8-Textdatei. Wähle unter CLI-Dump "
                         "die gespeicherte Betaflight-Ausgabe von `dump` (.txt).") from exc
    require(MARKER.decode("ascii").strip() not in dump,
            f"{path.name} ist ein Blackbox-Log. Wähle unter CLI-Dump die Betaflight-Ausgabe von `dump` (.txt).")
    require(re.search(r"^# Betaflight / ", dump, re.M) and re.search(r"^set p_roll = ", dump, re.M),
            f"{path.name} enthält keinen vollständigen Betaflight-CLI-Dump. "
            "Speichere die Ausgabe von `dump` als Textdatei und wähle sie unter CLI-Dump.")
    return dump


# Verify CLI names and Blackbox header fields against the exact prerelease revision.
CLI_FIRMWARE = (r"Betaflight ((?:4\.5|2025\.12|2026\.6)\.\d+"
                r"|2025\.12\.0-beta(?= \(9d3558c3f\))) \(([0-9a-f]+)\)")


DTERM_CUTOFFS = (DYNL, DYNH, STATIC, "dterm_lpf2_static_hz")
GYRO_CUTOFFS = ("gyro_lpf1_dyn_min_hz", "gyro_lpf1_dyn_max_hz", GYRO_LPF1, "gyro_lpf2_static_hz")
SLIDERS = {
    "dterm": ("D-Term Filter Multiplier", "simplified_dterm_filter_multiplier", -5, DTERM_CUTOFFS),
    "gyro": ("Gyro Filter Multiplier", "simplified_gyro_filter_multiplier", 5, GYRO_CUTOFFS),
    "master": ("Master Multiplier", "simplified_master_multiplier", 5, tuple(
        f"{term}_{axis}" for term in ("p", "i", "d", "d_min", "d_max", "f") for axis in AXES)),
}


def read_config(dump, headers):
    firmware = headers["Firmware revision"]
    match = re.match(CLI_FIRMWARE, firmware)
    require(match, f"Firmware ohne geprüfte CLI-Zuordnung: {firmware}")
    version, revision = match.groups()
    dynamic = [int(v) for v in headers["dterm_lpf1_dyn_hz"].split(",")]
    expected = {DYNL: dynamic[0], DYNH: dynamic[1], STATIC: int(headers[STATIC])}
    for axis in AXES:
        for term, value in zip("pid", headers[axis + "PID"].split(",")):
            expected[f"{term}_{axis}"] = int(value)
    extra_d = "d_min" if version.startswith("4.") else "d_max"
    for axis, value in zip(AXES, headers[extra_d].split(",")):
        expected[f"{extra_d}_{axis}"] = int(value)
    if GYRO_LPF1 in headers:
        expected[GYRO_LPF1] = int(headers[GYRO_LPF1])
    if "gyro_lpf1_dyn_hz" in headers:
        for name, value in zip(("gyro_lpf1_dyn_min_hz", "gyro_lpf1_dyn_max_hz"),
                               headers["gyro_lpf1_dyn_hz"].split(",")):
            expected[name] = int(value)
    if "ff_weight" in headers:
        for axis, value in zip(AXES, headers["ff_weight"].split(",")):
            expected[f"f_{axis}"] = int(value)
    for key in ("dterm_lpf2_static_hz", "gyro_lpf2_static_hz", *(entry[1] for entry in SLIDERS.values())):
        if key in headers:
            expected[key] = int(headers[key])
    log_settings = {key: str(value) for key, value in expected.items()}
    modes = {"simplified_pids_mode": {"0": "OFF", "1": "RP", "2": "RPY"},
             "simplified_dterm_filter": {"0": "OFF", "1": "ON"},
             "simplified_gyro_filter": {"0": "OFF", "1": "ON"}}
    for key, values in modes.items():
        if key in headers:
            require(headers[key] in values, f"Unbekannter Logwert für {key}.")
            log_settings[key] = values[headers[key]]
    if dump is None:
        return firmware, None, log_settings
    require(re.search(rf"^# Betaflight / [^\r\n]*\b{re.escape(version)}\s+[^\r\n]*\({revision}\)", dump, re.M),
            "CLI-Dump und Log müssen dieselbe Firmware-Revision verwenden.")
    profiles = set(re.findall(r"^profile ([0-9]+)\s*$", dump, re.M))
    require(len(profiles) == 1, "Aktives Profil fehlt oder mehrere Profile. CLI 'dump' verwenden.")
    settings = dict(re.findall(r"^set ([a-z0-9_]+) = ([^\r\n]+)", dump, re.M))
    settings = {key: value.strip() for key, value in settings.items()}
    for key, value in log_settings.items():
        dump_value = settings.get(key, "fehlt")
        require(dump_value == value,
                f"Log und CLI-Dump unterscheiden sich bei {key} (Log: {value}, Dump: {dump_value}).")
    return firmware, int(profiles.pop()), settings


def step_samples(sp, gyro, throttle, saturated, gaps, hz):
    events = []
    before, after = round(.045 * hz), round(.22 * hz)
    early, late = round(.065 * hz), round(.12 * hz)
    # Detect a commanded change across 30 ms, then validate both plateaus.
    delta_n = round(.03 * hz)
    hits = np.flatnonzero(abs(sp[delta_n:] - sp[:-delta_n]) > 65) + delta_n // 2
    for cluster in np.split(hits, np.flatnonzero(np.diff(hits) > delta_n) + 1):
        if not len(cluster):
            continue
        k = int(np.median(cluster))
        start, end = k - before, k + after
        if start < 0 or end > len(sp) or gaps[start:end].any() or saturated[start:end].any():
            continue
        base = sp[start:k - delta_n]
        plateau = sp[k + early:end]
        other = np.delete(gyro[start:end], 0, axis=1)
        if (np.ptp(base) > 15 or np.ptp(plateau) > 22
                or np.max(abs(other)) > 65 or np.ptp(throttle[start:end]) > .13
                or not .18 <= np.median(throttle[start:end]) <= .62):
            continue
        origin = float(np.median(base))
        amplitude = float(np.median(plateau) - origin)
        if abs(origin) > 30 or not 80 <= abs(amplitude) <= 400:
            continue
        actual = (gyro[k:end, 0] - origin) / amplitude
        actual = np.convolve(actual, np.ones(round(.008 * hz)) / round(.008 * hz), mode="valid")
        command = (sp[k:end] - origin) / amplitude
        peak = int(np.argmax(actual))
        rebound = max(0., float(1 - np.min(actual[peak:])))
        outside = np.flatnonzero(abs(actual - 1) > .10)
        settled = int(outside[-1] + 1) if len(outside) else 0
        settling_ms = 1000 * settled / hz if len(actual) - settled >= round(.030 * hz) else None
        events.append({
            "settling_ms": settling_ms,
            "sign": int(np.sign(amplitude)),
            "amplitude": abs(amplitude),
            "overshoot": max(0., float(np.max(actual) - 1)),
            "rebound": rebound,
            "error": float(np.mean(abs(actual[early:late] - command[early:late]))),
            "undershoot": float(1 - np.median(actual[early:late])),
        })
    return events


def flight_response(setpoint, gyro, throttle, saturated, gaps, hz):
    """Estimate closed-loop setpoint-to-gyro response from ordinary stick motion."""
    n = round(hz)
    window = np.hanning(n)
    freqs = np.fft.rfftfreq(n, 1 / hz)
    keep = (freqs >= 5) & (freqs <= 25)
    response = {}
    for axis, name in enumerate(AXES):
        commands, measurements = [], []
        for start in range(0, len(gaps) - n + 1, n):
            section = slice(start, start + n)
            x = setpoint[section, axis]
            if (gaps[section].any() or np.mean(saturated[section]) > .01
                    or np.median(throttle[section]) < .12 or np.std(x) < 25):
                continue
            y = gyro[section, axis]
            commands.append(np.fft.rfft(window * (x - x.mean()))[keep])
            measurements.append(np.fft.rfft(window * (y - y.mean()))[keep])
        if len(commands) < 6:
            continue
        x, y = np.array(commands), np.array(measurements)
        pxx = np.sum(abs(x) ** 2, axis=0)
        pyy = np.sum(abs(y) ** 2, axis=0)
        pxy = np.sum(x.conj() * y, axis=0)
        coherence = abs(pxy) ** 2 / np.maximum(pxx * pyy, 1e-12)
        excited = (pxx >= .015 * pxx.max()) & (pxx > 1e-12) & (coherence >= .85)
        bands = {}
        for low, high in ((5, 12), (12, 25)):
            mask = excited & (freqs[keep] >= low) & (freqs[keep] < high)
            if np.count_nonzero(mask) < 3:
                continue
            transfer = pxy[mask] / pxx[mask]
            bands[f"{low}-{high}"] = {
                "gain": float(np.median(abs(transfer))),
                "phase_delay_ms": float(np.median(
                    -np.angle(transfer) * 1000 / (2 * np.pi * freqs[keep][mask]))),
                "coherence": float(np.median(coherence[mask])),
            }
        if bands:
            response[name] = {"windows": len(commands), "bands": bands}
    return response


def resonance_scan(gyro, setpoint, raw, dterm, throttle, gaps, hz):
    """Find repeatable narrow peaks during quiet commands by throttle band."""
    n = round(hz)
    window = np.hanning(n)
    f = np.fft.rfftfreq(n, 1 / hz)
    use = (f >= 25) & (f <= min(120, .4 * hz))
    results = []
    for lower, upper in ((.15, .35), (.35, .55), (.55, .75), (.75, 1.01)):
        valid = []
        for start in range(0, len(gaps) - n + 1, n):
            part = slice(start, start + n)
            gas = throttle[part]
            if (gaps[part].any() or not lower <= np.median(gas) < upper
                    or np.ptp(gas) > .22 or np.percentile(abs(setpoint[part]), 90) > 75):
                continue
            valid.append(start)
        if len(valid) < 4:
            continue
        def spectrum(signal):
            chunks = np.stack([signal[i:i+n] for i in valid])
            chunks -= chunks.mean(axis=1, keepdims=True)
            return 2 * abs(np.fft.rfft(chunks * window[None, :, None], axis=1)) ** 2 / (n * (window @ window))
        filtered, command = spectrum(gyro), spectrum(setpoint)
        raw_power = spectrum(raw) if raw is not None else None
        d_power = spectrum(dterm) if dterm is not None else None
        average = np.median(filtered, axis=0)
        for axis, name in enumerate(AXES):
            k = np.flatnonzero(use)[np.argmax(average[use, axis])]
            neighborhood = (abs(f - f[k]) >= 5) & (abs(f - f[k]) <= 15)
            peak = abs(f - f[k]) <= 2
            rms = float(np.sqrt(np.median(filtered[:, peak, axis].sum(axis=1))))
            floor = float(np.median(average[neighborhood, axis]))
            prominence = 10 * np.log10(max(average[k, axis], 1e-12) / max(floor, 1e-12))
            command_rms = float(np.sqrt(np.median(command[:, peak, axis].sum(axis=1))))
            axis_ratio = rms / max(.01, max(np.sqrt(np.median(
                filtered[:, peak, other].sum(axis=1))) for other in range(3) if other != axis))
            results.append({"axis": name, "throttle": [lower, min(upper, 1.)],
                            "hz": float(f[k]), "windows": len(valid), "gyro_rms": rms,
                            "prominence_db": float(prominence), "command_rms": command_rms,
                            "axis_ratio": float(axis_ratio), "band_rms": float(np.sqrt(
                                np.median(filtered[:, use, axis].sum(axis=1)))),
                            "raw_rms": float(np.sqrt(np.median(raw_power[:, peak, axis].sum(axis=1))))
                            if raw_power is not None else None,
                            "dterm_rms": float(np.sqrt(np.median(d_power[:, peak, axis].sum(axis=1))))
                            if d_power is not None and axis < d_power.shape[2] else None})
    return results


def unresolved_resonance(peak):
    return (peak["gyro_rms"] >= 1.5 and peak["prominence_db"] >= 8
            and peak["axis_ratio"] >= 1.6 and peak["gyro_rms"] >= 3 * peak["command_rms"])


def estimated_step(sp, gyro, throttle, saturation, gaps, hz):
    """Fit a causal impulse model, withhold one third of independent windows."""
    stride = round(hz)
    decimation = max(1, round(hz / 500))
    model_hz = hz / decimation
    size = round(.16 * model_hz)
    windows = []
    for start in range(0, len(sp) - stride + 1, stride):
        end = start + stride
        x, y = sp[start:end], gyro[start:end]
        if (np.any(gaps[start:end]) or np.mean(saturation[start:end]) > .01
                or np.median(throttle[start:end]) < .12 or np.std(x) < 10):
            continue
        if decimation > 1:
            smooth = np.ones(decimation) / decimation
            x = np.convolve(x, smooth, mode="valid")[::decimation]
            y = np.convolve(y, smooth, mode="valid")[::decimation]
        x, y = x - x.mean(), y - y.mean()
        design = np.lib.stride_tricks.sliding_window_view(x, size)[:, ::-1]
        windows.append((design, y[size-1:]))
    if len(windows) < 9:
        return {"confidence": "insufficient", "windows": len(windows)}
    train = [(x, y) for i, (x, y) in enumerate(windows) if i % 3 != 0]
    design = np.concatenate([x for x, _ in train])
    target = np.concatenate([y for _, y in train])
    gram = design.T @ design
    cross = design.T @ target
    reg = .002 * np.trace(gram) / size
    impulse = np.linalg.solve(gram + reg * np.eye(size), cross)
    held_out = [(x, y) for i, (x, y) in enumerate(windows) if i % 3 == 0]
    score = float(np.sqrt(sum(np.sum((y - x @ impulse)**2) for x, y in held_out)
                          / max(1e-12, sum(y @ y for x, y in held_out))))
    step = np.cumsum(impulse)
    gain = float(np.median(step[-round(.025 * model_hz):]))
    if score > .30 or not .7 <= gain <= 1.3:
        return {"confidence": "insufficient", "windows": len(windows),
                "held_out_normalized_rmse": score}
    step /= gain
    outside = np.flatnonzero(abs(step - 1) > .10)
    index = int(outside[-1] + 1) if len(outside) else 0
    peak = int(np.argmax(step))
    return {"confidence": "exploratory", "windows": len(windows), "held_out_normalized_rmse": score,
            "overshoot": float(max(0, step[peak] - 1)),
            "rebound": float(max(0, 1 - step[peak:].min())),
            "settling_ms": 1000 * index / model_hz if len(step) - index >= round(.03 * model_hz) else None,
            "sample_ms": 1000 / model_hz, "curve": step.tolist()}


def measure_stops(setpoint, gyro, effort, saturated, gaps, hz):
    """Measure uncommanded reverse rotation after a natural stick release."""
    before, after = round(.080 * hz), round(.060 * hz)
    edge, brake = round(.012 * hz), round(.025 * hz)
    smoothing = np.ones(max(3, round(.005 * hz))) / max(3, round(.005 * hz))
    result = {}
    for axis, name in enumerate(AXES[:2]):
        command = setpoint[:, axis]
        events = []
        for stop in np.flatnonzero((abs(command[1:]) <= 20) & (abs(command[:-1]) > 20)) + 1:
            start, end = stop - before, stop + after
            if start < 0 or end > len(command) or gaps[start:end].any() or saturated[start:end].any():
                continue
            if (max(abs(command[stop:end])) > 30
                    or np.max(abs(np.delete(setpoint[stop-brake:end], axis, axis=1))) > 100):
                continue
            earlier = command[start:stop-edge]
            signed_rate = earlier[np.argmax(abs(earlier))]
            direction = np.sign(signed_rate)
            if abs(signed_rate) < 90 or np.min(direction * earlier) < -25:
                continue
            rotation = np.convolve(direction * gyro[stop:end, axis], smoothing, mode="valid")
            minimum = int(np.argmin(rotation))
            reversal = float(max(0, -rotation[minimum]))
            point = stop + minimum + len(smoothing) // 2
            braking = np.maximum(0, -direction * effort[max(stop-brake, point-brake):point+1, axis]).mean(axis=0)
            # Absolute braking contributions from P, I, D, F in logged PID units.
            feedforward = float(braking[3] / max(1, braking.sum()))
            events.append({"sign": int(direction), "reverse_rate": reversal, "relative": reversal / abs(signed_rate),
                           "feedforward_share": feedforward, "command_peak": float(abs(signed_rate))})
        result[name] = events
    return result


def summarize_stops(sources):
    summary = {}
    for axis in AXES[:2]:
        events = [event for source in sources for event in source.get("stops", {}).get(axis, [])]
        strong = [event for event in events
                  if event["reverse_rate"] >= 8 and event["relative"] >= .07
                  and event["feedforward_share"] >= .55]
        if events:
            summary[axis] = {
                "count": len(events),
                "positive": sum(event["sign"] > 0 for event in strong),
                "negative": sum(event["sign"] < 0 for event in strong),
                "observed_positive": sum(event["sign"] > 0 for event in events),
                "observed_negative": sum(event["sign"] < 0 for event in events),
                "median_command_peak": float(np.median([event["command_peak"] for event in events])),
                "median_reverse_rate": float(np.median([event["reverse_rate"] for event in events])),
                "median_qualified_ff_share": float(np.median([event["feedforward_share"] for event in strong]))
                if strong else None,
            }
    return summary


def filter_profile(sp, gyro, raw, dterm, throttle, rpm, gaps, saturated, hz):
    """Map uncommanded spectral power by throttle and estimate the gyro-chain phase delay."""
    n = round(.256 * hz)
    taper = np.hanning(n)
    f = np.fft.rfftfreq(n, 1 / hz)
    limit = min(500., .4 * hz)
    bins = 5
    edges = np.arange(25, limit - 24, 25)
    rows = [[] for _ in range(bins)]
    phases = []
    peak_rpm = []
    for start in range(0, len(sp) - n + 1, n):
        section = slice(start, start+n)
        gas = throttle[section]
        if gaps[section].any() or saturated[section].any() or np.ptp(gas) > .14:
            continue
        signals = np.column_stack((raw[section, :2], gyro[section, :2], dterm[section]))
        fft = np.fft.rfft((signals-signals.mean(axis=0))*taper[:, None], axis=0)
        power = 2 * abs(fft)**2 / (n * (taper @ taper))
        if np.std(raw[section, :2]) >= 10:
            phases.append(fft[:, :4])
        if np.max(abs(sp[section])) > 45 or np.median(gas) < .05:
            continue
        speed = float(np.median(rpm[section])) if rpm is not None and np.mean(rpm[section] > 0) >= .98 else None
        row = min(bins-1, int(np.median(gas)*bins))
        rows[row].append((power, speed))
        peak_band = (f >= 100) & (f <= limit)
        if speed and np.any(peak_band):
            raw_power = power[peak_band, :2].mean(axis=1)
            best = int(np.argmax(raw_power))
            if raw_power[best] >= 5 * max(np.median(raw_power), .01):
                peak_rpm.append((speed, f[peak_band][best]))
    profile = []
    for index, row in enumerate(rows):
        entry = {"low": index*20, "high": (index+1)*20, "windows": len(row)}
        if len(row) >= 6:
            powers = np.stack([pair[0] for pair in row])
            bands = [np.sqrt(np.median(powers[:, (f >= a)&(f < a+25), :].sum(axis=1), axis=0))
                     for a in edges]
            entry.update(frequency_hz=(edges+12.5).tolist(),
                         raw=[float(max(b[:2])) for b in bands],
                         gyro=[float(max(b[2:4])) for b in bands],
                         dterm=[float(max(b[4:])) for b in bands],
                         raw_hf=float(max(np.sqrt(np.median(powers[:, (f>=140)&(f<=limit), :2].sum(axis=1), axis=0)))),
                         gyro_hf=float(max(np.sqrt(np.median(powers[:, (f>=140)&(f<=limit), 2:4].sum(axis=1), axis=0)))),
                         dterm_hf=float(max(np.sqrt(np.median(powers[:, (f>=140)&(f<=limit), 4:].sum(axis=1), axis=0)))),
                         rpm_windows=sum(pair[1] is not None for pair in row))
        profile.append(entry)
    delay = {}
    if len(phases) >= 8:
        spectra = np.array(phases)
        x, y = spectra[:, :, :2], spectra[:, :, 2:]
        pxx, pyy = (np.sum(abs(a)**2, axis=0) for a in (x,y))
        pxy = np.sum(x.conj()*y, axis=0)
        coherence = abs(pxy)**2 / np.maximum(pxx*pyy, 1e-12)
        for axis, name in enumerate(AXES[:2]):
            keep = ((f>=7)&(f<=35)&(coherence[:,axis]>=.9)
                    &(pxx[:,axis]>=.01*pxx[:,axis].max())&(pxx[:,axis]>1e-12))
            if np.count_nonzero(keep) >= 3:
                phase = -np.angle(pxy[keep,axis])*1000/(2*np.pi*f[keep])
                if np.ptp(phase) <= 3 and 0 <= np.median(phase) <= 25:
                    delay[name] = float(np.median(phase))
    rpm_association = None
    if len(peak_rpm) >= 12:
        speeds, frequencies = np.array(peak_rpm).T
        if np.ptp(speeds) >= .2*np.median(speeds) and np.ptp(frequencies) >= 25:
            rpm_association = float(np.corrcoef(speeds, frequencies)[0,1])
    return {"bands": profile, "phase_delay_ms": delay, "rpm_peak_correlation": rpm_association,
            "rpm_configured": False}


def short_events(time, throttle, sp, gyro, motors, gaps, hz):
    """Flag brief oscillations and compare tracking after similar throttle recoveries."""
    n = round(.256 * hz)
    taper = np.hanning(n)
    frequencies = np.fft.rfftfreq(n, 1 / hz)
    band = (frequencies >= 25) & (frequencies <= 120)
    candidates = []
    for start in range(0, len(time) - n + 1, n):
        section = slice(start, start + n)
        if gaps[section].any() or np.max(abs(sp[section])) > 45 or np.median(throttle[section]) < .15:
            continue
        signal = gyro[section] - np.mean(gyro[section], axis=0)
        power = abs(np.fft.rfft(signal * taper[:, None], axis=0))[band] ** 2
        rms = np.sqrt(2 * power.sum(axis=0) / (n * (taper @ taper)))
        axis = int(np.argmax(rms))
        if rms[axis] >= 5:
            candidates.append(dict(seconds=float((time[start] - time[0]) / 1e6),
                                   axis=AXES[axis], hz=float(frequencies[band][np.argmax(power[:, axis])]),
                                   gas=float(np.median(throttle[section])), rms=float(rms[axis]),
                                   motor_peak=float(np.max(motors[section]))))
    # Compare low-stick throttle recoveries in the same initial and final gas bands.
    recoveries = {}
    chunk = round(.10 * hz)
    last = -10 * chunk
    for start in range(3 * chunk, len(time) - 6 * chunk, chunk):
        if start - last < 8 * chunk:
            continue
        before = float(np.median(throttle[start - 3*chunk:start]))
        after = float(np.median(throttle[start + chunk:start + 3*chunk]))
        section = slice(start, start + 6*chunk)
        if not (.12 <= before <= .42 and .35 <= after <= .75 and after - before >= .18):
            continue
        if gaps[start - 3*chunk:section.stop].any() or np.max(abs(sp[section, :2])) > 60 or np.max(motors[section]) >= .98:
            continue
        error = (gyro[section, :2] - sp[section, :2]).reshape(6, chunk, 2)
        rms = np.sqrt(np.mean(error**2, axis=1)).max(axis=1)
        above = np.flatnonzero(rms > 5)
        key = f"{int(before * 10) * 10} → {int(after * 10) * 10} %"
        recoveries.setdefault(key, []).append((float(rms.max()), float(.1 * (above[-1] + 1)) if above.size else 0.))
        last = start
    return sorted(candidates, key=lambda event: event["rms"], reverse=True)[:8], recoveries


def summarize_recoveries(flights):
    by_gas = {}
    for flight in flights:
        for gas, samples in flight.get("recoveries", {}).items():
            by_gas.setdefault(gas, []).extend(samples)
    return {gas: dict(count=len(samples), error_rms=float(np.median([s[0] for s in samples])),
                      duration=float(np.median([s[1] for s in samples])))
            for gas, samples in sorted(by_gas.items()) if len(samples) >= 3}


def analyze(headers, data):
    require(len(data) > 10000 and np.isfinite(data).all(), "Zu wenig gültige Flugdaten.")
    dt = np.diff(data[:, 0])
    require(np.all(dt > 0), "Zeitstempel sind nicht strikt aufsteigend.")
    period = np.median(dt)
    hz = 1e6 / period
    require(950 <= hz <= 8500, f"Ungeeignete effektive Lograte: {hz:.0f} Hz.")
    gaps = np.r_[False, abs(dt - period) > .20 * period]
    require(np.mean(gaps) < .025, "Zu viele Zeitlücken oder zu viel Jitter für diese Auswertung.")
    require((data[-1, 0] - data[0, 0]) / 1e6 >= 20, "Der Flug muss mindestens 20 s Logdaten liefern.")
    scale = 10 if int(headers["blackbox_high_resolution"]) else 1
    throttle = data[:, 1] / 1000
    sp, gyro, raw = [data[:, offset:11:3] / scale for offset in (2, 3, 4)]
    dterm = data[:, 11:13]
    low, high = map(int, headers["motorOutput"].split(","))
    require(high > low, "Ungültiger Motorbereich.")
    motors = (data[:, 13:17] - low) / (high - low)
    require(np.max(motors) <= 1.02, "Motorwerte passen nicht zum Logheader.")
    saturated = np.max(motors, axis=1) >= .98
    metrics, tracking, estimated_steps = {}, {}, {}
    stops = {}
    has_rpm = data.shape[1] in (21, 27)
    has_terms = data.shape[1] in (23, 27)
    if has_terms:
        optional = data[:, 17:23].reshape(len(data), 2, 3)
        effort = np.stack((optional[:, :, 0], optional[:, :, 1], dterm, optional[:, :, 2]), axis=2)
        stops = measure_stops(sp, gyro, effort, saturated, gaps, hz)
    for i, axis in enumerate(AXES):
        events = step_samples(sp[:, i], gyro[:, [i] + [j for j in range(3) if i != j]],
                              throttle, saturated, gaps, hz)
        moving = (abs(sp[:, i]) >= 120) & ~gaps
        usable = moving & ~saturated
        if np.count_nonzero(moving) >= round(.25 * hz):
            interval = max(1, round(.030 * hz))
            flat = np.r_[np.zeros(interval, dtype=bool),
                         abs(sp[interval:, i] - sp[:-interval, i]) <= .10 * abs(sp[interval:, i])]
            steady = usable & flat
            deficit = (1 - gyro[steady, i] / sp[steady, i])
            tracking[axis] = {
                "steady_seconds": float(np.count_nonzero(steady) / hz),
                "steady_rate": float(np.median(abs(sp[steady, i]))) if deficit.size else None,
                "steady_deficit": float(np.median(deficit)) if deficit.size else None,
                "seconds": float(np.count_nonzero(moving) / hz),
                "command_p95": float(np.percentile(abs(sp[moving, i]), 95)),
                "near_motor_limit": float(np.mean(saturated[moving])),
                "median_error": float(np.median(abs(sp[usable, i] - gyro[usable, i])))
                if np.count_nonzero(usable) >= round(.25 * hz) else None,
                "relative_error": float(np.median(
                    abs(sp[usable, i] - gyro[usable, i]) / abs(sp[usable, i])))
                if np.count_nonzero(usable) >= round(.25 * hz) else None,
            }
        if hz <= 2500:
            estimated_steps[axis] = estimated_step(sp[:, i], gyro[:, i], throttle, saturated, gaps, hz)
        signs = [x["sign"] for x in events]
        metrics[axis] = {"events": len(events), "positive": signs.count(1), "negative": signs.count(-1)}
        if signs.count(1) >= 3 and signs.count(-1) >= 3:
            for key in ("amplitude", "overshoot", "error", "undershoot", "rebound"):
                metrics[axis][key] = float(np.median([x[key] for x in events]))
    n = round(.256 * hz)
    w = np.hanning(n)
    freq = np.fft.rfftfreq(n, 1 / hz)
    band = (freq >= 140) & (freq <= min(450, .38 * hz))
    oscillation_band = (freq >= 25) & (freq <= 120)
    noise = {"low": [], "mid": []}
    for start in range(0, len(data) - n, n):
        s = slice(start, start + n)
        power = throttle[s]
        if (gaps[s].any() or saturated[s].any() or np.max(abs(sp[s])) > 30
                or np.ptp(power) > .11):
            continue
        t = np.median(power)
        if not .20 <= t < .65:
            continue
        signals = np.column_stack((gyro[s, :2], raw[s, :2], dterm[s]))
        spectrum = np.fft.rfft((signals - signals.mean(axis=0)) * w[:, None], axis=0)
        energy = 2 * abs(spectrum) ** 2 / (n * (w @ w))
        rms = np.sqrt(energy[band].sum(axis=0))
        osc = np.sqrt(energy[oscillation_band, :2].sum(axis=0))
        noise["low" if t < .40 else "mid"].append([*rms, *osc])
    bins = {key: np.median(values, axis=0).tolist() for key, values in noise.items()
            if len(values) >= 6}
    filters = filter_profile(sp, gyro, raw, dterm, throttle,
                             data[:, -4:] if has_rpm else None, gaps, saturated, hz)
    filters["rpm_configured"] = headers.get("dshot_bidir") == "1" and int(headers.get("rpm_filter_harmonics", 0)) > 0
    short, recoveries = short_events(data[:, 0], throttle, sp, gyro, motors, gaps, hz)
    return {"short_events": short, "recoveries": recoveries, "hz": round(hz), "axes": metrics, "noise": bins, "tracking": tracking,
            "filter_profile": filters, "control_terms_available": has_terms,
            "windows": {key: len(values) for key, values in noise.items()},
            "response": flight_response(sp, gyro, throttle, saturated, gaps, hz),
            "estimated_steps": estimated_steps, "stops": stops,
            "resonance": resonance_scan(gyro, sp, raw, dterm, throttle, gaps, hz)}


def comparable_axes(current, previous):
    matches = []
    for axis in AXES:
        a, b = current["axes"][axis], previous["axes"][axis]
        if ("amplitude" in a and "amplitude" in b
                and abs(a["amplitude"] / b["amplitude"] - 1) <= .30):
            matches.append(axis)
    return matches


def worse(current, previous, axes):
    for axis in axes:
        a, b = current["axes"][axis], previous["axes"][axis]
        for key, margin in (("error", .045), ("overshoot", .065)):
            if a[key] > b[key] * 1.15 + margin:
                return True
    for key in current["noise"].keys() & previous["noise"].keys():
        a, b = np.array(current["noise"][key]), np.array(previous["noise"][key])
        if np.any(a > b * 1.3 + np.array([.7] * 4 + [1.2] * 2 + [.9] * 2)):
            return True
    return False


def noisy_bands(metrics):
    return {band for band, values in metrics["noise"].items()
            if any(g > 2.5 and d > 4 and g > .20 * r
                   for g, r, d in zip(values[:2], values[2:4], values[4:6]))}


def propose(metrics, config, stage, firmware):
    changes, notes = {}, []
    bins = list(metrics["noise"].values())
    if not bins:
        return {}, ["Zu wenige ruhige Filterfenster für einen Änderungsvorschlag."]
    missing = [axis.title() for axis in AXES if "amplitude" not in metrics["axes"][axis]]
    if missing:
        notes.append("Zu wenig aussagekräftige Testimpulse für eine P- oder D-Korrektur auf " + ", ".join(missing) + ".")
    if strong_vibration(metrics):
        return {}, ["Starke Vibration in ruhigen Flugabschnitten. Props, Motoren und Aufbau prüfen."]
    # Independent evidence for high-frequency D-term noise and tracking.
    noisy = bool(noisy_bands(metrics))
    if noisy:
        active = [DYNL, DYNH] if int(config[DYNL]) > 0 else [STATIC]
        floor = {DYNL: 55, DYNH: 100, STATIC: 65}
        for key in active:
            old = int(config[key])
            new = max(floor[key], round(old * (.90 if stage == 1 else .95)))
            if new < old:
                changes[key] = str(new)
        if DYNL in active:
            minimum = int(changes.get(DYNL, config[DYNL]))
            maximum = int(changes.get(DYNH, config[DYNH]))
            if maximum <= minimum:
                changes.clear()
        if changes:
            if config.get("simplified_dterm_filter", "OFF") != "OFF":
                changes["simplified_dterm_filter"] = "OFF"
            notes.append("Restgeräusch in Gyro und D-Term: aktiven D-Term-Lowpass 1 vorsichtig absenken.")
            return changes, notes
        else:
            notes.append("Restgeräusch im D-Term. Der aktive LPF1 liegt bereits an der vorgesehenen Untergrenze.")
    if not noisy:
        notes.append("In den erfassten Gasbereichen wurde kein auffälliges hochfrequentes D-Term-Restgeräusch für eine Filteränderung gefunden.")
    for axis in AXES:
        result = metrics["axes"][axis]
        if config.get(f"f_{axis}") != "0":
            continue
        if "amplitude" not in result:
            continue
        key = "p_" + axis
        old = int(config[key])
        clean = len(bins) == 2 and all(max(values[4:6]) < 2.5 and max(values[6:]) < 3
                                       for values in bins)
        peak_key = ("d_" if firmware.startswith("Betaflight 4.") else "d_max_") + axis
        base_key = ("d_min_" if firmware.startswith("Betaflight 4.") else "d_") + axis
        base_d, peak_d = int(config[base_key]), int(config[peak_key])
        if (axis != "yaw" and clean and result["overshoot"] > .15
                and result["rebound"] > .12 and 20 <= base_d < 50 and peak_d <= 65):
            increment = 2 if stage == 1 else 1
            changes[base_key] = str(base_d + increment)
            if peak_d > 0 and peak_d >= base_d:
                changes[peak_key] = str(peak_d + increment)
            notes.append(f"{axis}: Überschwingen und anschließende Gegenbewegung bei niedrigem D-Term-Rauschen. D testweise erhöhen.")
        elif old >= 20 and result["overshoot"] > .20:
            reduce = min(5 if stage == 1 else 2, max(1, round(old * (.08 if stage == 1 else .04))))
            changes[key] = str(old - reduce)
            notes.append(f"{axis}: wiederholtes Überschwingen, P testweise senken.")
        elif (axis != "yaw" and not noisy and len(bins) == 2 and 20 <= old < 75
              and result["overshoot"] < .05 and result["undershoot"] > .13):
            changes[key] = str(old + (min(3, max(1, round(old * .05))) if stage == 1 else 1))
            notes.append(f"{axis}: anhaltender Rückstand bei geringem Überschwingen, P testweise erhöhen.")
    for axis, stop in metrics.get("stop_summary", {}).items():
        key = f"f_{axis}"
        old = int(config.get(key, 0))
        if (not changes and not noisy and old >= 40 and min(stop["positive"], stop["negative"]) >= 2
                and stop["count"] >= 10 and stop["median_reverse_rate"] >= 8
                and stop["median_qualified_ff_share"] >= .60):
            changes[key] = str(old - min(10 if stage == 1 else 5, max(1, round(old * .08))))
            count = stop["positive"] + stop["negative"]
            notes.append(f"{axis}: {count} Stickstopps mit Rückschlag und überwiegendem Feedforward-Bremsanteil. "
                         "Feedforward in einem kleinen A/B-Schritt senken und Stickstopps erneut messen.")
    if any(key.startswith(("p_", "d_", "f_")) for key in changes) and config.get("simplified_pids_mode", "OFF") != "OFF":
        changes["simplified_pids_mode"] = "OFF"
    return changes, notes


def cli_block(profile, changes):
    if not changes:
        return ""
    target = f"profile {profile}\n" if profile is not None else ""
    return target + "".join(f"set {k} = {v}\n" for k, v in changes.items())


def filter_comparison(flights):
    profiles = [flight.get("filter_profile", {}) for flight in flights]
    result = {}
    for index in (1, 2, 3):
        rows = [profile["bands"][index] for profile in profiles if len(profile.get("bands", [])) > index]
        if rows and all(row.get("rpm_windows", 0) >= 8 and row["rpm_windows"] >= .95*row["windows"]
                        for row in rows):
            result[str(index)] = {key: float(np.median([row[key] for row in rows]))
                                  for key in ("raw_hf", "gyro_hf", "dterm_hf")}
    return result


def combine_metrics(flights):
    """Give each flight with usable data for a measurement equal weight."""
    axes = {}
    for axis in AXES:
        results = [item["axes"][axis] for item in flights]
        usable = [item for item in results if "amplitude" in item]
        axes[axis] = {key: sum(item[key] for item in results)
                      for key in ("events", "positive", "negative")}
        if usable:
            for key in ("amplitude", "overshoot", "error", "undershoot", "rebound"):
                axes[axis][key] = float(np.median([item[key] for item in usable]))
    noise = {}
    for band in ("low", "mid"):
        values = [item["noise"][band] for item in flights if band in item["noise"]]
        if values:
            noise[band] = np.median(values, axis=0).tolist()
    delays = {}
    for axis in AXES[:2]:
        values = [flight.get("filter_profile", {}).get("phase_delay_ms", {}).get(axis)
                  for flight in flights]
        if all(value is not None for value in values):
            delays[axis] = float(np.median(values))
    windows = {band: sum(item["windows"][band] for item in flights) for band in ("low", "mid")}
    return {"recovery_summary": summarize_recoveries(flights), "hz": round(np.median([item["hz"] for item in flights])), "axes": axes,
            "noise": noise, "windows": windows,
            "stop_summary": summarize_stops(flights),
            "filter_comparison": filter_comparison(flights), "filter_delay_ms": delays,
            "control_terms_available": any(item.get("control_terms_available") for item in flights)}


def selected_segments(paths, index, skipped):
    for path in paths:
        try:
            sessions = path.read_bytes().split(MARKER)[1:]
            require(sessions, "Kein Betaflight-Rohlog erkannt.")
            require(index is None or 1 <= index <= len(sessions),
                    f"Segment {index} fehlt. Datei enthält {len(sessions)} Segment(e).")
        except (ValueError, OSError) as exc:
            skipped.append(f"{path.name}: {exc}")
            continue
        for number, segment in enumerate(sessions, 1):
            if index is None or index == number:
                yield f"{path.name} · Segment {number}", segment


def describe_segment(headers, data):
    duration = (data[-1, 0] - data[0, 0]) / 1e6 if len(data) > 1 else 0
    label = f"{duration:.1f} s"
    if duration < 20:
        return label + " · unter 20 s"
    try:
        metrics = analyze(headers, data)
    except (ValueError, KeyError, IndexError) as exc:
        return f"{label} · {exc}"
    axes = metrics["axes"]
    windows = sum(metrics["windows"].values())
    return (f"{label} · gültige Impulse Roll {axes['roll']['events']}, "
            f"Pitch {axes['pitch']['events']} · {windows} ruhige Filterfenster")


def check_previous_config(previous, firmware, profile, config):
    expected = previous["config"] | previous["changes"]
    old_profile = previous["profile"]
    require(firmware == previous["firmware"] and
            (profile is None or old_profile is None or profile == old_profile),
            "Firmware oder PID-Profil weicht vom vorherigen Bericht ab.")
    if profile is not None and old_profile is not None:
        keys = config.keys() | expected.keys()
    else:
        keys = (config.keys() & expected.keys()) | previous["changes"].keys()
        require({"p_roll", "p_pitch", "p_yaw"} <= keys,
                "Zu wenige PID-Werte für den Vergleich mit der vorigen Runde.")
    if relative := previous.get("relative_slider"):
        kind = relative["kind"]
        label, multiplier, step, affected = SLIDERS[kind]
        keys -= {*affected, multiplier}
        before, after = expected.get(multiplier), config.get(multiplier)
        common = [key for key in affected if key in expected and key in config]
        changed = [key for key in common if config[key] != expected[key]]
        direction = 1 if step > 0 else -1
        valid = changed and all(
            0 < (int(config[key]) - int(expected[key])) * direction <= max(2, .20 * int(expected[key]))
            and min(int(config[key]), int(expected[key])) > 0 for key in changed)
        valid = valid and all(key in config for key in affected if key in expected)
        valid = valid and all(config[key] == "0" if expected[key] == "0" else config[key] != "0" for key in common)
        if kind != "master":
            valid = valid and any(key in changed for key in affected[:3])
        if kind == "master":
            valid = valid and all(
                f"p_{axis}" in common and config[f"p_{axis}"] != "0"
                for axis in AXES[:2]) and any(key in changed for key in ("p_roll", "p_pitch"))
        require(valid and (before is None or after is None or int(after) - int(before) == step),
                f"{label}: Der erwartete Slider-Schritt ist in den geloggten Einstellungen nicht belegt. "
                "Prüfe den Slider und flieg dieselbe Konfiguration erneut.")
    differences = sorted(key for key in keys if config.get(key) != expected.get(key))
    require(not differences, "Konfiguration weicht bei diesen Werten vom erwarteten Stand ab: "
            + ", ".join(differences))


def tune_signature(headers):
    # These values are measurements of the running RC link, not configured tuning parameters.
    dynamic = {"Log start datetime", "vbatref", "rc_smoothing_active_cutoffs_ff_sp_thr",
               "rc_smoothing_rx_smoothed"}
    return tuple(sorted((key, value) for key, value in headers.items() if key not in dynamic))


def steady_tracking(flights):
    result = {}
    for axis in AXES[:2]:
        samples = [flight.get("tracking", {}).get(axis, {}) for flight in flights]
        if samples and all(sample.get("steady_seconds", 0) >= 2 and
                           sample["near_motor_limit"] <= .01 for sample in samples):
            result[axis] = {key: float(np.median([sample[key] for sample in samples]))
                            for key in ("steady_rate", "steady_deficit", "relative_error")}
    return result


def relative_recommendation(metrics, config, flights, proposal, previous):
    noisy = noisy_bands(metrics)
    last = (previous or {}).get("relative_slider") or {}
    kind = None
    if (last.get("kind") != "dterm" and config.get("simplified_dterm_filter") == "ON" and
            noisy and all(noisy <= noisy_bands(flight) for flight in flights) and
            any(key in proposal for key in DTERM_CUTOFFS)):
        kind = "dterm"
    elif proposal or noisy or any(flight.get("short_events") or
            any(unresolved_resonance(peak) for peak in flight["resonance"]) for flight in flights):
        return None
    elif (last.get("kind") != "gyro" and config.get("simplified_gyro_filter") == "ON" and
          clean_gyro_bands(flights) and all(0 < int(config.get(key, 0)) <= 600
              for key in GYRO_CUTOFFS if int(config.get(key, 0)) > 0) and
          any(int(config.get(key, 0)) > 0 for key in GYRO_CUTOFFS)):
        kind = "gyro"
    elif (last.get("kind") != "master" and config.get("simplified_pids_mode") in ("RP", "RPY") and
          all(set(flight["noise"]) == {"low", "mid"} and
              all(max(values[4:6]) < 2.5 and max(values[6:]) < 3 for values in flight["noise"].values())
              and all(.10 <= sample["steady_deficit"] <= .25 for sample in steady_tracking([flight]).values())
              and len(steady_tracking([flight])) == 2
              and all(flight["estimated_steps"].get(axis, {}).get("overshoot", 1) <= .10
                      for axis in AXES[:2]) for flight in flights)):
        kind = "master"
    if kind is None:
        return None
    label, key, step, _ = SLIDERS[kind]
    current = config.get(key)
    if current is not None and not 50 <= int(current) + step <= 150:
        return None
    reason = {
        "dterm": "Wiederholtes hochfrequentes D-Term-Rauschen. Flieg erneut ruhige Geraden im betroffenen Gasbereich.",
        "gyro": "Saubere Spektren, geloggtes RPM und messbare Gyro-Filterverzögerung. Wiederhole die ruhigen Geraden.",
        "master": "Roll und Pitch bleiben bei gleichmässiger Drehung hinter dem Sollwert, bei vorhandener Motorreserve. Wiederhole dieselben Manöver.",
    }[kind]
    direction = "erhöhen" if step > 0 else "senken"
    values = f" ({int(current) / 100:.2f} → {(int(current) + step) / 100:.2f})" if current else ""
    return dict(kind=kind, instruction=f"{label} um {abs(step) / 100:.2f} {direction}{values}.",
                reason=reason, undo=f"{label} um {abs(step) / 100:.2f} zurückstellen.",
                tracking=steady_tracking(flights) if kind == "master" else {})


def compare_relative(relative, metrics, old_metrics, flights):
    kind = relative["kind"]
    if kind == "master":
        before, after = relative["tracking"], steady_tracking(flights)
        if not all(axis in after and abs(after[axis]["steady_rate"] / values["steady_rate"] - 1) <= .25
                   for axis, values in before.items()):
            return False, False, False, "Für den Master-Vergleich fehlen ähnlich schnelle Roll- und Pitch-Manöver."
        report = "Sollwertfehler Roll / Pitch · " + " und ".join(
            f"{before[axis]['relative_error']:.0%} → {after[axis]['relative_error']:.0%}" for axis in AXES[:2])
        improved = all(after[axis]["relative_error"] <= before[axis]["relative_error"] - .01 for axis in AXES[:2])
        degraded = any(after[axis]["relative_error"] > before[axis]["relative_error"] + .03 for axis in AXES[:2])
        return True, improved, degraded, report
    if kind == "dterm":
        bands = noisy_bands(old_metrics)
        if not bands <= metrics["noise"].keys():
            return False, False, False, "Für die Filterprüfung fehlen ruhige Fenster im zuvor auffälligen Gasbereich."
        before = max(max(old_metrics["noise"][band][4:6]) for band in bands)
        after = max(max(metrics["noise"][band][4:6]) for band in bands)
        return True, after <= .85 * before, False, f"D-Term-Rauschen · {before:.1f} → {after:.1f} RMS"
    bands = {"1", "2", "3"}
    before, after = old_metrics.get("filter_comparison", {}), metrics.get("filter_comparison", {})
    delays_before, delays_after = old_metrics.get("filter_delay_ms", {}), metrics.get("filter_delay_ms", {})
    if not bands <= (before.keys() & after.keys()) or not set(AXES[:2]) <= (delays_before.keys() & delays_after.keys()):
        return False, False, False, "Für den Gyro-Vergleich fehlen vergleichbare Frequenzdaten oder Filterverzögerungen."
    degraded = any(after[band][key] > before[band][key] * 1.25 + margin for band in bands
                   for key, margin in (("gyro_hf", .20), ("dterm_hf", .35)))
    a, b = (sum(values[axis] for axis in AXES[:2]) / 2 for values in (delays_before, delays_after))
    return True, b <= a - .15, degraded, f"Gyro-Filterverzögerung · {a:.2f} → {b:.2f} ms"


def measure_batch(args, decoder, history, stage, previous):
    dump = read_dump(args.dump) if args.dump else None
    groups, seen, skipped = {}, set(history), []
    for name, segment in selected_segments([args.log, *args.additional_log], args.index, skipped):
        try:
            headers, data, digest = decode_segment(segment, decoder)
            require(digest not in seen,
                    "Dieses Logsegment ist doppelt oder wurde in einer vorigen Runde ausgewertet.")
            seen.add(digest)
            firmware = headers["Firmware revision"]
            diagnostic = previous is None and not re.match(CLI_FIRMWARE, firmware) and bool(re.match(
                r"Betaflight (?:4\.5|2025\.12|2026\.6)\.\d+-(?:alpha|beta|RC)\b", firmware, re.I))
            profile, config = None, {}
            if not diagnostic:
                try:
                    firmware, profile, config = read_config(dump, headers)
                    if previous:
                        check_previous_config(previous, firmware, profile, config)
                except ValueError as exc:
                    skipped.append(f"{name}: {exc}\n   {describe_segment(headers, data)}")
                    continue
            flight = analyze(headers, data)
            # Round the observed lograte into 50 Hz buckets to avoid combining dissimilar sampling.
            key = (tune_signature(headers), round(flight["hz"] / 50))
            group = groups.setdefault(key, {"firmware": firmware, "profile": profile, "config": config,
                                            "sources": [], "digests": [], "diagnostic": diagnostic})
            group["sources"].append({"file": name, "metrics": flight})
            group["digests"].append(digest)
        except subprocess.CalledProcessError as exc:
            detail = (exc.stderr or b"").decode(errors="replace").strip()
            skipped.append(f"{name}: Decoderfehler. {detail}")
        except (ValueError, KeyError, IndexError, OSError, subprocess.TimeoutExpired) as exc:
            skipped.append(f"{name}: {exc}")
    require(groups, "Kein CLI-Vorschlag möglich. Prüfe die Hinweise zu den ausgewählten Segmenten."
            "\n\n" + "\n\n".join(skipped))
    for group in groups.values():
        flights = [source["metrics"] for source in group["sources"]]
        metrics = group["metrics"] = combine_metrics(flights)
        group["vibration"] = [source["file"] for source in group["sources"]
                              if strong_vibration(source["metrics"])]
        if not group["diagnostic"] and not group["vibration"] and stage < 3:
            group["proposal"], group["reasons"] = group_proposal(
                metrics, group["config"], stage, group["firmware"], flights, args.allow_filter_opening)
        else:
            group["proposal"], group["reasons"] = {}, []
        group["relative_slider"] = None
        if not group["diagnostic"] and not group["vibration"] and stage < 3:
            group["relative_slider"] = relative_recommendation(
                metrics, group["config"], flights, group["proposal"], previous)
        group["rank"] = (int(bool(group["proposal"] or group["relative_slider"]) and not previous), not group["diagnostic"],
                         len(metrics["noise"]),
                         sum("amplitude" in axis for axis in metrics["axes"].values()),
                         len(flights), sum(metrics["windows"].values()))
    # Resolve exact ties by the segment hash, independent of the order in the file picker.
    chosen = max(groups.values(), key=lambda group: (group["rank"], min(group["digests"])))
    other = sorted(source["file"] for group in groups.values() if group is not chosen
                   for source in group["sources"])
    skipped.extend(f"{name}: Anderer aufgezeichneter Tune oder abweichende Lograte."
                   for name in other)
    if len(groups) > 1:
        reason = ("Für diese Gruppe liegt ein begründeter Änderungsvorschlag vor."
                  if (chosen["proposal"] or chosen["relative_slider"]) and not previous else
                  "Diese Gruppe bietet die beste vergleichbare Messabdeckung.")
    else:
        reason = "Diese Segmente gehören zur selben aufgezeichneten Konfiguration."
    selection = {
        "reason": reason,
        "groups": len(groups),
        "used": sorted(source["file"] for source in chosen["sources"]),
        "other": other,
        "skipped_count": len(skipped),
    }
    return chosen, skipped, selection


def strong_vibration(metrics):
    return any(max(values[6:]) > 7 or max(values[2:4]) > 22
               for values in metrics["noise"].values())


def tracking_notes(sources):
    notes = []
    for source in sources:
        details = []
        for axis, result in source["metrics"]["tracking"].items():
            error = result["median_error"]
            difference = f", mediane Abweichung {error:.0f} °/s" if error is not None else ""
            details.append(f"{axis.title()} {result['seconds']:.1f} s bei Sollrate ≥120 °/s "
                           f"(95. Perzentil {result['command_p95']:.0f} °/s{difference}, "
                           f"{result['near_motor_limit']:.0%} nahe Motorausgangsgrenze)")
        if details:
            notes.append(f"Freiflug in {source['file']}: " + " · ".join(details) + ".")
    return notes


def suppress_resonance_gains(changes, peaks):
    axes = {peak["axis"] for peak in peaks if unresolved_resonance(peak)}
    excluded = {f"{term}_{axis}" for term in ("p", "d", "d_min", "d_max", "f") for axis in axes}
    filtered = {key: value for key, value in changes.items() if key not in excluded}
    if not any(key.startswith(("p_", "d_", "f_")) for key in filtered):
        filtered.pop("simplified_pids_mode", None)
    return filtered


def clean_gyro_bands(flights):
    for flight in flights:
        profile = flight.get("filter_profile", {})
        bands = profile.get("bands", [])[1:4]
        delays = profile.get("phase_delay_ms", {})
        if (not profile.get("rpm_configured") or len(bands) != 3 or len(delays) != 2
                or min(delays.values()) < 2 or any(b.get("rpm_windows", 0) < 8
                   or b["rpm_windows"] < .95*b["windows"] or b["raw_hf"] > 15
                   or b["gyro_hf"] > .8 or b["dterm_hf"] > 1.5 for b in bands)):
            return False
    return True


def filter_opening(config, flights):
    # An explicit A/B test of one static gyro LPF, with logged RPM reception
    # and repeatable clean spectra through the working throttle range.
    old = int(config.get(GYRO_LPF1, 0))
    if (not 80 <= old <= 250 or int(config.get("gyro_lpf1_dyn_min_hz", -1)) != 0
            or config.get("simplified_gyro_filter") != "OFF"):
        return {}
    if not clean_gyro_bands(flights):
        return {}
    return {GYRO_LPF1: str(old + max(1, min(10, round(old*.05))))}


def group_proposal(metrics, config, stage, firmware, flights, allow_filter_opening=False):
    changes, notes = propose(metrics, config, stage, firmware)
    peaks = [peak for flight in flights for peak in flight["resonance"]]
    resonance_axes = sorted({peak["axis"] for peak in peaks if unresolved_resonance(peak)})
    if resonance_axes:
        notes.append(f"Schmalbandige, nicht kommandierte Schwingung auf {', '.join(resonance_axes)}. "
                     "Mechanik, Filterung und Reglerschwingung prüfen. Gain-Änderungen für diese Achsen zurückgestellt.")
        changes = suppress_resonance_gains(changes, peaks)
    tightening = any(key in changes for key in (DYNL, DYNH, STATIC))
    if allow_filter_opening and stage == 1 and not tightening and not resonance_axes:
        opening = filter_opening(config, flights)
        if opening:
            changes = opening
            notes = ["A/B-Test: statischen Gyro-LPF1 leicht öffnen. Messung, Motorwärme und Flugverhalten danach erneut prüfen."]
        else:
            notes.append("Filteröffnung zurückgestellt: Prüfe RPM-Abdeckung, saubere Spektren, messbare Verzögerung und aktiven statischen LPF1.")
    if GYRO_LPF1 in changes or any(key in changes for key in (DYNL, DYNH, STATIC)):
        changes = {key: value for key, value in changes.items()
                   if key in (GYRO_LPF1, DYNL, DYNH, STATIC, "simplified_dterm_filter")}
        notes.append("Filter zuerst: Gains mit dem Folgeflug separat bewerten.")
    if any(config.get(f"f_{a}") != "0" for a in AXES):
        notes.append("P/D-Balance: Nur Achsen mit nachweislich deaktiviertem Feedforward werden für P/D-Vorschläge berücksichtigt. "
                     "Dämpfung und Tracking mit vergleichbaren Testflügen getrennt prüfen.")
    return changes, notes


def equivalent_dterm_slider(firmware, config, changes):
    key = "simplified_dterm_filter_multiplier"
    cutoffs = {DYNL: 75, DYNH: 150, STATIC: 75, "dterm_lpf2_static_hz": 150}
    if (changes.get("simplified_dterm_filter") != "OFF"
            or not firmware.startswith(("Betaflight 4.5.2 ", "Betaflight 2026.6.2 "))
            or config.get("simplified_dterm_filter") != "ON"
            or not config.get(key, "").isdecimal() or not cutoffs.keys() <= config.keys()):
        return changes
    active = {name: base for name, base in cutoffs.items() if int(config[name]) > 0}
    current = int(config[key])
    if active and all(int(config[name]) == base * current // 100 for name, base in active.items()):
        for target in range(current - 1, max(0, current - 16), -1):
            if all(base * target // 100 == int(changes.get(name, config[name])) for name, base in active.items()):
                return {name: value for name, value in (changes | {key: str(target)}).items()
                        if name != "simplified_dterm_filter"}
    return changes


def slider_guidance(config, changes, sources, blocked):
    """Show an equivalent slider only when its complete set of effects matches."""
    if blocked:
        return []
    guidance = []
    opening = changes.get(GYRO_LPF1)
    if opening:
        guidance.append(f"Gyro-LPF1 · {config[GYRO_LPF1]} → {opening} Hz. Vergleiche Gyro-Rauschen und Filterverzögerung.")
    cutoffs = {DYNL: 75, DYNH: 150, STATIC: 75, "dterm_lpf2_static_hz": 150}
    changed = set(changes) & cutoffs.keys()
    if changed:
        values = ", ".join(f"{config[key]} → {changes[key]} Hz ({label})"
                           for key, label in ((DYNL, "Dyn. Minimum"), (DYNH, "Dyn. Maximum"), (STATIC, "Statisch"))
                           if key in changed)
        guidance.append(f"D-Term-LPF1 · {values}. Vergleiche das Rauschen im selben Gasbereich.")
        key = "simplified_dterm_filter_multiplier"
        if key in changes:
            guidance.append(f"D-Term Filter Multiplier · {int(config[key]) / 100:.2f} → {int(changes[key]) / 100:.2f}. Für die nächste Runde den aktuellen CLI-Dump mitliefern.")
    for kind, mode, offered in (("gyro", "simplified_gyro_filter", bool(opening)),
                                ("dterm", "simplified_dterm_filter", bool(changed))):
        if offered or config.get(mode) != "ON":
            continue
        label, key, _, _ = SLIDERS[kind]
        value = config.get(key)
        current = f"Bei {int(value) / 100:.2f} belassen." if value and value.isdecimal() else "Aktuellen Wert beibehalten."
        coverage = all(set(source["metrics"]["noise"]) == {"low", "mid"} for source in sources)
        if not coverage:
            guidance.append(f"{label} · Messung offen. Für die Beurteilung fehlen ruhige Passagen in einem Gasbereich.")
        elif kind == "dterm" and any(noisy_bands(source["metrics"]) for source in sources):
            guidance.append(f"{label} · D-Term-Rauschen prüfen. Wiederhole ruhige Geraden im auffälligen Gasbereich.")
        else:
            guidance.append(f"{label} · {current} Die Messung begründet aktuell keinen Slider-Schritt.")
    gains = [(key, value) for key, value in changes.items() if key.startswith(("p_", "d_", "f_")) and key not in cutoffs]
    if gains:
        guidance.append("PID und Feedforward · " + ", ".join(f"{key} {config[key]} → {value}" for key, value in sorted(gains))
                        + ". Wiederhole die Manöver der betroffenen Achsen.")
    if any(source["metrics"].get("short_events") for source in sources):
        multiplier = config.get("simplified_master_multiplier", "")
        current = f"Bei {int(multiplier) / 100:.2f} belassen." if multiplier.isdecimal() else "Aktuellen Wert beibehalten."
        guidance.append(f"Master Multiplier · {current} Im Log fallen kurze Schwingungen ohne starken Stickbefehl auf.")
    return guidance


def run(args):
    decoder = str(Path(args.decoder).resolve()) if Path(args.decoder).is_file() else args.decoder
    previous = json.loads(args.previous.read_text()) if args.previous else None
    stage = previous["stage"] + 1 if previous else 1
    require(stage <= 3, "Diese Messreihe ist nach Flug 3 abgeschlossen.")
    history = previous["history"] if previous else []
    if previous:
        require(not previous["blocked"], "Vorheriges Ergebnis ist blockiert. Ursache klären und Messreihe neu starten.")
    group, skipped, selection = measure_batch(args, decoder, history, stage, previous)
    firmware, profile, config = group["firmware"], group["profile"], group["config"]
    metrics, sources, digests = group["metrics"], group["sources"], group["digests"]
    notes = ["Übersprungen: " + item for item in skipped] + tracking_notes(sources)
    diagnostic = group["diagnostic"]
    if diagnostic:
        notes.append("Vorab-Firmware · Messwerte ausgewertet. Für diese Firmware-Version ist die CLI-Zuordnung ungeprüft.")
    elif profile is None and group["proposal"] and not group["relative_slider"]:
        notes.append("Ohne Dump: Vor dem Einfügen das geflogene PID-Profil auswählen und "
                     "die aktuellen Werte gegen die angezeigten Ausgangswerte prüfen.")
    changes = {}
    status = "Diagnose · Vorab-Firmware" if diagnostic else "prüfen"
    blocked = diagnostic
    relative = None
    comparison = None
    if previous:
        if profile is None or previous["profile"] is None:
            notes.append("Folgerunde ohne durchgehenden Dump-Abgleich: Die im Log belegten Werte wurden geprüft.")
        old_metrics = previous["metrics"]
        axes = comparable_axes(metrics, old_metrics)
        changed_axes = {axis for axis in AXES if any(
            f"{term}_{axis}" in previous["changes"] for term in ("p", "d", "d_min", "d_max"))}
        shared_bands = metrics["noise"].keys() & old_metrics["noise"].keys()
        ff_axes = [axis for axis in AXES if f"f_{axis}" in previous["changes"]]
        stop_comparison = [(metrics.get("stop_summary", {}).get(axis),
                            old_metrics.get("stop_summary", {}).get(axis)) for axis in ff_axes]
        stop_data_ready = all(a and b and a["count"] >= 6 and b["count"] >= 6
                              and min(a.get("observed_positive", 0), a.get("observed_negative", 0)) >= 2
                              and abs(a["median_command_peak"] / b.get("median_command_peak", 1) - 1) <= .35
                              for a, b in stop_comparison)
        stop_worse = stop_data_ready and any(
            a["median_reverse_rate"] > b["median_reverse_rate"] * 1.2 + 3 for a, b in stop_comparison)
        reopened = GYRO_LPF1 in previous["changes"]
        before_filters = old_metrics.get("filter_comparison", {})
        after_filters = metrics.get("filter_comparison", {})
        opening_bands = {"1", "2", "3"}
        opening_ready = not reopened or opening_bands <= (before_filters.keys() & after_filters.keys())
        opening_worse = reopened and opening_ready and any(
            after_filters[k][field] > before_filters[k][field]*1.25 + margin
            for k in opening_bands for field, margin in (("gyro_hf", .20), ("dterm_hf", .35)))
        tightened = any(key in previous["changes"] for key in (DYNL, DYNH, STATIC))
        missing_filter_bands = noisy_bands(old_metrics) - shared_bands if tightened else set()
        if missing_filter_bands:
            ranges = {"low": "20–40 %", "mid": "40–65 %"}
            notes.append("Für die Filterprüfung fehlen ruhige Messfenster im zuvor auffälligen Gasbereich "
                         + ", ".join(ranges[b] for b in sorted(missing_filter_bands)) + ".")
        if previous_slider := previous.get("relative_slider"):
            ready, improved, degraded, detail = compare_relative(
                previous_slider, metrics, old_metrics, [source["metrics"] for source in sources])
            oscillations = any(source["metrics"].get("short_events") for source in sources)
            previous_oscillations = any(source["metrics"].get("short_events") for source in previous["logs"])
            degraded = degraded or bool(group["vibration"]) or worse(metrics, old_metrics, axes)
            degraded = degraded or (oscillations and not previous_oscillations)
            if degraded:
                status = "Slider-Rücknahme empfohlen"
                blocked = True
                comparison = detail + " · " + previous_slider["undo"]
            elif not ready or not shared_bands:
                status = "Slider-Vergleich offen"
                blocked = True
                comparison = detail if not ready else "Für den Vergleich fehlen gemeinsame Gasbereiche."
            elif not improved:
                status = "Kein klarer Nutzen"
                blocked = True
                comparison = detail + " · " + previous_slider["undo"]
            else:
                status = "Verbesserung im Vergleich"
                comparison = detail
        elif missing_filter_bands or not shared_bands or not changed_axes.issubset(axes) or not stop_data_ready or not opening_ready:
            blocked = True
            status = "Vergleich offen"
            notes.append("Die Manöver oder Gasbereiche sind zu verschieden für eine Verifikation.")
        elif opening_worse or stop_worse or worse(metrics, old_metrics, axes):
            status = "Rücknahme prüfen"
            notes.append("Mindestens eine vergleichbare Kennzahl hat sich deutlich verschlechtert.")
            changes = {key: previous["config"][key] for key in previous["changes"]}
            blocked = True
        else:
            status = "Keine klare Verschlechterung"
            notes.append("Im vergleichbaren Messbereich liegt keine deutliche Verschlechterung vor.")
            if reopened:
                previous_delay = old_metrics.get("filter_delay_ms", {})
                current_delay = metrics.get("filter_delay_ms", {})
                overlap = sorted(previous_delay.keys() & current_delay.keys())
                for axis in overlap:
                    notes.append(f"{axis}: geschätzte Verzögerung der Gyro-Filterkette "
                                 f"{previous_delay[axis]:.2f} → {current_delay[axis]:.2f} ms.")
                if not overlap:
                    notes.append("Rauschen vergleichbar. Für eine Aussage zum Verzögerungsgewinn fehlt eine gemeinsame Messung.")
            for axis, (current, old) in zip(ff_axes, stop_comparison):
                notes.append(f"{axis}: mediane Gegenrotation nach Stickstopp "
                             f"{old['median_reverse_rate']:.1f} → {current['median_reverse_rate']:.1f} °/s.")
    vibration_logs = group["vibration"]
    if vibration_logs and not blocked:
        status = "Starke Vibration prüfen"
        notes.append("Starke Vibration in " + ", ".join(vibration_logs) + ". Props, Motoren und Aufbau prüfen.")
        blocked = True
    if not blocked and stage < 3:
        relative = group["relative_slider"]
        changes = {} if relative else equivalent_dterm_slider(firmware, config, group["proposal"])
        notes.extend(group["reasons"])
        if relative:
            status = "Slider-Schritt zur Flugprüfung"
        elif changes:
            status = "CLI-Vorschlag zur Flugprüfung"
        elif not previous:
            status = "Keine Änderung abgeleitet"
    restore = {key: config[key] for key in changes}
    report = dict(stage=stage, firmware=firmware, profile=profile, config=config,
                  metrics=metrics, changes=changes, status=status, notes=notes,
                  blocked=blocked, history=[*history, *digests], logs=sources, skipped=skipped,
                  selection=selection, diagnostic=diagnostic, relative_slider=relative, slider_comparison=comparison, slider_guidance=slider_guidance(config, changes, sources, blocked))
    args.report.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    target = "Messwerte" if diagnostic else (f"PID-Profil {profile}" if profile is not None else "PID-Profil manuell prüfen")
    print(f"Runde {stage}/3 · {len(sources)} Log(s) | {firmware} | {target} | {status}")
    print(selection["reason"])
    print("Verwendet: " + ", ".join(selection["used"]))
    print(json.dumps(metrics, indent=2, ensure_ascii=False))
    for note in [*notes, *report["slider_guidance"]]:
        print("- " + note)
    if relative:
        print(relative["instruction"], relative["reason"], relative["undo"], sep="\n")
    if comparison:
        print(comparison)
    if changes:
        if profile is None:
            print("\nErwartete aktuelle Werte vor dem Übernehmen\n" + cli_block(None, restore))
        print("\nCLI-Block (Werte prüfen, dann separat per save übernehmen)\n" + cli_block(profile, changes))
        if status != "Rücknahme prüfen":
            print("Rücknahmeblock für diesen Flug\n" + cli_block(profile, restore))
    print(f"\nBericht: {args.report}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, help="Betaflight-Blackbox-Rohlog")
    parser.add_argument("--additional-log", type=Path, action="append", default=[],
                        help="Weiteres Rohlog mit derselben Konfiguration (wiederholbar)")
    parser.add_argument("--dump", type=Path, help="Optional: CLI-Ausgabe von dump zur Profil- und Konfigurationsprüfung")
    parser.add_argument("--report", type=Path, required=True, help="Neuer JSON-Bericht")
    parser.add_argument("--previous", type=Path, help="JSON-Bericht des vorherigen Flugs")
    parser.add_argument("--index", type=int, help="Optional: nur diese Segmentnummer ab 1 je Datei auswerten")
    parser.add_argument("--allow-filter-opening", action="store_true",
                        help="Optionalen A/B-Vorschlag für weniger Gyrofilterung prüfen")
    parser.add_argument("--decoder", default="blackbox_decode")
    args = parser.parse_args()
    try:
        require(not args.report.exists(), "Bericht existiert bereits. Neuen Dateinamen wählen.")
        run(args)
    except subprocess.CalledProcessError as exc:
        parser.exit(2, "Decoderfehler: " + (exc.stderr or b"").decode(errors="replace") + "\n")
    except (ValueError, KeyError, IndexError, OSError, subprocess.TimeoutExpired) as exc:
        parser.exit(2, f"Analyse abgebrochen: {exc}\n")


if __name__ == "__main__":
    main()
