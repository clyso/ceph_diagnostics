import json
import os
import math

CEPH_DIAGNOSTICS_COLLECT_DIR = os.environ.get("CEPH_DIAGNOSTICS_COLLECT_DIR")

def parse_json_constants(arg):
    if arg == "Infinity":
        return math.inf
    elif arg == "-Infinity":
        return -math.inf
    elif arg == "NaN":
        return math.nan
    return None

def get_report():
    with open(CEPH_DIAGNOSTICS_COLLECT_DIR + "/cluster_health-report", "r") as f:
        # Replace " inf," with " Infinity," to avoid json parsing error:
        # python json module does not support "inf", "-inf", "nan" as valid json constants
        json_data = f.read().replace(
            " inf,", " Infinity,").replace(
                " -inf,", " -Infinity,").replace(
                    " nan,", " NaN,")
        return json.loads(json_data,
                          parse_constant=parse_json_constants)
