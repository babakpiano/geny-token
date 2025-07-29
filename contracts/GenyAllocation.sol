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
/// @notice Manages multiple token allocations (vested and unlocked) for the Genyleap ecosystem with customizable vesting schedules.
/// @dev Uses OpenZeppelin upgradeable contracts with Ownable2Step for enhanced security. Supports multiple beneficiaries and vesting schedules.
///      The owner must be a multisig contract (e.g., Gnosis Safe) for secure governance.
///      Uses block.timestamp for vesting calculations, which is safe for long-term vesting (e.g., months) as miner manipulation is negligible.
/// @custom:security-contact security@genyleap.com
contract GenyAllocation is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    IERC20 public token; // GENY token contract
    bool private tokenSet; // Flag to track if token is set
    uint256 public totalReleasedTokens; // Tracks total released tokens (vested + unlocked)
    address public timelock; // TimelockController for governance upgrades
    uint256 public constant TOTAL_SUPPLY = 2.56e8 * 1e18; // Fixed total supply
    uint48 public constant MAX_VESTING_DURATION = 48 * 30 days; // Max 48 months

    /// @dev Struct to store allocation details for each beneficiary, optimized for storage packing
    struct Allocation {
        address beneficiary; // Address receiving tokens (e.g., multisig, DAO, pool)
        uint48 startTime; // Vesting start time
        uint48 cliffSeconds; // Cliff period in seconds
        uint48 durationSeconds; // Total vesting duration in seconds
        uint48 intervalSeconds; // Release interval in seconds (e.g., monthly)
        uint96 vestedAmount; // Total vested tokens
        uint96 unlockedAmount; // Total unlocked tokens
        uint96 releasedVestedAmount; // Vested tokens released so far
        uint96 withdrawnUnlockedAmount; // Unlocked tokens withdrawn so far
        bool exists; // Flag to prevent duplicate allocations
    }

    /// @dev Mapping of allocation IDs to Allocation details
    mapping(uint256 allocationId => Allocation) public allocations;
    uint256 public allocationCount; // Total number of allocations
    uint256 public totalAllocated; // Total tokens allocated (vested + unlocked)
    bool public upgradesDisabled; // Flag to disable upgrades after maturity

    /// @notice Emitted when a new allocation is created
    event AllocationCreated(
        uint256 indexed allocationId,
        address indexed beneficiary,
        uint96 indexed vestedAmount,
        uint96 unlockedAmount,
        uint48 cliffSeconds,
        uint48 durationSeconds,
        uint48 intervalSeconds
    );

    /// @notice Emitted when vested tokens are released
    event VestedTokensReleased(uint256 indexed allocationId, address indexed beneficiary, uint96 indexed amount);

    /// @notice Emitted when unlocked tokens are withdrawn
    event UnlockedTokensWithdrawn(uint256 indexed allocationId, address indexed beneficiary, uint96 indexed amount);

    /// @notice Emitted when a beneficiary address is updated
    event BeneficiaryUpdated(uint256 indexed allocationId, address indexed oldBeneficiary, address indexed newBeneficiary);

    /// @notice Emitted when an allocation is cancelled
    event AllocationCancelled(uint256 indexed allocationId, address indexed beneficiary, uint256 remaining);

    /// @notice Emitted when total allocated amount changes
    event TotalAllocatedUpdated(uint256 indexed oldTotal, uint256 indexed newTotal);

    /// @notice Emitted when the token address is set
    event TokenSet(address indexed token);

    /// @notice Emitted when allowance is set for a spender
    event AllowanceSet(address indexed spender, uint256 amount);

    /// @notice Emitted when the contract is upgraded
    event Upgraded(address indexed newImplementation);

    /// @notice Emitted when upgrades are disabled
    event UpgradesDisabled();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the allocation contract
    /// @dev The owner must be a multisig contract (e.g., Gnosis Safe) for secure governance.
    /// @param newOwner Address of the contract owner (multisig)
    /// @param timelockAddress Address of the TimelockController
    function initialize(address newOwner, address timelockAddress) external initializer {
        require(newOwner != address(0), "Invalid owner");
        require(timelockAddress != address(0), "Invalid timelock");

        __Ownable2Step_init();
        _transferOwnership(newOwner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        timelock = timelockAddress;
        allocationCount = 1; // Start from 1 to avoid zero-to-one storage writes
    }

    /// @notice Sets the GENY token address
    /// @dev Only callable by the owner (multisig) and only once
    /// @param token_ Address of the GENY token contract
    function setToken(address token_) external onlyOwner {
        require(token_ != address(0), "Invalid token");
        require(!tokenSet, "Token already set");
        token = IERC20(token_);
        tokenSet = true;
        emit TokenSet(token_);
    }

    /// @notice Approves a spender to transfer tokens from this contract
    /// @dev Only callable by the owner (multisig)
    /// @param spender Address of the spender
    /// @param amount Amount of tokens to approve
    function approveSpender(address spender, uint256 amount) external onlyOwner tokenRequired {
        require(spender != address(0), "Invalid spender");
        token.approve(spender, amount);
        emit AllowanceSet(spender, amount);
    }

    /// @dev Modifier to ensure token is set before operations
    modifier tokenRequired() {
        require(tokenSet, "Token not set");
        _;
    }

    /// @notice Creates a new allocation
    /// @dev The owner (multisig) must ensure the allocation ID is unique and parameters align with tokenomics.
    /// @param allocationId Unique ID for the allocation
    /// @param beneficiary Address to receive tokens
    /// @param vestedAmount Total vested tokens
    /// @param unlockedAmount Total unlocked tokens
    /// @param cliffSeconds Cliff period in seconds
    /// @param durationSeconds Total vesting duration in seconds
    /// @param intervalSeconds Release interval in seconds
    function createAllocation(
        uint256 allocationId,
        address beneficiary,
        uint96 vestedAmount,
        uint96 unlockedAmount,
        uint48 cliffSeconds,
        uint48 durationSeconds,
        uint48 intervalSeconds
    ) external onlyOwner nonReentrant whenNotPaused tokenRequired {
        require(allocationId > 0, "Invalid allocation ID");
        require(!allocations[allocationId].exists, "Allocation already exists");
        require(beneficiary != address(0), "Invalid beneficiary");
        require(vestedAmount + unlockedAmount != 0, "No tokens");
        if (vestedAmount > 0) {
            require(durationSeconds > cliffSeconds, "Invalid duration");
            require(intervalSeconds != 0, "Invalid interval");
            require(intervalSeconds < durationSeconds, "Invalid interval");
            require(durationSeconds <= MAX_VESTING_DURATION, "Duration too long"); // Limit to 48 months
        }

        address thisContract = address(this);
        require(totalAllocated + vestedAmount + unlockedAmount <= TOTAL_SUPPLY, "Exceeds total supply");
        require(totalAllocated + vestedAmount + unlockedAmount <= token.balanceOf(thisContract), "Insufficient balance");

        Allocation storage allocation = allocations[allocationId];
        allocation.beneficiary = beneficiary;
        allocation.vestedAmount = vestedAmount;
        allocation.unlockedAmount = unlockedAmount;
        allocation.startTime = uint48(block.timestamp); // Safe for long-term vesting
        allocation.cliffSeconds = cliffSeconds;
        allocation.durationSeconds = durationSeconds;
        allocation.intervalSeconds = intervalSeconds;
        allocation.exists = true;

        uint256 oldTotal = totalAllocated;
        totalAllocated = totalAllocated + vestedAmount + unlockedAmount;
        allocationCount++; // Increment allocation count
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

    /// @notice Releases vested tokens for a specific allocation
    /// @dev Callable by anyone, but tokens are sent to the predefined beneficiary
    /// @param allocationId ID of the allocation
    function releaseVested(uint256 allocationId) external nonReentrant whenNotPaused tokenRequired {
        Allocation storage allocation = allocations[allocationId];
        require(allocation.exists, "Invalid allocation");
        require(block.timestamp >= allocation.startTime + allocation.cliffSeconds, "Cliff not reached");

        uint96 releasable = uint96(getReleasableVestedAmount(allocationId));
        require(releasable != 0, "No tokens to release");

        allocation.releasedVestedAmount = allocation.releasedVestedAmount + releasable;
        totalReleasedTokens += releasable; // Update total released tokens
        token.safeTransfer(allocation.beneficiary, releasable);
        emit VestedTokensReleased(allocationId, allocation.beneficiary, releasable);
    }

    /// @notice Withdraws unlocked tokens for a specific allocation
    /// @dev Only callable by the owner (multisig)
    /// @param allocationId ID of the allocation
    /// @param amount Amount to withdraw
    function withdrawUnlocked(uint256 allocationId, uint96 amount) external onlyOwner nonReentrant whenNotPaused tokenRequired {
        Allocation storage allocation = allocations[allocationId];
        require(allocation.exists, "Invalid allocation");
        require(amount != 0, "Invalid amount");
        require(amount <= allocation.unlockedAmount - allocation.withdrawnUnlockedAmount, "Insufficient balance");

        allocation.withdrawnUnlockedAmount = allocation.withdrawnUnlockedAmount + amount;
        totalReleasedTokens += amount; // Update total released tokens
        token.safeTransfer(allocation.beneficiary, amount);
        emit UnlockedTokensWithdrawn(allocationId, allocation.beneficiary, amount);
    }

    /// @notice Cancels an existing allocation
    /// @dev Only callable by the owner (multisig). Removes allocation and updates total allocated amount.
    /// @param allocationId ID of the allocation to cancel
    function cancelAllocation(uint256 allocationId) external onlyOwner nonReentrant {
        Allocation storage allocation = allocations[allocationId];
        require(allocation.exists, "Invalid allocation");

        uint256 remainingVested = allocation.vestedAmount - allocation.releasedVestedAmount;
        uint256 remainingUnlocked = allocation.unlockedAmount - allocation.withdrawnUnlockedAmount;
        uint256 totalRemaining = remainingVested + remainingUnlocked;

        uint256 oldTotal = totalAllocated;
        totalAllocated -= totalRemaining;
        emit TotalAllocatedUpdated(oldTotal, totalAllocated);

        address beneficiary = allocation.beneficiary;
        delete allocations[allocationId];
        emit AllocationCancelled(allocationId, beneficiary, totalRemaining);
    }

    /// @notice Updates the beneficiary for a specific allocation
    /// @dev Only callable by the owner (multisig)
    /// @param allocationId ID of the allocation
    /// @param newBeneficiary New beneficiary address
    function updateBeneficiary(uint256 allocationId, address newBeneficiary) external onlyOwner {
        Allocation storage allocation = allocations[allocationId];
        require(allocation.exists, "Invalid allocation");
        require(newBeneficiary != address(0), "Invalid beneficiary");
        require(newBeneficiary != allocation.beneficiary, "Same beneficiary");

        address oldBeneficiary = allocation.beneficiary;
        allocation.beneficiary = newBeneficiary;
        emit BeneficiaryUpdated(allocationId, oldBeneficiary, newBeneficiary);
    }

    /// @notice Calculates the releasable vested amount for an allocation
    /// @dev Uses Math.mulDiv for precise calculations to avoid precision loss
    /// @param allocationId ID of the allocation
    /// @return Amount of vested tokens that can be released
    function getReleasableVestedAmount(uint256 allocationId) public view returns (uint256) {
        Allocation storage allocation = allocations[allocationId];
        if (!allocation.exists || block.timestamp < allocation.startTime + allocation.cliffSeconds || allocation.vestedAmount == 0) {
            return 0;
        }

        uint48 elapsedTime = uint48(block.timestamp) - allocation.startTime; // Safe for long-term vesting
        if (elapsedTime >= allocation.durationSeconds + allocation.cliffSeconds) {
            return allocation.vestedAmount - allocation.releasedVestedAmount;
        }

        uint48 vestingElapsed = elapsedTime - allocation.cliffSeconds;
        // Use Math.mulDiv to avoid precision loss in vesting calculations
        uint256 vestedReleasable = Math.mulDiv(
            allocation.vestedAmount,
            vestingElapsed,
            allocation.durationSeconds,
            Math.Rounding.Floor
        );
        return vestedReleasable - allocation.releasedVestedAmount;
    }

    /// @notice Gets remaining vested and unlocked amounts for an allocation
    /// @param allocationId ID of the allocation
    /// @return remainingVested Remaining vested tokens
    /// @return remainingUnlocked Remaining unlocked tokens
    function getRemainingAmounts(uint256 allocationId) external view returns (uint256 remainingVested, uint256 remainingUnlocked) {
        Allocation storage allocation = allocations[allocationId];
        require(allocation.exists, "Invalid allocation");
        remainingVested = allocation.vestedAmount - allocation.releasedVestedAmount;
        remainingUnlocked = allocation.unlockedAmount - allocation.withdrawnUnlockedAmount;
    }

    /// @notice Gets the total token balance of the contract
    /// @return Total token balance
    function getBalance() external view tokenRequired returns (uint256) {
        address thisContract = address(this);
        return token.balanceOf(thisContract);
    }

    /// @notice Returns the total released tokens (vested and unlocked) across all allocations
    /// @return Total released tokens
    function getTotalReleasedTokens() external view tokenRequired returns (uint256) {
        return totalReleasedTokens;
    }

    /// @notice Pauses the contract
    /// @dev Only callable by the owner (multisig)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract
    /// @dev Only callable by governance (via timelock)
    function unpause() external onlyGovernance {
        _unpause();
    }

    /// @notice Disables upgrades permanently after maturity
    /// @dev Only callable by governance
    function disableUpgrades() external onlyGovernance {
        require(!upgradesDisabled, "Upgrades disabled");
        upgradesDisabled = true;
        emit UpgradesDisabled();
    }

    /// @notice Authorizes contract upgrades
    /// @dev Only callable by governance (via timelock)
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyGovernance {
        require(!upgradesDisabled, "Upgrades disabled");
        emit Upgraded(newImplementation);
    }

    /// @dev Restricts functions to governance (via timelock)
    modifier onlyGovernance() {
        require(msg.sender == timelock, "Caller is not governance");
        _;
    }

    // Gap for future upgrades to avoid storage collisions
    uint256[49] private __gap; // 50 slots reserved, minus one used
}