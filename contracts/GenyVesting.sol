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

/// @dev An interface for GenyGuard ultra-secure recovery logic.
interface IGenyGuard {
    function isRecoveryModeActive(address user) external view returns (bool);
    function getRecoveryWallet(address user) external view returns (address);
}

/// @title GenyVesting
/// @author compez.eth
/// @notice Manages linear vesting with cliff for Genyleap token allocations (e.g., team, investors), integrated with GenyGuard.
/// @dev Integrates with GenyAllocation for token supply and with GenyGuard for beneficiary recovery.
/// @custom:security-contact security@genyleap.com
contract GenyVesting is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    IERC20 public token; // GENY token contract
    address public allocationManager; // GenyAllocation contract
    address public beneficiary; // Address to receive vested tokens
    uint48 public startTime; // Vesting start time
    uint48 public cliffSeconds; // Cliff period in seconds
    uint48 public durationSeconds; // Total vesting duration in seconds
    uint48 public intervalSeconds; // Release interval in seconds (e.g., monthly)
    uint96 public totalAmount; // Total tokens to vest
    uint96 public releasedAmount; // Tokens released so far

    IGenyGuard public genyGuard; // Optional GenyGuard integration

    /// @notice Emitted when vested tokens are released
    event TokensReleased(address indexed beneficiary, uint96 amount);
    /// @notice Emitted when vesting is initialized
    event VestingInitialized(address indexed beneficiary, uint96 amount, uint48 startTime, uint48 cliff, uint48 duration);
    /// @notice Emitted when vesting parameters are updated
    event VestingParametersUpdated(uint48 newCliff, uint48 newDuration, uint48 newInterval);
    /// @notice Emitted when GenyGuard is set
    event GenyGuardSet(address indexed genyGuard);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address tokenAddress,
        address allocationManagerAddress,
        address newOwner,
        address beneficiaryAddress,
        uint96 amount,
        uint48 cliffDuration,
        uint48 vestingDuration,
        uint48 releaseInterval
    ) external initializer {
        require(tokenAddress != address(0), "Invalid token address");
        require(allocationManagerAddress != address(0), "Invalid allocation manager address");
        require(newOwner != address(0), "Invalid owner address");
        require(beneficiaryAddress != address(0), "Invalid beneficiary address");
        require(amount > 0, "Amount must be greater than zero");
        require(vestingDuration >= cliffDuration, "Duration must be >= cliff");
        require(releaseInterval > 0, "Interval must be greater than zero");

        __Ownable2Step_init();
        _transferOwnership(newOwner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        token = IERC20(tokenAddress);
        allocationManager = allocationManagerAddress;
        beneficiary = beneficiaryAddress;
        startTime = uint48(block.timestamp);
        cliffSeconds = cliffDuration;
        durationSeconds = vestingDuration;
        intervalSeconds = releaseInterval;
        totalAmount = amount;

        emit VestingInitialized(beneficiaryAddress, amount, startTime, cliffDuration, vestingDuration);
    }

    /// @notice Sets GenyGuard contract address for recovery mode logic (only owner)
    function setGenyGuard(address genyGuard_) external onlyOwner {
        require(genyGuard_ != address(0), "Invalid GenyGuard");
        genyGuard = IGenyGuard(genyGuard_);
        emit GenyGuardSet(genyGuard_);
    }

    /// @notice Releases vested tokens to the beneficiary or their recovery wallet if in recovery mode
    function release() external nonReentrant whenNotPaused {
        require(block.timestamp >= startTime + cliffSeconds, "Cliff period not reached");
        uint96 releasable = getReleasableAmount();
        require(releasable > 0, "No tokens to release");

        releasedAmount += releasable;

        // Use Guard if needed
        address payout = beneficiary;
        if (address(genyGuard) != address(0) && genyGuard.isRecoveryModeActive(beneficiary)) {
            payout = genyGuard.getRecoveryWallet(beneficiary);
            require(payout != address(0), "No recovery wallet set");
        }

        require(token.balanceOf(allocationManager) >= releasable, "Insufficient allocation balance");
        require(token.allowance(allocationManager, address(this)) >= releasable, "Insufficient allowance");
        token.safeTransferFrom(allocationManager, payout, releasable);

        emit TokensReleased(payout, releasable);
    }

    function getReleasableAmount() public view returns (uint96 amount) {
        if (block.timestamp < startTime + cliffSeconds) return 0;

        uint48 elapsedTime = uint48(block.timestamp - startTime);
        if (elapsedTime >= durationSeconds) {
            amount = totalAmount - releasedAmount;
        } else {
            amount = uint96(
                Math.mulDiv(totalAmount, elapsedTime, durationSeconds, Math.Rounding.Floor)
            ) - releasedAmount;
        }
    }

    function getRemainingAmount() external view returns (uint96 amount) {
        amount = totalAmount - releasedAmount;
    }

    function updateVestingParameters(
        uint48 newCliff,
        uint48 newDuration,
        uint48 newInterval
    ) external onlyOwner {
        require(newDuration >= newCliff, "Duration must be >= cliff");
        require(newInterval > 0, "Interval must be greater than zero");
        require(newDuration > 0, "Duration must be greater than zero");
        require(releasedAmount == 0, "Cannot update after release started");

        cliffSeconds = newCliff;
        durationSeconds = newDuration;
        intervalSeconds = newInterval;
        emit VestingParametersUpdated(newCliff, newDuration, newInterval);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
