"""Real signals sent only to disposable uninstall fixture subprocesses."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

harness = str(Path(sys.argv[1]).resolve())
root = Path(sys.argv[2]).resolve()
root.mkdir(parents=True, exist_ok=True)
for phase in ("before", "after"):
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        case = root / f"{phase}-{sig.name}"
        case.mkdir()
        with (case / "process.log").open("w") as log:
            process = subprocess.Popen(
                ["bash", harness, "--signal-fixture", phase, str(case)],
                stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
            )
            try:
                deadline = time.monotonic() + 20
                ready = case / "ready"
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.05)
                if not ready.exists():
                    raise AssertionError(f"Fixture did not become ready: {case}")
                pid = int(ready.read_text().strip())
                # Verify the PID belongs to this disposable process group.
                assert os.getpgid(pid) == process.pid
                os.kill(pid, sig)
                result = process.wait(timeout=10)
                assert result == 128 + sig, (sig, result)
                home = case / "home données with spaces"
                manager_state = home / "state/my-equicord-setup"
                journal = (manager_state / "uninstall.tsv").read_text()
                expected = "uninjection-started" if phase == "before" else "cleanup-started"
                assert f"stage\t{expected}\n" in journal
                assert (home / "data/my-equicord-setup/Equicord").is_dir()
                backup = home / "clients/Discord/resources/_app.asar"
                assert backup.exists() == (phase == "before")
                print(f"ok - real {sig.name}, {phase} restoration: journal and files preserved")
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=5)
