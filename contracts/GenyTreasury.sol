// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

/// @title GenyTreasury
/// @author compez.eth
/// @notice Manages treasury and DAO funds for Genyleap, with manual burns up to 2.56M tokens.
/// @dev Integrates with GenyDAO for governance. Uses nonReentrant, Pausable, and UUPS upgradeability.
/// @custom:security-contact security@genyleap.com
contract GenyTreasury is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    IERC20Upgradeable public token; // GENY token contract
    address public dao; // GenyDAO contract for governance
    uint96 public constant MAX_BURN = 2_560_000 * 1e18; // 2.56M tokens
    uint96 public totalBurned; // Total tokens burned

    /// @notice Emitted when tokens are burned
    /// @param burner Address that initiated the burn
    /// @param amount Amount of tokens burned
    event TokensBurned(address indexed burner, uint96 amount);
    /// @notice Emitted when tokens are withdrawn
    /// @param recipient Address receiving tokens
    /// @param amount Amount of tokens withdrawn
    event TokensWithdrawn(address indexed recipient, uint96 amount);

    constructor() { _disableInitializers(); }

    /// @notice Initializes the treasury contract
    /// @param _token Address of the GENY token contract
    /// @param _dao Address of the GenyDAO contract
    /// @param _owner Address of the contract owner (DAO multisig)
    function initialize(address _token, address _dao, address _owner) external initializer {
        require(_token != address(0) && _dao != address(0) && _owner != address(0), "Invalid address");

        __Ownable2Step_init();
        _transferOwnership(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        token = IERC20Upgradeable(_token);
        dao = _dao;
    }

    /// @notice Burns tokens (up to 2.56M)
    /// @param _amount Amount to burn
    function burn(uint96 _amount) external onlyDAO nonReentrant whenNotPaused {
        require(_amount > 0, "Amount must be greater than zero");
        require(totalBurned + _amount <= MAX_BURN, "Exceeds max burn limit");
        require(token.balanceOf(address(this)) >= _amount, "Insufficient balance");

        totalBurned += _amount;
        token.safeTransfer(address(0xdead), _amount);
        emit TokensBurned(msg.sender, _amount);
    }

    /// @notice Withdraws tokens to a recipient (DAO decisions)
    /// @param _recipient Recipient address
    /// @param _amount Amount to withdraw
    function withdraw(address _recipient, uint96 _amount) external onlyDAO nonReentrant whenNotPaused {
        require(_recipient != address(0), "Recipient cannot be zero address");
        require(_amount > 0, "Amount must be greater than zero");
        require(token.balanceOf(address(this)) >= _amount, "Insufficient balance");

        token.safeTransfer(_recipient, _amount);
        emit TokensWithdrawn(_recipient, _amount);
    }

    /// @notice Gets the treasury balance
    /// @return balance Treasury balance
    function getBalance() external view returns (uint96 balance) {
        balance = uint96(token.balanceOf(address(this)));
    }

    /// @notice Pauses the contract
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Authorizes contract upgrades
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Restricts functions to DAO
    modifier onlyDAO() {
        require(msg.sender == dao, "Caller is not DAO");
        _;
    }
}