"""Zoom meeting recorder.

Records system audio (speaker loopback) + default microphone as a single
mono M4A file, but only while a Zoom meeting is actually in progress.

Meeting detection is based on the presence of CptHost.exe ("Zoom Sharing
Host"), which Zoom.exe spawns exactly when a meeting starts and terminates
when the meeting ends.
"""

import logging
import logging.handlers
import os
import queue
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime

import numpy as np
import psutil
import soundcard as sc

CONFIG = {
    "output_dir": r"D:\video_cast\zoom",
    "log_file": r"D:\video_cast\zoom\recorder.log",
    "log_max_bytes": 1_000_000,
    "log_backup_count": 3,
    "meeting_process": "cpthost.exe",
    "poll_interval": 2.0,
    "stop_debounce": 5.0,
    "min_duration": 3.0,
    "sample_rate": 48000,
    "block_frames": 4800,
    "aac_bitrate": "128k",
    "ffmpeg": "ffmpeg",
}

CREATE_NO_WINDOW = 0x08000000

log = logging.getLogger("zoom_recorder")


def setup_logging():
    os.makedirs(CONFIG["output_dir"], exist_ok=True)
    log.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
    fh = logging.handlers.RotatingFileHandler(
        CONFIG["log_file"],
        maxBytes=CONFIG["log_max_bytes"],
        backupCount=CONFIG["log_backup_count"],
        encoding="utf-8",
    )
    fh.setFormatter(fmt)
    log.addHandler(fh)


def meeting_active():
    target = CONFIG["meeting_process"]
    for proc in psutil.process_iter(["name"]):
        try:
            name = proc.info.get("name")
            if name and name.lower() == target:
                return True
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    return False


