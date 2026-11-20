"""Generate a synthetic Betaflight 2026.6.2 log with a real slow-frame mode bit."""
import sys
from pathlib import Path

import numpy as np


def unsigned_vb(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def write_fixture(path):
    fields = ["loopIteration", "time", "setpoint[3]"]
    fields += [f"{name}[{axis}]" for axis in range(3) for name in ("setpoint", "gyroADC", "gyroUnfilt")]
    fields += ["axisD[0]", "axisD[1]", *(f"motor[{axis}]" for axis in range(4))]
    headers = {
        "Product": "Blackbox flight data recorder by Nicholas Sherlock",
        "Firmware type": "Cleanflight",
        "Firmware revision": "Betaflight 2026.6.2 (012345678) TEST",
        "I interval": "1", "P interval": "1", "Data version": "2", "motorOutput": "100,2000",
        "blackbox_high_resolution": "1", "gyro_scale": "0x3f800000",
        "dterm_lpf1_static_hz": "75", "dterm_lpf1_dyn_hz": "75,150",
        "ff_weight": "0,0,0", "d_max": "38,38,38",
        **{f"{axis}PID": "48,80,32" for axis in ("roll", "pitch", "yaw")},
        "Field I name": ",".join(fields), "Field I signed": ",".join(["1"] * len(fields)),
        "Field I predictor": ",".join(["0"] * len(fields)), "Field I encoding": ",".join(["0"] * len(fields)),
        "Field S name": "flightModeFlags", "Field S signed": "0",
        "Field S predictor": "0", "Field S encoding": "1",
    }
    time = np.arange(8000) / 1000
    chirp = 90 * np.sin(2 * np.pi * (5 * time + 5 * time**2))
    gyro = .8 * np.roll(chirp, 3)
    with path.open("wb") as f:
        f.write("".join(f"H {key}:{value}\n" for key, value in headers.items()).encode())
        for i in range(26000):
            active = 3000 <= i < 11000
            if i in (0, 3000, 11000):
                f.write(b"S" + unsigned_vb(64 if active else 0))
            x = round(chirp[i - 3000] * 10) if active else 0
            y = round(gyro[i - 3000] * 10) if active else 0
            row = [i, i * 1000, 300 if i < 16000 else 470, x, y, y, *([0] * 8), *([900] * 4)]
            f.write(b"I" + b"".join(unsigned_vb(2 * value if value >= 0 else -2 * value - 1) for value in row))


if __name__ == "__main__":
    write_fixture(Path(sys.argv[1]))
