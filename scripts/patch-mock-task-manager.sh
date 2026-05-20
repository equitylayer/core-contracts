#!/usr/bin/env bash
# Patches @cofhe/mock-contracts MockTaskManager to add batch verification stubs
# required by @fhenixprotocol/cofhe-contracts >=0.1.2.
# Remove this script once @cofhe/mock-contracts releases a compatible version.

set -euo pipefail

TARGET="node_modules/@cofhe/mock-contracts/contracts/MockTaskManager.sol"

if [ ! -f "$TARGET" ]; then
  echo "patch-mock-task-manager: $TARGET not found, skipping"
  exit 0
fi

if grep -q "verifyDecryptResultBatch" "$TARGET"; then
  echo "patch-mock-task-manager: already patched, skipping"
  exit 0
fi

python3 -c "
path = '$TARGET'
with open(path) as f:
    content = f.read()

stub = '''
  // --- Patched: stubs for cofhe-contracts >=0.1.2 batch verification ---
  function verifyDecryptResultBatch(uint256[] calldata ctHashes, uint256[] calldata results, bytes[] calldata signatures) external view returns (bool) {
    for (uint256 i = 0; i < ctHashes.length; i++) {
      if (!this.verifyDecryptResult(ctHashes[i], results[i], signatures[i])) return false;
    }
    return true;
  }

  function verifyDecryptResultBatchSafe(uint256[] calldata ctHashes, uint256[] calldata results, bytes[] calldata signatures) external view returns (bool[] memory) {
    bool[] memory _results = new bool[](ctHashes.length);
    for (uint256 i = 0; i < ctHashes.length; i++) {
      _results[i] = this.verifyDecryptResultSafe(ctHashes[i], results[i], signatures[i]);
    }
    return _results;
  }
'''

content = content.rstrip()
assert content.endswith('}'), 'Expected file to end with }'
content = content[:-1] + stub + '\n}\n'

with open(path, 'w') as f:
    f.write(content)
print('patch-mock-task-manager: patched successfully')
"
