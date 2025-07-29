// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.30;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title GenyBurnManager
/// @author compez.eth
/// @notice Manages the burning of GENY tokens with cooldowns and limits.
/// @dev Burns tokens from the allocationManager, with a max burn of 25.6M tokens, 10% per burn, and a 1-day cooldown.
///      Uses UUPS upgradeability, Ownable2Step, ReentrancyGuard, and Pausable for security.
///      Assumes GENY token implements ERC20Burnable for burning.
/// @custom:security-contact security@genyleap.com
contract GenyBurnManager is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    IERC20 public token;                   ///< GENY token contract (ERC20Burnable)
    address public dao;                    ///< GenyDAO contract for governance
    address public allocationManager;      ///< GenyAllocation contract (token supply source)
    uint48 public lastBurnTimestamp;       ///< Last burn timestamp
    uint256 public burnCount;              ///< Number of burns performed
    uint256 public totalBurned;            ///< Total tokens burned

    uint256 public constant MAX_TOTAL_BURN = 25_600_000 * 1e18; ///< Max 25.6M tokens to burn
    uint48  public constant BURN_COOLDOWN = 1 days;              ///< 1-day cooldown between burns
    uint32  public constant BURN_MAX_PERCENT = 10_00;            ///< Max 10% of allocationManager balance per burn (1000 = 10%)

    /// @notice Emitted when tokens are burned
    event TokensBurned(uint256 indexed burnId, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the burn manager contract
    /// @param _token Address of the GENY token contract
    /// @param _dao Address of the GenyDAO contract
    /// @param _allocationManager Address of the GenyAllocation contract
    /// @param _owner Address of the initial owner (e.g., multisig)
    function initialize(
        address _token,
        address _dao,
        address _allocationManager,
        address _owner
    ) external initializer {
        require(_token != address(0), "Invalid token address");
        require(_dao != address(0), "Invalid DAO address");
        require(_allocationManager != address(0), "Invalid allocation manager address");
        require(_owner != address(0), "Invalid owner address");

        __Ownable2Step_init();
        _transferOwnership(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        token = IERC20(_token);
        dao = _dao;
        allocationManager = _allocationManager;
        burnCount = 1;
    }

    /// @notice Burns tokens from the allocationManager (via transfer & burn)
    /// @param amount Amount of tokens to burn (must not exceed 10% allocationManager balance)
    function burnFromContract(uint256 amount) external onlyOwnerOrDAO nonReentrant whenNotPaused {
        require(block.timestamp >= lastBurnTimestamp + BURN_COOLDOWN, "Burn cooldown active");
        uint256 maxBurn = (token.balanceOf(allocationManager) * BURN_MAX_PERCENT) / 1e4;
        require(amount <= maxBurn, "Exceeds max burn limit");
        require(totalBurned + amount <= MAX_TOTAL_BURN, "Exceeds total burn cap");
        require(amount > 0, "Invalid amount");
        require(token.allowance(allocationManager, address(this)) >= amount, "Insufficient allowance");

        lastBurnTimestamp = uint48(block.timestamp);
        totalBurned += amount;

        token.safeTransferFrom(allocationManager, address(this), amount);
        ERC20Burnable(address(token)).burn(amount);

        emit TokensBurned(burnCount++, amount);
    }

    /// @notice Pauses the contract, preventing burns
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, allowing burns
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Authorizes contract upgrades (UUPS)
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Restricts functions to owner or DAO contract
    modifier onlyOwnerOrDAO() {
        require(msg.sender == owner() || msg.sender == dao, "Not authorized");
        _;
    }
}
