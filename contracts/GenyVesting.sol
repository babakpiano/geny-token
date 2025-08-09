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
import {IGenyGuard} from "./interfaces/IGenyGuard.sol";

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

    constructor() {
        // Prevent initializing the implementation directly.
        _disableInitializers();
    }

    // --------- LEGACY STORAGE (DO NOT REORDER/REMOVE) ---------
    IERC20  public token;
    address public allocationManager;

    // Legacy single-schedule fields
    address public beneficiary;
    uint48  public startTime;
    uint48  public cliffSeconds;
    uint48  public durationSeconds;
    uint48  public intervalSeconds;
    uint96  public totalAmount;
    uint96  public releasedAmount;

    IGenyGuard public genyGuard;

    // --------- NEW STORAGE (APPENDED AFTER LEGACY) ------------
    struct Schedule {
        address beneficiary;
        uint48 startTime;
        uint48 cliffSeconds;
        uint48 durationSeconds;
        uint48 intervalSeconds;
        uint96 totalAmount;
        uint96 releasedAmount;
        bool   exists;
    }

    mapping(uint256 => Schedule) public schedules;
    uint256 public scheduleCount;   // start from 1 for convenience (0 reserved)
    bool    public legacyMigrated;  // true after migrating legacy into a schedule

    /// @notice If true (default), any fee-on-transfer is rejected (must receive exactly requested amount).
    bool    public enforceExactTransfer;

    // ------------------- Constants / Limits -------------------
    uint256 private constant MAX_BATCH = 200;

    // ------------------- Custom Errors -------------------
    error InvalidToken();
    error InvalidOwner();
    error InvalidBeneficiary();
    error InvalidManager();
    error InvalidGuard();
    error ZeroAmount();
    error ZeroInterval();
    error CliffGTDuration();
    error CliffNotReached();
    error NothingToRelease();
    error NotEnoughBalance();
    error NotEnoughAllowance();
    error NoSuchSchedule();
    error AlreadyExists();
    error AlreadyReleased();
    error LegacyAlreadyMigrated();
    error LegacyEmpty();
    error FeeDetected();        // received < requested while enforceExactTransfer = true
    error TransferZero();       // no tokens received (protects weird tokens)
    error TooManyIds();

    // ------------------- Events -------------------
    event ScheduleCreated(
        uint256 indexed id,
        address indexed beneficiary,
        uint96  indexed totalAmount,
        uint48  startTime,
        uint48  cliffSeconds,
        uint48  durationSeconds,
        uint48  intervalSeconds
    );
    event ScheduleReleased(uint256 indexed id, address indexed beneficiary, uint96 amountReceived);
    event ScheduleBeneficiaryUpdated(uint256 indexed id, address indexed oldBeneficiary, address indexed newBeneficiary);
    event ScheduleCanceled(uint256 indexed id, uint96 remainingAmount);
    event ScheduleParamsUpdated(uint256 indexed id, uint48 newCliff, uint48 newDuration, uint48 newInterval);
    event LegacyMigrated(uint256 indexed id);
    event LegacyReleased(address indexed beneficiary, uint96 amountReceived);
    event GenyGuardSet(address indexed genyGuard);
    event AllocationManagerUpdated(address indexed oldManager, address indexed newManager);
    event EnforceExactTransferSet(bool enforce);

    // ------------------- Init -------------------
    /// @notice Standard initializer (not used during an upgrade).
    function initialize(
        address tokenAddress,
        address allocationManagerAddress,
        address newOwner
    ) external initializer {
        if (tokenAddress == address(0)) revert InvalidToken();
        if (allocationManagerAddress == address(0)) revert InvalidManager();
        if (newOwner == address(0)) revert InvalidOwner();

        __Ownable2Step_init();
        _transferOwnership(newOwner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        token = IERC20(tokenAddress);
        allocationManager = allocationManagerAddress;

        // Reserve index 0; start from 1 for nicer UX.
        if (scheduleCount == 0) scheduleCount = 1;

        // Default: reject fee-on-transfer tokens to keep accounting exact.
        enforceExactTransfer = true;
    }

    // ------------------- Admin -------------------
    /// @notice Set GenyGuard to support recovery-mode payouts.
    function setGenyGuard(address guard_) external onlyOwner {
        if (guard_ == address(0) || guard_.code.length == 0) revert InvalidGuard();
        if (address(genyGuard) == guard_) return; // avoid redundant write
        genyGuard = IGenyGuard(guard_);
        emit GenyGuardSet(guard_);
    }

    /// @notice Update the allocation manager address (source of tokens via transferFrom).
    function setAllocationManager(address newManager) external onlyOwner {
        if (newManager == address(0)) revert InvalidManager();
        address old = allocationManager;
        if (newManager == old) return; // avoid redundant write
        allocationManager = newManager;
        emit AllocationManagerUpdated(old, newManager);
    }

    /// @notice Configure handling of fee-on-transfer tokens.
    /// @param enforce If true, require exact receipt == requested amount (default). If false, accept net received.
    function setEnforceExactTransfer(bool enforce) external onlyOwner {
        if (enforceExactTransfer == enforce) return; // avoid redundant write
        enforceExactTransfer = enforce;
        emit EnforceExactTransferSet(enforce);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ------------------- Core (multi-schedule) -------------------
    /// @notice Create a new vesting schedule.
    /// @param id Unique schedule id (0 is reserved and not allowed).
    /// @param _beneficiary Recipient of vested tokens (or their recovery wallet).
    /// @param amount Total tokens to vest.
    /// @param cliff Cliff length in seconds.
    /// @param duration Total duration in seconds (must be >= cliff).
    /// @param interval Interval hint in seconds (not used on-chain for math; > 0).
    function createSchedule(
        uint256 id,
        address _beneficiary,
        uint96 amount,
        uint48 cliff,
        uint48 duration,
        uint48 interval
    ) external onlyOwner whenNotPaused {
        if (id == 0) revert AlreadyExists(); // id 0 is reserved
        if (schedules[id].exists) revert AlreadyExists();
        if (_beneficiary == address(0)) revert InvalidBeneficiary();
        if (amount == 0) revert ZeroAmount();
        if (interval == 0) revert ZeroInterval();
        if (duration < cliff) revert CliffGTDuration();

        uint48 _start = uint48(block.timestamp);
        schedules[id] = Schedule({
            beneficiary: _beneficiary,
            startTime: _start,
            cliffSeconds: cliff,
            durationSeconds: duration,
            intervalSeconds: interval,
            totalAmount: amount,
            releasedAmount: 0,
            exists: true
        });

        unchecked { ++scheduleCount; }
        emit ScheduleCreated(id, _beneficiary, amount, _start, cliff, duration, interval);
    }

    /// @notice Release currently vested tokens for a schedule.
    function release(uint256 id) external nonReentrant whenNotPaused {
        _release(id);
    }

    /// @notice Release for multiple schedules in one call.
    function releaseMany(uint256[] calldata ids) external nonReentrant whenNotPaused {
        uint256 len = ids.length;
        if (len > MAX_BATCH) revert TooManyIds();
        for (uint256 i = 0; i < len;) {
            _release(ids[i]);
            unchecked { ++i; }
        }
    }

    /// @notice Cancel a schedule. Does not move tokens; only deletes the record.
    function cancelSchedule(uint256 id) external onlyOwner whenNotPaused {
        Schedule storage s = schedules[id];
        if (!s.exists) revert NoSuchSchedule();
        uint96 remaining = s.totalAmount - s.releasedAmount;
        delete schedules[id];
        emit ScheduleCanceled(id, remaining);
    }

    /// @notice Change the beneficiary for a schedule.
    function setScheduleBeneficiary(uint256 id, address newBeneficiary) external onlyOwner {
        if (newBeneficiary == address(0)) revert InvalidBeneficiary();
        Schedule storage s = schedules[id];
        if (!s.exists) revert NoSuchSchedule();
        address old = s.beneficiary;
        if (newBeneficiary == old) return; // avoid redundant write
        s.beneficiary = newBeneficiary;
        emit ScheduleBeneficiaryUpdated(id, old, newBeneficiary);
    }

    /// @notice Update vesting params for a schedule (only before any release).
    function updateScheduleParams(uint256 id, uint48 newCliff, uint48 newDuration, uint48 newInterval)
        external onlyOwner
    {
        if (newInterval == 0) revert ZeroInterval();
        if (newDuration < newCliff) revert CliffGTDuration();
        Schedule storage s = schedules[id];
        if (!s.exists) revert NoSuchSchedule();
        if (s.releasedAmount != 0) revert AlreadyReleased();

        s.cliffSeconds = newCliff;
        s.durationSeconds = newDuration;
        s.intervalSeconds = newInterval;
        emit ScheduleParamsUpdated(id, newCliff, newDuration, newInterval);
    }

    // ------------------- Legacy support -------------------
    /// @notice View releasable amount for the legacy single-schedule (0 if migrated).
    function legacyGetReleasable() public view returns (uint96) {
        if (legacyMigrated) return 0;
        if (totalAmount == 0) return 0;
        if (block.timestamp < startTime + cliffSeconds) return 0;

        uint48 elapsed = uint48(block.timestamp - startTime);
        uint96 vested = elapsed >= durationSeconds
            ? totalAmount
            : uint96(Math.mulDiv(uint256(totalAmount), uint256(elapsed), uint256(durationSeconds), Math.Rounding.Floor));
        return vested - releasedAmount;
    }

    /// @notice Release tokens for the legacy schedule (before migration).
    function releaseLegacy() external nonReentrant whenNotPaused {
        if (legacyMigrated) revert NothingToRelease();
        if (totalAmount == 0) revert LegacyEmpty();
        if (block.timestamp < startTime + cliffSeconds) revert CliffNotReached();

        uint96 releasable = legacyGetReleasable();
        if (releasable == 0) revert NothingToRelease();

        address to = _resolvePayout(beneficiary);
        uint96 received = _pullFromManager(to, releasable);

        if (enforceExactTransfer && received != releasable) revert FeeDetected();
        if (received == 0) revert TransferZero();

        // Account by actual received (protects fee-on-transfer when enforceExactTransfer=false)
        releasedAmount += received;
        emit LegacyReleased(to, received);
    }

    /// @notice One-time migration: copy legacy single-schedule into a new multi-schedule id.
    function migrateLegacy(uint256 id) external onlyOwner {
        if (legacyMigrated) revert LegacyAlreadyMigrated();
        if (totalAmount == 0) revert LegacyEmpty();
        if (id == 0 || schedules[id].exists) revert AlreadyExists();

        schedules[id] = Schedule({
            beneficiary: beneficiary,
            startTime: startTime,
            cliffSeconds: cliffSeconds,
            durationSeconds: durationSeconds,
            intervalSeconds: intervalSeconds,
            totalAmount: totalAmount,
            releasedAmount: releasedAmount,
            exists: true
        });

        legacyMigrated = true;
        emit LegacyMigrated(id);
    }

    // ------------------- Views -------------------
    function getReleasable(uint256 id) public view returns (uint96) {
        Schedule storage s = schedules[id];
        if (!s.exists) return 0;
        if (block.timestamp < s.startTime + s.cliffSeconds) return 0;
        return _releasableOf(s);
    }

    function vestedAt(uint256 id, uint48 ts) public view returns (uint96) {
        Schedule storage s = schedules[id];
        if (!s.exists) return 0;
        if (ts < s.startTime + s.cliffSeconds) return 0;
        uint48 elapsed = ts - s.startTime;
        if (elapsed >= s.durationSeconds) return s.totalAmount;
        return uint96(Math.mulDiv(uint256(s.totalAmount), uint256(elapsed), uint256(s.durationSeconds), Math.Rounding.Floor));
    }

    function endTime(uint256 id) external view returns (uint48) {
        Schedule storage s = schedules[id];
        if (!s.exists) return 0;
        return s.startTime + s.durationSeconds;
    }

    function claimable(uint256 id) external view returns (uint96) {
        return getReleasable(id);
    }

    // ------------------- Internal helpers -------------------
    function _release(uint256 id) internal {
        Schedule storage s = schedules[id];
        if (!s.exists) revert NoSuchSchedule();
        if (block.timestamp < s.startTime + s.cliffSeconds) revert CliffNotReached();

        uint96 releasable = _releasableOf(s);
        if (releasable == 0) revert NothingToRelease();

        address to = _resolvePayout(s.beneficiary);
        uint96 received = _pullFromManager(to, releasable);

        if (enforceExactTransfer && received != releasable) revert FeeDetected();
        if (received == 0) revert TransferZero();

        s.releasedAmount += received;
        emit ScheduleReleased(id, s.beneficiary, received);
    }

    function _releasableOf(Schedule storage s) internal view returns (uint96) {
        uint48 elapsed = uint48(block.timestamp - s.startTime);
        uint96 vested = elapsed >= s.durationSeconds
            ? s.totalAmount
            : uint96(Math.mulDiv(uint256(s.totalAmount), uint256(elapsed), uint256(s.durationSeconds), Math.Rounding.Floor));
        return vested - s.releasedAmount;
    }

    function _resolvePayout(address user) internal view returns (address) {
        if (address(genyGuard) != address(0) && genyGuard.isRecoveryModeActive(user)) {
            address rw = genyGuard.getRecoveryWallet(user);
            if (rw == address(0)) revert InvalidBeneficiary();
            return rw;
        }
        return user;
    }

    /// @dev Pull tokens from allocationManager to `to` and return the *actual* received amount.
    function _pullFromManager(address to, uint96 amount) internal returns (uint96 received) {
        IERC20 _token = token;
        address _manager = allocationManager;

        if (_token.balanceOf(_manager) < amount) revert NotEnoughBalance();
        if (_token.allowance(_manager, address(this)) < amount) revert NotEnoughAllowance();

        uint256 pre = _token.balanceOf(to);
        _token.safeTransferFrom(_manager, to, amount);
        uint256 post = _token.balanceOf(to);

        uint256 delta = post - pre;
        if (delta == 0) revert TransferZero();
        if (delta > type(uint96).max) {
            delta = type(uint96).max;
        }
        return uint96(delta);
    }

    // ------------------- Upgrade -------------------
    function _authorizeUpgrade(address) internal view override onlyOwner {}

    // Legacy had uint256[50] __gap; we consumed some slots for new vars.
    // Keep a reduced gap to preserve total layout flexibility.
    uint256[50] private __gap;
}