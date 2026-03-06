import json
import math
import os
import signal
import sys

from functools import wraps


CEPH_DIAGNOSTICS_COLLECT_DIR = os.environ.get("CEPH_DIAGNOSTICS_COLLECT_DIR")

def parse_json_constants(arg):
    if arg == "Infinity":
        return math.inf
    elif arg == "-Infinity":
        return -math.inf
    elif arg == "NaN":
        return math.nan
    return None

def json_load(filename, exit_on_error=True):
    file_size = 0
    try:
        file_size = os.path.getsize(filename)
        with open(filename, "r") as f:
            # Replace " inf," with " Infinity," to avoid json parsing error:
            # python json module does not support "inf", "-inf", "nan" as valid json constants
            json_data = f.read()

            if not json_data.strip():
                file_size = 0

            json_data = json_data.replace(
                " inf,", " Infinity,").replace(
                    " -inf,", " -Infinity,").replace(
                        " nan,", " NaN,")

            return json.loads(json_data,
                              parse_constant=parse_json_constants)
    except json.JSONDecodeError as e:
        if file_size == 0:
            e = "file is empty"
        print(f"Error parsing JSON file {filename}: {e}", file=sys.stderr)
        if exit_on_error:
            sys.exit(1)
        return None
    except FileNotFoundError:
        print(f"File not found: {filename}", file=sys.stderr)
        if exit_on_error:
            sys.exit(1)
        return None
    except Exception as e:
        print(f"An error occurred while reading {filename}: {e}",
              file=sys.stderr)
        if exit_on_error:
            sys.exit(1)
        return None

def get_report():
    return json_load(CEPH_DIAGNOSTICS_COLLECT_DIR + "/cluster_health-report")

def handle_broken_pipe(func):
    @wraps(func)
    def wrapper(*args, **kwargs):
        # Handle BrokenPipeError gracefully
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
        try:
            return func(*args, **kwargs)
        except BrokenPipeError:
            # when piping to less
            # Python flushes standard streams on exit; redirect remaining output
            # to /dev/null to avoid another BrokenPipeError at that time
            devnull = os.open(os.devnull, os.O_WRONLY)
            os.dup2(devnull, sys.stdout.fileno())
            sys.exit(1)  # Python exits with error code 1 on EPIPE
    return wrapper
