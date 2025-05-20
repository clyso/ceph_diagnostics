import json
import math
import os
import sys

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
    size = 0
    try:
        file_size = os.path.getsize(filename)
        with open(filename, "r") as f:
            # Replace " inf," with " Infinity," to avoid json parsing error:
            # python json module does not support "inf", "-inf", "nan" as valid json constants
            json_data = f.read().replace(
                " inf,", " Infinity,").replace(
                    " -inf,", " -Infinity,").replace(
                        " nan,", " NaN,")
            return json.loads(json_data,
                              parse_constant=parse_json_constants)
    except json.JSONDecodeError as e:
        if size == 0:
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
