// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap
pragma solidity 0.8.30;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import { IGenyGuard } from "./interfaces/IGenyGuard.sol";


/// @title GenyStaking
/// @author compez.eth
/// @notice Allows users to stake GENY tokens and earn annual rewards (6-10%) in the Genyleap ecosystem
/// @dev Uses OpenZeppelin upgradeable contracts with SafeERC20. If GenyGuard is set and recovery mode is active, rewards are sent to the recovery wallet.
/// Unstaking and reward claiming are allowed even when the contract is paused to prevent locking user funds.
/// @custom:security-contact security@genyleap.com
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
    /// @notice Address of the token allocation contract
    address public allocation;
    /// @notice GenyGuard contract for recovery management
    IGenyGuard public genyGuard;
    /// @notice Annual reward rate (600 to 1000 basis points)
    uint32 public rewardRate;
    /// @notice Denominator for reward calculations (10000 = 100%)
    uint32 public constant REWARD_DENOMINATOR = 10_000;
    /// @notice Seconds in a year for reward calculations
    uint48 public constant SECONDS_PER_YEAR = 365 days;

    /// @dev Structure to store user stake information
    struct Stake {
        uint96 amount; // Amount of staked tokens
        uint48 startTime; // Timestamp when staking began
        uint96 rewardDebt; // Accumulated rewards for the user
    }

    /// @notice Mapping of user addresses to their stake details
    mapping(address => Stake) public stakes;
    /// @notice Mapping of user addresses to their last reward claim timestamp
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
    /// @notice Emitted when the GenyGuard contract is set
    event GenyGuardSet(address indexed genyGuard);

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
    }

    /// @notice Sets the GenyGuard contract address
    /// @param guard Address of the GenyGuard contract
    function setGenyGuard(address guard) external onlyOwner {
        require(guard != address(0), "Invalid guard");
        genyGuard = IGenyGuard(guard);
        emit GenyGuardSet(guard);
    }

    /// @notice Stakes GENY tokens for the caller
    /// @dev Resets lastClaimed to current timestamp if the user's stake is zero (first stake or after full unstake)
    /// @param _amount Amount of tokens to stake
    function stake(uint96 _amount) external nonReentrant whenNotPaused {
        require(_amount > 0, "Zero amount");
        require(token.allowance(msg.sender, address(this)) >= _amount, "Allowance too low");
        // Reset lastClaimed if the user has no active stake to prevent reward accumulation during non-staked periods
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

    /// @notice Unstakes tokens for the caller
    /// @dev Allows unstaking even when the contract is paused to prevent locking user funds
    /// @param _amount Amount of tokens to unstake
    function unstake(uint96 _amount) external nonReentrant {
        require(_amount > 0, "Zero amount");
        require(stakes[msg.sender].amount >= _amount, "Not enough staked");
        _updateRewards(msg.sender);
        stakes[msg.sender].amount -= _amount;
        totalStaked -= _amount;
        token.safeTransfer(msg.sender, _amount);
        emit Unstaked(msg.sender, _amount);
    }

    /// @notice Claims accumulated rewards for the caller
    /// @dev Allows claiming rewards even when the contract is paused to prevent locking user funds
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
        stakes[msg.sender].rewardDebt = 0;
        token.safeTransferFrom(allocation, to, reward);
        emit RewardsClaimed(to, reward);
    }

    /// @notice Withdraws excess tokens by the owner
    /// @param _amount Amount of tokens to withdraw
    function withdrawTokens(uint96 _amount) external onlyOwner nonReentrant {
        require(_amount > 0, "Zero amount");
        uint256 available = token.balanceOf(address(this)) - totalStaked;
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
            Math.mulDiv(s.amount, rewardRate * elapsed, REWARD_DENOMINATOR * SECONDS_PER_YEAR, Math.Rounding.Floor)
        );
        reward += s.rewardDebt;
    }

    /// @notice Returns the total rewards for all staked tokens
    /// @return total Total rewards accumulated
    function getTotalRewards() external view returns (uint96 total) {
        return totalStaked > 0
            ? uint96(
                Math.mulDiv(
                    totalStaked,
                    rewardRate * (uint48(block.timestamp) - stakes[address(this)].startTime),
                    REWARD_DENOMINATOR * SECONDS_PER_YEAR,
                    Math.Rounding.Floor
                )
            )
            : 0;
    }

    /// @notice Pauses the contract
    /// @dev Only affects staking and owner-specific functions; unstaking and reward claiming remain available
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Authorizes contract upgrades
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Updates the user's reward debt based on elapsed time
    /// @param user Address of the user
    function _updateRewards(address user) private {
        Stake storage s = stakes[user];
        if (s.amount == 0) return;
        uint48 elapsed = uint48(block.timestamp) - lastClaimed[user];
        uint96 reward = uint96(
            Math.mulDiv(s.amount, rewardRate * elapsed, REWARD_DENOMINATOR * SECONDS_PER_YEAR, Math.Rounding.Floor)
        );
        s.rewardDebt += reward;
        lastClaimed[user] = uint48(block.timestamp);
    }
}