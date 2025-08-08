// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.30;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @title GenyAirdrop
/// @author compez.eth
/// @notice Seasonal airdrop & tipping manager for GENY for per-season caps, and a global 32M GENY distribution cap.
/// @custom:security-contact security@genyleap.com
contract GenyAirdrop is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice GENY ERC20 token used for distributions.
    IERC20 public token;

    /// @notice Contract that actually holds tokens and approves this contract (GenyAllocation).
    address public allocationManager;

    /// @notice Contract that is allowed to spend user daily tipping quotas.
    address public tippingContract;

    /// @notice Global cap for all airdrop distributions across seasons (32M GENY).
    uint256 public constant TOTAL_AIRDROP = 32_000_000 * 1e18;

    /// @notice Unclaimed portion of a season can be reclaimed after ~90 days from season end.
    uint48 public constant RECLAIM_PERIOD = 3 * 30 days;

    /// @dev Per-season configuration and accounting.
    struct Season {
        string  title;                   // Human-readable title
        uint48  startTime;               // Start timestamp (inclusive)
        uint48  endTime;                 // End timestamp (inclusive)
        uint96  minHolding;              // Minimum user balance required to participate
        uint96  minHoldingGrowthPercent; // For derived seasons: % growth vs prior season's minHolding
        bytes32 merkleRoot;              // Eligibility Merkle root
        uint96  seasonDistribution;      // Season cap
        uint96  baseDailyQuota;          // Base daily quota (multiplied by a per-user multiplier)
        uint96  seasonTotalDistributed;  // Accrued distribution in this season
        bool    finished;                // Manual finalize guard (optional)
    }

    /// @dev Per-user daily tipping accounting within a season.
    struct TippingQuota {
        uint96 totalQuota;  // Available quota for the current (rolled) day
        uint96 usedQuota;   // Consumed quota for the current day
        uint48 lastReset;   // Timestamp used to detect new day boundary
        uint96 totalTipped; // Lifetime amount tipped for this user within the season
    }

    /// @notice seasonId => Season
    mapping(uint32 => Season) public seasons;

    /// @notice user => seasonId => TippingQuota
    mapping(address => mapping(uint32 => TippingQuota)) public tippingQuotas;

    /// @notice Latest season id (0 means none).
    uint32 public currentSeasonId;

    /// @notice Aggregate amount distributed across all seasons.
    uint256 public totalDistributed;

    /// @notice Sum of all seasonDistribution values (must stay <= TOTAL_AIRDROP).
    uint256 public totalPlannedDistribution;

    /// @notice Address-level blacklist/whitelist switches.
    mapping(address => bool) public isBlacklisted;
    mapping(address => bool) public isWhitelisted;

    /// @notice If true, only whitelisted users can claim/tip.
    bool public useWhitelist;

    /// @notice One-time off-chain claim marker per (user, season).
    mapping(address => mapping(uint32 => bool)) public claimedOffchain;

    // ──────────────────────────────
    // Events
    // ──────────────────────────────

    /// @notice Emitted when a new season is created.
    event SeasonAdded(
        uint32 indexed seasonId,
        string title,
        uint48 startTime,
        uint48 endTime,
        uint96 minHolding,
        uint96 seasonDistribution,
        uint96 baseDailyQuota
    );

    /// @notice Emitted on successful tipping quota spending.
    event TippingQuotaUsed(address indexed user, uint32 indexed seasonId, uint96 amount);

    /// @notice Emitted when unclaimed season budget is pulled into this contract.
    event UnclaimedTokensReclaimed(uint32 indexed seasonId, uint96 amount);

    /// @notice Emitted when a season's Merkle root is updated.
    event MerkleRootUpdated(uint32 indexed seasonId, bytes32 merkleRoot);

    /// @notice Emitted when base daily quota is updated for a season.
    event BaseDailyQuotaUpdated(uint32 indexed seasonId, uint96 newQuota);

    /// @notice Emitted when min holding is updated for a season.
    event MinHoldingUpdated(uint32 indexed seasonId, uint96 newMinHolding);

    /// @notice Emitted when a season is finalized.
    event SeasonFinished(uint32 indexed seasonId, uint96 distributed);

    /// @notice Emitted on off-chain claim.
    event ClaimedOffchain(
        address indexed user,
        uint32 indexed seasonId,
        uint96 amount,
        uint256 snapshotBalance,
        uint256 snapshotBlock
    );

    /// @notice Emitted when list statuses change.
    event BlacklistUpdated(address indexed user, bool status);
    event WhitelistUpdated(address indexed user, bool status);
    event WhitelistEnforcementChanged(bool enforced);

    /// @notice Emitted when tipping contract changes.
    event TippingContractUpdated(address indexed newTippingContract);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the airdrop module (UUPS pattern).
    /// @dev Must be called exactly once on the proxy. Sets core addresses and resets counters.
    /// @param tokenAddress ERC20 token address (GENY).
    /// @param allocationManagerAddress Contract holding tokens and approving this contract.
    /// @param newOwner Initial owner (ideally a multisig / timelock).
    function initialize(
        address tokenAddress,
        address allocationManagerAddress,
        address newOwner
    ) external initializer {
        require(tokenAddress != address(0), "Invalid token address");
        require(allocationManagerAddress != address(0), "Invalid allocation manager address");
        require(newOwner != address(0), "Invalid owner address");

        __Ownable2Step_init();
        _transferOwnership(newOwner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        token = IERC20(tokenAddress);
        allocationManager = allocationManagerAddress;

        currentSeasonId = 0;
        totalDistributed = 0;
        totalPlannedDistribution = 0;
        useWhitelist = false;
    }

    /// @notice Add/remove an address from blacklist.
    /// @param user Target address.
    /// @param value True to blacklist; false to remove.
    function setBlacklist(address user, bool value) external onlyOwner {
        isBlacklisted[user] = value;
        emit BlacklistUpdated(user, value);
    }

    /// @notice Add/remove an address from whitelist.
    /// @param user Target address.
    /// @param value True to whitelist; false to remove.
    function setWhitelist(address user, bool value) external onlyOwner {
        isWhitelisted[user] = value;
        emit WhitelistUpdated(user, value);
    }

    /// @notice Enable/disable whitelist enforcement globally.
    /// @param enforced If true, only whitelisted users can claim/tip.
    function setWhitelistEnforcement(bool enforced) external onlyOwner {
        useWhitelist = enforced;
        emit WhitelistEnforcementChanged(enforced);
    }

    /// @notice Set the tipping contract allowed to spend quotas.
    /// @param newTippingContract Tipping contract address (non-zero).
    function setTippingContract(address newTippingContract) external onlyOwner {
        require(newTippingContract != address(0), "Invalid tipping contract");
        tippingContract = newTippingContract;
        emit TippingContractUpdated(newTippingContract);
    }

    /// @notice Pause all state-changing operations.
    function pause() external onlyOwner { _pause(); }

    /// @notice Unpause the contract.
    function unpause() external onlyOwner { _unpause(); }

    // ──────────────────────────────
    // Season management
    // ──────────────────────────────

    /// @notice Create a new season window with cap/eligibility.
    /// @dev If a previous season exists, it must have ended.
    /// @param title Human-readable label for UIs/announcements.
    /// @param startTime Season start (>= now).
    /// @param endTime Season end (> startTime).
    /// @param baseMinHolding Minimum GENY holding for the (first or base) season.
    /// @param growthPercent If not the first season, minHolding grows by this % vs previous.
    /// @param seasonDistribution Token cap for this season.
    /// @param baseDailyQuota Base daily quota used to compute per-user quotas.
    /// @param merkleRoot Merkle root for eligibility (tipping/claim).
    function addSeason(
        string memory title,
        uint48 startTime,
        uint48 endTime,
        uint96 baseMinHolding,
        uint96 growthPercent,
        uint96 seasonDistribution,
        uint96 baseDailyQuota,
        bytes32 merkleRoot
    ) external onlyOwner whenNotPaused {
        require(startTime >= block.timestamp, "Start time must be future");
        require(endTime > startTime, "End time must be after start");
        require(seasonDistribution > 0, "Invalid distribution");
        require(baseDailyQuota > 0, "Invalid quota");

        uint96 minHolding_ = baseMinHolding;
        if (currentSeasonId > 0) {
            require(block.timestamp > seasons[currentSeasonId].endTime, "Current season not ended");
            minHolding_ = seasons[currentSeasonId].minHolding +
                uint96((uint256(seasons[currentSeasonId].minHolding) * growthPercent) / 100);
        }

        require(totalPlannedDistribution + seasonDistribution <= TOTAL_AIRDROP, "Planned cap exceeded");
        totalPlannedDistribution += seasonDistribution;

        seasons[++currentSeasonId] = Season({
            title: title,
            startTime: startTime,
            endTime: endTime,
            minHolding: minHolding_,
            minHoldingGrowthPercent: growthPercent,
            merkleRoot: merkleRoot,
            seasonDistribution: seasonDistribution,
            baseDailyQuota: baseDailyQuota,
            seasonTotalDistributed: 0,
            finished: false
        });

        emit SeasonAdded(currentSeasonId, title, startTime, endTime, minHolding_, seasonDistribution, baseDailyQuota);
    }

    // ──────────────────────────────
    // Tipping (only tippingContract)
    // ──────────────────────────────

    /// @notice Spend a user's daily tipping quota and transfer tokens to them.
    /// @dev Only callable by `tippingContract`. Uses day-based rollover for quotas.
    /// @param user Recipient whose quota/lifetime limits are checked.
    /// @param seasonId Target season id (must be active).
    /// @param amount Amount to tip (must be > 0).
    /// @param multiplier Quota multiplier applied on the next daily reset (use 1 if none).
    /// @param maxTippingAmount Max lifetime tipping for this user in this season (in Merkle leaf).
    /// @param merkleProof Proof for leaf = keccak256(abi.encodePacked(user, maxTippingAmount)).
    function useTippingQuota(
        address user,
        uint32 seasonId,
        uint96 amount,
        uint32 multiplier,
        uint256 maxTippingAmount,
        bytes32[] calldata merkleProof
    ) external nonReentrant whenNotPaused {
        require(msg.sender == tippingContract && tippingContract != address(0), "Only tipping contract");
        _validateSeason(seasonId);
        Season storage season = seasons[seasonId];
        require(!season.finished, "Season finished");
        require(block.timestamp >= season.startTime, "Season not started");
        require(block.timestamp <= season.endTime, "Season ended");
        require(!isBlacklisted[user], "Blacklisted");
        if (useWhitelist) require(isWhitelisted[user], "Not whitelisted");
        require(token.balanceOf(user) >= season.minHolding, "Insufficient holding");
        require(amount > 0, "Invalid amount");

        require(season.merkleRoot != bytes32(0), "Merkle root not set");
        bytes32 leaf = keccak256(abi.encodePacked(user, maxTippingAmount));
        require(MerkleProof.verify(merkleProof, season.merkleRoot, leaf), "Invalid Merkle proof");

        TippingQuota storage quota = tippingQuotas[user][seasonId];
        uint48 currentDay = uint48(block.timestamp / 1 days);
        if (currentDay > uint48(quota.lastReset / 1 days)) {
            quota.totalQuota = uint96(uint256(season.baseDailyQuota) * (multiplier == 0 ? 1 : multiplier));
            quota.usedQuota = 0;
            quota.lastReset = uint48(block.timestamp);
        }
        require(quota.totalQuota >= quota.usedQuota + amount, "Insufficient quota");
        require(quota.totalTipped + amount <= maxTippingAmount, "Exceeds max tipping");

        require(season.seasonTotalDistributed + amount <= season.seasonDistribution, "Exceeds season distribution");
        require(totalDistributed + amount <= TOTAL_AIRDROP, "Exceeds total airdrop");
        require(token.allowance(allocationManager, address(this)) >= amount, "Insufficient allowance");

        quota.usedQuota += amount;
        quota.totalTipped += amount;
        season.seasonTotalDistributed += amount;
        totalDistributed += amount;

        token.safeTransferFrom(allocationManager, user, amount);

        emit TippingQuotaUsed(user, seasonId, amount);
    }

    // ──────────────────────────────
    // Off-chain claim (one-time per user/season)
    // ──────────────────────────────

    /// @notice Claim an off-chain allocated amount once per season.
    /// @dev Merkle leaf must encode (account, snapshotBalance, snapshotBlock, maxTippingAmount).
    /// @param seasonId Target season id (must be active).
    /// @param amount Amount to claim (must be > 0 and <= maxTippingAmount).
    /// @param snapshotBalance Off-chain recorded balance at `snapshotBlock` (for UI/Audit).
    /// @param snapshotBlock Snapshot block number (for UI/Audit).
    /// @param maxTippingAmount Upper-bound validated by the Merkle leaf.
    /// @param merkleProof Merkle proof for the leaf above.
    function claimAirdrop(
        uint32 seasonId,
        uint96 amount,
        uint256 snapshotBalance,
        uint256 snapshotBlock,
        uint256 maxTippingAmount,
        bytes32[] calldata merkleProof
    ) external nonReentrant whenNotPaused {
        _validateSeason(seasonId);
        Season storage season = seasons[seasonId];

        require(!season.finished, "Season finished");
        require(block.timestamp >= season.startTime, "Season not started");
        require(block.timestamp <= season.endTime, "Season ended");
        require(!isBlacklisted[msg.sender], "Blacklisted");
        if (useWhitelist) require(isWhitelisted[msg.sender], "Not whitelisted");
        require(token.balanceOf(msg.sender) >= season.minHolding, "Insufficient holding");
        require(!claimedOffchain[msg.sender][seasonId], "Already claimed");
        require(amount > 0, "Invalid amount");

        require(season.merkleRoot != bytes32(0), "Merkle root not set");
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, snapshotBalance, snapshotBlock, maxTippingAmount));
        require(MerkleProof.verify(merkleProof, season.merkleRoot, leaf), "Invalid proof");

        require(amount <= maxTippingAmount, "Exceeds max claimable");
        require(season.seasonTotalDistributed + amount <= season.seasonDistribution, "Exceeds season");
        require(totalDistributed + amount <= TOTAL_AIRDROP, "Exceeds total airdrop");
        require(token.allowance(allocationManager, address(this)) >= amount, "Insufficient allowance");

        claimedOffchain[msg.sender][seasonId] = true;
        season.seasonTotalDistributed += amount;
        totalDistributed += amount;

        token.safeTransferFrom(allocationManager, msg.sender, amount);

        emit ClaimedOffchain(msg.sender, seasonId, amount, snapshotBalance, snapshotBlock);
    }

    // ──────────────────────────────
    // Finalize & reclaim
    // ──────────────────────────────

    /// @notice Manually finalize a season (optional guard for future flows).
    /// @param seasonId Season to finalize.
    function finishSeason(uint32 seasonId) external onlyOwner {
        _validateSeason(seasonId);
        seasons[seasonId].finished = true;
        emit SeasonFinished(seasonId, seasons[seasonId].seasonTotalDistributed);
    }

    /// @notice Reclaim unspent season budget into this contract after reclaim window.
    /// @dev Pulls from `allocationManager` using `safeTransferFrom` (requires allowance).
    /// @param seasonId Season whose unclaimed amount should be reclaimed.
    function reclaimUnclaimed(uint32 seasonId) external onlyOwner nonReentrant {
        _validateSeason(seasonId);
        Season storage season = seasons[seasonId];
        require(block.timestamp > season.endTime + RECLAIM_PERIOD, "Reclaim period not reached");

        uint96 unclaimed = season.seasonDistribution - season.seasonTotalDistributed;
        require(unclaimed > 0, "No unclaimed tokens");
        require(token.balanceOf(allocationManager) >= unclaimed, "Insufficient allocation manager balance");
        require(token.allowance(allocationManager, address(this)) >= unclaimed, "Insufficient allowance");

        token.safeTransferFrom(allocationManager, address(this), unclaimed);

        emit UnclaimedTokensReclaimed(seasonId, unclaimed);
    }

    // ──────────────────────────────
    // Admin updates
    // ──────────────────────────────

    /// @notice Update minimum holding requirement for a season.
    /// @param seasonId Target season id.
    /// @param newMinHolding New min holding (> 0).
    function updateSeasonMinHolding(uint32 seasonId, uint96 newMinHolding) external onlyOwner {
        _validateSeason(seasonId);
        require(newMinHolding > 0, "Invalid min holding");
        seasons[seasonId].minHolding = newMinHolding;
        emit MinHoldingUpdated(seasonId, newMinHolding);
    }

    /// @notice Update base daily quota for a season.
    /// @param seasonId Target season id.
    /// @param newQuota New base daily quota (> 0).
    function updateBaseDailyQuota(uint32 seasonId, uint96 newQuota) external onlyOwner {
        _validateSeason(seasonId);
        require(newQuota > 0, "Invalid quota");
        seasons[seasonId].baseDailyQuota = newQuota;
        emit BaseDailyQuotaUpdated(seasonId, newQuota);
    }

    /// @notice Update Merkle root for a season.
    /// @param seasonId Target season id.
    /// @param merkleRoot New Merkle root.
    function updateMerkleRoot(uint32 seasonId, bytes32 merkleRoot) external onlyOwner {
        _validateSeason(seasonId);
        seasons[seasonId].merkleRoot = merkleRoot;
        emit MerkleRootUpdated(seasonId, merkleRoot);
    }

    // ──────────────────────────────
    // Views
    // ──────────────────────────────

    /// @notice Check if a season has ended.
    /// @param seasonId Season id to check.
    /// @return ended True if `block.timestamp > endTime`.
    function isSeasonEnded(uint32 seasonId) public view returns (bool ended) {
        _validateSeason(seasonId);
        ended = block.timestamp > seasons[seasonId].endTime;
    }

    /// @notice Global remaining airdrop capacity.
    /// @return remainingAirdrop TOTAL_AIRDROP - totalDistributed.
    function getRemainingAirdrop() external view returns (uint256 remainingAirdrop) {
        remainingAirdrop = TOTAL_AIRDROP - totalDistributed;
    }

    /// @notice Packed season details for UI/frontends.
    /// @param seasonId Target season id.
    /// @return title Season title.
    /// @return startTime Start timestamp.
    /// @return endTime End timestamp.
    /// @return minHolding Minimum user holding.
    /// @return minHoldingGrowthPercent Growth % vs previous season (if used).
    /// @return merkleRoot Eligibility root.
    /// @return seasonDistribution Season cap.
    /// @return baseDailyQuota Base daily quota.
    /// @return seasonTotalDistributed Distributed so far in this season.
    /// @return finished Finalized flag.
    function getSeasonStats(uint32 seasonId)
        external
        view
        returns (
            string memory title,
            uint48 startTime,
            uint48 endTime,
            uint96 minHolding,
            uint96 minHoldingGrowthPercent,
            bytes32 merkleRoot,
            uint96 seasonDistribution,
            uint96 baseDailyQuota,
            uint96 seasonTotalDistributed,
            bool finished
        )
    {
        _validateSeason(seasonId);
        Season storage season = seasons[seasonId];
        return (
            season.title,
            season.startTime,
            season.endTime,
            season.minHolding,
            season.minHoldingGrowthPercent,
            season.merkleRoot,
            season.seasonDistribution,
            season.baseDailyQuota,
            season.seasonTotalDistributed,
            season.finished
        );
    }

    /// @notice Whether `user` already used their off-chain claim for `seasonId`.
    /// @param user Account to check.
    /// @param seasonId Season id.
    /// @return True if claimed before; false otherwise.
    function getUserClaimed(address user, uint32 seasonId) external view returns (bool) {
        return claimedOffchain[user][seasonId];
    }

    /// @notice Read current daily quota info for a user/season.
    /// @param user Account to query.
    /// @param seasonId Season id.
    /// @return totalQuota Daily quota available at the last reset.
    /// @return usedQuota Amount consumed since last reset.
    /// @return lastReset Timestamp when the daily quota last rolled over.
    /// @return totalTipped Lifetime tipped amount in this season for `user`.
    function getUserQuota(address user, uint32 seasonId)
        external
        view
        returns (uint96 totalQuota, uint96 usedQuota, uint48 lastReset, uint96 totalTipped)
    {
        TippingQuota storage q = tippingQuotas[user][seasonId];
        return (q.totalQuota, q.usedQuota, q.lastReset, q.totalTipped);
    }

    // ──────────────────────────────
    // Internals / upgrades
    // ──────────────────────────────

    /// @dev Reverts if `seasonId` is not in [1..currentSeasonId].
    function _validateSeason(uint32 seasonId) private view {
        require(seasonId > 0 && seasonId <= currentSeasonId, "Invalid season ID");
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Storage gap reserved for future state variables (UUPS safe-append pattern).
    /// Reduce the length when adding new variables at the end to keep the layout shift-free.
    uint256[50] private __gap;
}
