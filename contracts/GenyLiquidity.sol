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

/// @title GenyLiquidity
/// @author compez.eth
/// @notice Manages liquidity allocation for GENY tokens with simple transfer to liquidity pools.
/// @dev Allocates 16M free and 16M vested GENY tokens (over 24 months) for liquidity pools (e.g., Uniswap V3).
/// Uses nonReentrant, Pausable, and UUPS upgradeability with Ownable2Step for security.
/// @custom:security-contact security@genyleap.com
contract GenyLiquidity is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    IERC20 public token; // GENY token contract
    address public allocationManager; // GenyAllocation for token supply
    uint256 public constant FREE_LIQUIDITY = 16_000_000 * 1e18; // 16M free tokens
    uint256 public constant VESTED_LIQUIDITY = 16_000_000 * 1e18; // 16M vested tokens
    uint48 public constant VESTING_DURATION = 24 * 30 days; // 24 months
    uint48 public vestingStartTime; // Vesting start timestamp
    uint96 public vestedReleased; // Total vested tokens released
    uint96 public totalTransferred; // Total tokens transferred to pools

    /// @notice Emitted when liquidity is added to a pool
    /// @param poolAddress Address of the liquidity pool
    /// @param genyAmount Amount of GENY tokens transferred
    /// @param pairedToken Address of the paired token
    /// @param pairedAmount Amount of paired token transferred
    event LiquidityAdded(address indexed poolAddress, uint96 genyAmount, address indexed pairedToken, uint96 pairedAmount);
    /// @notice Emitted when vested tokens are released
    /// @param amount Amount of vested tokens released
    event VestedTokensReleased(uint96 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the liquidity contract
    /// @param _token Address of the GENY token contract
    /// @param _allocationManager Address of the GenyAllocation contract
    /// @param _owner Address of the initial owner (e.g., multisig)
    function initialize(
        address _token,
        address _allocationManager,
        address _owner
    ) external initializer {
        require(_token != address(0), "Invalid token address");
        require(_allocationManager != address(0), "Invalid allocation manager address");
        require(_owner != address(0), "Invalid owner address");
        require(_allocationManager.code.length > 0, "Allocation manager not a contract");
        __Ownable2Step_init();
        _transferOwnership(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        token = IERC20(_token);
        allocationManager = _allocationManager;
        vestingStartTime = uint48(block.timestamp);
    }

    /// @notice Adds liquidity by transferring GENY and paired tokens to a pool
    /// @param poolAddress Address of the liquidity pool (e.g., Uniswap V3 pool)
    /// @param genyAmount Amount of GENY tokens to transfer
    /// @param pairedToken Address of the paired token (e.g., ETH, USDC)
    /// @param pairedAmount Amount of paired token to transfer
    function addLiquidity(
        address poolAddress,
        uint96 genyAmount,
        address pairedToken,
        uint96 pairedAmount
    ) external onlyOwner nonReentrant whenNotPaused {
        require(poolAddress != address(0), "Invalid pool address");
        require(genyAmount > 0, "Invalid GENY amount");
        require(pairedToken != address(0), "Invalid paired token");
        require(pairedAmount > 0, "Invalid paired amount");
        require(poolAddress.code.length > 0, "Pool not a contract");

        uint256 totalAvailable = FREE_LIQUIDITY + getReleasableVested() - totalTransferred;
        require(totalAvailable >= genyAmount, "Insufficient GENY balance");
        require(token.balanceOf(allocationManager) >= genyAmount, "Insufficient GENY in allocation");
        require(token.allowance(allocationManager, address(this)) >= genyAmount, "Insufficient GENY allowance");
        require(IERC20(pairedToken).balanceOf(owner()) >= pairedAmount, "Insufficient paired token balance");
        require(IERC20(pairedToken).allowance(owner(), address(this)) >= pairedAmount, "Insufficient paired token allowance");

        // Calculate how much of genyAmount comes from vested tokens
        uint256 freeAvailable = FREE_LIQUIDITY > totalTransferred ? FREE_LIQUIDITY - totalTransferred : 0;
        uint96 vestedUsed = freeAvailable >= genyAmount ? 0 : uint96(genyAmount - freeAvailable);
        vestedReleased += vestedUsed; // Update vestedReleased for vested tokens used
        totalTransferred += genyAmount;

        token.safeTransferFrom(allocationManager, poolAddress, genyAmount);
        IERC20(pairedToken).safeTransferFrom(owner(), poolAddress, pairedAmount);
        emit LiquidityAdded(poolAddress, genyAmount, pairedToken, pairedAmount);
    }

    /// @notice Releases vested liquidity tokens
    /// @return amount Amount of tokens released
    function releaseVested() external onlyOwner nonReentrant whenNotPaused returns (uint96 amount) {
        amount = getReleasableVested();
        require(amount > 0, "No tokens to release");
        require(token.balanceOf(allocationManager) >= amount, "Insufficient GENY in allocation");
        require(token.allowance(allocationManager, address(this)) >= amount, "Insufficient GENY allowance");
        vestedReleased += amount;
        token.safeTransferFrom(allocationManager, address(this), amount);
        emit VestedTokensReleased(amount);
    }

    /// @notice Calculates releasable vested tokens
    /// @return amount Amount of vested tokens releasable
    function getReleasableVested() public view returns (uint96 amount) {
        if (block.timestamp < vestingStartTime) return 0;
        uint48 elapsed = uint48(block.timestamp - vestingStartTime);
        if (elapsed >= VESTING_DURATION) {
            amount = uint96(VESTED_LIQUIDITY - vestedReleased);
        } else {
            amount = uint96(Math.mulDiv(VESTED_LIQUIDITY, elapsed, VESTING_DURATION, Math.Rounding.Floor) - vestedReleased);
        }
    }

    /// @notice Gets the total available liquidity (free + releasable vested)
    /// @return totalAvailable Total available tokens
    function getTotalAvailable() external view returns (uint256 totalAvailable) {
        totalAvailable = FREE_LIQUIDITY + getReleasableVested() - totalTransferred;
    }

    /// @notice Gets the contract's current GENY token balance
    /// @return balance Current GENY token balance
    function getContractBalance() external view returns (uint256 balance) {
        balance = token.balanceOf(address(this));
    }

    /// @notice Pauses the contract
    /// @dev Only callable by owner
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract
    /// @dev Only callable by owner
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Authorizes contract upgrades
    /// @param newImplementation Address of the new implementation
    /// @dev Only callable by owner
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}