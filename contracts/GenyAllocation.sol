// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.30;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title GenyAllocation
/// @author compez.eth
/// @notice Manages multiple token allocations (vested and unlocked) with linear vesting after a cliff.
/// @dev Upgradeable via UUPS + Ownable2Step. Privileged actions gated by the owner (expected multisig).
///      Uses block.timestamp for long-term vesting; intervalSeconds is informational (for off-chain tooling).
contract GenyAllocation is
    Initializable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ---- Config / State ----
    IERC20 public token;                // GENY token contract
    bool private tokenSet;              // True once token is set
    uint256 public totalReleasedTokens; // Sum of all released (vested + unlocked)

    uint256 public constant TOTAL_SUPPLY = 2.56e8 * 1e18; // 256,000,000 * 1e18
    uint48  public constant MAX_VESTING_DURATION = 48 * 30 days;

    uint48 public deploymentTime;       // For upgrade maturity logic (1y lock)
    bool   public upgradesDisabled;

    /// @dev Packed struct for an allocation
    struct Allocation {
        address beneficiary;              // Receiver (multisig/DAO/pool)
        uint48  startTime;                // Vesting start
        uint48  cliffSeconds;             // Cliff length
        uint48  durationSeconds;          // Linear vest duration (post-cliff)
        uint48  intervalSeconds;          // UI hint (not used on-chain for math)
        uint96  vestedAmount;             // Total vested amount
        uint96  unlockedAmount;           // Total unlocked amount
        uint96  releasedVestedAmount;     // Already released vested
        uint96  withdrawnUnlockedAmount;  // Already withdrawn unlocked
        bool    exists;                   // Guard for presence
    }

    mapping(uint256 allocationId => Allocation) public allocations;
    uint256 public allocationCount;
    uint256 public totalAllocated;       // Sum of all allocated (vested + unlocked)

    // ---- Events ----
    event AllocationCreated(
        uint256 indexed allocationId,
        address indexed beneficiary,
        uint96  indexed vestedAmount,
        uint96  unlockedAmount,
        uint48  cliffSeconds,
        uint48  durationSeconds,
        uint48  intervalSeconds
    );
    event VestedTokensReleased(uint256 indexed allocationId, address indexed beneficiary, uint96 indexed amount);
    event UnlockedTokensWithdrawn(uint256 indexed allocationId, address indexed beneficiary, uint96 indexed amount);
    event BeneficiaryUpdated(uint256 indexed allocationId, address indexed oldBeneficiary, address indexed newBeneficiary);
    event AllocationCancelled(uint256 indexed allocationId, address indexed beneficiary, uint256 remaining);
    event TotalAllocatedUpdated(uint256 indexed oldTotal, uint256 indexed newTotal);
    event TokenSet(address indexed token);
    event AllowanceSet(address indexed spender, uint256 amount);
    event UpgradesDisabled();

    // ---- Init ----

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice UUPS initializer
    function initialize(address newOwner) external initializer {
        require(newOwner != address(0), "Invalid owner");

        __Ownable2Step_init();
        _transferOwnership(newOwner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        allocationCount = 1; // avoid zero-to-one write pattern later
        deploymentTime = uint48(block.timestamp);
    }

    // ---- Admin ----

    /// @notice Set the ERC20 token address (one-time)
    function setToken(address token_) external onlyOwner {
        require(token_ != address(0), "Invalid token");
        require(!tokenSet, "Token already set");
        require(token_.code.length > 0, "Token must be contract");
        token = IERC20(token_);
        tokenSet = true;
        emit TokenSet(token_);
    }

    /// @notice Approve spender with OZ v5-safe pattern
    function approveSpender(address spender, uint256 amount) external onlyOwner tokenRequired {
        require(spender != address(0), "Invalid spender");
        token.forceApprove(spender, amount);
        emit AllowanceSet(spender, amount);
    }

    /// @notice Pause all state-changing flows except view
    function pause() external onlyOwner { _pause(); }

    /// @notice Unpause the contract
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Permanently disable upgrades after 1 year from initialize
    function disableUpgrades() external onlyOwner {
        require(!upgradesDisabled, "Upgrades disabled");
        require(block.timestamp >= deploymentTime + 365 days, "Too early");
        upgradesDisabled = true;
        emit UpgradesDisabled();
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address /*newImplementation*/) internal view override onlyOwner {
        require(!upgradesDisabled, "Upgrades disabled");
    }

    // ---- Allocations ----

    /**
     * @notice Create a new allocation.
     * @dev Requires contract balance to already hold enough tokens to back the new allocation.
     */
    function createAllocation(
        uint256 allocationId,
        address beneficiary,
        uint96  vestedAmount,
        uint96  unlockedAmount,
        uint48  cliffSeconds,
        uint48  durationSeconds,
        uint48  intervalSeconds
    )
        external
        onlyOwner
        nonReentrant
        whenNotPaused
        tokenRequired
    {
        require(allocationId > 0, "Invalid allocation ID");
        require(!allocations[allocationId].exists, "Allocation already exists");
        require(beneficiary != address(0), "Invalid beneficiary");
        require(vestedAmount + unlockedAmount != 0, "No tokens");

        if (vestedAmount > 0) {
            require(durationSeconds > 0, "Invalid duration");
            require(intervalSeconds != 0, "Invalid interval");
            require(intervalSeconds < durationSeconds, "Invalid interval");
            require(durationSeconds <= MAX_VESTING_DURATION, "Duration too long");
        }

        uint256 newTotal = totalAllocated + vestedAmount + unlockedAmount;
        require(newTotal <= TOTAL_SUPPLY, "Exceeds total supply");
        require(newTotal <= token.balanceOf(address(this)), "Insufficient balance");

        Allocation storage a = allocations[allocationId];
        a.beneficiary     = beneficiary;
        a.vestedAmount    = vestedAmount;
        a.unlockedAmount  = unlockedAmount;
        a.startTime       = uint48(block.timestamp);
        a.cliffSeconds    = cliffSeconds;
        a.durationSeconds = durationSeconds;
        a.intervalSeconds = intervalSeconds; // UI hint only
        a.exists          = true;

        uint256 oldTotal = totalAllocated;
        totalAllocated   = newTotal;
        allocationCount++;

        emit TotalAllocatedUpdated(oldTotal, totalAllocated);
        emit AllocationCreated(
            allocationId,
            beneficiary,
            vestedAmount,
            unlockedAmount,
            cliffSeconds,
            durationSeconds,
            intervalSeconds
        );
    }

    /// @notice Release vested tokens to beneficiary (anyone can call).
    function releaseVested(uint256 allocationId)
        external
        nonReentrant
        whenNotPaused
        tokenRequired
    {
        Allocation storage a = allocations[allocationId];
        require(a.exists, "Invalid allocation");
        require(block.timestamp >= a.startTime + a.cliffSeconds, "Cliff not reached");

        uint96 releasable = uint96(getReleasableVestedAmount(allocationId));
        require(releasable != 0, "No tokens to release");

        a.releasedVestedAmount += releasable;
        totalReleasedTokens    += releasable;
        token.safeTransfer(a.beneficiary, releasable);

        emit VestedTokensReleased(allocationId, a.beneficiary, releasable);
    }

    /// @notice Withdraw unlocked tokens to beneficiary (owner only).
    function withdrawUnlocked(uint256 allocationId, uint96 amount)
        external
        onlyOwner
        nonReentrant
        whenNotPaused
        tokenRequired
    {
        Allocation storage a = allocations[allocationId];
        require(a.exists, "Invalid allocation");
        require(amount != 0, "Invalid amount");
        require(amount <= a.unlockedAmount - a.withdrawnUnlockedAmount, "Insufficient balance");

        a.withdrawnUnlockedAmount += amount;
        totalReleasedTokens       += amount;
        token.safeTransfer(a.beneficiary, amount);

        emit UnlockedTokensWithdrawn(allocationId, a.beneficiary, amount);
    }

    /// @notice Cancel an allocation and free its un-released amounts from totalAllocated.
    function cancelAllocation(uint256 allocationId)
        external
        onlyOwner
        nonReentrant
    {
        Allocation storage a = allocations[allocationId];
        require(a.exists, "Invalid allocation");

        uint256 remainingVested   = uint256(a.vestedAmount) - uint256(a.releasedVestedAmount);
        uint256 remainingUnlocked = uint256(a.unlockedAmount) - uint256(a.withdrawnUnlockedAmount);
        uint256 totalRemaining    = remainingVested + remainingUnlocked;

        uint256 oldTotal = totalAllocated;
        totalAllocated  -= totalRemaining;
        emit TotalAllocatedUpdated(oldTotal, totalAllocated);

        address beneficiary = a.beneficiary;
        delete allocations[allocationId];

        emit AllocationCancelled(allocationId, beneficiary, totalRemaining);
    }

    /// @notice Update the beneficiary address for an allocation (owner only).
    function updateBeneficiary(uint256 allocationId, address newBeneficiary) external onlyOwner {
        Allocation storage a = allocations[allocationId];
        require(a.exists, "Invalid allocation");
        require(newBeneficiary != address(0), "Invalid beneficiary");
        require(newBeneficiary != a.beneficiary, "Same beneficiary");

        address old = a.beneficiary;
        a.beneficiary = newBeneficiary;

        emit BeneficiaryUpdated(allocationId, old, newBeneficiary);
    }

    // ---- Views ----

    /// @notice Linear vesting after cliff (timestamp-based).
    function getReleasableVestedAmount(uint256 allocationId) public view returns (uint256) {
        Allocation storage a = allocations[allocationId];
        if (!a.exists || a.vestedAmount == 0) return 0;

        uint256 startPlusCliff = uint256(a.startTime) + uint256(a.cliffSeconds);
        if (block.timestamp < startPlusCliff) return 0;

        uint48 elapsedTime = uint48(block.timestamp) - a.startTime;

        // Past end => fully vested minus what was already released
        if (elapsedTime >= a.cliffSeconds + a.durationSeconds) {
            return uint256(a.vestedAmount) - uint256(a.releasedVestedAmount);
        }

        // Linear portion
        uint48 vestingElapsed = elapsedTime - a.cliffSeconds;
        uint256 vested = Math.mulDiv(
            uint256(a.vestedAmount),
            uint256(vestingElapsed),
            uint256(a.durationSeconds),
            Math.Rounding.Floor
        );
        return vested - uint256(a.releasedVestedAmount);
    }

    function getRemainingAmounts(uint256 allocationId)
        external
        view
        returns (uint256 remainingVested, uint256 remainingUnlocked)
    {
        Allocation storage a = allocations[allocationId];
        require(a.exists, "Invalid allocation");
        remainingVested   = uint256(a.vestedAmount) - uint256(a.releasedVestedAmount);
        remainingUnlocked = uint256(a.unlockedAmount) - uint256(a.withdrawnUnlockedAmount);
    }

    function getBalance() external view tokenRequired returns (uint256) {
        return token.balanceOf(address(this));
    }

    function getTotalReleasedTokens() external view tokenRequired returns (uint256) {
        return totalReleasedTokens;
    }

    modifier tokenRequired() {
        require(tokenSet, "Token not set");
        _;
    }

    /// @dev Storage gap for future variable additions (OZ pattern).
    /// If you add new state variables at the end in a future upgrade,
    /// decrease the length of this array by the same number of slots.
    uint256[50] private __gap;
}
