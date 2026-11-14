#!/usr/bin/env python3
"""Run an executable once for every address represented by an IPv4 pattern."""

from __future__ import annotations

import argparse
import itertools
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time
from concurrent.futures import FIRST_COMPLETED, Future, ThreadPoolExecutor, wait
from dataclasses import dataclass
from typing import Iterator, Sequence


DEFAULT_MAX_TARGETS = 65_536


class InputError(ValueError):
    """Raised when a command-line value cannot be used safely."""


@dataclass(frozen=True)
class CommandResult:
    target: str
    returncode: int | None
    stdout: str
    stderr: str
    duration: float
    error: str | None = None
    timed_out: bool = False

    @property
    def succeeded(self) -> bool:
        return self.returncode == 0 and self.error is None


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="verifier",
        description=(
            "Replace every whole IPv4 octet named 'x' with 0 through 255, "
            "then invoke EXECUTABLE as: EXECUTABLE IP [ARG ...]."
        ),
        epilog=(
            "Example: verifier --jobs 8 198.x.8.1 "
            "default_credentials_test.py root toor"
        ),
    )
    parser.add_argument(
        "--jobs",
        type=positive_int,
        default=1,
        metavar="N",
        help="maximum simultaneous processes (default: 1)",
    )
    parser.add_argument(
        "--timeout",
        type=positive_float,
        default=None,
        metavar="SECONDS",
        help="terminate an invocation if it exceeds this duration",
    )
    parser.add_argument(
        "--max-targets",
        type=positive_int,
        default=DEFAULT_MAX_TARGETS,
        metavar="N",
        help=(
            "refuse patterns expanding beyond N addresses "
            f"(default: {DEFAULT_MAX_TARGETS})"
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print commands without executing them",
    )
    parser.add_argument("pattern", help="IPv4 pattern, for example 198.x.8.1")
    parser.add_argument("executable", help="script or executable to invoke")
    parser.add_argument(
        "executable_args",
        nargs=argparse.REMAINDER,
        metavar="ARG",
        help="arguments appended after the generated IP address",
    )
    return parser


def positive_int(value: str) -> int:
    try:
        parsed = int(value, 10)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def positive_float(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a number") from exc
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def parse_pattern(pattern: str) -> tuple[tuple[str | None, ...], int]:
    octets = pattern.split(".")
    if len(octets) != 4:
        raise InputError("the IP pattern must contain exactly four octets")

    parsed: list[str | None] = []
    variable_count = 0

    for position, octet in enumerate(octets, start=1):
        if octet.lower() == "x":
            parsed.append(None)
            variable_count += 1
            continue

        if not octet or not octet.isascii() or not octet.isdecimal():
            raise InputError(
                f"octet {position} must be 'x' or a decimal number from 0 to 255"
            )

        value = int(octet, 10)
        if value > 255:
            raise InputError(f"octet {position} is outside the range 0 to 255")
        parsed.append(str(value))

    target_count = 256**variable_count
    return tuple(parsed), target_count


def generate_targets(pattern: Sequence[str | None]) -> Iterator[str]:
    variable_count = sum(octet is None for octet in pattern)
    for replacements in itertools.product(range(256), repeat=variable_count):
        replacement_iter = iter(replacements)
        yield ".".join(
            str(next(replacement_iter)) if octet is None else octet
            for octet in pattern
        )


def resolve_command(executable: str) -> list[str]:
    supplied = Path(executable).expanduser()
    located: Path | None = None

    if supplied.is_file():
        located = supplied.resolve()
    elif os.sep not in executable and (os.altsep is None or os.altsep not in executable):
        match = shutil.which(executable)
        if match:
            located = Path(match)

    if located is None:
        raise InputError(f"executable or script was not found: {executable}")

    if located.suffix.lower() == ".py":
        return [sys.executable, str(located)]

    if not os.access(located, os.X_OK):
        raise InputError(
            f"file is not executable: {located}; add a shebang and execute permission"
        )

    return [str(located)]


def invoke(
    target: str,
    command_prefix: Sequence[str],
    executable_args: Sequence[str],
    timeout: float | None,
) -> CommandResult:
    command = [*command_prefix, target, *executable_args]
    started = time.monotonic()

    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=timeout,
        )
        return CommandResult(
            target=target,
            returncode=completed.returncode,
            stdout=completed.stdout,
            stderr=completed.stderr,
            duration=time.monotonic() - started,
        )
    except subprocess.TimeoutExpired as exc:
        return CommandResult(
            target=target,
            returncode=None,
            stdout=output_as_text(exc.stdout),
            stderr=output_as_text(exc.stderr),
            duration=time.monotonic() - started,
            error=f"timed out after {timeout:g} seconds",
            timed_out=True,
        )
    except OSError as exc:
        return CommandResult(
            target=target,
            returncode=None,
            stdout="",
            stderr="",
            duration=time.monotonic() - started,
            error=str(exc),
        )


def output_as_text(value: str | bytes | None) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode(errors="replace")
    return value


def emit_result(result: CommandResult, completed: int, total: int) -> None:
    if result.error:
        status = result.error
    else:
        status = f"exit={result.returncode}"

    print(
        f"[{completed}/{total}] {result.target} {status} ({result.duration:.2f}s)",
        file=sys.stderr,
        flush=True,
    )

    if result.stdout:
        print_stream_block(sys.stdout, result.target, "stdout", result.stdout)
    if result.stderr:
        print_stream_block(sys.stderr, result.target, "stderr", result.stderr)


def print_stream_block(stream: object, target: str, name: str, content: str) -> None:
    print(f"--- {target} {name} ---", file=stream)
    print(content, end="" if content.endswith("\n") else "\n", file=stream, flush=True)


def run_sequential(
    targets: Iterator[str],
    total: int,
    command_prefix: Sequence[str],
    executable_args: Sequence[str],
    timeout: float | None,
) -> tuple[int, int]:
    failures = 0
    timeouts = 0
    for completed, target in enumerate(targets, start=1):
        result = invoke(target, command_prefix, executable_args, timeout)
        emit_result(result, completed, total)
        failures += not result.succeeded
        timeouts += result.timed_out
    return failures, timeouts


def run_parallel(
    targets: Iterator[str],
    total: int,
    command_prefix: Sequence[str],
    executable_args: Sequence[str],
    timeout: float | None,
    jobs: int,
) -> tuple[int, int]:
    failures = 0
    timeouts = 0
    completed = 0

    with ThreadPoolExecutor(max_workers=jobs) as executor:
        pending: dict[Future[CommandResult], str] = {}

        for _ in range(min(jobs, total)):
            target = next(targets)
            future = executor.submit(
                invoke, target, command_prefix, executable_args, timeout
            )
            pending[future] = target

        while pending:
            finished, _ = wait(pending, return_when=FIRST_COMPLETED)
            for future in finished:
                pending.pop(future)
                result = future.result()
                completed += 1
                emit_result(result, completed, total)
                failures += not result.succeeded
                timeouts += result.timed_out

                try:
                    target = next(targets)
                except StopIteration:
                    continue
                new_future = executor.submit(
                    invoke, target, command_prefix, executable_args, timeout
                )
                pending[new_future] = target

    return failures, timeouts


def dry_run(
    targets: Iterator[str],
    command_prefix: Sequence[str],
    executable_args: Sequence[str],
) -> None:
    for target in targets:
        print(shlex.join([*command_prefix, target, *executable_args]))


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        pattern, target_count = parse_pattern(args.pattern)
        if target_count > args.max_targets:
            raise InputError(
                f"pattern expands to {target_count:,} targets, exceeding "
                f"--max-targets {args.max_targets:,}"
            )
        command_prefix = resolve_command(args.executable)
    except InputError as exc:
        parser.error(str(exc))

    targets = generate_targets(pattern)
    print(
        f"Expanded {args.pattern} to {target_count:,} target(s); jobs={args.jobs}",
        file=sys.stderr,
    )

    if args.dry_run:
        dry_run(targets, command_prefix, args.executable_args)
        return 0

    started = time.monotonic()
    try:
        if args.jobs == 1:
            failures, timeouts = run_sequential(
                targets,
                target_count,
                command_prefix,
                args.executable_args,
                args.timeout,
            )
        else:
            failures, timeouts = run_parallel(
                targets,
                target_count,
                command_prefix,
                args.executable_args,
                args.timeout,
                args.jobs,
            )
    except KeyboardInterrupt:
        print("Interrupted; stopping new work.", file=sys.stderr)
        return 130

    elapsed = time.monotonic() - started
    succeeded = target_count - failures
    print(
        f"Summary: {succeeded}/{target_count} succeeded, {failures} failed, "
        f"{timeouts} timed out in {elapsed:.2f}s",
        file=sys.stderr,
    )
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
