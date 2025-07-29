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

/// @title GenyTreasury
/// @author compez.eth
/// @notice Manages treasury funds for the Genyleap ecosystem, holding and distributing GENY tokens, with a placeholder for future buyback mechanism.
/// @dev Uses OpenZeppelin upgradeable contracts with Ownable2Step for enhanced security. Includes a placeholder for buyback, to be expanded later via upgrades.
///      The owner must be a multisig contract (e.g., Gnosis Safe) for secure governance.
/// @custom:security-contact security@genyleap.com
contract GenyTreasury is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public token; // GENY token contract
    address public allocation; // GenyAllocation contract address
    address public buybackPool; // Future address to hold bought-back tokens
    uint256 public buybackReserve; // Reserve for future buyback operations

    /// @notice Emitted when tokens are withdrawn from the treasury
    event TokensWithdrawn(address indexed to, uint256 amount);

    /// @notice Emitted when ETH is received for buyback reserve
    event BuybackReserveAdded(uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the treasury contract
    /// @dev The owner must be a multisig contract (e.g., Gnosis Safe) for secure governance.
    /// @param _token Address of the GENY token contract
    /// @param _allocation Address of the GenyAllocation contract
    /// @param _buybackPool Address to hold bought-back tokens (can be updated later)
    /// @param _owner Address of the contract owner (multisig)
    function initialize(address _token, address _allocation, address _buybackPool, address _owner) external initializer {
        require(_token != address(0), "Invalid token");
        require(_allocation != address(0), "Invalid allocation");
        require(_buybackPool != address(0), "Invalid buyback pool");
        require(_owner != address(0), "Invalid owner");

        __Ownable2Step_init();
        if (owner() == address(0)) _transferOwnership(_owner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        if (address(token) == address(0)) token = IERC20(_token);
        if (allocation == address(0)) allocation = _allocation;
        if (buybackPool == address(0)) buybackPool = _buybackPool;
    }

    /// @notice Withdraws tokens from the treasury
    /// @dev Only callable by the owner (multisig)
    /// @param _to Address to receive the tokens
    /// @param _amount Amount of tokens to withdraw
    function withdraw(address _to, uint256 _amount) external onlyOwner nonReentrant whenNotPaused {
        require(_to != address(0), "Invalid recipient");
        require(_amount > 0, "Invalid amount");
        address treasury = address(this);
        require(token.balanceOf(treasury) >= _amount, "Insufficient balance");

        token.safeTransfer(_to, _amount);
        emit TokensWithdrawn(_to, _amount);
    }

    /// @notice Adds ETH to the buyback reserve
    /// @dev Only callable by the owner (multisig). 15% of the amount is reserved for future buyback.
    /// @param _amount Amount of ETH to add to the reserve
    function addBuybackReserve(uint256 _amount) external payable onlyOwner nonReentrant whenNotPaused {
        require(msg.value == _amount, "Invalid ETH amount");
        require(_amount > 0, "Amount must be greater than zero");

        uint256 buybackAmount = (_amount * 1500) / 10000; // 15% of the amount
        buybackReserve += buybackAmount;
        emit BuybackReserveAdded(buybackAmount);
    }

    /// @notice Placeholder for future buyback execution
    /// @dev To be implemented in a future upgrade. Currently does nothing but logs the intent.
    /// @param _ethAmount Amount of ETH to use (placeholder)
    function executeBuyback(uint256 _ethAmount) external onlyOwner nonReentrant whenNotPaused {
        require(_ethAmount <= buybackReserve, "Insufficient buyback reserve");
        require(_ethAmount > 0, "Invalid ETH amount");

        // Placeholder: Future upgrade will implement the actual buyback logic
        buybackReserve -= _ethAmount;
        emit TokensWithdrawn(buybackPool, 0); // Placeholder event, amount will be updated later
    }

    /// @notice Gets the total token balance of the treasury
    /// @return Total token balance
    function getBalance() external view returns (uint256) {
        address treasury = address(this);
        return token.balanceOf(treasury);
    }

    /// @notice Gets the current buyback reserve
    /// @return Current ETH reserve for buyback
    function getBuybackReserve() external view returns (uint256) {
        return buybackReserve;
    }

    /// @notice Allows the contract to receive ETH for buyback reserve
    receive() external payable {
        emit BuybackReserveAdded(msg.value);
    }

    /// @notice Pauses the contract
    /// @dev Only callable by the owner (multisig)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract
    /// @dev Only callable by the owner (multisig)
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Authorizes contract upgrades
    /// @dev Only callable by the owner (multisig)
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
