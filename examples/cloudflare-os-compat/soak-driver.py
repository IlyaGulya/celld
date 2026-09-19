#!/usr/bin/env python3
"""The load half of the fleet soak: writes, reads, and the bars they must meet.

It drives two celld nodes through `soak-test.sh` and reports one JSON object on
stdout for the orchestrator to judge. Nothing here talks to S3 directly; the
orchestrator measures the bucket.

The invariants are the ones a durability claim rests on:

- **no lost acknowledged write** - every value the writer saw acknowledged is
  readable afterwards, and reads never move backwards (RPO=0);
- **no invented write** - a read never exceeds the highest value acknowledged by
  any writer before it, so a failover cannot serve state that was never written;
- **errors only while ownership turns over** - a call may fail inside the window
  that starts with a SIGKILL, and must not fail outside it;
- **bridges retire** - the origin node's `rpc_bridge_handles` returns to zero
  once the load stops, and stays bounded while it runs.
"""
import argparse
import json
import random
import threading
import time
import urllib.error
import urllib.request

FAILURE = object()


class Metrics:
    """What the soak has to prove, counted where it can be counted soundly.

    A client's acknowledgement is a *lower* bound on durable state, not an upper
    one: a write whose response is lost - the node was killed while answering -
    can still be committed, so a read above the last acknowledged value is not
    invented state. Three facts are sound and together they cover the same
    ground:

    - a read is only required to see what was acknowledged *before it started*,
      so the reader samples the frontier first (a concurrent writer's in-flight
      value is not a rollback);
    - every value the client saw acknowledged has to stay readable (`final_read`
      is at least `max_acknowledged`);
    - a read can never exceed the number of increments the client asked for, so
      `final_read` above `write_attempts` would be state nobody wrote.
    """

    def __init__(self):
        self.lock = threading.Lock()
        self.ok = 0
        self.errors = 0
        self.turnover_errors = 0
        self.rollbacks = 0
        self.max_acknowledged = 0
        self.max_read = 0
        self.latencies = []
        self.unexpected = []
        self.reads = 0
        self.writes = 0
        # Every increment the client asked for, including the ones whose reply
        # it never saw: those are the only writes that can be durable without
        # being acknowledged.
        self.write_attempts = 0
        self.write_unknown = 0

    def frontier(self):
        with self.lock:
            return self.max_acknowledged

    def record_attempt(self, write):
        with self.lock:
            if write:
                self.write_attempts += 1

    def record_unknown_write(self):
        with self.lock:
            self.write_unknown += 1

    def record_ok(self, latency, value=None, write=False, frontier=0):
        with self.lock:
            self.ok += 1
            self.latencies.append(latency)
            if write:
                self.writes += 1
                if value is not None:
                    self.max_acknowledged = max(self.max_acknowledged, value)
            else:
                self.reads += 1
                if value is not None:
                    if value < frontier:
                        self.rollbacks += 1
                    self.max_read = max(self.max_read, value)

    def record_error(self, turnover, detail, at):
        with self.lock:
            self.errors += 1
            if turnover:
                self.turnover_errors += 1
            elif len(self.unexpected) < 20:
                self.unexpected.append(f"{at}s {detail}")


class Window:
    """The interval in which a failed call is expected: kill to rejoin.

    A success on the surviving node says nothing about the killed one, so only
    the orchestrator's rejoin timestamp closes the window, plus a settle period
    for the returning node to become usable again.
    """

    def __init__(self, settle_s):
        self.settle_s = settle_s
        self.open = False
        self.close_at = 0.0

    def killed(self):
        self.open = True
        self.close_at = 0.0

    def rejoined(self):
        self.close_at = time.monotonic() + self.settle_s

    def is_open(self):
        if self.open:
            return True
        if self.close_at and time.monotonic() < self.close_at:
            return True
        self.close_at = 0.0
        return False


def one_call(base, path, timeout, window, metrics, write, origin=0.0):
    frontier = metrics.frontier() if not write else 0
    metrics.record_attempt(write)
    started = time.monotonic()
    try:
        with urllib.request.urlopen(
            f"{base}{path}", data=b"" if write else None, timeout=timeout
        ) as response:
            payload = json.loads(response.read())
    except Exception as error:  # noqa: BLE001 - every failure is data here
        if write:
            metrics.record_unknown_write()
        metrics.record_error(
            window.is_open(), f"{path}: {error}", round(time.monotonic() - origin, 1)
        )
        return FAILURE
    value = payload.get("result")
    if not isinstance(value, (int, float)):
        metrics.record_error(
            window.is_open(), f"{path}: unexpected payload {payload}",
            round(time.monotonic() - origin, 1),
        )
        return FAILURE
    metrics.record_ok(time.monotonic() - started, value, write, frontier)
    return value


def writer(base, path, timeout, window, metrics, stop, pace, origin):
    while not stop.is_set():
        one_call(base, path, timeout, window, metrics, write=True, origin=origin)
        if pace:
            time.sleep(pace)


def reader(base, timeout, window, metrics, stop, pace, origin):
    while not stop.is_set():
        one_call(base, "/value", timeout, window, metrics, write=False, origin=origin)
        if pace:
            time.sleep(pace)


