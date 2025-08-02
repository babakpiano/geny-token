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

/// @dev GenyGuard interface for secure recovery mode.
interface IGenyGuard {
    function isRecoveryModeActive(address user) external view returns (bool);
    function getRecoveryWallet(address user) external view returns (address);
}

/// @title GenyVesting
/// @author compez.eth
/// @notice Linear vesting with cliff and optional recovery for Genyleap allocations.
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

    IERC20 public token;
    address public allocationManager;
    address public beneficiary;
    uint48 public startTime;
    uint48 public cliffSeconds;
    uint48 public durationSeconds;
    uint48 public intervalSeconds;
    uint96 public totalAmount;
    uint96 public releasedAmount;
    IGenyGuard public genyGuard;

    event TokensReleased(address indexed beneficiary, uint96 amount);
    event VestingInitialized(address indexed beneficiary, uint96 amount, uint48 startTime, uint48 cliff, uint48 duration);
    event VestingParametersUpdated(uint48 newCliff, uint48 newDuration, uint48 newInterval);
    event GenyGuardSet(address indexed genyGuard);

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes vesting contract.
    /// @param tokenAddress ERC20 token address.
    /// @param allocationManagerAddress Source wallet for vesting tokens.
    /// @param newOwner Multisig owner address.
    /// @param beneficiaryAddress Receiver of vested tokens.
    /// @param amount Total tokens to vest.
    /// @param cliffDuration Cliff period (seconds).
    /// @param vestingDuration Total vesting (seconds).
    /// @param releaseInterval Interval for linear release (seconds).
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
        require(tokenAddress != address(0), "Invalid token");
        require(allocationManagerAddress != address(0), "Invalid allocation manager");
        require(newOwner != address(0), "Invalid owner");
        require(beneficiaryAddress != address(0), "Invalid beneficiary");
        require(amount > 0, "Zero amount");
        require(vestingDuration >= cliffDuration, "Cliff > duration");
        require(releaseInterval > 0, "Zero interval");

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

    /// @notice Sets GenyGuard (recovery logic contract).
    function setGenyGuard(address genyGuard_) external onlyOwner {
        require(genyGuard_ != address(0), "Invalid GenyGuard");
        genyGuard = IGenyGuard(genyGuard_);
        emit GenyGuardSet(genyGuard_);
    }

    /// @notice Releases available vested tokens.
    function release() external nonReentrant whenNotPaused {
        require(block.timestamp >= startTime + cliffSeconds, "Cliff not reached");
        uint96 releasable = getReleasableAmount();
        require(releasable > 0, "Nothing releasable");

        releasedAmount += releasable;
        address payout = beneficiary;
        if (address(genyGuard) != address(0) && genyGuard.isRecoveryModeActive(beneficiary)) {
            payout = genyGuard.getRecoveryWallet(beneficiary);
            require(payout != address(0), "No recovery wallet");
        }
        require(token.balanceOf(allocationManager) >= releasable, "Not enough balance");
        require(token.allowance(allocationManager, address(this)) >= releasable, "Not enough allowance");

        token.safeTransferFrom(allocationManager, payout, releasable);
        emit TokensReleased(payout, releasable);
    }

    /// @notice Returns amount of vested tokens available for release.
    function getReleasableAmount() public view returns (uint96 amount) {
        if (block.timestamp < startTime + cliffSeconds) return 0;
        uint48 elapsedTime = uint48(block.timestamp - startTime);
        if (elapsedTime >= durationSeconds) {
            amount = totalAmount - releasedAmount;
        } else {
            amount = uint96(Math.mulDiv(totalAmount, elapsedTime, durationSeconds, Math.Rounding.Floor)) - releasedAmount;
        }
    }

    /// @notice Returns remaining vested tokens.
    function getRemainingAmount() external view returns (uint96 amount) {
        amount = totalAmount - releasedAmount;
    }

    /// @notice Updates vesting schedule parameters (before any release).
    function updateVestingParameters(
        uint48 newCliff,
        uint48 newDuration,
        uint48 newInterval
    ) external onlyOwner {
        require(newDuration >= newCliff, "Cliff > duration");
        require(newInterval > 0, "Zero interval");
        require(newDuration > 0, "Zero duration");
        require(releasedAmount == 0, "Cannot update after release started");

        cliffSeconds = newCliff;
        durationSeconds = newDuration;
        intervalSeconds = newInterval;
        emit VestingParametersUpdated(newCliff, newDuration, newInterval);
    }

    /// @notice Pauses contract functions.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses contract functions.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Authorizes contract upgrades (onlyOwner).
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
