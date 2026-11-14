#!/usr/bin/env python3
"""Run isolated audio regression checks: python3 Tests/check_audio.py.

Compile the production muter against simulated CoreAudio calls so these checks
never change real output volume or require a connected Bluetooth headset.
Compile the production recorder unchanged for synthetic PCM conversion checks.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="popy-audio-checks-") as temp:
    temp = Path(temp)
    source = (root / "Popy/Services/SystemAudioMuter.swift").read_text()
    for original, fake in [
        ("AudioObjectGetPropertyDataSize", "fakeGetSize"),
        ("AudioObjectGetPropertyData", "fakeGet"),
        ("AudioObjectSetPropertyData", "fakeSet"),
        ("AudioObjectHasProperty", "fakeHasProperty"),
        ("AudioObjectIsPropertySettable", "fakeIsSettable"),
    ]:
        source = source.replace(original, fake)
    simulated = temp / "SystemAudioMuter.swift"
    simulated.write_text(source)
    for production, checks, name in [
        (simulated, root / "Tests/SystemAudioMuterChecks.swift", "muter"),
        (root / "Popy/Services/AudioRecorder.swift", root / "Tests/AudioConversionChecks.swift", "conversion"),
    ]:
        binary = temp / name
        subprocess.run(["xcrun", "swiftc", str(production), str(checks), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
