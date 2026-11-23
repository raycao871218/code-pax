"""Keeps the Python bridge and the Swift client agreeing on the wire protocol."""
import re
import unittest
from pathlib import Path

from bridge import PROTOCOL

ROOT = Path(__file__).resolve().parent.parent


class ProtocolContractTests(unittest.TestCase):
    def test_bridge_protocol_is_inside_swift_supported_range(self):
        source = (ROOT / "CodePax/CodexModels.swift").read_text()
        match = re.search(r"static let supported = (\d+)\.\.\.(\d+)", source)
        self.assertIsNotNone(match, "BridgeCompatibility.supported not found")
        low, high = int(match.group(1)), int(match.group(2))
        self.assertTrue(low <= PROTOCOL <= high,
                        "bridge PROTOCOL=%d outside Swift supported %d...%d" % (PROTOCOL, low, high))


if __name__ == "__main__":
    unittest.main()
