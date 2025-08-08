// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {IGenyGuard} from "./interfaces/IGenyGuard.sol";

/// @title GenyStaking
/// @author compez.eth
/// @notice Allows users to stake GENY tokens and earn annual rewards (6-10%) in the Genyleap ecosystem
/// @dev Upgradeable (UUPS). Unstake/claim allowed while paused. Rewards are pulled from `allocation`.
///      If GenyGuard is set and user is in recovery, rewards go to their recovery wallet.
contract GenyStaking is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @notice The GENY token contract
    IERC20 public token;
    /// @notice Address of the token allocation contract (funds reward via allowance)
    address public allocation;
    /// @notice GenyGuard contract for recovery management (optional; zero disables)
    IGenyGuard public genyGuard;
    /// @notice Annual reward rate (600 to 1000 basis points)
    uint32 public rewardRate;

    /// @notice Denominator for reward calculations (10000 = 100%)
    uint32 public constant REWARD_DENOMINATOR = 10_000;
    /// @notice Seconds in a year for reward calculations
    uint48 public constant SECONDS_PER_YEAR = 365 days;

    /// @dev Structure to store user stake information
    struct Stake {
        uint96 amount;     // Amount of staked tokens
        uint48 startTime;  // Timestamp when staking began (informational)
        uint96 rewardDebt; // Accumulated rewards for the user (to be claimed)
    }

    /// @notice Mapping of user addresses to their stake details
    mapping(address => Stake) public stakes;
    /// @notice Mapping of user addresses to their last reward accrual timestamp
    mapping(address => uint48) public lastClaimed;
    /// @notice Total amount of tokens staked in the contract
    uint96 public totalStaked;

    /// @notice Emitted when a user stakes tokens
    event Staked(address indexed user, uint96 amount);
    /// @notice Emitted when a user unstakes tokens
    event Unstaked(address indexed user, uint96 amount);
    /// @notice Emitted when a user claims rewards
    event RewardsClaimed(address indexed user, uint96 amount);
    /// @notice Emitted when the reward rate is updated
    event RewardRateUpdated(uint32 oldRate, uint32 newRate);
    /// @notice Emitted when the owner withdraws excess tokens
    event TokensWithdrawn(address indexed owner, uint96 amount);
    /// @notice Emitted when the GenyGuard contract is set/cleared
    event GenyGuardSet(address indexed genyGuard);
    event InitializedStaking(address indexed owner, address indexed token, address indexed allocation, uint32 rewardRate);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the staking contract
    /// @param _token Address of the GENY token contract
    /// @param _allocation Address of the token allocation contract
    /// @param _owner Address of the initial owner (e.g., multisig)
    /// @param _rewardRate Initial reward rate (600 to 1000 basis points)
    function initialize(
        address _token,
        address _allocation,
        address _owner,
        uint32 _rewardRate
    ) external initializer {
        require(_token != address(0), "Invalid token");
        require(_allocation != address(0), "Invalid allocation");
        require(_owner != address(0), "Invalid owner");
        require(_rewardRate >= 600 && _rewardRate <= 1000, "Reward rate out of range");

        __Ownable2Step_init();
        _transferOwnership(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        token = IERC20(_token);
        allocation = _allocation;
        rewardRate = _rewardRate;

        emit InitializedStaking(_owner, _token, _allocation, _rewardRate);
    }

    /// @notice Sets or clears the GenyGuard contract address (zero disables)
    function setGenyGuard(address guard) external onlyOwner {
        if (guard != address(0)) {
            require(guard.code.length > 0, "Guard must be contract");
        }
        genyGuard = IGenyGuard(guard);
        emit GenyGuardSet(guard);
    }

    /// @notice Stakes GENY tokens for the caller
    /// @param _amount Amount of tokens to stake
    function stake(uint96 _amount) external nonReentrant whenNotPaused {
        require(_amount > 0, "Zero amount");
        // Explicit allowance check for clean revert reason and UX
        require(token.allowance(msg.sender, address(this)) >= _amount, "Allowance too low");

        // If first time (or after full unstake), reset lastClaimed to now
        if (stakes[msg.sender].amount == 0) {
            lastClaimed[msg.sender] = uint48(block.timestamp);
        }

        _updateRewards(msg.sender);

        stakes[msg.sender].amount += _amount;
        stakes[msg.sender].startTime = uint48(block.timestamp);
        totalStaked += _amount;

        token.safeTransferFrom(msg.sender, address(this), _amount);
        emit Staked(msg.sender, _amount);
    }

    /// @notice Unstakes tokens for the caller (allowed even when paused)
    /// @param _amount Amount of tokens to unstake
    function unstake(uint96 _amount) external nonReentrant {
        require(_amount > 0, "Zero amount");
        Stake storage s = stakes[msg.sender];
        require(s.amount >= _amount, "Not enough staked");

        _updateRewards(msg.sender);

        s.amount -= _amount;
        totalStaked -= _amount;

        token.safeTransfer(msg.sender, _amount);
        emit Unstaked(msg.sender, _amount);
    }

    /// @notice Claims accumulated rewards for the caller (allowed even when paused)
    /// @return reward Amount of rewards claimed
    function claimRewards() external nonReentrant returns (uint96 reward) {
        _updateRewards(msg.sender);

        reward = stakes[msg.sender].rewardDebt;
        require(reward > 0, "No rewards");
        require(token.allowance(allocation, address(this)) >= reward, "Allocation allowance too low");

        address to = msg.sender;
        if (address(genyGuard) != address(0) && genyGuard.isRecoveryModeActive(to)) {
            to = genyGuard.getRecoveryWallet(to);
            require(to != address(0), "No recovery wallet");
        }

        // effects before interaction
        stakes[msg.sender].rewardDebt = 0;

        token.safeTransferFrom(allocation, to, reward);
        emit RewardsClaimed(to, reward);
    }

    /// @notice Withdraws excess tokens by the owner (not staked funds)
    function withdrawTokens(uint96 _amount) external onlyOwner nonReentrant {
        require(_amount > 0, "Zero amount");
        uint256 bal = token.balanceOf(address(this));
        require(bal >= uint256(totalStaked), "Invariant");
        uint256 available = bal - uint256(totalStaked);
        require(available >= _amount, "Insufficient excess");

        token.safeTransfer(msg.sender, _amount);
        emit TokensWithdrawn(msg.sender, _amount);
    }

    /// @notice Updates the reward rate
    /// @param _newRate New reward rate (600 to 1000 basis points)
    function updateRewardRate(uint32 _newRate) external onlyOwner {
        require(_newRate >= 600 && _newRate <= 1000, "Invalid reward rate");
        uint32 oldRate = rewardRate;
        rewardRate = _newRate;
        emit RewardRateUpdated(oldRate, _newRate);
    }

    /// @notice Returns the claimable rewards for a user
    /// @param user Address of the user
    /// @return reward Amount of claimable rewards
    function getClaimableRewards(address user) external view returns (uint96 reward) {
        Stake memory s = stakes[user];
        if (s.amount == 0) return 0;

        uint48 elapsed = uint48(block.timestamp) - lastClaimed[user];
        reward = uint96(
            Math.mulDiv(
                uint256(s.amount),
                uint256(rewardRate) * uint256(elapsed),
                uint256(REWARD_DENOMINATOR) * uint256(SECONDS_PER_YEAR),
                Math.Rounding.Floor
            )
        );
        reward += s.rewardDebt;
    }

    /// @notice Pauses the contract (staking only; unstake/claim remain available)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Authorizes contract upgrades (UUPS)
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Updates the user's reward debt based on elapsed time
    function _updateRewards(address user) private {
        Stake storage s = stakes[user];
        if (s.amount == 0) return;

        uint48 elapsed = uint48(block.timestamp) - lastClaimed[user];
        if (elapsed == 0) return;

        uint96 reward = uint96(
            Math.mulDiv(
                uint256(s.amount),
                uint256(rewardRate) * uint256(elapsed),
                uint256(REWARD_DENOMINATOR) * uint256(SECONDS_PER_YEAR),
                Math.Rounding.Floor
            )
        );
        s.rewardDebt += reward;
        lastClaimed[user] = uint48(block.timestamp);
    }

    /// @dev Storage gap for future variable additions (OZ pattern).
    /// If you add new state variables at the end in a future upgrade,
    /// decrease the length of this array by the same number of slots.
    uint256[50] private __gap;
}