class Recorder:
    def __init__(self):
        self.rate = CONFIG["sample_rate"]
        self.block = CONFIG["block_frames"]
        self.output_dir = CONFIG["output_dir"]
        self._stop = threading.Event()
        self._queues = {}
        self._threads = []
        self._ffmpeg = None
        self._writer = None
        self.frames_written = 0
        self.path = None

    def _open_devices(self):
        speaker = sc.default_speaker()
        loopback = sc.get_microphone(id=str(speaker.name), include_loopback=True)
        mic = sc.default_microphone()
        return loopback, mic

    def _reader(self, name, device, channels):
        q = self._queues[name]
        try:
            with device.recorder(samplerate=self.rate, channels=channels) as rec:
                while not self._stop.is_set():
                    data = rec.record(numframes=self.block)
                    q.put(data)
        except Exception as exc:  # device disappeared / busy
            log.error("reader %s failed: %s", name, exc)
            self._stop.set()

    def _writer_loop(self):
        try:
            spk_block = self._queues["spk"].get(timeout=3.0)
            mic_block = self._queues["mic"].get(timeout=3.0)
        except queue.Empty:
            log.error("no audio data received; aborting recording")
            self._stop.set()
            return

        spk_ch = spk_block.shape[1] if spk_block.ndim > 1 else 1
        mic_ch = mic_block.shape[1] if mic_block.ndim > 1 else 1
        buf_spk = np.empty((0, spk_ch), dtype=np.float32)
        buf_mic = np.empty((0, mic_ch), dtype=np.float32)
        buf_spk = np.concatenate([buf_spk, spk_block.reshape(-1, spk_ch)])
        buf_mic = np.concatenate([buf_mic, mic_block.reshape(-1, mic_ch)])

        def drain():
            nonlocal buf_spk, buf_mic
            while True:
                try:
                    block = self._queues["spk"].get_nowait()
                    buf_spk = np.concatenate([buf_spk, block.reshape(-1, spk_ch)])
                except queue.Empty:
                    break
            while True:
                try:
                    block = self._queues["mic"].get_nowait()
                    buf_mic = np.concatenate([buf_mic, block.reshape(-1, mic_ch)])
                except queue.Empty:
                    break

        while True:
            drain()
            n = min(len(buf_spk), len(buf_mic))
            if n == 0:
                if self._stop.is_set():
                    break
                time.sleep(0.005)
                continue

            spk = buf_spk[:n].mean(axis=1)
            mic = buf_mic[:n].mean(axis=1)
            buf_spk = buf_spk[n:]
            buf_mic = buf_mic[n:]

            mix = 0.5 * spk + 0.5 * mic
            np.clip(mix, -1.0, 1.0, out=mix)
            try:
                self._ffmpeg.stdin.write(mix.astype("<f4").tobytes())
                self.frames_written += n
            except (BrokenPipeError, OSError) as exc:
                log.error("ffmpeg pipe failed: %s", exc)
                self._stop.set()
                break
        try:
            self._ffmpeg.stdin.flush()
        except (BrokenPipeError, OSError):
            pass

    def start(self):
        loopback, mic = self._open_devices()
        now = datetime.now()
        day_dir = os.path.join(self.output_dir, now.strftime("%Y-%m-%d"))
        os.makedirs(day_dir, exist_ok=True)
        name = "Zoom_" + now.strftime("%Y%m%d_%H%M%S") + ".m4a"
        self.path = os.path.join(day_dir, name)
        cmd = [
            CONFIG["ffmpeg"], "-hide_banner", "-loglevel", "error", "-y",
            "-f", "f32le", "-ar", str(self.rate), "-ac", "1", "-i", "pipe:0",
            "-c:a", "aac", "-b:a", CONFIG["aac_bitrate"],
            "-movflags", "+faststart", self.path,
        ]
        self._ffmpeg = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, creationflags=CREATE_NO_WINDOW,
        )
        self._stop.clear()
        self._queues = {"spk": queue.Queue(), "mic": queue.Queue()}
        self._threads = [
            threading.Thread(target=self._reader, args=("spk", loopback, None), daemon=True),
            threading.Thread(target=self._reader, args=("mic", mic, 1), daemon=True),
        ]
        for t in self._threads:
            t.start()
        self._writer = threading.Thread(target=self._writer_loop, daemon=True)
        self._writer.start()
        log.info("recording started -> %s", self.path)

    def stop(self):
        self._stop.set()
        for t in self._threads:
            t.join(timeout=3.0)
        if self._writer is not None:
            self._writer.join(timeout=10.0)
        if self._ffmpeg is not None:
            try:
                if self._ffmpeg.stdin:
                    self._ffmpeg.stdin.close()
            except OSError:
                pass
            try:
                _, err = self._ffmpeg.communicate(timeout=30.0)
                if err:
                    log.warning("ffmpeg: %s", err.decode("utf-8", "replace").strip())
            except subprocess.TimeoutExpired:
                self._ffmpeg.kill()
                log.error("ffmpeg did not exit in time; killed")
        duration = self.frames_written / self.rate
        if duration < CONFIG["min_duration"]:
            log.info("recording too short (%.1fs), removing %s", duration, self.path)
            try:
                if self.path and os.path.exists(self.path):
                    os.remove(self.path)
            except OSError as exc:
                log.error("cannot remove short file: %s", exc)
        else:
            log.info("recording finished -> %s (%.1fs)", self.path, duration)
        self.frames_written = 0
        self._ffmpeg = None
        self._writer = None
        self._threads = []


def main():
    stop_event = threading.Event()

    def handle_signal(signum, frame):
        stop_event.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(sig, handle_signal)
        except (ValueError, OSError):
            pass

    log.info("zoom_recorder started (watching %s)", CONFIG["meeting_process"])
    recorder = None
    inactive_since = None

    try:
        while not stop_event.is_set():
            active = meeting_active()
            if recorder is None:
                if active:
                    try:
                        recorder = Recorder()
                        recorder.start()
                        inactive_since = None
                    except Exception as exc:
                        log.error("cannot start recording: %s", exc)
                        recorder = None
                        time.sleep(CONFIG["poll_interval"])
            else:
                if active:
                    inactive_since = None
                else:
                    if inactive_since is None:
                        inactive_since = time.monotonic()
                    elif time.monotonic() - inactive_since >= CONFIG["stop_debounce"]:
                        recorder.stop()
                        recorder = None
                        inactive_since = None
            stop_event.wait(CONFIG["poll_interval"])
    finally:
        if recorder is not None:
            log.info("shutting down, finalizing current recording")
            recorder.stop()
        log.info("zoom_recorder stopped")


if __name__ == "__main__":
    setup_logging()
    main()