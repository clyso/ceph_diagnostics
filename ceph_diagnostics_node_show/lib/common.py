import json
import os
import re

CEPH_DIAGNOSTICS_COLLECT_DIR = os.environ.get("CEPH_DIAGNOSTICS_COLLECT_DIR")

def load_json(fname):
    with open(fname, "r") as f:
        lines = f.readlines()
        if not lines:
            return None
        begin = 0
        end = len(lines)
        while begin < 10 and not re.search(r'[{[]', lines[begin]):
            begin += 1
            if begin == end:
                return None
        while end > begin and not re.search(r'[}\]]', lines[end - 1]):
            end -= 1
        return json.loads("".join(lines[begin:end]))