def sample(urls, stop, samples, interval):
    """Sample every node, because a capability's origin can be any of them."""
    while not stop.is_set():
        total = 0
        seen = 0
        for url in urls:
            try:
                with urllib.request.urlopen(url, timeout=10) as response:
                    state = json.loads(response.read())
                handles = state.get("rpc_bridge_handles")
                if isinstance(handles, int):
                    total += handles
                    seen += 1
            except Exception:  # noqa: BLE001 - a node being killed is expected
                continue
        samples.append(
            {"at": round(time.monotonic(), 3), "handles": total if seen else None}
        )
        stop.wait(interval)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", action="append", required=True, dest="bases")
    parser.add_argument("--state-url", action="append", required=True, dest="state_urls")
    parser.add_argument("--duration", type=float, required=True)
    parser.add_argument("--writers", type=int, default=2)
    parser.add_argument("--readers", type=int, default=4)
    parser.add_argument("--pace-ms", type=int, default=50)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--sample-ms", type=int, default=1000)
    parser.add_argument("--quiesce-s", type=float, default=30)
    parser.add_argument("--settle-s", type=float, default=5)
    parser.add_argument("--output", required=True)
    arguments = parser.parse_args()

    # The fleet becomes usable asynchronously after the nodes report health, so
    # wait for a first successful call on each node before counting: the bars
    # describe steady state, not fleet startup.
    for name, base in enumerate(arguments.bases):
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen(f"{base}/value", timeout=10) as response:
                    json.loads(response.read())
                break
            except Exception:  # noqa: BLE001 - startup is expected to be noisy
                time.sleep(1)
        else:
            raise SystemExit(f"node {name} never answered a read before the soak")

    origin = time.monotonic()
    metrics = Metrics()
    window = Window(arguments.settle_s)
    stop = threading.Event()
    samples = []
    pace = arguments.pace_ms / 1000

    # The orchestrator opens the window through the signal file it touches, so
    # the driver stays the only thing that reads wall-clock state from the nodes.
    signal_path = f"{arguments.output}.signal"

    def watch_signal():
        seen = 0
        while not stop.is_set():
            try:
                with open(signal_path) as handle:
                    lines = [line for line in handle.read().split("\n") if line.strip()]
            except FileNotFoundError:
                lines = []
            for line in lines[seen:]:
                event, _ = (line.split() + ["", ""])[:2]
                if event == "kill":
                    window.killed()
                elif event == "rejoin":
                    window.rejoined()
            seen = len(lines)
            stop.wait(0.025)

    threads = [
        threading.Thread(
            target=writer,
            args=(
                arguments.bases[index % len(arguments.bases)],
                "/bump",
                arguments.timeout,
                window,
                metrics,
                stop,
                pace,
                origin,
            ),
            daemon=True,
        )
        for index in range(arguments.writers)
    ] + [
        threading.Thread(
            target=reader,
            args=(
                arguments.bases[index % len(arguments.bases)],
                arguments.timeout,
                window,
                metrics,
                stop,
                pace,
                origin,
            ),
            daemon=True,
        )
        for index in range(arguments.readers)
    ] + [
        threading.Thread(
            target=sample,
            args=(arguments.state_urls, stop, samples, arguments.sample_ms / 1000),
            daemon=True,
        ),
        threading.Thread(target=watch_signal, daemon=True),
    ]
    for thread in threads:
        thread.start()

    time.sleep(arguments.duration)
    stop.set()

    # Quiesce: with no load in flight, request-end retirement has to drain the
    # origin node's bridge handles.
    handles_after_load = None
    handles_after_load_by_node = {}
    deadline = time.monotonic() + arguments.quiesce_s
    while time.monotonic() < deadline:
        per_node = {}
        for url in arguments.state_urls:
            try:
                with urllib.request.urlopen(url, timeout=10) as response:
                    state = json.loads(response.read())
                per_node[url] = state.get("rpc_bridge_handles")
            except Exception:  # noqa: BLE001 - a node may be mid-restart
                per_node[url] = None
        handles_after_load_by_node = per_node
        if per_node and all(value == 0 for value in per_node.values()):
            handles_after_load = 0
            break
        # Not zero everywhere yet: report the sum, so a regression names a node
        # that never drained instead of a bare null.
        known = [value for value in per_node.values() if isinstance(value, int)]
        handles_after_load = sum(known) if known else None
        time.sleep(1)

    # The last acknowledged write can land after the final read of the load, so
    # durability is judged by a read taken now, with nothing in flight.
    final_read = None
    read_deadline = time.monotonic() + arguments.quiesce_s
    while time.monotonic() < read_deadline and final_read is None:
        for base in arguments.bases:
            try:
                with urllib.request.urlopen(f"{base}/value", timeout=10) as response:
                    final_read = json.loads(response.read()).get("result")
                break
            except Exception:  # noqa: BLE001 - a node may still be restarting
                continue
        if final_read is None:
            time.sleep(1)

    observed = [entry["handles"] for entry in samples if entry["handles"] is not None]
    latencies = sorted(metrics.latencies)
    report = {
        "ok": metrics.ok,
        "errors": metrics.errors,
        "turnover_errors": metrics.turnover_errors,
        "unexpected_errors": metrics.unexpected,
        "reads": metrics.reads,
        "writes": metrics.writes,
        "write_attempts": metrics.write_attempts,
        "writes_without_reply": metrics.write_unknown,
        "rollbacks": metrics.rollbacks,
        "max_acknowledged": metrics.max_acknowledged,
        "max_read": metrics.max_read,
        "final_read": final_read,
        "latency_ms": {
            "p50": round(latencies[len(latencies) // 2] * 1000, 1) if latencies else None,
            "p99": round(latencies[int(len(latencies) * 0.99)] * 1000, 1)
            if latencies
            else None,
            "max": round(latencies[-1] * 1000, 1) if latencies else None,
        },
        "bridge_handles": {
            "max": max(observed) if observed else None,
            "after_load": handles_after_load,
            "per_node": handles_after_load_by_node,
            "samples": len(observed),
        },
    }
    with open(arguments.output, "w") as handle:
        json.dump(report, handle, indent=2)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
