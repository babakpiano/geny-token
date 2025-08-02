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
/// @notice Manages seasonal airdrop campaigns for GENY tokens with flexible distribution and reclaim of unclaimed tokens
/// @dev Holds and distributes up to 32M GENY tokens (managed via GenyAllocation), with unclaimed tokens returning to Airdrop after 3 months.
/// Allows manual season-based distribution as per announced schedules, integrated with GenyAllocation.
/// Uses nonReentrant, Pausable, and UUPS upgradeability with Ownable2Step for security.
/// Uses block.timestamp for season timing, safe for long-term schedules (e.g., days/months).
/// @custom:security-contact security@genyleap.com
contract GenyAirdrop is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice The GENY token contract
    IERC20 public token;
    /// @notice Address of the DAO (timelock controller)
    address public dao;
    /// @notice Address of the GenyAllocation contract
    address public allocationManager;
    /// @notice Address of the GenyTipping contract
    address public tippingContract;
    /// @notice Address of the timelock contract
    address public timelock;
    /// @notice Total GENY tokens allocated for airdrop
    uint256 public constant TOTAL_AIRDROP = 32_000_000 * 1e18;
    /// @notice Period after season end for reclaiming unclaimed tokens
    uint48 public constant RECLAIM_PERIOD = 3 * 30 days;

    /// @dev Structure to store season details
    struct Season {
        string title; // Season title
        uint48 startTime; // Season start timestamp
        uint48 endTime; // Season end timestamp
        uint96 minHolding; // Minimum GENY holding for eligibility
        bytes32 merkleRoot; // Merkle root for eligibility verification
        uint96 seasonDistribution; // Total tokens allocated for the season
        uint96 baseDailyQuota; // Base daily tipping quota
        uint96 seasonTotalDistributed; // Total tokens distributed in the season
    }

    /// @dev Structure to store tipping quota details for a user
    struct TippingQuota {
        uint96 totalQuota; // Total available quota
        uint96 usedQuota; // Used quota
        uint48 lastReset; // Last quota reset timestamp
        uint96 totalTipped; // Total tokens tipped by the user
    }

    /// @notice Mapping of season IDs to season details
    mapping(uint32 => Season) public seasons;
    /// @notice Mapping of user addresses to season-specific tipping quotas
    mapping(address => mapping(uint32 => TippingQuota)) public tippingQuotas;
    /// @notice Current season ID
    uint32 public currentSeasonId;
    /// @notice Total tokens distributed across all seasons
    uint256 public totalDistributed;
    /// @notice Mapping of user addresses to blacklist status
    mapping(address => bool) public isBlacklisted;
    /// @notice Mapping of user addresses to whitelist status
    mapping(address => bool) public isWhitelisted;
    /// @notice Flag to enforce whitelist usage
    bool public useWhitelist;

    /// @notice Emitted when a new season is added
    event SeasonAdded(uint32 indexed seasonId, string title, uint48 startTime, uint48 endTime, uint96 minHolding, uint96 seasonDistribution, uint96 baseDailyQuota);
    /// @notice Emitted when a tipping quota is used
    event TippingQuotaUsed(address indexed user, uint32 indexed seasonId, uint96 amount);
    /// @notice Emitted when unclaimed tokens are reclaimed
    event UnclaimedTokensReclaimed(uint32 indexed seasonId, uint96 amount);
    /// @notice Emitted when the distribution limit is adjusted
    event DistributionLimitAdjusted(uint256 newLimit);
    /// @notice Emitted when a season's Merkle root is updated
    event MerkleRootUpdated(uint32 indexed seasonId, bytes32 merkleRoot);
    /// @notice Emitted when a season's base daily quota is updated
    event BaseDailyQuotaUpdated(uint32 indexed seasonId, uint96 newQuota);
    /// @notice Emitted when a season's minimum holding is updated
    event MinHoldingUpdated(uint32 indexed seasonId, uint96 newMinHolding);
    /// @notice Emitted when the tipping contract address is updated
    event TippingContractUpdated(address indexed newTippingContract);
    /// @notice Emitted for debugging pause status
    event DebugPaused(bool paused);
    /// @notice Emitted for debugging tipping contract calls
    event DebugTippingContract(address caller, address tippingContract);
    /// @notice Emitted when a user's blacklist status is updated
    event BlacklistUpdated(address indexed user, bool status);
    /// @notice Emitted when a user's whitelist status is updated
    event WhitelistUpdated(address indexed user, bool status);
    /// @notice Emitted when whitelist enforcement is changed
    event WhitelistEnforcementChanged(bool enforced);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the airdrop contract
    /// @param tokenAddress Address of the GENY token contract
    /// @param daoAddress Address of the DAO (timelock controller)
    /// @param allocationManagerAddress Address of the GenyAllocation contract
    /// @param timelockAddress Address of the timelock contract
    /// @param newOwner Address of the initial owner (e.g., multisig)
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

    /// @notice Sets a user's blacklist status
    /// @param user Address of the user
    /// @param value Blacklist status (true = blacklisted)
    function setBlacklist(address user, bool value) external onlyOwner {
        isBlacklisted[user] = value;
        emit BlacklistUpdated(user, value);
    }

    /// @notice Sets a user's whitelist status
    /// @param user Address of the user
    /// @param value Whitelist status (true = whitelisted)
    function setWhitelist(address user, bool value) external onlyOwner {
        isWhitelisted[user] = value;
        emit WhitelistUpdated(user, value);
    }

    /// @notice Enables or disables whitelist enforcement
    /// @param enforced Whether to enforce whitelist
    function setWhitelistEnforcement(bool enforced) external onlyOwner {
        useWhitelist = enforced;
        emit WhitelistEnforcementChanged(enforced);
    }

    /// @notice Pauses the contract
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Sets the tipping contract address
    /// @param newTippingContract Address of the new tipping contract
    function setTippingContract(address newTippingContract) external onlyOwner {
        require(newTippingContract != address(0), "Invalid tipping contract");
        tippingContract = newTippingContract;
        emit TippingContractUpdated(newTippingContract);
    }

    /// @notice Adds a new season for airdrop distribution
    /// @param title Season title
    /// @param startTime Season start timestamp
    /// @param endTime Season end timestamp
    /// @param minHolding Minimum GENY holding for eligibility
    /// @param seasonDistribution Total tokens allocated for the season
    /// @param baseDailyQuota Base daily tipping quota
    /// @param merkleRoot Merkle root for eligibility verification
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

    /// @notice Uses a user's tipping quota for distribution
    /// @dev Only callable by the tipping contract. Ensures season is active and not ended.
    /// @param user Address of the user
    /// @param seasonId Season ID
    /// @param amount Amount of tokens to distribute
    /// @param multiplier Multiplier for the tipping quota
    /// @param maxTippingAmount Maximum allowed tipping amount
    /// @param merkleProof Merkle proof for eligibility
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
        require(block.timestamp >= seasons[seasonId].startTime, "Season not started");
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

    /// @notice Reclaims unclaimed tokens after the reclaim period
    /// @param seasonId Season ID
    function reclaimUnclaimed(uint32 seasonId) external onlyOwner nonReentrant {
        _validateSeason(seasonId);
        require(block.timestamp > seasons[seasonId].endTime + RECLAIM_PERIOD, "Reclaim period not reached");
        Season storage season = seasons[seasonId];
        uint96 unclaimed = season.seasonDistribution - season.seasonTotalDistributed;
        require(unclaimed > 0, "No unclaimed tokens");
        require(token.balanceOf(allocationManager) >= unclaimed, "Insufficient allocation manager balance");
        require(token.allowance(allocationManager, address(this)) >= unclaimed, "Insufficient allowance");
        token.safeTransferFrom(allocationManager, address(this), unclaimed);
        emit UnclaimedTokensReclaimed(seasonId, unclaimed);
    }

    /// @notice Checks if a season has ended
    /// @param seasonId Season ID
    /// @return ended True if the season has ended
    function isSeasonEnded(uint32 seasonId) public view returns (bool ended) {
        _validateSeason(seasonId);
        ended = block.timestamp > seasons[seasonId].endTime;
    }

    /// @notice Gets the remaining airdrop tokens
    /// @return remainingAirdrop Remaining tokens available for distribution
    function getRemainingAirdrop() external view returns (uint256 remainingAirdrop) {
        remainingAirdrop = TOTAL_AIRDROP - totalDistributed;
    }

    /// @notice Updates the minimum holding for a season
    /// @param seasonId Season ID
    /// @param newMinHolding New minimum holding amount
    function updateSeasonMinHolding(uint32 seasonId, uint96 newMinHolding) external onlyOwner {
        _validateSeason(seasonId);
        require(newMinHolding > 0, "Invalid min holding");
        seasons[seasonId].minHolding = newMinHolding;
        emit MinHoldingUpdated(seasonId, newMinHolding);
    }

    /// @notice Updates the base daily quota for a season
    /// @param seasonId Season ID
    /// @param newQuota New base daily quota
    function updateBaseDailyQuota(uint32 seasonId, uint96 newQuota) external onlyOwner {
        _validateSeason(seasonId);
        require(newQuota > 0, "Invalid quota");
        seasons[seasonId].baseDailyQuota = newQuota;
        emit BaseDailyQuotaUpdated(seasonId, newQuota);
    }

    /// @notice Updates the Merkle root for a season
    /// @param seasonId Season ID
    /// @param merkleRoot New Merkle root
    function updateMerkleRoot(uint32 seasonId, bytes32 merkleRoot) external onlyOwner {
        _validateSeason(seasonId);
        seasons[seasonId].merkleRoot = merkleRoot;
        emit MerkleRootUpdated(seasonId, merkleRoot);
    }

    /// @notice Adjusts the total distribution limit
    /// @param newLimit New distribution limit
    function adjustDistributionLimit(uint256 newLimit) external onlyOwner {
        require(newLimit >= totalDistributed, "New limit must be >= distributed");
        emit DistributionLimitAdjusted(newLimit);
    }

    /// @notice Gets details of a season
    /// @param seasonId Season ID
    /// @return title Season title
    /// @return startTime Season start timestamp
    /// @return endTime Season end timestamp
    /// @return minHolding Minimum GENY holding
    /// @return merkleRoot Merkle root
    /// @return seasonDistribution Total tokens allocated
    /// @return baseDailyQuota Base daily quota
    /// @return seasonTotalDistributed Total tokens distributed
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

    /// @dev Validates a season ID
    /// @param seasonId Season ID
    function _validateSeason(uint32 seasonId) private view {
        require(seasonId > 0 && seasonId <= currentSeasonId, "Invalid season ID");
    }

    /// @notice Authorizes contract upgrades
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Restricts function calls to the DAO (timelock)
    modifier onlyDAO() {
        require(msg.sender == timelock, "Caller is not DAO");
        _;
    }
}

interface IGenyAllocation {
    function getTotalReleasedTokens() external view returns (uint256);
}