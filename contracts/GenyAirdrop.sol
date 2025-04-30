// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title GenyAirdrop
/// @author compez.eth
/// @notice Manages seasonal airdrop campaigns for GENY tokens with vesting and Merkle Proof verification.
/// @dev Supports seasonal distributions, 3-month withdrawal lock, and DAO governance via GIP. Integrates with GenyAllocation for token supply.
///      Uses nonReentrant, Pausable, and UUPS upgradeability with Ownable2Step for security.
/// @custom:security-contact security@genyleap.com
contract GenyAirdrop is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    IERC20Upgradeable public token; // GENY token contract
    address public dao; // GenyDAO contract for governance
    address public allocationManager; // GenyAllocation for token supply
    address public tippingContract; // GenyTipping contract
    address public timelock; // Timelock for DAO governance
    uint256 public constant TOTAL_AIRDROP = 16_000_000 * 1e18; // 16M GENY
    uint48 public constant WITHDRAWAL_PERIOD = 3 * 30 days; // 3 months

    /// @dev Stores seasonal airdrop details
    struct Season {
        string title; // Season title
        uint48 startTime; // Season start timestamp
        uint48 endTime; // Season end timestamp
        uint96 minHolding; // Minimum GENY holding required
        bytes32 merkleRoot; // Merkle root for eligibility
        uint96 seasonDistribution; // Total tokens for the season
        uint96 baseDailyQuota; // Base daily tipping quota
        uint96 seasonTotalDistributed; // Total tokens distributed in season
    }

    /// @dev Stores tipping quota for users per season
    struct TippingQuota {
        uint96 totalQuota; // Total available quota
        uint96 usedQuota; // Used quota
        uint48 lastReset; // Last reset timestamp
        uint96 totalTipped; // Total tipped amount
    }

    mapping(uint32 => Season) public seasons; // Season ID to details
    mapping(address => mapping(uint32 => TippingQuota)) public tippingQuotas; // User to season tipping quotas
    uint32 public currentSeasonId; // Current active season
    uint256 public totalDistributed; // Total tokens distributed across seasons

    /// @notice Emitted when a new season is added
    event SeasonAdded(uint32 indexed seasonId, string title, uint48 startTime, uint48 endTime, uint96 minHolding, uint96 seasonDistribution, uint96 baseDailyQuota);
    /// @notice Emitted when tipping quota is used
    event TippingQuotaUsed(address indexed user, uint32 indexed seasonId, uint96 amount);
    /// @notice Emitted when unclaimed tokens are withdrawn
    event UnclaimedTokensWithdrawn(address indexed dao, uint32 indexed seasonId, uint96 amount);
    /// @notice Emitted when Merkle root is updated
    event MerkleRootUpdated(uint32 indexed seasonId, bytes32 merkleRoot);
    /// @notice Emitted when base daily quota is updated
    event BaseDailyQuotaUpdated(uint32 indexed seasonId, uint96 newQuota);
    /// @notice Emitted when minimum holding is updated
    event MinHoldingUpdated(uint32 indexed seasonId, uint96 newMinHolding);
    /// @notice Emitted when tipping contract is updated
    event TippingContractUpdated(address indexed newTippingContract);

    constructor() { _disableInitializers(); }

    /// @notice Initializes the airdrop contract
    /// @param _token Address of the GENY token contract
    /// @param _dao Address of the GenyDAO contract
    /// @param _allocationManager Address of the GenyAllocation contract
    /// @param _timelock Address of the TimelockController contract
    /// @param _owner Address of the initial owner (e.g., multisig)
    function initialize(
        address _token,
        address _dao,
        address _allocationManager,
        address _timelock,
        address _owner
    ) external initializer {
        _validateAddresses(_token, _dao, _allocationManager, _timelock, _owner);

        __Ownable2Step_init();
        _transferOwnership(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        token = IERC20Upgradeable(_token);
        dao = _dao;
        allocationManager = _allocationManager;
        timelock = _timelock;
        currentSeasonId = 0;
        totalDistributed = 0;
    }

    /// @notice Sets the tipping contract address
    /// @param _tippingContract Address of the GenyTipping contract
    function setTippingContract(address _tippingContract) external onlyOwner {
        require(_tippingContract != address(0), "Invalid tipping contract");
        tippingContract = _tippingContract;
        emit TippingContractUpdated(_tippingContract);
    }

    /// @notice Adds a new airdrop season
    /// @param _title Season title
    /// @param _startTime Season start timestamp
    /// @param _endTime Season end timestamp
    /// @param _minHolding Minimum GENY holding required
    /// @param _seasonDistribution Total tokens for the season
    /// @param _baseDailyQuota Base daily tipping quota
    /// @param _merkleRoot Merkle root for eligibility verification
    function addSeason(
        string memory _title,
        uint48 _startTime,
        uint48 _endTime,
        uint96 _minHolding,
        uint96 _seasonDistribution,
        uint96 _baseDailyQuota,
        bytes32 _merkleRoot
    ) external onlyOwner whenNotPaused {
        require(_startTime >= block.timestamp, "Start time must be future");
        require(_endTime > _startTime, "End time must be after start");
        require(_seasonDistribution > 0 && totalDistributed + _seasonDistribution <= TOTAL_AIRDROP, "Invalid distribution");
        require(_baseDailyQuota > 0, "Invalid quota");
        if (currentSeasonId > 0) {
            require(block.timestamp > seasons[currentSeasonId].endTime, "Current season not ended");
        }

        seasons[++currentSeasonId] = Season({
            title: _title,
            startTime: _startTime,
            endTime: _endTime,
            minHolding: _minHolding,
            merkleRoot: _merkleRoot,
            seasonDistribution: _seasonDistribution,
            baseDailyQuota: _baseDailyQuota,
            seasonTotalDistributed: 0
        });

        emit SeasonAdded(currentSeasonId, _title, _startTime, _endTime, _minHolding, _seasonDistribution, _baseDailyQuota);
    }

    /// @notice Updates the minimum holding for a season
    /// @param _seasonId Season ID
    /// @param _newMinHolding New minimum holding
    function updateSeasonMinHolding(uint32 _seasonId, uint96 _newMinHolding) external onlyOwner {
        _validateSeason(_seasonId);
        require(_newMinHolding > 0, "Invalid min holding");
        seasons[_seasonId].minHolding = _newMinHolding;
        emit MinHoldingUpdated(_seasonId, _newMinHolding);
    }

    /// @notice Updates the base daily quota for a season
    /// @param _seasonId Season ID
    /// @param _newQuota New base daily quota
    function updateBaseDailyQuota(uint32 _seasonId, uint96 _newQuota) external onlyOwner {
        _validateSeason(_seasonId);
        require(_newQuota > 0, "Invalid quota");
        seasons[_seasonId].baseDailyQuota = _newQuota;
        emit BaseDailyQuotaUpdated(_seasonId, _newQuota);
    }

    /// @notice Updates the Merkle root for a season
    /// @param _seasonId Season ID
    /// @param _merkleRoot New Merkle root
    function updateMerkleRoot(uint32 _seasonId, bytes32 _merkleRoot) external onlyOwner {
        _validateSeason(_seasonId);
        seasons[_seasonId].merkleRoot = _merkleRoot;
        emit MerkleRootUpdated(_seasonId, _merkleRoot);
    }

    /// @notice Retrieves the tipping quota for a user in a season
    /// @param _user User address
    /// @param _seasonId Season ID
    /// @param _multiplier Multiplier for quota calculation
    /// @return quota Available tipping quota
    function getTippingQuota(address _user, uint32 _seasonId, uint32 _multiplier) external view returns (uint256 quota) {
        _validateSeason(_seasonId);
        require(token.balanceOf(_user) >= seasons[_seasonId].minHolding, "Insufficient holding");

        TippingQuota storage quotaStruct = tippingQuotas[_user][_seasonId];
        uint48 currentDay = uint48(block.timestamp / 1 days);
        uint48 lastResetDay = uint48(quotaStruct.lastReset / 1 days);

        quota = (currentDay > lastResetDay || quotaStruct.totalQuota == 0)
            ? seasons[_seasonId].baseDailyQuota * _multiplier
            : quotaStruct.totalQuota > quotaStruct.usedQuota ? quotaStruct.totalQuota - quotaStruct.usedQuota : 0;
    }

    /// @notice Uses tipping quota for a user
    /// @param _user User address
    /// @param _seasonId Season ID
    /// @param _amount Amount to use
    /// @param _multiplier Multiplier for quota
    /// @param _maxTippingAmount Maximum allowed tipping amount
    /// @param _merkleProof Merkle proof for eligibility
    function useTippingQuota(
        address _user,
        uint32 _seasonId,
        uint96 _amount,
        uint32 _multiplier,
        uint256 _maxTippingAmount,
        bytes32[] calldata _merkleProof
    ) external nonReentrant {
        require(msg.sender == tippingContract, "Only tipping contract");
        _validateSeason(_seasonId);
        require(block.timestamp <= seasons[_seasonId].endTime, "Season ended");
        require(token.balanceOf(_user) >= seasons[_seasonId].minHolding, "Insufficient holding");

        bytes32 leaf = keccak256(abi.encodePacked(_user, _maxTippingAmount));
        require(MerkleProof.verify(_merkleProof, seasons[_seasonId].merkleRoot, leaf), "Invalid Merkle proof");

        TippingQuota storage quota = tippingQuotas[_user][_seasonId];
        uint48 currentDay = uint48(block.timestamp / 1 days);
        if (currentDay > uint48(quota.lastReset / 1 days)) {
            quota.totalQuota = seasons[_seasonId].baseDailyQuota * _multiplier;
            quota.usedQuota = 0;
            quota.lastReset = uint48(block.timestamp);
        }

        require(quota.totalQuota >= quota.usedQuota + _amount, "Insufficient quota");
        require(quota.totalTipped + _amount <= _maxTippingAmount, "Exceeds max tipping");

        quota.usedQuota += _amount;
        quota.totalTipped += _amount;

        Season storage season = seasons[_seasonId];
        require(season.seasonTotalDistributed + _amount <= season.seasonDistribution, "Exceeds season distribution");
        season.seasonTotalDistributed += _amount;
        totalDistributed += _amount;

        token.safeTransferFrom(allocationManager, _user, _amount);
        emit TippingQuotaUsed(_user, _seasonId, _amount);
    }

    /// @notice Withdraws unclaimed tokens after withdrawal period
    /// @param _seasonId Season ID
    function withdrawUnclaimed(uint32 _seasonId) external onlyOwner nonReentrant {
        _validateSeason(_seasonId);
        require(block.timestamp > seasons[_seasonId].endTime + WITHDRAWAL_PERIOD, "Withdrawal period not reached");
        require(dao != address(0), "DAO address not set");

        uint96 unclaimed = seasons[_seasonId].seasonDistribution - seasons[_seasonId].seasonTotalDistributed;
        require(unclaimed > 0, "No unclaimed tokens");

        token.safeTransferFrom(allocationManager, dao, unclaimed);
        emit UnclaimedTokensWithdrawn(dao, _seasonId, unclaimed);
    }

    /// @notice Checks if a season has ended
    /// @param _seasonId Season ID
    /// @return ended True if the season has ended
    function isSeasonEnded(uint32 _seasonId) public view returns (bool ended) {
        _validateSeason(_seasonId);
        ended = block.timestamp > seasons[_seasonId].endTime;
    }

    /// @notice Returns the remaining airdrop tokens
    /// @return remainingAirdrop Remaining airdrop amount
    function getRemainingAirdrop() external view returns (uint256 remainingAirdrop) {
        remainingAirdrop = TOTAL_AIRDROP - totalDistributed;
    }

    /// @notice Returns season details
    /// @param _seasonId Season ID
    /// @return title Season title
    /// @return startTime Season start timestamp
    /// @return endTime Season end timestamp
    /// @return minHolding Minimum GENY holding required
    /// @return merkleRoot Merkle root for eligibility
    /// @return seasonDistribution Total tokens for the season
    /// @return baseDailyQuota Base daily tipping quota
    /// @return seasonTotalDistributed Total tokens distributed in season
    function getSeasonDetails(uint32 _seasonId) external view returns (
        string memory title,
        uint48 startTime,
        uint48 endTime,
        uint96 minHolding,
        bytes32 merkleRoot,
        uint96 seasonDistribution,
        uint96 baseDailyQuota,
        uint96 seasonTotalDistributed
    ) {
        _validateSeason(_seasonId);
        Season storage season = seasons[_seasonId];
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

    /// @dev Validates season ID
    function _validateSeason(uint32 _seasonId) private view {
        require(_seasonId > 0 && _seasonId <= currentSeasonId, "Invalid season ID");
    }

    /// @dev Validates initialization addresses
    function _validateAddresses(address _token, address _dao, address _allocationManager, address _timelock, address _owner) private pure {
        require(_token != address(0) && _dao != address(0) && _allocationManager != address(0) && _timelock != address(0) && _owner != address(0), "Invalid address");
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Restricts functions to DAO (via Timelock)
    modifier onlyDAO() {
        require(msg.sender == timelock, "Caller is not DAO");
        _;
    }
}

interface IGenyAllocation {
    function getTotalReleasedTokens() external view returns (uint256);
}
