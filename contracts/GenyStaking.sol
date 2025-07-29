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

/// @dev An interface for GenyGuard ultra-secure recovery logic
interface IGenyGuard {
    function isRecoveryModeActive(address user) external view returns (bool);
    function getRecoveryWallet(address user) external view returns (address);
}

/// @title GenyStaking
/// @author compez.eth
/// @notice Allows users to stake GENY tokens and earn rewards (6-10% annually) in the Genyleap ecosystem.
/// @dev Uses OpenZeppelin upgradeable contracts with SafeERC20. If GenyGuard is set and recovery mode is active, rewards go to recovery wallet.
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

    IERC20 public token;
    address public allocation;
    IGenyGuard public genyGuard;

    uint32 public rewardRate;
    uint32 public constant REWARD_DENOMINATOR = 10_000;
    uint48 public constant SECONDS_PER_YEAR = 365 days;

    struct Stake {
        uint96 amount;
        uint48 startTime;
        uint96 rewardDebt;
    }

    mapping(address => Stake) public stakes;
    mapping(address => uint48) public lastClaimed;
    uint96 public totalStaked;

    event Staked(address indexed user, uint96 amount);
    event Unstaked(address indexed user, uint96 amount);
    event RewardsClaimed(address indexed user, uint96 amount);
    event RewardRateUpdated(uint32 oldRate, uint32 newRate);
    event TokensWithdrawn(address indexed owner, uint96 amount);
    event GenyGuardSet(address indexed genyGuard);

    constructor() {
        _disableInitializers();
    }

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

    function setGenyGuard(address guard) external onlyOwner {
        require(guard != address(0), "Invalid guard");
        genyGuard = IGenyGuard(guard);
        emit GenyGuardSet(guard);
    }

    function stake(uint96 _amount) external nonReentrant whenNotPaused {
        require(_amount > 0, "Zero amount");
        require(token.allowance(msg.sender, address(this)) >= _amount, "Allowance too low");

        if (stakes[msg.sender].amount == 0 && lastClaimed[msg.sender] == 0) {
            lastClaimed[msg.sender] = uint48(block.timestamp);
        }

        _updateRewards(msg.sender);

        stakes[msg.sender].amount += _amount;
        stakes[msg.sender].startTime = uint48(block.timestamp);
        totalStaked += _amount;

        token.safeTransferFrom(msg.sender, address(this), _amount);
        emit Staked(msg.sender, _amount);
    }

    function unstake(uint96 _amount) external nonReentrant whenNotPaused {
        require(_amount > 0, "Zero amount");
        require(stakes[msg.sender].amount >= _amount, "Not enough staked");

        _updateRewards(msg.sender);

        stakes[msg.sender].amount -= _amount;
        totalStaked -= _amount;

        token.safeTransfer(msg.sender, _amount);
        emit Unstaked(msg.sender, _amount);
    }

    function claimRewards() external nonReentrant whenNotPaused returns (uint96 reward) {
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

    function withdrawTokens(uint96 _amount) external onlyOwner nonReentrant {
        require(_amount > 0, "Zero amount");
        uint256 available = token.balanceOf(address(this)) - totalStaked;
        require(available >= _amount, "Insufficient excess");

        token.safeTransfer(msg.sender, _amount);
        emit TokensWithdrawn(msg.sender, _amount);
    }

    function updateRewardRate(uint32 _newRate) external onlyOwner {
        require(_newRate >= 600 && _newRate <= 1000, "Invalid reward rate");
        uint32 oldRate = rewardRate;
        rewardRate = _newRate;
        emit RewardRateUpdated(oldRate, _newRate);
    }

    function getClaimableRewards(address user) external view returns (uint96 reward) {
        Stake memory s = stakes[user];
        if (s.amount == 0) return 0;

        uint48 elapsed = uint48(block.timestamp) - lastClaimed[user];
        reward = uint96(
            Math.mulDiv(s.amount, rewardRate * elapsed, REWARD_DENOMINATOR * SECONDS_PER_YEAR, Math.Rounding.Floor)
        );
        reward += s.rewardDebt;
    }

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

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

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
