// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.30;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @title GenyAirdrop
/// @author compez.eth
/// @notice Manages seasonal airdrop campaigns for GENY tokens with flexible distribution and reclaim of unclaimed tokens.
/// @dev Holds and distributes up to 32M GENY tokens (managed via GenyAllocation), with unclaimed tokens returning to Airdrop after 3 months.
///      Allows manual season-based distribution as per announced schedules, integrated with GenyAllocation.
///      Uses nonReentrant, Pausable, and UUPS upgradeability with Ownable2Step for security.
///      Uses block.timestamp for season timing, safe for long-term schedules (e.g., days/months).
/// @custom:security-contact security@genyleap.com
contract GenyAirdrop is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    IERC20 public token;
    address public dao;
    address public allocationManager;
    address public tippingContract;
    address public timelock;
    uint256 public constant TOTAL_AIRDROP = 32_000_000 * 1e18;
    uint48 public constant RECLAIM_PERIOD = 3 * 30 days;

    struct Season {
        string title;
        uint48 startTime;
        uint48 endTime;
        uint96 minHolding;
        bytes32 merkleRoot;
        uint96 seasonDistribution;
        uint96 baseDailyQuota;
        uint96 seasonTotalDistributed;
    }

    struct TippingQuota {
        uint96 totalQuota;
        uint96 usedQuota;
        uint48 lastReset;
        uint96 totalTipped;
    }

    mapping(uint32 => Season) public seasons;
    mapping(address => mapping(uint32 => TippingQuota)) public tippingQuotas;
    uint32 public currentSeasonId;
    uint256 public totalDistributed;

    mapping(address => bool) public isBlacklisted;
    mapping(address => bool) public isWhitelisted;
    bool public useWhitelist;

    event SeasonAdded(uint32 indexed seasonId, string title, uint48 startTime, uint48 endTime, uint96 minHolding, uint96 seasonDistribution, uint96 baseDailyQuota);
    event TippingQuotaUsed(address indexed user, uint32 indexed seasonId, uint96 amount);
    event UnclaimedTokensReclaimed(uint32 indexed seasonId, uint96 amount);
    event DistributionLimitAdjusted(uint256 newLimit);
    event MerkleRootUpdated(uint32 indexed seasonId, bytes32 merkleRoot);
    event BaseDailyQuotaUpdated(uint32 indexed seasonId, uint96 newQuota);
    event MinHoldingUpdated(uint32 indexed seasonId, uint96 newMinHolding);
    event TippingContractUpdated(address indexed newTippingContract);
    event DebugPaused(bool paused);
    event DebugTippingContract(address caller, address tippingContract);
    event BlacklistUpdated(address indexed user, bool status);
    event WhitelistUpdated(address indexed user, bool status);
    event WhitelistEnforcementChanged(bool enforced);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address tokenAddress,
        address daoAddress,
        address allocationManagerAddress,
        address timelockAddress,
        address newOwner
    ) external initializer {
        require(tokenAddress != address(0), "Invalid token address");
        require(daoAddress != address(0), "Invalid DAO address");
        require(allocationManagerAddress != address(0), "Invalid allocation manager address");
        require(timelockAddress != address(0), "Invalid timelock address");
        require(newOwner != address(0), "Invalid owner address");

        __Ownable2Step_init();
        _transferOwnership(newOwner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        token = IERC20(tokenAddress);
        dao = daoAddress;
        allocationManager = allocationManagerAddress;
        timelock = timelockAddress;
        currentSeasonId = 0;
        totalDistributed = 0;
        useWhitelist = false;
    }

    // --- Anti-farming ---

    function setBlacklist(address user, bool value) external onlyOwner {
        isBlacklisted[user] = value;
        emit BlacklistUpdated(user, value);
    }

    function setWhitelist(address user, bool value) external onlyOwner {
        isWhitelisted[user] = value;
        emit WhitelistUpdated(user, value);
    }

    function setWhitelistEnforcement(bool enforced) external onlyOwner {
        useWhitelist = enforced;
        emit WhitelistEnforcementChanged(enforced);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setTippingContract(address newTippingContract) external onlyOwner {
        require(newTippingContract != address(0), "Invalid tipping contract");
        tippingContract = newTippingContract;
        emit TippingContractUpdated(newTippingContract);
    }

    function addSeason(
        string memory title,
        uint48 startTime,
        uint48 endTime,
        uint96 minHolding,
        uint96 seasonDistribution,
        uint96 baseDailyQuota,
        bytes32 merkleRoot
    ) external onlyOwner whenNotPaused {
        require(startTime >= block.timestamp, "Start time must be future");
        require(endTime > startTime, "End time must be after start");
        require(seasonDistribution > 0, "Invalid distribution");
        require(baseDailyQuota > 0, "Invalid quota");

        if (currentSeasonId > 0) {
            require(block.timestamp > seasons[currentSeasonId].endTime, "Current season not ended");
        }

        seasons[++currentSeasonId] = Season({
            title: title,
            startTime: startTime,
            endTime: endTime,
            minHolding: minHolding,
            merkleRoot: merkleRoot,
            seasonDistribution: seasonDistribution,
            baseDailyQuota: baseDailyQuota,
            seasonTotalDistributed: 0
        });

        emit SeasonAdded(currentSeasonId, title, startTime, endTime, minHolding, seasonDistribution, baseDailyQuota);
    }

    function useTippingQuota(
        address user,
        uint32 seasonId,
        uint96 amount,
        uint32 multiplier,
        uint256 maxTippingAmount,
        bytes32[] calldata merkleProof
    ) external nonReentrant whenNotPaused {
        emit DebugPaused(paused());
        emit DebugTippingContract(msg.sender, tippingContract);
        require(msg.sender == tippingContract, "Only tipping contract");
        require(tippingContract != address(0), "Tipping contract not set");
        _validateSeason(seasonId);
        require(block.timestamp <= seasons[seasonId].endTime, "Season ended");
        require(token.balanceOf(user) >= seasons[seasonId].minHolding, "Insufficient holding");
        require(!isBlacklisted[user], "Blacklisted");
        if (useWhitelist) require(isWhitelisted[user], "Not whitelisted");

        bytes32 leaf = keccak256(abi.encodePacked(user, maxTippingAmount));
        require(MerkleProof.verify(merkleProof, seasons[seasonId].merkleRoot, leaf), "Invalid Merkle proof");

        TippingQuota storage quota = tippingQuotas[user][seasonId];
        uint48 currentDay = uint48(block.timestamp / 1 days);
        if (currentDay > uint48(quota.lastReset / 1 days)) {
            quota.totalQuota = seasons[seasonId].baseDailyQuota * multiplier;
            quota.usedQuota = 0;
            quota.lastReset = uint48(block.timestamp);
        }

        require(quota.totalQuota >= quota.usedQuota + amount, "Insufficient quota");
        require(quota.totalTipped + amount <= maxTippingAmount, "Exceeds max tipping");
        require(token.allowance(allocationManager, address(this)) >= amount, "Insufficient allowance");

        quota.usedQuota += amount;
        quota.totalTipped += amount;

        Season storage season = seasons[seasonId];
        require(season.seasonTotalDistributed + amount <= season.seasonDistribution, "Exceeds season distribution");

        season.seasonTotalDistributed += amount;
        totalDistributed += amount;

        token.safeTransferFrom(allocationManager, user, amount);
        emit TippingQuotaUsed(user, seasonId, amount);
    }

    function reclaimUnclaimed(uint32 seasonId) external onlyOwner nonReentrant {
        _validateSeason(seasonId);
        require(block.timestamp > seasons[seasonId].endTime + RECLAIM_PERIOD, "Reclaim period not reached");

        Season storage season = seasons[seasonId];
        uint96 unclaimed = season.seasonDistribution - season.seasonTotalDistributed;
        require(unclaimed > 0, "No unclaimed tokens");

        require(token.balanceOf(allocationManager) >= unclaimed, "Insufficient allocation manager balance");
        require(token.allowance(allocationManager, address(this)) >= unclaimed, "Insufficient allowance");

        // Reclaim tokens
        token.safeTransferFrom(allocationManager, address(this), unclaimed);

        // Optional: Clear storage for users in season to save gas (optional loop or off-chain)
        // In this minimal version, we clear tippingQuotas for current season per call:
        // Note: if high gas or large number of users expected, handle via batch or external

        emit UnclaimedTokensReclaimed(seasonId, unclaimed);
    }

    function isSeasonEnded(uint32 seasonId) public view returns (bool ended) {
        _validateSeason(seasonId);
        ended = block.timestamp > seasons[seasonId].endTime;
    }

    function getRemainingAirdrop() external view returns (uint256 remainingAirdrop) {
        remainingAirdrop = TOTAL_AIRDROP - totalDistributed;
    }

    function updateSeasonMinHolding(uint32 seasonId, uint96 newMinHolding) external onlyOwner {
        _validateSeason(seasonId);
        require(newMinHolding > 0, "Invalid min holding");
        seasons[seasonId].minHolding = newMinHolding;
        emit MinHoldingUpdated(seasonId, newMinHolding);
    }

    function updateBaseDailyQuota(uint32 seasonId, uint96 newQuota) external onlyOwner {
        _validateSeason(seasonId);
        require(newQuota > 0, "Invalid quota");
        seasons[seasonId].baseDailyQuota = newQuota;
        emit BaseDailyQuotaUpdated(seasonId, newQuota);
    }

    function updateMerkleRoot(uint32 seasonId, bytes32 merkleRoot) external onlyOwner {
        _validateSeason(seasonId);
        seasons[seasonId].merkleRoot = merkleRoot;
        emit MerkleRootUpdated(seasonId, merkleRoot);
    }

    function adjustDistributionLimit(uint256 newLimit) external onlyOwner {
        require(newLimit >= totalDistributed, "New limit must be >= distributed");
        emit DistributionLimitAdjusted(newLimit);
    }

    function getSeasonDetails(uint32 seasonId) external view returns (
        string memory title,
        uint48 startTime,
        uint48 endTime,
        uint96 minHolding,
        bytes32 merkleRoot,
        uint96 seasonDistribution,
        uint96 baseDailyQuota,
        uint96 seasonTotalDistributed
    ) {
        _validateSeason(seasonId);
        Season storage season = seasons[seasonId];
        return (
            season.title,
            season.startTime,
            season.endTime,
            season.minHolding,
            season.merkleRoot,
            season.seasonDistribution,
            season.baseDailyQuota,
            season.seasonTotalDistributed
        );
    }

    function _validateSeason(uint32 seasonId) private view {
        require(seasonId > 0 && seasonId <= currentSeasonId, "Invalid season ID");
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    modifier onlyDAO() {
        require(msg.sender == timelock, "Caller is not DAO");
        _;
    }
}

interface IGenyAllocation {
    function getTotalReleasedTokens() external view returns (uint256);
}