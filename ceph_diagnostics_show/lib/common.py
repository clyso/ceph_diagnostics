import json
import os

CEPH_DIAGNOSTICS_COLLECT_DIR = os.environ.get("CEPH_DIAGNOSTICS_COLLECT_DIR")

def get_report():
    with open(CEPH_DIAGNOSTICS_COLLECT_DIR + "/cluster_health-report", "r") as f:
        return json.load(f)
