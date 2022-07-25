// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";

import "./interfaces/IProofVerificationFunction.sol";
import "./interfaces/IRelayHub.sol";
import "./interfaces/IValidatorChecker.sol";
import "./interfaces/IBridgeRegistry.sol";
import "./interfaces/IStaking.sol";

import "./libraries/BitUtils.sol";
import "./libraries/MerklePatriciaProof.sol";

contract RelayHub is Multicall, IRelayHub, IBridgeRegistry, IValidatorChecker {

    using EnumerableSet for EnumerableSet.AddressSet;
    using BitMaps for BitMaps.BitMap;

    bytes32 internal constant ZERO_BLOCK_HASH = bytes32(0x00);
    address internal constant ZERO_ADDRESS = address(0x00);

    // lets keep default verification function as zero to make it manageable by BAS relay hub itself
    IProofVerificationFunction internal constant DEFAULT_VERIFICATION_FUNCTION = IProofVerificationFunction(ZERO_ADDRESS);
    IStaking internal constant ZERO_STAKING_ADDRESS = IStaking(ZERO_ADDRESS);

    event ChainRegistered(uint256 indexed chainId, address[] initValidatorSet);
    event ValidatorSetUpdated(uint256 indexed chainId, address[] newValidatorSet);

    struct ValidatorHistory {
        // set with all validators and their indices (never remove values)
        EnumerableSet.AddressSet allValidators;
        // mapping from epoch to the bitmap with active validators indices
        mapping(uint64 => BitMaps.BitMap) activeValidators;
        mapping(uint64 => uint64) validatorCount;
        // checkpoint history
        mapping(uint64 => bytes32) epochCheckpoints;
        // latest published epoch
        uint64 latestKnownEpoch;
    }

    enum ChainStatus {
        NotFound,
        Verifying,
        Active
    }

    enum ChainType {
        BSC,
        BAS
    }

    struct BAS {
        ChainStatus chainStatus;
        ChainType chainType;
        IProofVerificationFunction verificationFunction;
        address bridgeAddress;
        uint32 epochLength;
    }

    // default verification function for certified chains
    IProofVerificationFunction internal _defaultVerificationFunction;
    IStaking internal _stakingContract;
    // mapping with all registered chains
    mapping(uint256 => ValidatorHistory) _validatorHistories;
    mapping(uint256 => BAS) internal _registeredChains;

    constructor(IProofVerificationFunction defaultVerificationFunction, IStaking stakingContract) {
        _defaultVerificationFunction = defaultVerificationFunction;
        _stakingContract = stakingContract;
    }

    function getBridgeAddress(uint256 chainId) external view returns (address) {
        return _registeredChains[chainId].bridgeAddress;
    }

    function registerCertifiedBAS(
        uint256 chainId,
        bytes calldata rawGenesisBlock,
        address bridgeAddress,
        uint32 epochLength
    ) external {
        _registerChainWithVerificationFunction(
            chainId,
            DEFAULT_VERIFICATION_FUNCTION,
            rawGenesisBlock,
            ZERO_BLOCK_HASH,
            ChainStatus.Verifying,
            ChainType.BAS,
            bridgeAddress,
            epochLength
        );
    }

    function registerUsingCheckpoint(
        uint256 chainId,
        bytes calldata rawCheckpointBlock,
        bytes32 checkpointHash,
        address bridgeAddress,
        uint32 epochLength
    ) external {
        _registerChainWithVerificationFunction(
            chainId,
            DEFAULT_VERIFICATION_FUNCTION,
            rawCheckpointBlock,
            checkpointHash,
            ChainStatus.Verifying,
            ChainType.BAS,
            bridgeAddress,
            epochLength
        );
    }

    function registerBAS(
        uint256 chainId,
        IProofVerificationFunction verificationFunction,
        bytes calldata rawGenesisBlock,
        address bridgeAddress,
        uint32 epochLength
    ) external {
        _registerChainWithVerificationFunction(
            chainId,
            verificationFunction,
            rawGenesisBlock,
            ZERO_BLOCK_HASH,
            ChainStatus.Verifying,
            ChainType.BAS,
            bridgeAddress,
            epochLength
        );
    }

    function registerBSC(
        uint256 chainId,
        bytes calldata rawGenesisBlock,
        address bridgeAddress,
        uint32 epochLength
    ) external {
        _registerChainWithVerificationFunction(
            chainId,
            DEFAULT_VERIFICATION_FUNCTION,
            rawGenesisBlock,
            ZERO_BLOCK_HASH,
            ChainStatus.Verifying,
            ChainType.BSC,
            bridgeAddress,
            epochLength
        );
    }

    function _registerChainWithVerificationFunction(
        uint256 chainId,
        IProofVerificationFunction verificationFunction,
        bytes calldata rawCheckpointBlock,
        bytes32 checkpointHash,
        ChainStatus defaultStatus,
        ChainType chainType,
        address bridgeAddress,
        uint32 epochLength
    ) internal {
        BAS memory bas = _registeredChains[chainId];
        require(bas.chainStatus == ChainStatus.NotFound || bas.chainStatus == ChainStatus.Verifying, "already registered");
        (
        bytes32 blockHash,
        address[] memory initialValidatorSet,
        uint64 blockNumber
        ) = _verificationFunction(verificationFunction).verifyBlockWithoutQuorum(chainId, rawCheckpointBlock, epochLength);
        if (checkpointHash != ZERO_BLOCK_HASH) {
            require(checkpointHash == blockHash, "bad checkpoint hash");
        }
        bas.chainStatus = defaultStatus;
        bas.chainType = chainType;
        bas.verificationFunction = verificationFunction;
        bas.bridgeAddress = bridgeAddress;
        bas.epochLength = epochLength;
        {
            ValidatorHistory storage validatorHistory = _validatorHistories[chainId];
            _updateActiveValidatorSet(validatorHistory, initialValidatorSet, blockNumber / epochLength);
        }
        _registeredChains[chainId] = bas;
        emit ChainRegistered(chainId, initialValidatorSet);
    }

    function _updateActiveValidatorSet(ValidatorHistory storage validatorHistory, address[] memory newValidatorSet, uint64 epochNumber) internal {
        // make sure epochs updated one by one (don't do this check for the first transition)
        if (validatorHistory.latestKnownEpoch > 0 && epochNumber > 0) {
            require(epochNumber == validatorHistory.latestKnownEpoch + 1, "bad epoch");
        }
        uint256[] memory buckets = new uint256[]((validatorHistory.allValidators.length() >> 8) + 1);
        // build set of buckets with new bits
        for (uint256 i = 0; i < newValidatorSet.length; i++) {
            // add validator to the set of all validators
            address validator = newValidatorSet[i];
            validatorHistory.allValidators.add(validator);
            // get index of the validator in the set (-1 because 0 is not used)
            uint256 index = validatorHistory.allValidators._inner._indexes[bytes32(uint256(uint160(validator)))] - 1;
            buckets[index >> 8] |= 1 << (index & 0xff);
        }
        // copy buckets (its cheaper to keep buckets in memory)
        BitMaps.BitMap storage currentBitmap = validatorHistory.activeValidators[epochNumber];
        for (uint256 i = 0; i < buckets.length; i++) {
            currentBitmap._data[i] = buckets[i];
        }
        // remember total amount of validators and latest verified epoch
        validatorHistory.validatorCount[epochNumber] = uint64(newValidatorSet.length);
        validatorHistory.latestKnownEpoch = epochNumber;
    }

    function getActiveValidators(uint256 chainId) external view returns (address[] memory) {
        ValidatorHistory storage validatorHistory = _validatorHistories[chainId];
        return _extractActiveValidators(validatorHistory, validatorHistory.latestKnownEpoch);
    }

    function _extractActiveValidators(ValidatorHistory storage validatorHistory, uint64 atEpoch) internal view returns (address[] memory) {
        uint256 validatorsLength = validatorHistory.allValidators.length();
        uint256 totalBuckets = (validatorsLength >> 8) + 1;
        address[] memory activeValidators = new address[](validatorsLength);
        BitMaps.BitMap storage bitmap = validatorHistory.activeValidators[atEpoch];
        uint256 j = 0;
        for (uint256 i = 0; i < totalBuckets; i++) {
            uint256 bucket = bitmap._data[i];
            while (bucket != 0) {
                uint256 zeroes = BitUtils.ctz(bucket);
                bucket ^= (1 << zeroes);
                activeValidators[j] = address(uint160(uint256(bytes32(validatorHistory.allValidators._inner._values[(i << 8) + zeroes]))));
                j++;
            }
        }
        assembly {
            mstore(activeValidators, j)
        }
        return activeValidators;
    }

    function checkValidators(uint256 chainId, address[] memory validators, uint64 epoch) external view returns (uint64 uniqueValidators) {
        ValidatorHistory storage validatorHistory = _validatorHistories[chainId];
        BitMaps.BitMap storage activeValidators = validatorHistory.activeValidators[epoch];
        for (uint256 i = 0; i < validators.length; i++) {
            uint256 index = validatorHistory.allValidators._inner._indexes[bytes32(uint256(uint160(validators[i])))] - 1;
            require(activeValidators.get(index), "not a validator");
            uniqueValidators++;
        }
        return uniqueValidators;
    }

    function getLatestTransitionedEpoch(uint256 chainId) external view returns (uint64) {
        ValidatorHistory storage validatorHistory = _validatorHistories[chainId];
        return validatorHistory.latestKnownEpoch;
    }

    function updateValidatorSet(uint256 chainId, bytes[] calldata blockProofs) external {
        BAS memory bas = _registeredChains[chainId];
        require(bas.chainStatus == ChainStatus.Verifying || bas.chainStatus == ChainStatus.Active, "not active");
        ValidatorHistory storage validatorHistory = _validatorHistories[chainId];
        (address[] memory newValidatorSet, uint64 epochNumber) = _verificationFunction(bas.verificationFunction).verifyValidatorTransition(chainId, blockProofs, bas.epochLength, this);
        bas.chainStatus = ChainStatus.Active;
        _updateActiveValidatorSet(validatorHistory, newValidatorSet, epochNumber);
        _registeredChains[chainId] = bas;
        emit ValidatorSetUpdated(chainId, newValidatorSet);
    }

    function updateValidatorSetUsingEpochBlocks(uint256 chainId, bytes[] calldata blockProofs) external {
        BAS memory bas = _registeredChains[chainId];
        require(bas.chainStatus == ChainStatus.Verifying || bas.chainStatus == ChainStatus.Active, "not active");
        ValidatorHistory storage validatorHistory = _validatorHistories[chainId];
        IProofVerificationFunction pvf = _verificationFunction(bas.verificationFunction);
        // the key magic is that we can skip confirmations for epoch if it doesn't change validator set
        bytes32 validatorSnapshot;
        uint256 calldataOffset = 0;
        uint256 calldataSize = 0;
        for (uint256 i = 0; i < blockProofs.length; i++) {
            (, address[] memory validatorSet, uint64 blockNumber) = pvf.verifyBlockWithoutQuorum(chainId, blockProofs[i], bas.epochLength);
            if (blockNumber % bas.epochLength != 0) {
                break;
            }
            // increase block proof offset (0x20 is length of array)
            calldataOffset += blockProofs[i].length + 0x20;
            calldataSize++;
            // calc new validator snapshot and block epoch
            bytes32 newValidatorSnapshot = keccak256(abi.encode(validatorSet));
            uint64 blockEpoch = blockNumber / bas.epochLength;
            // first block must start new epoch
            if (i == 0) {
                validatorSnapshot = newValidatorSnapshot;
                require(blockEpoch == validatorHistory.latestKnownEpoch + 1, "bad epoch transition");
                validatorHistory.latestKnownEpoch++;
                continue;
            }
            // make sure validator set doesn't change
            require(newValidatorSnapshot != validatorSnapshot, "bad validator snapshot");
        }
        // calc new block proof offset with
        bytes[] calldata blockProofsWithOffset;
        assembly {
            blockProofsWithOffset.offset := add(blockProofs.offset, calldataOffset)
            blockProofsWithOffset.length := sub(blockProofs.length, calldataSize)
        }

        (address[] memory newValidatorSet, uint64 epochNumber) = pvf.verifyValidatorTransition(chainId, blockProofsWithOffset, bas.epochLength, this);
        bas.chainStatus = ChainStatus.Active;
        _updateActiveValidatorSet(validatorHistory, newValidatorSet, epochNumber);
        _registeredChains[chainId] = bas;
        emit ValidatorSetUpdated(chainId, newValidatorSet);
    }

    function checkpointTransition(
        uint256 chainId,
        bytes calldata rawEpochBlock,
        bytes32 checkpointHash,
        bytes[] calldata signatures
    ) external {
        // make sure bas is registered and active
        BAS memory bas = _registeredChains[chainId];
        require(bas.chainStatus == ChainStatus.Verifying || bas.chainStatus == ChainStatus.Active, "not active");
        // verify next epoch block with new validator set
        (
        bytes32 blockHash,
        address[] memory newValidatorSet,
        uint64 blockNumber
        ) = _verificationFunction(bas.verificationFunction).verifyBlockWithoutQuorum(chainId, rawEpochBlock, bas.epochLength);
        uint64 newEpochNumber = blockNumber / bas.epochLength;
        // lets check signatures and make sure quorum is reached
        if (bas.chainType == ChainType.BSC) {
            bytes32 signingRoot = keccak256(abi.encode(blockHash, checkpointHash));
            for (uint256 i = 0; i < signatures.length; i++) {
                require(_stakingContract.isValidatorActive(ECDSA.recover(signingRoot, signatures[i])), "bad validator");
            }
            uint256 totalValidators = _stakingContract.getValidators().length;
            require(signatures.length >= totalValidators, "quorum not reached");
        } else if (bas.chainType == ChainType.BAS) {
            address[] memory signers = new address[](signatures.length);
            bytes32 signingRoot = keccak256(abi.encode(blockHash, checkpointHash));
            for (uint256 i = 0; i < signatures.length; i++) {
                signers[i] = ECDSA.recover(signingRoot, signatures[i]);
            }
            require(checkValidatorsAndQuorumReached(chainId, signers, newEpochNumber - 1), "quorum not reached");
        } else {
            revert("incorrect chain type");
        }
        // update validator set and remember checkpoint hash
        {
            ValidatorHistory storage validatorHistory = _validatorHistories[chainId];
            _updateActiveValidatorSet(validatorHistory, newValidatorSet, newEpochNumber);
            validatorHistory.epochCheckpoints[blockNumber / bas.epochLength] = checkpointHash;
        }
        // remember bas status
        bas.chainStatus = ChainStatus.Active;
        _registeredChains[chainId] = bas;
    }

    function checkValidatorsAndQuorumReached(uint256 chainId, address[] memory validatorSet, uint64 epochNumber) public view returns (bool) {
        // find validator history for epoch and bitmap with active validators
        ValidatorHistory storage validatorHistory = _validatorHistories[chainId];
        BitMaps.BitMap storage bitMap = validatorHistory.activeValidators[epochNumber];
        // we must know total active validators and unique validators to check reachability of the quorum
        uint256 totalValidators = validatorHistory.validatorCount[epochNumber];
        uint256 uniqueValidators = 0;
        uint256[] memory markedValidators = new uint256[]((totalValidators + 0xff) >> 8);
        for (uint256 i = 0; i < validatorSet.length; i++) {
            // find validator's index and make sure it exists in the validator set
            uint256 rawIndex = validatorHistory.allValidators._inner._indexes[bytes32(uint256(uint160(validatorSet[i])))];
            if (rawIndex == 0 || !bitMap.get(rawIndex - 1)) {
                // its safe to skip because we might have produced block by validators from the next set
                continue;
            }
            uint256 index = rawIndex - 1;
            // mark used validators to be sure quorum is well-calculated
            uint256 usedMask = 1 << (index & 0xff);
            if (markedValidators[index >> 8] & usedMask == 0) {
                uniqueValidators++;
            }
            markedValidators[index >> 8] |= usedMask;
        }
        return uniqueValidators >= totalValidators * 2 / 3;
    }

    function checkReceiptProof(
        uint256 chainId,
        bytes[] calldata blockProofs,
        bytes calldata rawReceipt,
        bytes calldata proofSiblings,
        bytes calldata proofPath
    ) external view virtual override returns (bool) {
        // make sure bas chain is registered and active
        BAS memory bas = _registeredChains[chainId];
        require(bas.chainStatus == ChainStatus.Active, "not active");
        // verify block transition
        IProofVerificationFunction pvf = _verificationFunction(bas.verificationFunction);
        IProofVerificationFunction.BlockHeader memory blockHeader = pvf.verifyBlockAndReachedQuorum(chainId, blockProofs, bas.epochLength, this);
        // check receipt proof
        return pvf.checkReceiptProof(rawReceipt, blockHeader.receiptsRoot, proofSiblings, proofPath);
    }

    function _verificationFunction(IProofVerificationFunction verificationFunction) internal view returns (IProofVerificationFunction) {
        if (verificationFunction == DEFAULT_VERIFICATION_FUNCTION) {
            return _defaultVerificationFunction;
        } else {
            return verificationFunction;
        }
    }
}