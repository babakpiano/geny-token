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
contract GenyBurnManager is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    IERC20 public token;              // GENY token contract (must support ERC20Burnable)
    address public dao;               // GenyDAO contract
    address public allocationManager; // GenyAllocation contract (token source)

    uint48 public lastBurnTimestamp;  // Last burn timestamp
    uint256 public burnCount;         // Number of burns performed
    uint256 public totalBurned;       // Total tokens burned

    uint256 public constant MAX_TOTAL_BURN = 25_600_000 * 1e18; // Max 25.6M tokens to burn overall
    uint48  public constant BURN_COOLDOWN = 1 days;              // 1-day cooldown between burns
    uint32  public constant BURN_MAX_PERCENT = 10_00;            // Max 10% of allocationManager balance per burn (1000 = 10%)

    /// @notice Emitted when tokens are burned
    event TokensBurned(uint256 indexed burnId, uint256 amount);

    /// @notice Emitted when DAO address is updated
    event DAOUpdated(address indexed oldDAO, address indexed newDAO);

    /// @notice Emitted when AllocationManager address is updated
    event AllocationManagerUpdated(address indexed oldAllocationManager, address indexed newAllocationManager);

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

    /// @notice Burns tokens from the allocationManager (transferFrom -> burn)
    /// @param amount Requested amount to burn; must be <= 10% of allocationManager balance.
    /// @dev If the token has transfer fees, the actually received amount is burned and accounted.
    function burnFromContract(uint256 amount) external onlyOwnerOrDAO nonReentrant whenNotPaused {
        require(block.timestamp >= lastBurnTimestamp + BURN_COOLDOWN, "Burn cooldown active");
        require(amount > 0, "Invalid amount");

        uint256 maxBurn = (token.balanceOf(allocationManager) * BURN_MAX_PERCENT) / 1e4;
        require(amount <= maxBurn, "Exceeds max burn limit");
        require(totalBurned + amount <= MAX_TOTAL_BURN, "Exceeds total burn cap");
        require(token.allowance(allocationManager, address(this)) >= amount, "Insufficient allowance");

        // Pull tokens from allocationManager
        uint256 beforeBal = token.balanceOf(address(this));
        token.safeTransferFrom(allocationManager, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - beforeBal;
        require(received > 0, "No tokens received");

        // Burn actual received amount
        ERC20Burnable(address(token)).burn(received);

        lastBurnTimestamp = uint48(block.timestamp);
        totalBurned += received;

        emit TokensBurned(burnCount++, received);
    }

    /// @notice Updates the DAO address
    function setDAO(address _dao) external onlyOwner {
        require(_dao != address(0), "Invalid DAO");
        emit DAOUpdated(dao, _dao);
        dao = _dao;
    }

    /// @notice Updates the AllocationManager address
    function setAllocationManager(address _am) external onlyOwner {
        require(_am != address(0), "Invalid allocation manager");
        emit AllocationManagerUpdated(allocationManager, _am);
        allocationManager = _am;
    }

    /// @notice Pauses the contract, preventing burns
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, allowing burns
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Restricts functions to owner or DAO contract
    modifier onlyOwnerOrDAO() {
        require(msg.sender == owner() || msg.sender == dao, "Not authorized");
        _;
    }

    /// @dev Authorizes contract upgrades (UUPS)
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Storage gap for future variable additions (OZ pattern).
    /// If you add new state variables at the end in a future upgrade,
    /// decrease the length of this array by the same number of slots.
    uint256[50] private __gap;
}
