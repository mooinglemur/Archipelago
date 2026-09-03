from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time

import ModuleUpdate

ModuleUpdate.update()

from Utils import is_frozen, is_windows, local_path

NO_EXIT_CONFIRMATION = "ARCHIPELAGO_NO_EXIT_CONFIRMATION"


def get_generate_command() -> list[str]:
    """
    Command that performs a single generation.

    This deliberately does not go through worlds.LauncherComponents.get_exe: importing that module imports the
    worlds package, which loads every installed world. That is pointless work for a process whose only job is to
    spawn children, and it would hold those modules in memory for the entire run.
    """
    if is_frozen():
        return [local_path("ArchipelagoGenerate" + (".exe" if is_windows else ""))]
    return [sys.executable, local_path("Generate.py")]


def run_once(command: list[str]) -> int:
    env = os.environ.copy()
    # a failed attempt must not block the loop on stdin
    env[NO_EXIT_CONFIRMATION] = "1"
    # the parent already did this, and re-checking it once per attempt is wasted time
    env["SKIP_REQUIREMENTS_UPDATE"] = "1"
    return subprocess.run(command, env=env, check=False).returncode


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Runs Generate until it succeeds. Every attempt is a fresh process, so nothing from a failed "
                    "generation carries into the next one. Unrecognized arguments are passed through to Generate.")
    parser.add_argument("--max_attempts", type=int, default=0,
                        help="Give up after this many failures. 0, the default, retries forever.")
    parser.add_argument("--retry_delay", type=float, default=0.0,
                        help="Seconds to wait between attempts.")
    args, generate_args = parser.parse_known_args(argv)

    if args.max_attempts < 0:
        parser.error("--max_attempts cannot be negative")
    if args.retry_delay < 0:
        parser.error("--retry_delay cannot be negative")

    if any(arg == "--seed" or arg.startswith("--seed=") for arg in generate_args):
        print("Warning: --seed makes every attempt roll the same multiworld, "
              "so a failing seed will keep failing.", file=sys.stderr, flush=True)

    command = get_generate_command() + generate_args
    attempt = 0
    return_code = 0
    while not args.max_attempts or attempt < args.max_attempts:
        attempt += 1
        of_total = f" of {args.max_attempts}" if args.max_attempts else ""
        print(f"--- Generation attempt {attempt}{of_total} ---", flush=True)
        return_code = run_once(command)
        if return_code == 0:
            print(f"--- Generation succeeded on attempt {attempt} ---", flush=True)
            return 0
        print(f"--- Generation attempt {attempt} failed with exit code {return_code} ---",
              file=sys.stderr, flush=True)
        if args.retry_delay:
            time.sleep(args.retry_delay)

    print(f"--- Giving up after {attempt} failed attempts ---", file=sys.stderr, flush=True)
    return return_code


def wait_for_close() -> None:
    try:
        input("Press enter to close.")
    except EOFError:  # no console attached, nothing to wait for
        pass


if __name__ == "__main__":
    import atexit
    confirmation = None if os.environ.get(NO_EXIT_CONFIRMATION) else atexit.register(wait_for_close)
    try:
        exit_code = main()
    except KeyboardInterrupt:
        print("\n--- Interrupted ---", file=sys.stderr, flush=True)
        exit_code = 1
        if confirmation:
            atexit.unregister(confirmation)
    else:
        # in case of error-free exit should not need confirmation
        if exit_code == 0 and confirmation:
            atexit.unregister(confirmation)
    sys.exit(exit_code)
