.PHONY: build test fmt circuits circuits-test verifiers clean-circuits

# === Solidity ===

build:
	forge build

test:
	forge test

fmt:
	forge fmt

# === ZK circuits ===

circuits:
	cd circuits && nargo compile --workspace

circuits-test:
	cd circuits && nargo test --workspace

verifiers: circuits
	cd circuits && for pkg in safe_batch_conversion cn_batch_conversion; do \
	    echo "Generating verifier for $$pkg..."; \
	    bb write_vk -b target/$$pkg.json -o target/$$pkg.vk --oracle_hash keccak || exit 1; \
	    bb write_solidity_verifier -k target/$$pkg.vk/vk -o target/contract_$$pkg.sol -t evm || exit 1; \
	done
	@echo ""
	@echo "Generating thin per-circuit wrappers in src/zk-verifiers/ ..."
	@echo "  (math lives in SharedHonkVerifier.sol; wrappers hold only the VK and forward to it)"
	@mkdir -p src/zk-verifiers
	@for pkg in safe_batch_conversion cn_batch_conversion; do \
	    pascal=$$(echo $$pkg | awk -F_ '{for(i=1;i<=NF;i++)$$i=toupper(substr($$i,1,1)) substr($$i,2);}1' OFS=''); \
	    contract=$${pascal}Verifier; \
	    out=src/zk-verifiers/$${contract}.sol; \
	    awk -v contract="$${contract}" ' \
	      BEGIN { print "// SPDX-License-Identifier: Apache-2.0"; \
	              print "// Copyright 2022 Aztec"; \
	              print "pragma solidity ^0.8.35;"; \
	              print ""; \
	              print "import {SharedHonkVerifier, Honk} from \"./SharedHonkVerifier.sol\";"; \
	              print "import {IZKVerifier} from \"../interfaces/IZKVerifier.sol\";"; } \
	      NR<=3 { next } \
	      /^library HonkVerificationKey/ { in_lib=1 } \
	      in_lib && /^}/ { print; \
	                       print ""; \
	                       printf("contract %s is IZKVerifier {\n", contract); \
	                       print "    SharedHonkVerifier public immutable shared;"; \
	                       print ""; \
	                       print "    constructor(SharedHonkVerifier _shared) {"; \
	                       print "        shared = _shared;"; \
	                       print "    }"; \
	                       print ""; \
	                       print "    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool) {"; \
	                       print "        return shared.verify("; \
	                       print "            proof,"; \
	                       print "            publicInputs,"; \
	                       print "            HonkVerificationKey.loadVerificationKey(),"; \
	                       print "            LOG_N,"; \
	                       print "            VK_HASH,"; \
	                       print "            NUMBER_OF_PUBLIC_INPUTS"; \
	                       print "        );"; \
	                       print "    }"; \
	                       print "}"; \
	                       exit } \
	      { print } \
	    ' circuits/target/contract_$$pkg.sol > $$out; \
	    echo "  wrote $$out"; \
	done
	@echo ""
	@echo "Wrappers regenerated. SharedHonkVerifier.sol is hand-maintained; only update it"
	@echo "when 'bb' itself changes its math/template (rare). Build with: forge build"

clean-circuits:
	rm -rf circuits/target
