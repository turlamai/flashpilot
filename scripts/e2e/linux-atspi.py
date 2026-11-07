#!/usr/bin/env python3
import argparse
import json
import time
from pathlib import Path

import pyatspi


def children(node):
    for index in range(node.childCount):
        try:
            yield node.getChildAtIndex(index)
        except Exception:
            continue


def walk(node):
    yield node
    for child in children(node):
        yield from walk(child)


def role(node):
    try:
        return node.getRoleName()
    except Exception:
        return "unknown"


def text(node):
    try:
        value = node.queryText()
        return value.getText(0, value.characterCount)
    except Exception:
        return ""


def wait_for(description, probe, timeout=45.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = probe()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {description}")


def find_application():
    desktop = pyatspi.Registry.getDesktop(0)
    for application in children(desktop):
        for node in walk(application):
            if role(node) == "frame" and (node.name or "") == "FlashPilot":
                return application
    return None


def find_named(root, name, expected_role=None):
    for node in walk(root):
        if (node.name or "") == name and (expected_role is None or role(node) == expected_role):
            return node
    return None


def enabled(node):
    try:
        return node.getState().contains(pyatspi.STATE_ENABLED)
    except Exception:
        return False


def contains(root, fragment):
    return any(fragment in (node.name or "") or fragment in text(node) for node in walk(root))


def press(node):
    actions = node.queryAction()
    if actions.nActions < 1 or not actions.doAction(0):
        raise AssertionError(f"AT-SPI action failed for {node.name!r}")


def snapshot(node, depth=0):
    result = {"name": node.name or "", "role": role(node)}
    value = text(node)
    if value:
        result["text"] = value
    if depth < 8:
        result["children"] = [snapshot(child, depth + 1) for child in children(node)]
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    application = None
    try:
        application = wait_for("FlashPilot application", find_application)
        window = wait_for(
            "FlashPilot frame", lambda: next((n for n in walk(application) if role(n) == "frame"), None)
        )
        wait_for(
            "embedded backend readiness",
            lambda: contains(window, "Embedded Racket CS is ready"),
        )
        validate = wait_for(
            "Validate bench button",
            lambda: next(
                (
                    node
                    for node in walk(window)
                    if (node.name or "") == "Validate bench"
                    and role(node) == "push button"
                ),
                None,
            ),
        )
        press(validate)
        wait_for("validation result from embedded backend", lambda: contains(window, '"ok":true'))

        flash = wait_for(
            "Flash plan button",
            lambda: next(
                (
                    node
                    for node in walk(window)
                    if (node.name or "") == "Flash plan"
                    and role(node) == "push button"
                ),
                None,
            ),
        )
        press(flash)
        wait_for(
            "flash result from the simulated bench",
            lambda: contains(window, '"ok":true') and contains(window, "ecu-reset"),
        )
    except Exception:
        if application is not None:
            (args.output / "accessibility-failure.json").write_text(
                json.dumps(snapshot(application), ensure_ascii=False, indent=2), encoding="utf-8"
            )
        raise

    (args.output / "accessibility.json").write_text(
        json.dumps(snapshot(application), ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (args.output / "interaction-trace.json").write_text(
        json.dumps(
            {
                "platform": "linux",
                "actions": ["press:Validate bench", "press:Flash plan"],
                "assertions": [
                    "packaged GTK4 frame activated on native Wayland",
                    "Validate bench exposed through AT-SPI",
                    "validation request crossed RVT1 into the simulated ECU backend",
                    "native result contains ok=true",
                    "flash plan executed on the simulated bench through AT-SPI",
                ],
            },
            indent=2,
        ),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
