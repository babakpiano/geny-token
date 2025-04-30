// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.29;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title GenyAllocation
/// @author compez.eth
/// @notice Manages multiple token allocations (vested and unlocked) for the Genyleap ecosystem with customizable vesting schedules.
/// @dev Uses OpenZeppelin upgradeable contracts with Ownable2Step for enhanced security. Supports multiple beneficiaries and vesting schedules.
///      All sensitive functions are protected with onlyOwner modifier. UUPS upgradeability is implemented via _authorizeUpgrade.
/// @custom:security-contact security@genyleap.com
contract GenyAllocation is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public token; // GENY token contract

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
    }

    /// @dev Mapping of allocation IDs to Allocation details
    mapping(uint256 allocationId => Allocation) public allocations;
    uint256 public allocationCount; // Total number of allocations
    uint256 public totalAllocated; // Total tokens allocated (vested + unlocked)

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

    /// @notice Emitted when total allocated amount changes
    event TotalAllocatedUpdated(uint256 indexed oldTotal, uint256 indexed newTotal);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the allocation contract
    /// @param _token Address of the GENY token contract
    /// @param _owner Address of the contract owner (e.g., multisig)
    /// @dev Sets up ownership with Ownable2Step, initializes UUPS, ReentrancyGuard, and Pausable
    function initialize(address _token, address _owner) external initializer {
        require(_token != address(0), "Invalid token");
        require(_owner != address(0), "Invalid owner");

        __Ownable2Step_init();
        _transferOwnership(_owner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        token = IERC20(_token);
        allocationCount = 1; // Start from 1 to avoid zero-to-one storage writes
    }

    /// @notice Creates a new allocation
    /// @param _beneficiary Address to receive tokens
    /// @param _vestedAmount Total vested tokens
    /// @param _unlockedAmount Total unlocked tokens
    /// @param _cliffSeconds Cliff period in seconds
    /// @param _durationSeconds Total vesting duration in seconds
    /// @param _intervalSeconds Release interval in seconds
    /// @dev Only callable by the owner. Uses nonReentrant to prevent reentrancy attacks.
    function createAllocation(
        address _beneficiary,
        uint96 _vestedAmount,
        uint96 _unlockedAmount,
        uint48 _cliffSeconds,
        uint48 _durationSeconds,
        uint48 _intervalSeconds
    ) external onlyOwner nonReentrant whenNotPaused payable {
        require(_beneficiary != address(0), "Invalid beneficiary");
        require(_vestedAmount + _unlockedAmount != 0, "No tokens");
        require(_durationSeconds > _cliffSeconds, "Invalid duration");
        require(_intervalSeconds != 0, "Invalid interval");
        require(_intervalSeconds < _durationSeconds, "Invalid interval");
        require(_durationSeconds < 10 * 365 days, "Duration too long");

        address thisContract = address(this);
        require(totalAllocated + _vestedAmount + _unlockedAmount <= token.balanceOf(thisContract), "Insufficient balance");

        uint256 allocationId = allocationCount;
        allocationCount = allocationId + 1;

        Allocation storage allocation = allocations[allocationId];
        allocation.beneficiary = _beneficiary;
        allocation.vestedAmount = _vestedAmount;
        allocation.unlockedAmount = _unlockedAmount;
        allocation.startTime = uint48(block.timestamp);
        allocation.cliffSeconds = _cliffSeconds;
        allocation.durationSeconds = _durationSeconds;
        allocation.intervalSeconds = _intervalSeconds;

        uint256 oldTotal = totalAllocated;
        totalAllocated = totalAllocated + _vestedAmount + _unlockedAmount;
        emit TotalAllocatedUpdated(oldTotal, totalAllocated);

        emit AllocationCreated(
            allocationId,
            _beneficiary,
            _vestedAmount,
            _unlockedAmount,
            _cliffSeconds,
            _durationSeconds,
            _intervalSeconds
        );
    }

    /// @notice Releases vested tokens for a specific allocation
    /// @param _allocationId ID of the allocation
    /// @dev Public function to allow anyone to release vested tokens after the cliff period. Uses nonReentrant.
    function releaseVested(uint256 _allocationId) external nonReentrant whenNotPaused {
        Allocation storage allocation = allocations[_allocationId];
        require(allocation.beneficiary != address(0), "Invalid allocation");
        require(block.timestamp >= allocation.startTime + allocation.cliffSeconds, "Cliff not reached");

        uint96 releasable = uint96(getReleasableVestedAmount(_allocationId));
        require(releasable != 0, "No tokens to release");

        allocation.releasedVestedAmount = allocation.releasedVestedAmount + releasable;
        token.safeTransfer(allocation.beneficiary, releasable);
        emit VestedTokensReleased(_allocationId, allocation.beneficiary, releasable);
    }

    /// @notice Withdraws unlocked tokens for a specific allocation
    /// @param _allocationId ID of the allocation
    /// @param _amount Amount to withdraw
    /// @dev Only callable by the owner. Uses nonReentrant.
    function withdrawUnlocked(uint256 _allocationId, uint96 _amount) external onlyOwner nonReentrant whenNotPaused payable {
        Allocation storage allocation = allocations[_allocationId];
        require(allocation.beneficiary != address(0), "Invalid allocation");
        require(_amount != 0, "Invalid amount");
        require(_amount <= allocation.unlockedAmount - allocation.withdrawnUnlockedAmount, "Insufficient balance");

        allocation.withdrawnUnlockedAmount = allocation.withdrawnUnlockedAmount + _amount;
        token.safeTransfer(allocation.beneficiary, _amount);
        emit UnlockedTokensWithdrawn(_allocationId, allocation.beneficiary, _amount);
    }

    /// @notice Updates the beneficiary for a specific allocation
    /// @param _allocationId ID of the allocation
    /// @param _newBeneficiary New beneficiary address
    /// @dev Only callable by the owner
    function updateBeneficiary(uint256 _allocationId, address _newBeneficiary) external onlyOwner payable {
        Allocation storage allocation = allocations[_allocationId];
        require(allocation.beneficiary != address(0), "Invalid allocation");
        require(_newBeneficiary != address(0), "Invalid beneficiary");
        require(_newBeneficiary != allocation.beneficiary, "Same beneficiary");

        address oldBeneficiary = allocation.beneficiary;
        allocation.beneficiary = _newBeneficiary;
        emit BeneficiaryUpdated(_allocationId, oldBeneficiary, _newBeneficiary);
    }

    /// @notice Calculates the releasable vested amount for an allocation
    /// @param _allocationId ID of the allocation
    /// @return Amount of vested tokens that can be released
    function getReleasableVestedAmount(uint256 _allocationId) public view returns (uint256) {
        Allocation storage allocation = allocations[_allocationId];
        if (allocation.beneficiary == address(0) || block.timestamp < allocation.startTime + allocation.cliffSeconds) {
            return 0;
        }

        uint48 elapsedTime = uint48(block.timestamp) - allocation.startTime;
        if (elapsedTime >= allocation.durationSeconds) {
            return allocation.vestedAmount - allocation.releasedVestedAmount;
        }

        uint48 intervalsPassed = elapsedTime / allocation.intervalSeconds;
        uint256 vestedReleasable = (allocation.vestedAmount * intervalsPassed * allocation.intervalSeconds) / allocation.durationSeconds;
        return vestedReleasable - allocation.releasedVestedAmount;
    }

    /// @notice Gets remaining vested and unlocked amounts for an allocation
    /// @param _allocationId ID of the allocation
    /// @return remainingVested Remaining vested tokens
    /// @return remainingUnlocked Remaining unlocked tokens
    function getRemainingAmounts(uint256 _allocationId) external view returns (uint256 remainingVested, uint256 remainingUnlocked) {
        Allocation storage allocation = allocations[_allocationId];
        require(allocation.beneficiary != address(0), "Invalid allocation");
        remainingVested = allocation.vestedAmount - allocation.releasedVestedAmount;
        remainingUnlocked = allocation.unlockedAmount - allocation.withdrawnUnlockedAmount;
    }

    /// @notice Gets the total token balance of the contract
    /// @return Total token balance
    function getBalance() external view returns (uint256) {
        address thisContract = address(this);
        return token.balanceOf(thisContract);
    }

    /// @notice Pauses the contract
    /// @dev Only callable by the owner
    function pause() external onlyOwner payable {
        _pause();
    }

    /// @notice Unpauses the contract
    /// @dev Only callable by the owner
    function unpause() external onlyOwner payable {
        _unpause();
    }

    /// @notice Authorizes contract upgrades
    /// @param newImplementation Address of the new implementation
    /// @dev Only callable by the owner. Required for UUPS upgradeability.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}