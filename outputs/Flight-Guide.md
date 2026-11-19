# Blackbox Auto-Tune · Flight guide

1. Enable Blackbox logging. Include setpoint, PID terms, gyro, unfiltered gyro and motor outputs.
2. Fly in Acro (Air). Make a few straight passes, first at easy forward-flight throttle and then with a little more. Hold throttle roughly steady for a few seconds and turn between passes.
3. Fly several separate rolls and flips in both directions. Move one axis at a time, center the stick afterward and let the quad settle. Leave some throttle in reserve.
4. For a propwash comparison, add a few similar low-throttle descents and throttle recoveries with minimal roll or pitch input.
5. Select logs flown with the same settings. A Betaflight CLI dump is optional. The dashboard shows what the log covers, any tuning suggestion and what to fly next.
6. Record the original settings, then test the suggested change on its own. Repeat similar maneuvers on the follow-up flight. Compare the measurements and check motor temperature after landing.

Reports are kept locally. In the installed app, use **Show report in Finder** to find them. CLI commands and relative slider steps include a way to undo the change.
